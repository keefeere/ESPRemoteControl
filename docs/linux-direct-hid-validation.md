# Linux direct HID: hardware validation

This report records testing on September 18–19, 2026. Setup and rollback commands
are in the [Linux guide](linux-direct-hid.md). Input works in the last confirmed
session; reliable recovery after logout, reboot, or switching hosts has **not**
been established.

## Tested environment

| Component | Version |
| --- | --- |
| ESP Remote / iOS | 2.2.9 (53) / 26.7 |
| Host | KeeFRogBz, Bazzite 44 |
| Kernel | 7.2.4-ogc3.1.fc44.x86_64 |
| BlueZ | 5.87 |
| WirePlumber / PipeWire | 0.5.12 / 1.6.8 |

The existing iPhone bond and the second host (Mac) were retained. No kernel,
driver, or package was replaced. The final setup has one BlueZ API drop-in, an
on-demand LE command, and a separate audio receiver switch. No reconnect service
or reactive audio guard is installed.

## Initial success and session failures

On September 18, restarting Bluetooth with its experimental userspace API
enabled allowed explicit LE connection and attached the phone's kernel HID.
The maintainer confirmed input through several app background/foreground cycles.
An initial deliberate LE disconnect also recovered before the helper issued a
new connection request. Promoting the temporary API override to persistent setup
and repeating installation preserved the working connection.

After Linux logout/login, the maintainer reported lost HID on both Linux and Mac
and phone audio routed to Linux. Linux had Classic connected, LE disconnected,
unresolved services, and a retained UHID device. Explicit LE connection returned
`Operation already in progress`. The Bluetooth daemon had not restarted.
Setting the phone's preferred bearer to LE and explicitly resetting this phone's
connection restored Linux HID; the maintainer confirmed working input. This did
not isolate the preference's effect or explain the Mac's failure.

Audio returned after suspend/resume despite `PreferredBearer=le` and a per-phone
audio profile set to `off`. A reactive audio guard could disconnect audio but
was rejected because a brief connection can still interrupt playback. It was
disabled and subsequently removed, including its experimental implementation.

## Audio receiver switch

The maintainer chose a reversible switch for reception from all phones in the
user's audio session. Disabling it removed local Audio Sink UUID `110b`, while
retaining Audio Source `110a` and Handsfree Audio Gateway `111f`. WH-1000XM5 was
again the default PipeWire output; the iPhone retained LE and attached HID with
Classic disconnected. The menu entry was pinned beside both panels' system trays.

The disabled receiving roles survived the host reboot at 01:00 on September 19.
The obsolete per-phone `51-iphone-no-audio.conf` was backed up and removed to
avoid interfering when reception is enabled again. This host-specific migration
is separate from the portable installer. Parser integration tests verified that
off/on restores the underlying configuration. Headphone playback, headset
microphone operation, and repeated sleep/login cycles still require physical
testing; retained roles and a default-output snapshot do not prove all of them.

## Reboot recurrence and captured kernel defect

At 05:09, the iPhone remained bonded and trusted on both bearers, with the LE
preference saved, but neither bearer connected. The cached UUID list lacked HID.
The app showed live HID subscriptions for the Mac while Linux remained pending.
The helper incorrectly required cached HID before status or explicit connection;
that condition was removed and regression-tested. LE requests still timed out,
so the helper defect was not the complete cause.

A fresh HCI trace captured the iPhone advertising a resolvable private address
with type **Random**, followed by LE Extended Create Connection to that same
address with type **Public**. The request did not connect; after cancellation,
the controller reported Unknown Connection Identifier. Active discovery resolved
the address to the existing bonded identity, demonstrating that the phone was
visible and its identity resolvable.

This matches upstream Linux commit
[`555cd2bd860e`: keep dst_type with dst when reusing an LE connection](https://github.com/torvalds/linux/commit/555cd2bd860e7c4bdc3f4e4405b05515b0d9bc87).
Disassembly of the installed `bluetooth.ko` confirmed that its reuse path copies
the address without updating the type. The installed module was built on
September 13 before the patch was authored later that day. Repeated user-space
requests cannot repair this kernel path.

At the time of the September 19 check, the registry's
`bazzite-deck-nvidia:stable` image was `44.20260916`, with the same
`7.2.4-ogc3.1.fc44.x86_64` kernel. No verified fixed package was found in that
checked channel. Kernel activation would require reboot; this is not an additive
userspace package suitable for `rpm-ostree install -yA` live application.

## Manual recovery and actual input verification

Around 05:17, LE and the HID service reappeared, but UHID subsequently vanished
and input reports produced `EINVAL`. At 05:20, overlapping tests included a
scoped LE reset and a manual **Connect for KeeFRogBz in the Bluetooth device
list**. The maintainer identified that manual action as restoring ESP Remote.
The helper did not issue another Connect, but that does **not** establish native
autoconnection or prove the reset caused recovery. The manual action's exact
transport sequence was not captured.

The host then reported `LE=yes, Classic=no, services=yes, HID=attached`. The
maintainer initially confirmed input, then reported that connected status still
did not produce input. The descriptor matched the app, report protocol was
selected, and all four report notification descriptors read `0100` (enabled).

A bounded 90-second reader counted only this phone's HID and input events,
without storing key contents: 338 mouse HID reports, 30 keyboard HID reports,
585 relative-motion events, and 20 keyboard key events. During this check, the
maintainer twice confirmed working input. The reader exited and closed its file
descriptors. No reconnect, notification write, or audio/service change occurred
during that check. Why input resumed in this phase was not isolated.

The Bluetooth daemon's PID/start time remained unchanged; bonds were retained,
receiving audio remained off, and no reconnect watcher was installed. This
confirms temporary working input, not fixed future recovery. The kernel defect
explains the captured malformed connection attempt; it is not established as the
sole cause of every outage or proof that its patch alone fixes all behavior.

## Evidence and remaining checks

Private captures and selected excerpts are stored locally under
`~/.local/state/esp-remote-control/diagnostics/2026-09-19/reconnect-0509/`:
`findings.md`, `address-type-evidence.txt`, `kernel-address-fix.patch`,
`hci_connect_le.disassembly.txt`, `gatt-notification-state.txt`, and
`input-counts.json`. The raw HCI trace is not included in the repository.

Still needed: a verified patched kernel followed by controlled reboot,
logout/login, sleep/resume, app lifecycle, and host-switching tests. Each needs
both the transport/HID state and actual cursor/keyboard confirmation. Automated
helper tests check request selection and local configuration behavior; they do
not establish Bluetooth reliability on physical devices.
