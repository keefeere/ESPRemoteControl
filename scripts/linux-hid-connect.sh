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

adapter="hci0"
device=""
name_filter=""
watch=0
interval=5
drop_audio=0
trust=0
status_only=0

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

is_linked() {
  device_info "$1" | grep -qi '^[[:space:]]*Connected:[[:space:]]*yes'
}

# A connected ACL link is not yet a keyboard. BlueZ's HoG plugin creates a HID
# device whose HID_UNIQ is the peer address once the profile is actually up.
has_hid_device() {
  local mac
  mac="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  local uevent
  for uevent in /sys/bus/hid/devices/*/uevent; do
    [ -r "$uevent" ] || continue
    if grep -qi "^HID_UNIQ=$mac\$" "$uevent"; then return 0; fi
  done
  return 1
}

paired_devices() {
  # "devices Paired" exists in current BlueZ; paired-devices is the older name.
  bluetoothctl devices Paired 2>/dev/null | awk '$1 == "Device" { print $2 }' \
    || bluetoothctl paired-devices 2>/dev/null | awk '$1 == "Device" { print $2 }'
}

resolve_device() {
  local candidates=() mac
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
  done < <(paired_devices)

  case "${#candidates[@]}" in
    1) printf '%s' "${candidates[0]}" ;;
    0) die "no paired device offers the HID service. Pair the iPhone first, with pairing open in the app." ;;
    *)
      printf 'several paired devices offer HID; choose one with --device:\n' >&2
      for mac in "${candidates[@]}"; do
        printf '  %s  %s\n' "$mac" "$(device_name "$mac")" >&2
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

connect_hid() {
  local mac="$1"
  if has_hid_device "$mac"; then
    if [ "$drop_audio" -eq 1 ]; then drop_audio_profiles "$mac"; fi
    return 0
  fi
  profile_call connect "$mac" "$HID_UUID" || true
  # ConnectProfile returns before the HoG plugin has attached the input device.
  local waited=0
  while [ "$waited" -lt 10 ]; do
    has_hid_device "$mac" && break
    sleep 1
    waited=$((waited + 1))
  done
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
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

require bluetoothctl
[ -n "$device" ] || device="$(resolve_device)"
device="$(printf '%s' "$device" | tr 'a-z' 'A-Z')"
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
