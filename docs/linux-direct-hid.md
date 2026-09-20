# Direct Bluetooth HID on Linux

This guide is for **Direct Bluetooth** in InpuDeck. The ESP32 USB adapter does
not need this Linux setup.

Keyboard and mouse input have been verified on Bazzite, but recovery after
logout/reboot remains unreliable. The tested kernel also contains an LE address
type bug; enabling the API or installing a helper does not repair it. See the
[validation report](linux-direct-hid-validation.md) for evidence and remaining limits.

## Why there is a helper

An iPhone is a dual-mode Bluetooth device: the same pairing can expose Classic
phone/audio services and the app's **HID over LE** service. A desktop Bluetooth
panel generally calls BlueZ [`Device1.Connect`][BlueZ Device API]. BlueZ chooses a transport and
connects eligible profiles, which can take the phone's audio without attaching
its BLE keyboard. `Connected: yes` alone therefore does not mean HID is ready.

Passing the HID UUID to `bluetoothctl connect` is not a reliable LE selector.
In [BlueZ 5.87's ConnectProfile implementation][connect-source], that method
explicitly uses `BDADDR_BREDR`. Our previous guide recommended it incorrectly.

The helper calls **[`org.bluez.Bearer.LE1.Connect`][BlueZ LE bearer implementation]**
for the selected paired phone.
It finds the actual D-Bus object by its `Address` and `Adapter` properties, checks
that the LE API is available, and waits for both the LE link and the phone's
kernel HID device. It does not fall back to a Classic connection. BlueZ and the
kernel then handle the input reports normally; the helper does not relay keys,
create a network server, or need to stay running for input to work.

**Start with the on-demand helper.** BlueZ may reconnect by itself; that worked
in an initial test, but a later logout/login failed. An always-running watcher
is optional. Repeating connection requests alone did not fix the recorded
reboot failure. The helper now refreshes LE discovery before an offline
connection attempt and backs off after failures; this is not a kernel fix.

BlueZ's [HoG profile][BlueZ HoG] already requests native automatic connection.
An extra watcher is not inherently required for a BLE keyboard. Profile discovery
and a functioning LE transport are prerequisites; repeated user-space requests
cannot repair an invalid controller connection command.

The phone's `UUIDs` property is cached discovery information. After an app stop
or host reboot it may lack `1812` even while the bond is intact. An explicit
`--device <MAC>` therefore allows LE discovery without a cached HID UUID, while
still requiring a paired, unblocked peer and the LE API. Automatic target
selection remains conservative and requires cached HID. `--status` reports the
missing attachment instead of refusing diagnostics. Success still requires both
the LE connection and the matching kernel HID device.

Before connecting a disconnected LE peer, the helper starts an LE-only
discovery session for at most 12 seconds. This lets BlueZ observe the phone's
advertisement and refresh its service/address state. It releases its discovery
session before issuing `LE1.Connect`, and stops early if BlueZ connects the phone
itself. A connected LE peer is not scanned or disconnected. Discovery can still
receive other devices' advertisements, but connection selection remains restricted
to the paired identity and adapter; the app's name is never a connection key.
Only this client's discovery session/filter is released; another application's
active discovery session remains its own responsibility.
No UUID discovery filter is set: matching UUID filters can crash BlueZ 5.87
([upstream issue #2282](https://github.com/bluez/bluez/issues/2282)).

## Minimum host changes

| Component | Default setup | Scope / rollback |
| --- | --- | --- |
| BlueZ userspace API | One systemd drop-in adds `--experimental` | Host-wide API exposure; `inpudeck-le-setup.py disable` removes our drop-in |
| On-demand helper | Two files under `~/.local/libexec/inpudeck` and a launcher `~/.local/bin/inpudeck-hid` | Per user; `inpudeck-hid --uninstall` |
| Reconnect service | Not installed | Optional `--install-service`; remove with `--uninstall-service` |
| Audio configuration | Not changed | Audio restrictions need separate configuration; see limitations below |
| Audio receiver switch | Separate optional installation | User menu/panel launcher; persistent receiving-role override only while off; `on` or `uninstall` restores underlying roles |
| Pairing / trust | Preserved | Pair or `--trust` only when explicitly requested |
| Transport preference | Preserved by installation | Optional per-phone `--preferred-bearer le`; restore the previous value with the same option |
| LE discovery | Up to 12 seconds before each offline connection attempt | Temporary; stopped before connecting, no scan while LE is connected |
| BlueZ 5.87 address-resolution workaround | Optional `bluetooth.service` startup hook for bonded dual-mode peers | Kernel flag only; remove the installed hook files and reload systemd |
| Kernel / drivers / privacy / discoverability | Not configured by the helper | Existing host policy continues to apply; BlueZ manages controller privacy during normal discovery/connection |

The BlueZ experimental switch exposes userspace APIs for the whole daemon; it
cannot be scoped to just this phone. The helper's connect/disconnect requests
are scoped to one phone on one adapter. This does **not** enable
`KernelExperimental`, disable Classic globally, or alter headphone support.

The setup supports the standard Fedora/Bazzite and Debian `bluetoothd` service
paths. It refuses custom daemon arguments or locally modified files at its own
paths instead of overwriting them. Because the drop-in overrides `ExecStart`,
review it if a distribution later changes its daemon command or path.

## Setup once, safely repeat later

Run these commands from the repository. Python 3, `python3-dbus`, BlueZ, and
systemd are required. First check dependencies:

```bash
python3 -c 'import dbus'
bluetoothctl --version
```

On Bazzite/Fedora Atomic, if `python3-dbus` is missing and there are no conflicting
pending deployments, this additive userspace package is suitable for
`sudo rpm-ostree install -yA python3-dbus`. No installation is needed if the import
already succeeds. If live apply is unavailable, activate the pending deployment
with a reboot; a kernel/driver change is not part of this setup.

Preview and save the persistent API setting:

```bash
python3 scripts/inpudeck-le-setup.py enable --dry-run
sudo python3 scripts/inpudeck-le-setup.py enable
python3 scripts/inpudeck-le-setup.py status
```

`enable` adds `/etc/systemd/system/bluetooth.service.d/90-inpudeck-le.conf`
and runs `daemon-reload` only if files changed. Repeating it is a no-op. It
promotes our earlier temporary test override from `/run` without stopping a
working connection. It does not modify `/etc/bluetooth/main.conf`.

Saving the setting does **not** restart Bluetooth. If the running daemon already
has `--experimental` (as after our temporary test), it keeps working. Otherwise
activate at the next reboot, or explicitly restart Bluetooth at a convenient time:

```bash
sudo python3 scripts/inpudeck-le-setup.py enable --restart
```

A restart briefly disconnects **all** local Bluetooth devices. It is never
implicit in the default setup command. For a temporary test instead, use
`enable --temporary --restart`; its `/run` override disappears at reboot.

Install the on-demand command as your desktop user, **without sudo**:

```bash
./scripts/inpudeck-hid.sh --install
~/.local/bin/inpudeck-hid --help
```

The installer also removes an earlier `esp-remote-hid` launcher, reconnect
service, and helper copies when they carry the ESP Remote ownership marker.
It refuses similarly named files without that marker instead of overwriting
them.

Repeat `--install` after updating the repository; it updates only these helper
files. It does not start a service, trust a phone, modify audio routing, or edit
your shell profile. Use the full path if `~/.local/bin` is not on `PATH`.
`--prefix /absolute/path` allows a different user installation directory.

## Pairing and normal connection

Keep an existing working bond. If this computer is not paired yet:

1. In InpuDeck choose **Direct Bluetooth**, then **Allow new pairing**.
2. On Linux run `bluetoothctl`, then `scan le` and find the phone/InpuDeck.
3. Run `pair AA:BB:CC:DD:EE:FF`, then `trust AA:BB:CC:DD:EE:FF` and `scan off`.
4. Leave InpuDeck open with this computer selected, and run:

```bash
~/.local/bin/inpudeck-hid --device AA:BB:CC:DD:EE:FF
~/.local/bin/inpudeck-hid --device AA:BB:CC:DD:EE:FF --status
```

The optional `--trust` flag sets trust explicitly. Otherwise connecting does not
change it. The helper can infer a single paired HID phone when `--device` is
omitted; ambiguity requires an explicit address or `--name`. Use `--adapter hci1`
if the bond belongs to another adapter.

A successful result requires `Bearer.LE1.Connected` plus a Bluetooth HID device
whose `HID_UNIQ` is the peer address and `HID_PHYS` is the local adapter.
A retained UHID object alone can outlive a lost link. `ServicesResolved` is printed
separately: BlueZ 5.87 resets this shared flag on a Classic disconnection even
when LE remains connected, so it cannot gate HID status.
These host checks still do not prove that input reaches the selected host. A USB
bridge with the same name does not count. If metadata differs on another kernel,
collect `--debug` output rather than assuming a name match proves readiness.

Several saved computers may stay connected to the phone; InpuDeck routes input
to the selected computer. There is no need to delete the second computer's bond.
The iOS host UUID shown by the app is **not** its Bluetooth MAC address.

## Optional background reconnect

No watcher is needed for input once HID is attached. The optional watcher
checks readiness and can attempt discovery/LE connection while waiting for a
phone. It cannot fix the kernel defect. Install it only if this background
behavior is wanted:

```bash
# Foreground watcher; Ctrl+C stops only this helper
~/.local/bin/inpudeck-hid --device AA:BB:CC:DD:EE:FF --watch

# Optional per-user service, enabled at user login
~/.local/bin/inpudeck-hid --device AA:BB:CC:DD:EE:FF --install-service
journalctl --user -u inpudeck-hid.service -f

# Remove only the service, retain the on-demand command
~/.local/bin/inpudeck-hid --uninstall-service
```

The watcher checks HID every five seconds by default. These checks read D-Bus
and kernel state; they do not issue scan/connect requests while HID is ready.
An unsuccessful attempt waits 30, 60, 120, 240, then at most 300 seconds before
another attempt. Each offline attempt includes the bounded discovery above.
HID checks continue during the pause, so a native reconnect resets the backoff.
This trades longer recovery when a phone returns after a long absence for fewer
radio requests. It does not forcibly drop connections after a timeout. Errors
remain visible in its log. Repeating service installation reuses the same unit;
unchanged configuration does not restart the watcher. The service runs as the
user, not root; it is not a system-wide pre-login or pre-OS keyboard solution.

### BlueZ 5.87 dual-mode address-resolution bug

A bonded iPhone can advertise with a rotating LE private address while BlueZ
remembers its public identity. BlueZ 5.87 may then discover the iPhone but hang
on the later LE connection: it puts the public identity in the controller's
accept list without enabling address resolution for that device. This is
[BlueZ issue #2356](https://github.com/bluez/bluez/issues/2356). A matching
local trace showed the iPhone advertisement resolving during discovery, but
the subsequent filtered connection timed out. Setting the kernel device flag
`0x04` once made the next LE/HID attempt connect in five seconds, and physical
keyboard and mouse input worked. The flag is lost when bluetoothd restarts.

For this BlueZ version, install the small startup hook from the repository:

```bash
sudo install -Dm755 scripts/inpudeck-le-address-resolution.py \
  /usr/local/libexec/inpudeck-le-address-resolution.py
sudo install -Dm644 scripts/91-inpudeck-address-resolution.conf \
  /etc/systemd/system/bluetooth.service.d/91-inpudeck-address-resolution.conf
sudo systemctl daemon-reload
```

It runs within the existing `bluetooth.service` after each daemon start. It
only sets a management flag for bonds with both BR/EDR and LE keys plus an IRK;
it does not scan, connect, alter keys, or restart Bluetooth. The existing
optional user watcher remains responsible for requesting an LE connection.
To remove the hook, delete the two installed files and run `systemctl
daemon-reload`; no immediate Bluetooth restart is needed. A future BlueZ fix
can replace this workaround. This does not explain delayed Windows reconnects.

## Explicit recovery and transport preference

For a deliberate reset of this phone's LE channel, use `--reset-le`. It calls
`Bearer.LE1.Disconnect` before trying again. It preserves the bond and does not
reset the adapter, but it will briefly interrupt input to this computer.

If LE is disconnected but a request remains pending, `Bearer.LE1.Disconnect`
may return `NotConnected` without cancelling that request. The separate explicit
`--reset-device` uses `Device1.Disconnect` to cancel pending connection requests
and disconnect **both** transports of this phone, then attempts LE again. It
keeps the bond, but also interrupts this phone's audio/tethering connections.
Neither the default helper nor watcher invokes this recovery automatically.

BlueZ may also expose a saved, per-device transport preference:

```bash
~/.local/bin/inpudeck-hid --device AA:BB:CC:DD:EE:FF --preferred-bearer le
# Restore the original default when appropriate:
~/.local/bin/inpudeck-hid --device AA:BB:CC:DD:EE:FF --preferred-bearer last-used
```

This configuration command does not reconnect. It influences later ordinary
connection requests; it does not prohibit incoming Classic/audio connections or
repair existing GATT state. In BlueZ 5.87, a generic `Connect` while LE is already
connected explicitly tries Classic, even with this preference. Continue using the
LE helper for connection requests. BlueZ stores the preference for this phone on
this adapter.

## Optional audio isolation

### Reversible GUI switch for receiving audio

For a host that only occasionally needs to play a phone's Bluetooth audio,
`scripts/inpudeck-audio-receiver.py` provides a separate KDE menu switch:

```bash
# Run as the desktop user, without sudo. Installation alone changes no roles.
python3 scripts/inpudeck-audio-receiver.py install
~/.local/bin/inpudeck-audio-receiver off
# Open the menu entry, or launch the dialog directly:
~/.local/bin/inpudeck-audio-receiver gui
```

Installation migrates a managed `90-esp-remote-audio-receiver.conf` fragment
and removes the old managed launcher, desktop entry, and script copies. Files
with local changes or without the old ownership marker are left untouched and
reported as an error.

Search the application menu for **Bluetooth Audio Reception**. To keep it beside
the Bluetooth tray, right-click
the menu entry, choose **Add to Panel (Widget)**, and position it in panel edit
mode. This uses Plasma's existing application launcher widget, without patching
BlueDevil or adding an idle background process. It is a separate button; the
Bluetooth device list and System Settings page are unchanged. The dialog shows
the configured state and offers **Enable / Disable**; cancelling does nothing.

The switch changes receiving roles for **all Bluetooth peers in this user's
audio session**, including already paired phones. It leaves the host's headphone
output and headset microphone gateway roles enabled. On the tested Bazzite host:

| Setting | WirePlumber roles |
| --- | --- |
| On (underlying distribution settings) | `a2dp_sink a2dp_source hfp_ag` |
| Off | `a2dp_source hfp_ag` |

Off writes one owned fragment,
`~/.config/wireplumber/wireplumber.conf.d/90-inpudeck-audio-receiver.conf`, using
`override.bluez5.roles` so the array replaces the earlier setting. It persists
across login/reboot. On removes only that fragment, restoring the underlying
configuration. Both changes restart **WirePlumber only**, briefly interrupting
computer audio; pairing and the Bluetooth daemon are untouched. Selecting the
current state is a no-op. This prevents this session from exposing the disabled
audio receiving roles; it does not block Classic Bluetooth or other services.
Other users and the login screen have separate audio sessions.

Requirements: Python 3, PyGObject with WirePlumber 0.5 introspection, `kdialog`,
and the user's `wireplumber.service`; all were already installed on this host.
The helper reads the effective configuration with WirePlumber's own parser,
validates headphone roles, refuses unknown/LE Audio role configurations, and
preserves unrelated or manually edited files. Failed activation restores the
previous fragment and attempts to restart the previous audio configuration.
Configuration validation failure alone does not restart audio.

```bash
~/.local/bin/inpudeck-audio-receiver status
~/.local/bin/inpudeck-audio-receiver on         # allow phone audio again
~/.local/bin/inpudeck-audio-receiver uninstall # restore roles and remove files
```

Remove a pinned panel button through Plasma's panel edit mode when uninstalling.
Existing per-device audio profile rules are not automatically changed by this
installer: an old `device.profile = "off"` rule may need reviewing if reception
is enabled but playback remains unavailable. On KeeFRogBz, the known obsolete
`51-iphone-no-audio.conf` was backed up under
`~/.local/state/inpudeck/diagnostics/2026-09-19/` and removed from active
configuration when installing the switch. That migration is separate from the
portable helper and can be reversed by restoring the backup.

### Earlier per-phone workarounds and limitations

LE-only connection does not request Classic audio. Another application or the
Bluetooth panel may still initiate a generic connection. `--drop-audio` can
release phone audio profiles already connected; it may not resume paused media.

The earlier per-phone `device.disabled = true` recipe was withdrawn: the installed
WirePlumber 0.5.12 Bluetooth monitor does not check that property when creating
devices. `device.profile = "off"` is also not a ban on incoming audio; profile
policy can change it. The host already had such an `off` rule when the maintainer
reported audio capture after login.

A reactive audio guard was tested and removed because connecting and then
disconnecting audio can still interrupt headphone playback. It is not included
in the helper. The receiver switch prevents this session from exposing the
receiving roles in the first place.

One likely trigger is desktop restoration: [KDE BlueDevil's device monitor][KDE restore]
saves connected devices and calls ordinary `Connect` when restoring them after
login/resume. On BlueZ 5.87 that can add Classic to an already connected LE phone,
regardless of `PreferredBearer=le`. The tested host's saved list included the
iPhone. This is a source-backed explanation consistent with the observed resume
and audio reconnection; the actual original D-Bus caller was not captured.

[WirePlumber's `bluez5.roles`][WirePlumber Bluetooth] controls which Bluetooth audio
roles the user session exposes. Removing the receiving role can prevent Linux
from acting as a phone's Bluetooth speaker, while retaining output/headset roles.
This setting applies to **all peers in that audio session**, not just one phone;
it is a separate choice, not part of installing the HID helper. Its activation
restarts WirePlumber and briefly interrupts the audio session. Existing manual
audio rules remain untouched by helper installation/removal.

### Preventing an audio connection before it starts

The installed BlueZ 5.87 has no standard per-device service denylist in its
Device/Bearer APIs. Its [administrative service allowlist][BlueZ Admin policy]
rejects incoming and outgoing services at adapter scope; it cannot select one
phone. A device's UUID list is discovered information, not a writable list of
permissions. Removing cached audio UUIDs or pairing via LE is not an enduring
prohibition on Classic/audio discovery and connection.

An authorization agent is not a complete replacement: BlueZ [automatically
authorizes trusted devices][BlueZ authorization], and a service authorization
callback does not govern every locally initiated profile connection. Removing
trust alone does not implement a per-phone audio denylist.

A per-phone service policy would require changes beyond these helpers. No
BlueZ replacement, bond edit or administrative allowlist has been applied. The
receiver switch restricts roles for the user session, not one phone's permissions.

## Linux connection details and diagnostics

- Linux acts as the LE central/GATT client; the phone publishes HID as a peripheral.
  A typical BlueZ desktop does not advertise over LE by default, so the app's
  **Find computer** may not list it. Classic discoverability alone is not an LE
  advertisement. The verified path here starts from the computer.
- Advertising may use a rotating private address. BlueZ can expose the bonded
  identity in `Address` while retaining an earlier address in its D-Bus object
  path. The helper enumerates objects instead of constructing a path from MAC.
- `Public`/`Random` are address types and do not by themselves identify Classic
  versus LE. Likewise, a name changing between “iPhone” and “InpuDeck” is not
  proof of which transport is connected.
- `Connected: yes` can describe Classic alone. `--debug` prints separate
  `LEConnected` and `BREDRConnected` states. `unknown` means the bearer property is
  unavailable, not proof that the radio is disconnected.
- An empty name-filtered scan is not proof the phone is absent: iOS may omit the
  local name in background. Use the paired identity and HCI evidence.
- If `Bearer.LE1.Connect` is missing, check setup/activation and the installed
  BlueZ capabilities. The helper fails visibly instead of using Classic as a
  fallback. Do not replace a working pairing merely because this API is disabled.

Start with read-only diagnostics:

```bash
~/.local/bin/inpudeck-hid --debug
~/.local/bin/inpudeck-hid --why
python3 scripts/inpudeck-le-setup.py status
journalctl -u bluetooth --since '5 minutes ago'
```

`--why` checks adapter, pairing, trust, cached HID and API availability. With sudo
it can also check whether bond key sections exist; it does not print their values.
No single check establishes that every layer can reconnect.

For a controlled reproduction, capture `sudo btmon -w /tmp/esp-force-le.btsnoop`
and export the app's **Share log** around the same attempt. Keep the
watcher stopped while attributing a disconnect. Note when the app was merely
backgrounded, when the host slept, and when a deliberate reset was requested.
Stop btmon after the test. Capture files can contain Bluetooth traffic from other
devices; share selected diagnostic excerpts when possible.

## Rollback

```bash
# User files and optional service; does not remove the phone's pairing
~/.local/bin/inpudeck-hid --uninstall

# Preview/remove only our BlueZ overrides
python3 scripts/inpudeck-le-setup.py disable --dry-run
sudo python3 scripts/inpudeck-le-setup.py disable
```

Removing the drop-in applies at Bluetooth's next start/reboot. Add `--restart`
only when ready to interrupt Bluetooth immediately. `disable --temporary` removes
only our `/run` overrides. Repeated removal is harmless; unrelated overrides,
main.conf settings, packages and manually created audio rules remain in place.
If experimental APIs were independently enabled elsewhere, removing our drop-in
does not disable that separate configuration.

## Validation

The [hardware validation report](linux-direct-hid-validation.md) separates
working input, manual recovery, the captured kernel defect, and behavior still
requiring device testing.

Run regression checks without Bluetooth hardware or root:

```bash
python3 -B -m unittest discover -s Tests -p 'test_linux_*.py'
bash -n scripts/inpudeck-hid.sh scripts/inpudeck-le-api-test.sh
```

These cover transport selection, adapter/object identity, HID matching,
idempotent installation, configuration rollback, and the audio switch. The
WirePlumber parser integration check runs when its introspection library is
available. CI runs the offline suite; it does not establish physical pairing,
input delivery, or wake behavior.

[connect-source]: https://github.com/bluez/bluez/blob/5.87/src/device.c#L2879
[BlueZ Device API]: https://github.com/bluez/bluez/blob/5.87/doc/org.bluez.Device.rst
[BlueZ LE bearer implementation]: https://github.com/bluez/bluez/blob/5.87/src/bearer.c
[WirePlumber Bluetooth]: https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/bluetooth.html
[BlueZ HoG]: https://github.com/bluez/bluez/blob/5.87/profiles/input/hog.c#L204
[KDE restore]: https://github.com/KDE/bluedevil/blob/master/src/kded/devicemonitor.cpp
[BlueZ Admin policy]: https://github.com/bluez/bluez/blob/5.87/doc/org.bluez.AdminPolicySet.rst
[BlueZ authorization]: https://github.com/bluez/bluez/blob/5.87/src/adapter.c#L7759
