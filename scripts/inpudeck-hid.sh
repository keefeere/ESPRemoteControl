#!/usr/bin/env bash
# Connect a bonded iPhone over LE only, then verify its kernel HID device.
# BlueZ ConnectProfile(1812) selects BR/EDR; it cannot force a BLE HID link.
# The companion uses org.bluez.Bearer.LE1.Connect without a Classic fallback.
set -euo pipefail

HID_UUID="00001812-0000-1000-8000-00805f9b34fb"
# Classic phone services distinguish an iPhone from other paired HID devices.
PHONE_UUIDS=(
  "0000110a-0000-1000-8000-00805f9b34fb" # A2DP source
  "0000110c-0000-1000-8000-00805f9b34fb" # AVRCP target
  "0000110e-0000-1000-8000-00805f9b34fb" # AVRCP controller
  "0000111f-0000-1000-8000-00805f9b34fb" # Hands-free gateway
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
install_files=0
install_service=0
uninstall_service=0
uninstall_files=0
prefix="$HOME/.local"
user_config="${XDG_CONFIG_HOME:-$HOME/.config}"
reset_le=0
reset_device=0
preferred_bearer=""
backend="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/inpudeck-bluez-le.py"

usage() {
  cat <<'USAGE'
Usage: inpudeck-hid.sh [options]

  -d, --device <MAC>     Paired iPhone address (AA:BB:CC:DD:EE:FF).
                         Works even if BlueZ has not cached its HID service.
  -n, --name <text>      Pick a paired device whose name contains <text>.
  -a, --adapter <hciN>   Bluetooth adapter to use (default: hci0).
  -w, --watch [seconds]  Keep the HID profile connected, polling every
                         <seconds> (default: 5). Runs until interrupted.
                         Failed attempts back off from 30s to 5 minutes.
      --drop-audio       Disconnect iPhone audio profiles that something else
                         already connected. Recovery only; see the note below.
      --reset-le         Explicitly disconnect only LE before connecting again.
      --reset-device     Cancel this phone's pending requests and disconnect both
                         transports before LE reconnect. Keeps the pairing.
      --preferred-bearer <le|bredr|last-used|last-seen>
                         Save this phone's transport preference in BlueZ.
                         Configuration only; does not reconnect or block audio.
      --trust            Mark the device trusted so BlueZ accepts its
                         reconnects without a desktop prompt.
      --status           Print the current state and exit.
      --debug            Print paired devices, the target, and every HID
                         device the kernel exposes, then exit.
      --why              Check host settings that can stop it
                         from reconnecting to the phone by itself, then exit.
                         Run with sudo to check bond key presence (not values).
      --install          Install/update inpudeck-hid in the user prefix.
                         Copies files only; no service, trust or audio changes.
      --prefix <path>    Installation prefix (default: ~/.local).
      --install-service  Additionally enable an optional user reconnect service.
      --uninstall-service Remove only the optional reconnect service.
      --uninstall        Remove installed helper files and its optional service.
  -h, --help             Show this help.

Requires python3-dbus and BlueZ exposing experimental Bearer.LE1.Connect.
See docs/linux-direct-hid.md for setup. No fallback to Classic is performed.
An offline target gets up to 12s of LE HID discovery before a connection attempt.
Existing LE links are preserved; a ready HID link requires no discovery/connect.

With no -d/-n, the paired device that offers HID and also looks like a phone
is used; several candidates are listed instead of guessed.

--drop-audio only disconnects audio profiles that already connected, and by
then the phone may have lost audio focus. Start with the LE helper. Optional
audio reception control is documented separately; installation does not add it.

Examples:
  inpudeck-hid.sh --trust     # one-off HID-only connect
  inpudeck-hid.sh --watch     # keep the HID profile connected
  inpudeck-hid.sh --debug     # what is paired and what the kernel sees
  sudo inpudeck-hid.sh --why  # why this computer is not reconnecting
  inpudeck-hid.sh --install   # install on-demand command only
  inpudeck-hid.sh --install-service --device AA:BB:CC:DD:EE:FF
USAGE
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

bluez() {
  python3 "$backend" --adapter "$adapter" "$@"
}

adapter_info() {
  bluez adapter-info
}

device_info() {
  bluez info "$1"
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

# Require both the LE bearer and the target's Bluetooth HID device. A Classic
# link or a same-name USB bridge must not produce a successful keyboard status.
has_hid_device() {
  bluez hid-ready "$1"
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
  printf '== LE API ==\n'
  [ -z "$mac" ] || bluez check "$mac" || true
}

paired_devices() {
  bluez paired
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
    die "no paired device has cached HID. For an already paired iPhone, open InpuDeck and pass --device <MAC>."
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
    printf 'For an existing bond, open InpuDeck and specify its address with --device; do not remove the bond just because HID is absent from the cache.\n' >&2
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

# These host-side checks identify common prerequisites. They cannot prove
# successful radio connection, GATT subscriptions, or delivery of input.
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
  adapter_mac="$(adapter_info \
    | awk '/^Controller /{ print $2; exit }')"
  [ -n "$adapter_mac" ] || return 1
  printf '/var/lib/bluetooth/%s/%s' "$adapter_mac" "$mac"
}

why_not_reconnecting() {
  local mac="$1" info dir
  info="$(device_info "$mac")"

  printf '== what can stop this computer from reconnecting on its own ==\n'

  if adapter_info | grep -qiE '^[[:space:]]*Powered:[[:space:]]*yes'; then
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

  # Trust can bypass service authorization prompts; it does not ensure LE HID
  # discovery or reconnection, and is not a transport/audio restriction.
  if info_says Trusted "$info"; then
    verdict ok "device is trusted"
  else
    verdict unknown "device is not trusted; service authorization may require a prompt (use --trust if intended)"
  fi

  if has_hid_service "$mac"; then
    verdict ok "cached services include HID"
  else
    verdict unknown "HID is absent from cached services; open InpuDeck and connect using --device to discover it again"
  fi

  # iOS advertises with a rotating resolvable private address. Without the
  # Identity Resolving Key from bonding, this computer cannot tell that any of
  # those addresses is the phone, so its connect request never matches and it
  # waits forever on a device that is right there advertising.
  if dir="$(bond_dir "$mac")" && [ -r "$dir/info" ]; then
    if grep -q '^\[IdentityResolvingKey\]' "$dir/info"; then
      verdict ok "bond has the phone's identity key (address resolution still needs verification)"
    else
      verdict unknown "bond has no saved IdentityResolvingKey; investigate LE bonding and address resolution before re-pairing"
    fi
    if grep -qE '^\[(LongTermKey|PeripheralLongTermKey|SlaveLongTermKey)\]' "$dir/info"; then
      verdict ok "bond has an LE long-term key"
    else
      verdict unknown "bond has no saved LE long-term key; inspect LE pairing and authentication before re-pairing"
    fi
  elif [ "$(id -u)" != 0 ]; then
    verdict unknown "bonding keys not readable — re-run with sudo to check the identity key"
  else
    verdict unknown "no readable bond record at the expected path for $mac; compare BlueZ's pairing state"
  fi

  if is_linked "$mac"; then
    verdict ok "a link is up right now"
    if has_hid_device "$mac"; then
      verdict ok "the HID profile is attached (kernel has the input device)"
    else
      verdict bad "link is up but LE HID is not attached; open InpuDeck and retry with --device $mac"
    fi
  else
    verdict unknown "no link right now — that is normal while the phone is idle; it becomes a problem only if it stays this way with the app open"
  fi

  printf '\n== explicit LE connection support ==\n'
  bluez check "$mac" || true

  cat <<'NOTE'

Keep InpuDeck open on the selected host while testing. A name-filtered scan
alone cannot prove the phone is absent: iOS may omit its name in background.
An LE-only connection still needs a working controller, bond and GATT session.
This helper never uses generic Connect or ConnectProfile to connect the phone.
Use --reset-le only for a deliberate LE reset; --watch does not tear links down.
NOTE
}

report() {
  local mac="$1" info le_state classic_state resolved
  info="$(device_info "$mac")"
  le_state="$(printf '%s\n' "$info" | awk '/LEConnected:/ {print $2}')"
  classic_state="$(printf '%s\n' "$info" | awk '/BREDRConnected:/ {print $2}')"
  resolved="$(printf '%s\n' "$info" | awk '/ServicesResolved:/ {print $2}')"
  printf '%s (%s): LE=%s, Classic=%s, services=%s, HID=%s\n' \
    "$(device_name "$mac")" "$mac" \
    "${le_state:-unknown}" "${classic_state:-unknown}" "${resolved:-unknown}" \
    "$(has_hid_device "$mac" && echo attached || echo not-ready)"
}

drop_audio_profiles() {
  bluez drop-audio "$1"
}

# An LE link can be established before HoG attaches the kernel input device.
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

  bluez discover "$mac" || return $?
  bluez connect "$mac" || return $?
  if await_hid_device "$mac" 15; then
    if [ "$drop_audio" -eq 1 ]; then drop_audio_profiles "$mac"; fi
    return 0
  fi
  printf 'LE request did not produce a kernel HID device; preserving the link (use --debug)\n' >&2
  return 1
}

copy_if_changed() {
  local source="$1" target="$2" mode="$3"
  if [ -e "$target" ] && [ "$source" -ef "$target" ]; then return 0; fi
  if [ -r "$target" ] && cmp -s -- "$source" "$target"; then return 0; fi
  install -m "$mode" -- "$source" "$target"
}

check_user_install() {
  [ "$(id -u)" -ne 0 ] || die "run helper installation as your desktop user, without sudo"
  [[ "$prefix" = /* ]] || die "installation prefix must be an absolute path"
  [[ "$prefix" != *$'\n'* ]] || die "installation prefix must not contain newlines"
}

remove_legacy_user_install() {
  local launcher="$prefix/bin/esp-remote-hid"
  local unit="$user_config/systemd/user/esp-remote-hid.service"
  local owned_files=0 changed_units=0

  if [ -L "$launcher" ] || { [ -e "$launcher" ] && ! grep -q '^# Managed by ESP Remote$' "$launcher"; }; then
    die "legacy command has no ESP Remote ownership marker; inspect it first: $launcher"
  fi
  if [ -L "$unit" ] || { [ -e "$unit" ] && ! grep -q '^# Managed by ESP Remote$' "$unit"; }; then
    die "legacy service has no ESP Remote ownership marker; inspect it first: $unit"
  fi

  if [ -e "$launcher" ]; then
    owned_files=1
    rm -- "$launcher"
  fi
  if [ -e "$unit" ]; then
    owned_files=1
    require systemctl
    systemctl --user disable --now esp-remote-hid.service
    rm -- "$unit"
    changed_units=1
  fi
  if [ "$owned_files" -eq 1 ]; then
    rm -f -- "$prefix/libexec/esp-remote-control/linux-hid-connect.sh" \
      "$prefix/libexec/esp-remote-control/linux-bluez-le.py"
    rmdir -- "$prefix/libexec/esp-remote-control" 2>/dev/null || true
  fi
  if [ "$changed_units" -eq 1 ]; then systemctl --user daemon-reload; fi
}

install_user_files() {
  check_user_install
  require install
  remove_legacy_user_install
  local libexec="$prefix/libexec/inpudeck"
  local installed="$libexec/inpudeck-hid.sh"
  local launcher="$prefix/bin/inpudeck-hid" text
  if [ -L "$launcher" ] || { [ -e "$launcher" ] && ! grep -q '^# Managed by InpuDeck$' "$launcher"; }; then
    die "refusing to replace an unrelated command: $launcher"
  fi
  mkdir -p "$libexec" "$prefix/bin"
  [ ! -L "$installed" ] && [ ! -L "$libexec/inpudeck-bluez-le.py" ] || die "installed helper files must not be symlinks"
  copy_if_changed "${BASH_SOURCE[0]}" "$installed" 0755
  copy_if_changed "$backend" "$libexec/inpudeck-bluez-le.py" 0644
  printf -v text '#!/usr/bin/env bash\n# Managed by InpuDeck\nexec %q --prefix %q "$@"\n' "$installed" "$prefix"
  if [ ! -f "$launcher" ] || [ "$(cat "$launcher")" != "${text%$'\n'}" ]; then
    printf '%s' "$text" >"$launcher"
    chmod 0755 "$launcher"
  fi
  printf 'Installed on-demand command: %s (no service or audio settings changed)\n' "$launcher"
}

check_owned_service() {
  local unit="$user_config/systemd/user/${1:-inpudeck-hid.service}"
  if [ -L "$unit" ] || { [ -e "$unit" ] && ! grep -q '^# Managed by InpuDeck$' "$unit"; }; then
    die "existing service has no ownership marker; inspect it first: $unit"
  fi
}

install_user_service() {
  local mac="$1" units="$user_config/systemd/user" text changed=0 was_active=0
  local service_name="inpudeck-hid.service" service_args="--watch" description="Reconnect InpuDeck over LE"
  check_user_install
  check_owned_service "$service_name"
  # systemd expands these characters in ExecStart. Refuse unusual prefixes
  # instead of saving a unit that calls a different command.
  [[ "$prefix" != *['%$"\']* ]] || die "service prefix contains unsupported systemd characters"
  install_user_files
  require systemctl
  if systemctl --user is-active --quiet "$service_name"; then was_active=1; fi
  mkdir -p "$units"
  printf -v text '# Managed by InpuDeck\n[Unit]\nDescription=%s\n\n[Service]\nExecStart="%s/libexec/inpudeck/inpudeck-hid.sh" --adapter %s --device %s %s\nRestart=on-failure\nRestartSec=10\n\n[Install]\nWantedBy=default.target\n' "$description" "$prefix" "$adapter" "$mac" "$service_args"
  local unit="$units/$service_name"
  if [ ! -f "$unit" ] || [ "$(cat "$unit")" != "${text%$'\n'}" ]; then
    printf '%s' "$text" >"$unit"
    changed=1
    systemctl --user daemon-reload
  fi
  systemctl --user enable --now "$service_name"
  if [ "$changed" -eq 1 ] && [ "$was_active" -eq 1 ]; then systemctl --user restart "$service_name"; fi
  printf 'Optional %s enabled for %s. WirePlumber configuration was not changed.\n' "$service_name" "$mac"
}

uninstall_user_service_files() {
  check_user_install
  local service_name="${1:-inpudeck-hid.service}"
  check_owned_service "$service_name"
  local unit="$user_config/systemd/user/$service_name"
  if [ -f "$unit" ]; then
    systemctl --user disable --now "$service_name"
    rm -- "$unit"
    systemctl --user daemon-reload
  fi
  remove_legacy_user_install
  printf 'Optional %s removed (or already absent).\n' "$service_name"
}

uninstall_user_files() {
  check_user_install
  local launcher="$prefix/bin/inpudeck-hid"
  if [ -L "$launcher" ] || { [ -e "$launcher" ] && ! grep -q '^# Managed by InpuDeck$' "$launcher"; }; then
    die "refusing to remove an unrelated command: $launcher"
  fi
  check_owned_service
  uninstall_user_service_files
  rm -f -- "$launcher" "$prefix/libexec/inpudeck/inpudeck-hid.sh" \
    "$prefix/libexec/inpudeck/inpudeck-bluez-le.py"
  rmdir -- "$prefix/libexec/inpudeck" 2>/dev/null || true
  printf 'Helper files removed. BlueZ API configuration and pairing are unchanged.\n'
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
    --reset-le) reset_le=1; shift ;;
    --reset-device) reset_device=1; shift ;;
    --preferred-bearer) preferred_bearer="${2:?--preferred-bearer requires a value}"; shift 2 ;;
    --trust) trust=1; shift ;;
    --status) status_only=1; shift ;;
    --debug) debug_only=1; shift ;;
    --why) why_only=1; shift ;;
    --install) install_files=1; shift ;;
    --prefix) prefix="${2:?--prefix requires an absolute path}"; shift 2 ;;
    --install-service) install_service=1; shift ;;
    --uninstall-service) uninstall_service=1; shift ;;
    --uninstall) uninstall_files=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$reset_le" -eq 0 ] || [ "$reset_device" -eq 0 ] || die "choose --reset-le or --reset-device"
if [ -n "$preferred_bearer" ]; then
  case "$preferred_bearer" in le|bredr|last-used|last-seen) ;; *) die "invalid preferred bearer" ;; esac
  [ "$reset_le" -eq 0 ] && [ "$reset_device" -eq 0 ] && [ "$watch" -eq 0 ] \
    && [ "$install_files" -eq 0 ] && [ "$install_service" -eq 0 ] \
    && [ "$uninstall_files" -eq 0 ] && [ "$uninstall_service" -eq 0 ] \
    && [ "$status_only" -eq 0 ] && [ "$debug_only" -eq 0 ] && [ "$why_only" -eq 0 ] \
    && [ "$drop_audio" -eq 0 ] && [ "$trust" -eq 0 ] \
    || die "--preferred-bearer is a separate configuration command"
fi

if [ "$uninstall_files" -eq 1 ]; then
  uninstall_user_files
  exit 0
fi
if [ "$uninstall_service" -eq 1 ]; then
  uninstall_user_service_files
  exit 0
fi
if [ "$install_files" -eq 1 ] && [ "$install_service" -eq 0 ]; then
  install_user_files
  exit 0
fi

require python3
[ -r "$backend" ] || die "missing companion: $backend"
python3 -c 'import dbus' 2>/dev/null || die "python3-dbus is required"
[[ "$adapter" =~ ^hci[0-9]+$ ]] || die "adapter must be hciN"
[ "$interval" -gt 0 ] || die "watch interval must be positive"
adapter_info >/dev/null || die "cannot read adapter $adapter"
if [ -z "$device" ]; then
  # Debugging must still report what it can when the target is ambiguous.
  if [ "$debug_only" -eq 1 ] || [ "$why_only" -eq 1 ]; then
    device="$(resolve_device || true)"
  else
    device="$(resolve_device)"
  fi
fi
device="$(printf '%s' "$device" | tr 'a-z' 'A-Z')"

if [ -n "$preferred_bearer" ]; then
  bluez preferred-bearer "$device" "$preferred_bearer"
  exit $?
fi

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
  bluez check "$device" || exit $?
  if [ "$trust" -eq 1 ]; then bluez trust "$device"; fi
  install_user_service "$device"
  exit 0
fi

if [ "$status_only" -eq 1 ]; then
  report "$device"
  exit 0
fi

bluez check "$device" || exit $?

if [ "$reset_device" -eq 1 ]; then
  bluez disconnect-device "$device" || exit $?
fi

if [ "$reset_le" -eq 1 ]; then
  bluez disconnect "$device" || exit $?
fi

if [ "$trust" -eq 1 ]; then
  bluez trust "$device" \
    || printf 'warning: could not mark %s trusted\n' "$device" >&2
fi

if [ "$watch" -eq 0 ]; then
  if connect_hid "$device"; then
    report "$device"
    exit 0
  fi
  report "$device"
  printf 'run with --debug and share the output if the phone reports HID ready\n' >&2
  die "the HID profile did not come up. Open InpuDeck on the iPhone with direct Bluetooth selected, then retry."
fi

printf 'watching %s every %ss; failed attempts back off 30–300s; press Ctrl+C to stop\n' "$device" "$interval"
previous=""
next_attempt=0
retry_delay=30
while :; do
  if has_hid_device "$device"; then
    current="up"
    next_attempt=0
    retry_delay=30
  else
    current="down"
    if [ "$SECONDS" -ge "$next_attempt" ]; then
      connect_hid "$device" || true
      if has_hid_device "$device"; then
        current="up"
        next_attempt=0
        retry_delay=30
      else
        next_attempt=$((SECONDS + retry_delay))
        printf 'Next reconnect attempt in %ss; monitoring HID without radio requests\n' "$retry_delay"
        retry_delay=$((retry_delay * 2))
        if [ "$retry_delay" -gt 300 ]; then retry_delay=300; fi
      fi
    fi
  fi
  if [ "$current" != "$previous" ]; then
    printf '%s  keyboard %s\n' "$(date '+%H:%M:%S')" "$current"
    previous="$current"
  fi
  sleep "$interval"
done
