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
why_only=0
install_service=0
uninstall_service=0

usage() {
  cat <<'USAGE'
Usage: linux-hid-connect.sh [options]

  -d, --device <MAC>     Paired iPhone address (AA:BB:CC:DD:EE:FF).
  -n, --name <text>      Pick a paired device whose name contains <text>.
  -a, --adapter <hciN>   Bluetooth adapter to use (default: hci0).
  -w, --watch [seconds]  Keep the HID profile connected, polling every
                         <seconds> (default: 5). Runs until interrupted.
      --drop-audio       Disconnect iPhone audio profiles that something else
                         already connected. Recovery only; see the note below.
      --trust            Mark the device trusted so BlueZ accepts its
                         reconnects without a desktop prompt.
      --status           Print the current state and exit.
      --debug            Print paired devices, the target, and every HID
                         device the kernel exposes, then exit.
      --why              Check everything on this computer that can stop it
                         from reconnecting to the phone by itself, then exit.
                         Run with sudo to include the bonding keys.
      --install          Install a user service that reconnects HID after
                         login/wake and permanently hides this phone from
                         WirePlumber audio routing. Implies --trust.
      --uninstall        Remove that service and its WirePlumber rule.
  -h, --help             Show this help.

With no -d/-n, the paired device that offers HID and also looks like a phone
is used; several candidates are listed instead of guessed.

--drop-audio only disconnects audio profiles that already connected, and by
then the phone has lost audio focus. Prefer preventing the capture: never use
the desktop applet's Connect, and disable the device in your audio stack.

Examples:
  linux-hid-connect.sh --trust     # one-off HID-only connect
  linux-hid-connect.sh --watch     # keep the HID profile connected
  linux-hid-connect.sh --debug     # what is paired and what the kernel sees
  sudo linux-hid-connect.sh --why  # why this computer is not reconnecting
  linux-hid-connect.sh --install   # persistent HID-only connection
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

  if [ "${#candidates[@]}" -eq 0 ]; then
    die "no paired device offers the HID service. Pair the iPhone first, with pairing open in the app."
  fi

  # Naming a keyboard or a mouse as a candidate for the phone is worse than
  # saying nothing: it sends people to --device with the wrong address. When
  # nothing looks like a phone, the bond is most likely gone.
  if [ "${#phones[@]}" -eq 0 ]; then
    printf 'no paired device looks like the phone. These offer HID but look like keyboards or mice:\n' >&2
    for mac in "${candidates[@]}"; do
      printf '  %s  %s\n' "$mac" "$(device_name "$mac")" >&2
    done
    printf '\nIf the iPhone was paired here before, its bond or its cached HID service is gone.\n' >&2
    printf 'Check with:  bluetoothctl devices Paired\n' >&2
    printf 'Then pair again with pairing open in the app, or force this address with --device.\n' >&2
    exit 1
  fi

  if [ "${#candidates[@]}" -eq 1 ]; then
    printf '%s' "${candidates[0]}"
    return 0
  fi

  printf 'several paired devices look like the phone; choose one with --device or --name:\n' >&2
  for mac in "${candidates[@]}"; do
    printf '  %s  %s%s\n' "$mac" "$(device_name "$mac")" \
      "$(is_phone_like "$mac" && echo '  [phone-like]' || echo '')" >&2
  done
  exit 1
}

# A BLE keyboard is ready the instant you switch it on because the device only
# has to advertise while the computer keeps a connect request pending for it.
# The phone's half is not something this script can see; this is everything on
# *this* computer that can stop its half, in the order it tends to break.
verdict() {
  case "$1" in
    ok) printf '  [ ok ] %s\n' "$2" ;;
    bad) printf '  [FAIL] %s\n' "$2" ;;
    *) printf '  [ ?? ] %s\n' "$2" ;;
  esac
}

info_says() {
  printf '%s' "$2" | grep -qiE "^[[:space:]]*$1:[[:space:]]*yes"
}

bond_dir() {
  local mac="$1" adapter_mac
  adapter_mac="$(bluetoothctl show "$adapter" 2>/dev/null \
    | awk '/^Controller /{ print $2; exit }')"
  [ -n "$adapter_mac" ] || return 1
  printf '/var/lib/bluetooth/%s/%s' "$adapter_mac" "$mac"
}

why_not_reconnecting() {
  local mac="$1" info dir
  info="$(device_info "$mac")"

  printf '== what can stop this computer from reconnecting on its own ==\n'

  if bluetoothctl show "$adapter" 2>/dev/null | grep -qiE '^[[:space:]]*Powered:[[:space:]]*yes'; then
    verdict ok "adapter $adapter is powered"
  else
    verdict bad "adapter $adapter is off — nothing scans, nothing reconnects"
  fi

  if info_says Paired "$info"; then
    verdict ok "device is paired"
  else
    verdict bad "device is not paired — pair it in the desktop applet first"
  fi

  if info_says Blocked "$info"; then
    verdict bad "device is BLOCKED — run: bluetoothctl unblock $mac"
  else
    verdict ok "device is not blocked"
  fi

  # Without Trusted, BlueZ asks a human before accepting an incoming link, and
  # on a headless or locked session nobody answers, so the attempt dies.
  if info_says Trusted "$info"; then
    verdict ok "device is trusted"
  else
    verdict bad "device is NOT trusted — run: bluetoothctl trust $mac (or --trust)"
  fi

  if has_hid_service "$mac"; then
    verdict ok "device offers the HID service"
  else
    verdict bad "device does not offer HID — the phone is not in direct mode, or the bond predates it"
  fi

  # iOS advertises with a rotating resolvable private address. Without the
  # Identity Resolving Key from bonding, this computer cannot tell that any of
  # those addresses is the phone, so its connect request never matches and it
  # waits forever on a device that is right there advertising.
  if dir="$(bond_dir "$mac")" && [ -r "$dir/info" ]; then
    if grep -q '^\[IdentityResolvingKey\]' "$dir/info"; then
      verdict ok "bond has the phone's identity key (its rotating address resolves)"
    else
      verdict bad "bond has NO IdentityResolvingKey — this computer cannot recognise the phone's rotating address; remove the device and pair again"
    fi
    if grep -qE '^\[(LongTermKey|PeripheralLongTermKey|SlaveLongTermKey)\]' "$dir/info"; then
      verdict ok "bond has an LE long-term key"
    else
      verdict bad "bond has no LE long-term key — this is a classic-only bond; remove the device and pair again"
    fi
  elif [ "$(id -u)" != 0 ]; then
    verdict unknown "bonding keys not readable — re-run with sudo to check the identity key"
  else
    verdict bad "no bond record on disk for $mac — the pairing is gone"
  fi

  if is_linked "$mac"; then
    verdict ok "a link is up right now"
    if has_hid_device "$mac"; then
      verdict ok "the HID profile is attached (kernel has the input device)"
    else
      verdict bad "link is up but HID is NOT attached — run this script with no options to attach it"
    fi
  else
    verdict unknown "no link right now — that is normal while the phone is idle; it becomes a problem only if it stays this way with the app open"
  fi

  cat <<'NOTE'

Two things this computer cannot tell you, and how to settle them:

  * Whether the phone is advertising. Run, while the app is open and the phone
    is NOT connected here:
        bluetoothctl --timeout 12 scan le | grep -i 'ESP Remote'
    Nothing found means the phone's half is broken (app closed, Bluetooth off,
    out of range) and no amount of host-side fixing will help.

  * Whether BlueZ still has a pending connect for it. BlueZ stops trying after
    an explicit disconnect and does not resume until the next Connect() — so
    `bluetoothctl disconnect`, the applet's Disconnect button, and this
    script's own drop-and-retry all leave it idle by design. Re-arm it with:
        bluetoothctl connect <MAC>        # or just run this script
    A device that is Trusted and bonded is re-armed automatically at boot and
    when the adapter is powered back on, but not after a manual disconnect.

Everything else that stops it is physical: the phone is off, out of range, or
its Bluetooth is disabled.
NOTE
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

install_user_service() {
  local mac="$1"
  local libexec="$HOME/.local/libexec/esp-remote-control"
  local units="$HOME/.config/systemd/user"
  local wireplumber="$HOME/.config/wireplumber/wireplumber.conf.d"
  local installed="$libexec/linux-hid-connect.sh"
  local card="bluez_card.${mac//:/_}"

  require install
  require systemctl
  mkdir -p "$libexec" "$units" "$wireplumber"
  install -m 0755 "${BASH_SOURCE[0]}" "$installed"
  cat >"$units/esp-remote-hid.service" <<UNIT
[Unit]
Description=Keep ESP Remote connected as HID only
After=bluetooth.target

[Service]
ExecStart="$installed" --device $mac --watch
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  cat >"$wireplumber/51-esp-remote.conf" <<WIREPLUMBER
-- Keep the iPhone available to BlueZ HID while excluding it from audio.
monitor.bluez.rules = [
  {
    matches = [ { device.name = "~$card" } ]
    actions = { update-props = { device.disabled = true } }
  }
]
WIREPLUMBER

  bluetoothctl trust "$mac" >/dev/null 2>&1 \
    || printf 'warning: could not mark %s trusted\n' "$mac" >&2
  systemctl --user daemon-reload
  systemctl --user enable --now esp-remote-hid.service
  systemctl --user try-restart wireplumber.service >/dev/null 2>&1 || true
  printf 'Installed persistent HID reconnect for %s. Audio routing is disabled for %s.\n' "$mac" "$card"
}

uninstall_user_service_files() {
  command -v systemctl >/dev/null 2>&1 && {
    systemctl --user disable --now esp-remote-hid.service >/dev/null 2>&1 || true
  }
  rm -f "$HOME/.config/systemd/user/esp-remote-hid.service"
  rm -f "$HOME/.config/wireplumber/wireplumber.conf.d/51-esp-remote.conf"
  rm -f "$HOME/.local/libexec/esp-remote-control/linux-hid-connect.sh"
  command -v systemctl >/dev/null 2>&1 && {
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user try-restart wireplumber.service >/dev/null 2>&1 || true
  }
  printf 'Removed the persistent ESP Remote HID service and audio-isolation rule.\n'
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
    --why) why_only=1; shift ;;
    --install) install_service=1; trust=1; shift ;;
    --uninstall) uninstall_service=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

if [ "$uninstall_service" -eq 1 ]; then
  install_service=0
  uninstall_user_service_files
  exit 0
fi

require bluetoothctl
if [ -z "$device" ]; then
  # Debugging must still report what it can when the target is ambiguous.
  if [ "$debug_only" -eq 1 ] || [ "$why_only" -eq 1 ]; then
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

if [ "$why_only" -eq 1 ]; then
  [ -n "$device" ] || die "no paired iPhone found; pass --device <MAC>"
  report "$device"
  why_not_reconnecting "$device"
  exit 0
fi

if [ "$install_service" -eq 1 ]; then
  [ -n "$device" ] || die "no paired iPhone found; pass --device <MAC>"
  has_hid_service "$device" \
    || die "$device is not paired or does not offer the HID service"
  install_user_service "$device"
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
