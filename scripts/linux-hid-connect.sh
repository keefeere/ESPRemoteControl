#!/usr/bin/env bash
# Connect only the HID-over-GATT profile of a paired iPhone running ESP Remote
# Control in direct Bluetooth mode.
#
# A desktop "Connect" button calls BlueZ's generic Connect(), which brings up
# every eligible profile of a bonded device. Pairing the BLE keyboard creates a
# bond with the whole phone, so that generic call also connects the iPhone's
# audio profiles and moves phone audio to the computer. ConnectProfile() takes a
# single service UUID instead, which is what this script uses.
#
# The iPhone cannot start this connection itself: it publishes the HID service
# as a BLE peripheral, and a BlueZ desktop does not advertise over BLE, so it
# never appears in the app's computer search. The computer always initiates.
set -euo pipefail

HID_UUID="00001812-0000-1000-8000-00805f9b34fb"
# iPhone-side audio and phonebook services that a generic Connect() also brings
# up. Only ever disconnected, never connected, by this script.
AUDIO_UUIDS=(
  "0000110a-0000-1000-8000-00805f9b34fb" # A2DP source
  "0000110c-0000-1000-8000-00805f9b34fb" # AVRCP target
  "0000110e-0000-1000-8000-00805f9b34fb" # AVRCP controller
  "0000111f-0000-1000-8000-00805f9b34fb" # Hands-free audio gateway
  "00001112-0000-1000-8000-00805f9b34fb" # Headset audio gateway
)
# A keyboard or a mouse offers HID and little else. A phone also carries these,
# which is what separates the device running the app from the other HID devices
# already paired with this computer.
PHONE_UUIDS=(
  "${AUDIO_UUIDS[@]}"
  "0000112f-0000-1000-8000-00805f9b34fb" # Phone Book Access server
  "00001132-0000-1000-8000-00805f9b34fb" # Message Access server
)

adapter="hci0"
device=""
name_filter=""
watch=0
interval=5
drop_audio=0
trust=0
status_only=0
debug_only=0

usage() {
  cat <<'USAGE'
Usage: linux-hid-connect.sh [options]

  -d, --device <MAC>     Paired iPhone address (AA:BB:CC:DD:EE:FF).
  -n, --name <text>      Pick a paired device whose name contains <text>.
  -a, --adapter <hciN>   Bluetooth adapter to use (default: hci0).
  -w, --watch [seconds]  Keep the HID profile connected, polling every
                         <seconds> (default: 5). Runs until interrupted.
      --drop-audio       Disconnect iPhone audio profiles if something else
                         connected them.
      --trust            Mark the device trusted so BlueZ accepts its
                         reconnects without a desktop prompt.
      --status           Print the current state and exit.
      --debug            Print paired devices, the target, and every HID
                         device the kernel exposes, then exit.
  -h, --help             Show this help.

With no -d/-n, the only paired device advertising the HID service is used.

Examples:
  linux-hid-connect.sh --trust                 # one-off HID-only connect
  linux-hid-connect.sh --watch --drop-audio    # keep HID up, keep audio away
USAGE
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

# BlueZ 5.65 added the optional UUID argument to bluetoothctl's connect and
# disconnect commands. Older builds silently ignore it and connect everything,
# which is exactly the behaviour this script exists to avoid.
uuid_capable=""
bluetoothctl_takes_uuid() {
  if [ -z "$uuid_capable" ]; then
    local version major minor
    version="$(bluetoothctl --version 2>/dev/null | tr -cd '0-9.\n' | head -n1)"
    major="${version%%.*}"
    minor="${version#*.}"
    minor="${minor%%.*}"
    uuid_capable="no"
    if [ -n "$version" ] && [ "${major:-0}" -ge 5 ]; then
      if [ "${major:-0}" -gt 5 ] || [ "${minor:-0}" -ge 65 ]; then uuid_capable="yes"; fi
    fi
  fi
  [ "$uuid_capable" = "yes" ]
}

dbus_path() {
  printf '/org/bluez/%s/dev_%s' "$adapter" "${1//:/_}"
}

# One remote service UUID, connected or disconnected on its own. bluetoothctl is
# preferred because it ships with BlueZ itself; busctl and dbus-send cover older
# builds whose bluetoothctl cannot address a single profile.
profile_call() {
  local action="$1" mac="$2" uuid="$3"
  if bluetoothctl_takes_uuid; then
    bluetoothctl "$action" "$mac" "$uuid" >/dev/null 2>&1
  elif command -v busctl >/dev/null 2>&1; then
    local method="ConnectProfile"
    [ "$action" = "disconnect" ] && method="DisconnectProfile"
    busctl call org.bluez "$(dbus_path "$mac")" org.bluez.Device1 \
      "$method" s "$uuid" >/dev/null 2>&1
  elif command -v dbus-send >/dev/null 2>&1; then
    local method="ConnectProfile"
    [ "$action" = "disconnect" ] && method="DisconnectProfile"
    dbus-send --system --print-reply --dest=org.bluez \
      "$(dbus_path "$mac")" "org.bluez.Device1.$method" \
      "string:$uuid" >/dev/null 2>&1
  else
    die "no way to address a single profile: need bluetoothctl 5.65+, busctl, or dbus-send"
  fi
}

device_info() {
  bluetoothctl info "$1" 2>/dev/null || true
}

device_name() {
  device_info "$1" | awk -F': ' '/^[[:space:]]*Name:/ { print $2; exit }'
}

has_hid_service() {
  device_info "$1" | grep -qi "$HID_UUID"
}

is_phone_like() {
  local info uuid
  info="$(device_info "$1")"
  for uuid in "${PHONE_UUIDS[@]}"; do
    printf '%s' "$info" | grep -qi "$uuid" && return 0
  done
  return 1
}

is_linked() {
  device_info "$1" | grep -qi '^[[:space:]]*Connected:[[:space:]]*yes'
}

# A connected ACL link is not yet a keyboard. Once the HoG profile attaches, a
# HID device appears carrying the peer address. Which key holds it varies with
# the kernel and BlueZ version — usually HID_UNIQ, sometimes only inside
# HID_PHYS or the device path — so match the address anywhere in the uevent
# rather than on one exact key. An address string is specific enough that a
# false positive is not a practical concern, and the local adapter has a
# different one.
has_hid_device() {
  local mac name uevent hid_name
  mac="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  name="$(device_name "$1")"
  if [ ! -d /sys/bus/hid/devices ]; then
    # Nothing to inspect on this kernel; the link state is the only signal.
    is_linked "$1"
    return
  fi
  for uevent in /sys/bus/hid/devices/*/uevent; do
    [ -r "$uevent" ] || continue
    grep -qi "$mac" "$uevent" && return 0
    # iOS advertises with a rotating private address, so the address BlueZ
    # stored at bonding and the one the kernel recorded for the HID device
    # need not be the same string. The name does not rotate, and the app
    # advertises a fixed one, so match on that too.
    hid_name="$(sed -n 's/^HID_NAME=//p' "$uevent" | head -n1)"
    [ -n "$hid_name" ] || continue
    [ -n "$name" ] && [ "$hid_name" = "$name" ] && return 0
    case "$hid_name" in *"ESP Remote"*) return 0 ;; esac
  done
  return 1
}

# Everything needed to tell "the profile did not attach" apart from "the script
# cannot see that it did". Report this when the phone says HID is ready and the
# computer disagrees.
dump_debug() {
  local mac="${1:-}" uevent
  printf '== paired devices ==\n'
  paired_devices | while read -r peer; do
    [ -n "$peer" ] || continue
    printf '  %s  %s%s%s\n' "$peer" "$(device_name "$peer")" \
      "$(has_hid_service "$peer" && echo '  [hid]' || echo '')" \
      "$(is_phone_like "$peer" && echo '  [phone-like]' || echo '')"
  done
  if [ -n "$mac" ]; then
    printf '== target %s ==\n' "$mac"
    device_info "$mac" | sed 's/^/  /'
  else
    printf '== target ==\n  not resolved; pass --device or --name\n'
  fi
  printf '== HID devices ==\n'
  if [ ! -d /sys/bus/hid/devices ]; then
    printf '  no /sys/bus/hid/devices on this kernel\n'
  else
    local found=0
    for uevent in /sys/bus/hid/devices/*/uevent; do
      [ -r "$uevent" ] || continue
      found=1
      printf '  %s\n' "$uevent"
      grep -E '^(HID_NAME|HID_PHYS|HID_UNIQ|HID_ID)=' "$uevent" | sed 's/^/    /'
    done
    # An empty list and an unreadable one look the same otherwise, and they
    # mean different things: nothing attached versus nothing to inspect.
    [ "$found" -eq 1 ] || printf '  none attached\n'
  fi
  printf '== bluetoothctl ==\n'
  printf '  version: %s\n' "$(bluetoothctl --version 2>/dev/null || echo unknown)"
  printf '  single-profile connect: %s\n' "$(bluetoothctl_takes_uuid && echo bluetoothctl || echo dbus)"
}

paired_devices() {
  # "devices Paired" exists in current BlueZ; older builds print usage for it
  # and expect "paired-devices" instead, so fall back on empty output rather
  # than on the exit status, which those builds still report as success.
  local found=""
  found="$(bluetoothctl devices Paired 2>/dev/null | awk '$1 == "Device" { print $2 }')" || true
  if [ -z "$found" ]; then
    found="$(bluetoothctl paired-devices 2>/dev/null | awk '$1 == "Device" { print $2 }')" || true
  fi
  [ -n "$found" ] && printf '%s\n' "$found"
  return 0
}

resolve_device() {
  local candidates=() phones=() mac
  while read -r mac; do
    [ -n "$mac" ] || continue
    has_hid_service "$mac" || continue
    if [ -n "$name_filter" ]; then
      case "$(device_name "$mac")" in
        *"$name_filter"*) ;;
        *) continue ;;
      esac
    fi
    candidates+=("$mac")
    if is_phone_like "$mac"; then phones+=("$mac"); fi
  done < <(paired_devices)

  # A computer with keyboards and mice already paired has several HID devices,
  # so narrow to the one that also looks like a phone before giving up.
  if [ "${#phones[@]}" -eq 1 ]; then
    printf '%s' "${phones[0]}"
    return 0
  fi

  case "${#candidates[@]}" in
    1) printf '%s' "${candidates[0]}" ;;
    0) die "no paired device offers the HID service. Pair the iPhone first, with pairing open in the app." ;;
    *)
      printf 'several paired devices could be the phone; choose one with --device or --name:\n' >&2
      for mac in "${candidates[@]}"; do
        printf '  %s  %s%s\n' "$mac" "$(device_name "$mac")" \
          "$(is_phone_like "$mac" && echo '  [phone-like]' || echo '')" >&2
      done
      exit 1
      ;;
  esac
}

report() {
  local mac="$1"
  printf '%s (%s): link %s, keyboard %s\n' \
    "$(device_name "$mac")" "$mac" \
    "$(is_linked "$mac" && echo up || echo down)" \
    "$(has_hid_device "$mac" && echo up || echo down)"
}

drop_audio_profiles() {
  local mac="$1" uuid
  for uuid in "${AUDIO_UUIDS[@]}"; do
    device_info "$mac" | grep -qi "$uuid" || continue
    profile_call disconnect "$mac" "$uuid" || true
  done
}

# ConnectProfile returns before the HoG plugin has attached the input device.
await_hid_device() {
  local mac="$1" waited=0
  while [ "$waited" -lt "${2:-10}" ]; do
    has_hid_device "$mac" && return 0
    sleep 1
    waited=$((waited + 1))
  done
  has_hid_device "$mac"
}

connect_hid() {
  local mac="$1"
  if has_hid_device "$mac"; then
    if [ "$drop_audio" -eq 1 ]; then drop_audio_profiles "$mac"; fi
    return 0
  fi

  profile_call connect "$mac" "$HID_UUID" || true
  if await_hid_device "$mac"; then
    if [ "$drop_audio" -eq 1 ]; then drop_audio_profiles "$mac"; fi
    return 0
  fi

  # BlueZ answers ConnectProfile with "already connected" while holding a link
  # whose HoG attachment is gone — the state left behind when the phone moves
  # its HID session to another computer and back. Only dropping the whole link
  # makes it redo pairing-free reconnection and reattach the profile.
  printf 'HID did not attach; dropping the link and retrying\n' >&2
  bluetoothctl disconnect "$mac" >/dev/null 2>&1 || true
  sleep 2
  profile_call connect "$mac" "$HID_UUID" || true
  await_hid_device "$mac" 15
  if [ "$drop_audio" -eq 1 ]; then drop_audio_profiles "$mac"; fi
  has_hid_device "$mac"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--device) device="${2:-}"; shift 2 ;;
    -n|--name) name_filter="${2:-}"; shift 2 ;;
    -a|--adapter) adapter="${2:-}"; shift 2 ;;
    -w|--watch)
      watch=1
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then interval="$2"; shift; fi
      shift
      ;;
    --drop-audio) drop_audio=1; shift ;;
    --trust) trust=1; shift ;;
    --status) status_only=1; shift ;;
    --debug) debug_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

require bluetoothctl
if [ -z "$device" ]; then
  # Debugging must still report what it can when the target is ambiguous.
  if [ "$debug_only" -eq 1 ]; then
    device="$(resolve_device || true)"
  else
    device="$(resolve_device)"
  fi
fi
device="$(printf '%s' "$device" | tr 'a-z' 'A-Z')"

if [ "$debug_only" -eq 1 ]; then
  [ -n "$device" ] && report "$device"
  dump_debug "$device"
  exit 0
fi

has_hid_service "$device" \
  || die "$device is not paired or does not offer the HID service"

if [ "$status_only" -eq 1 ]; then
  report "$device"
  exit 0
fi

if [ "$trust" -eq 1 ]; then
  bluetoothctl trust "$device" >/dev/null 2>&1 \
    || printf 'warning: could not mark %s trusted\n' "$device" >&2
fi

if [ "$watch" -eq 0 ]; then
  if connect_hid "$device"; then
    report "$device"
    exit 0
  fi
  report "$device"
  printf 'run with --debug and share the output if the phone reports HID ready\n' >&2
  die "the HID profile did not come up. Open ESP Remote Control on the iPhone with direct Bluetooth selected, then retry."
fi

printf 'watching %s every %ss; press Ctrl+C to stop\n' "$device" "$interval"
previous=""
while :; do
  if has_hid_device "$device"; then
    current="up"
  else
    connect_hid "$device" >/dev/null 2>&1 || true
    if has_hid_device "$device"; then current="up"; else current="down"; fi
  fi
  if [ "$current" != "$previous" ]; then
    printf '%s  keyboard %s\n' "$(date '+%H:%M:%S')" "$current"
    previous="$current"
  fi
  sleep "$interval"
done
