# Direct BLE HID: v2 research

Reviewed: 2026-09-04. Status: the v2 prototype is implemented. HID report/session
tests and the Xcode 26.6 iOS build passed for commit `802bb64`, producing version
2.0.0 (16) ([run and IPA artifact](https://github.com/keefeere/ESPRemoteControl/actions/runs/33843087676)).
The user confirmed keyboard and mouse input on a physical iPhone/macOS pair.
The app reused the pairing created with BlueTouch; input began after toggling
Bluetooth off and on on the Mac. This records the observation, not a confirmed
root cause. The user also confirmed input on Linux, with an inconsistent
connection process. Windows testing remains pending. The sections below preserve
the research evidence and acceptance criteria.

## Decision and evidence

Keep direct Bluetooth keyboard/mouse as v2. Defer LAN host mode (formerly v3).
The user has tested BlueTouch successfully against macOS and Linux without an
ESP32 adapter or companion application. Windows is still unverified by the user.
BlueTouch's [App Store description](https://apps.apple.com/us/app/bluetouch/id1622635358)
also explicitly describes direct Bluetooth operation without additional software.

The earlier conclusion that iOS cannot implement this was too broad. Historical
failures to publish the short HID UUID do not establish that every CoreBluetooth
HID implementation fails.

Two public sources identify a concrete implementation path:

- In the [conath HID example discussion](https://gist.github.com/conath/c606d95d58bbcb50e9715864eeeecf07),
  experimenters report that the full UUID allows service registration, followed
  by successful typing on Android and Windows and a separate Mac confirmation.
  The 2024 follow-ups also document descriptor fixes and reconnect problems;
  the old example itself should not be treated as a finished implementation.
- [darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote) contains an iOS
  CoreBluetooth HID peripheral. Code inspected at commit
  `ad7a76ce6132254fbd6085af87cea8d10aa8a82d` (2026-07-24). Its author describes
  host compatibility and platform-specific pairing constraints. This is source
  inspection and upstream reporting, not our own runtime verification.

BlueTouch's source and a Bluetooth capture from the user's devices were not
available for inspection. HOGP is the working architectural explanation; the
claim that BlueTouch uses exactly the same UUID construction and GATT layout
remains an inference. There is no need to reproduce its UI to implement v2.

## How direct mode works

The [HID over GATT Profile](https://www.bluetooth.com/specifications/specs/hid-over-gatt-profile-1-0/)
provides the standard Bluetooth LE input protocol. The proposed path is:

```text
iPhone keyboard / trackpad
    -> CBPeripheralManager publishing HID over GATT
    -> computer's built-in Bluetooth HID support
    -> keyboard / mouse input
```

This reverses our current BLE role: the iPhone currently acts as a central,
writing custom commands to an ESP32 peripheral. In direct mode the computer is
the central and subscribes to input reports published by the iPhone.

The concrete UUID distinction is `1812` versus
`00001812-0000-1000-8000-00805F9B34FB`. Apple documents the
[equivalence of short SIG UUIDs and the Bluetooth base UUID form](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/PerformingCommonPeripheralRoleTasks/PerformingCommonPeripheralRoleTasks.html).
The inspected [HIDProfile.swift](https://github.com/jqssun/darwin-bt-remote/blob/ad7a76ce6132254fbd6085af87cea8d10aa8a82d/BTRemote/LowEnergy/HIDProfile.swift)
uses full strings for the services, characteristics, and descriptors. It defines
separate keyboard and mouse report identities, plus optional reports. Acceptance
of this form is an observed implementation behavior, not an Apple guarantee of
HID peripheral compatibility across iOS releases.

The inspected [HIDPeripheral.swift](https://github.com/jqssun/darwin-bt-remote/blob/ad7a76ce6132254fbd6085af87cea8d10aa8a82d/BTRemote/LowEnergy/HIDPeripheral.swift)
constructs a HID service with Report Map, Report, Report Reference descriptors,
HID Information, Protocol Mode, and boot characteristics. Reports require
encrypted access. It advertises the HID service, answers host reads, sends an
initial report when the host subscribes, and uses `updateValue` for input.
Report Reference (`0x2908`) is a descriptor attached to a report characteristic,
not an additional report characteristic. These details explain why merely
changing the service UUID is insufficient.

The reference's [iOS project configuration](https://github.com/jqssun/darwin-bt-remote/blob/ad7a76ce6132254fbd6085af87cea8d10aa8a82d/project.yml)
does not configure a special iOS HID entitlement. Its BLE path uses public
CoreBluetooth APIs. Its code is AGPL-3.0-only; no implementation code has been
copied into this repository.

## Implementation sequence for this app

1. Build a small HOGP prototype: advertise, pair from the host, send and release
   one key, move the pointer, click, and scroll. Log registration, reads,
   subscriptions, and send readiness. Record iOS and host OS versions.
2. Introduce `DirectHIDTransport` behind `InputTransport`. Move observable
   connection state and mode selection into a controller shared by the views;
   `ContentView`, `RemoteKeyboardView`, and `ControlPadPage` currently depend on
   the concrete `BLEKeyboardBridge` type. Reuse `Shared/HID.swift` and
   `Shared/TextTypingPlanner.swift`.
3. Encode complete keyboard/button state into HID reports. Preserve every
   key-down/key-up transition under notification backpressure; do not replace a
   pending text sequence with only its latest report. Keep mouse movement
   ordering consistent with button transitions.
4. Add direct-mode pairing/status UI, host selection, input release on mode
   changes, peripheral background configuration, and reconnect handling. Retain
   ESP mode as the existing USB path. Shortcuts should wait for the selected
   transport to become ready before sending text.
5. Validate on macOS, Linux, and Windows: English/Ukrainian layouts, held keys,
   modifier chords, drag, both scroll axes, long text, Bluetooth interruption,
   host restart, app relaunch, and switching transports without stuck input.

Pairing and GATT cache behavior need real-device checks. Passing service
registration or compiling successfully is not sufficient acceptance evidence.
The inspected implementation is a feasibility reference, not a substitute for
checking our own report map and protocol behavior against the HID specifications.

## Prototype implementation

- `DirectHIDTransport` publishes keyboard/mouse HID, handles host reads/writes,
  encrypted report subscriptions, fresh peripheral setup on launch, and connection logs.
- `BluetoothHostBrowser` adds outgoing BLE connections from the phone and system
  connection events. An outgoing link does not count as working HID until the
  host subscribes to both input reports; Mac behavior needs a real-device test.
- `RemoteInputController` switches routes after release reports, keeps ESP as
  the initial default, and remembers the user's choice.
- The existing status strips expose mode selection and pairing in both input
  tabs. Shortcuts and the existing keyboard/trackpad use the selected route.
- `Shared/HIDReports.swift` owns HID encoding, FIFO backpressure, and single-host
  session state, with executable checks in `Tests/DirectHIDTests.swift`.

## Remaining BlueTouch-specific verification

If exact interoperability details are needed, capture a BlueTouch connection on
the already working Linux host and record the advertised services, discovered
GATT tree, Report Map bytes, Report Reference values, security negotiation, and
input notifications. Initial pairing/service discovery and a later reconnect
should be separate cases because the host can cache the GATT database. Compare
that trace with our prototype. The host-visible trace can establish the wire
protocol; it cannot prove which Swift/Objective-C API BlueTouch calls internally.

Direct HID still sends key usages interpreted by the host layout; it does not
provide arbitrary Unicode or a two-way clipboard protocol. Those remain possible
future reasons for LAN mode, not prerequisites for the requested keyboard/mouse.
Pre-OS support in direct Bluetooth mode must be tested per host; the existing
ESP32 USB mode remains the established path for that use case.

## Saved computers and reconnect diagnostics (2.0.5)

The Bluetooth sheet now keeps multiple computers, shows the selected and
HID-ready host, and allows selection, a local display name, and “Forget in app”.
The existing selected host and outgoing connection name migrate on upgrade.
Input is sent only to the selected host; switching first drains neutral reports
and discards queued input. A known incoming-only host may still need to initiate
the link from the computer. Selecting a host does not forcibly disconnect a
system Bluetooth link owned by the computer or another app.

Names are used only when CoreBluetooth resolves them for the same identifier.
A `CBCentral` does not provide a friendly name, so incoming hosts can appear as
“Комп’ютер · <short ID>” until named by the user or discovered by the browser.
“Forget in app” removes saved selection and automatic reconnect data. Forgetting
the selected host closes pairing, including after relaunch; stale subscriptions
cannot immediately add it back. Explicitly opening pairing can add it again.
System pairing is separate and can be removed in the iPhone/computer's Bluetooth
settings. The Share extension retains its existing separate preferences container
and selected host; host management here applies to the main application.

The supplied 2.0.2 Linux log shows both keyboard and mouse subscriptions at
13:08:37, then both unsubscribing at 13:10:18, followed by an advertising error.
It contains no error details or peer identities and does not establish a KDE
Connect conflict. The app now serializes pending advertising starts, handles a
HID connection becoming ready before advertising completes, and logs shortened
peer IDs plus error domain/code/message. An outgoing BLE disconnect does not
clear HID state while the selected host remains subscribed to input reports.
Apple explicitly notes that
[`cancelPeripheralConnection`](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection(_:))
does not necessarily disconnect the physical link when another app still uses it.
Fresh input subscription callbacks establish HID readiness. Stored entries in
[`subscribedCentrals`](https://developer.apple.com/documentation/corebluetooth/cbmutablecharacteristic/subscribedcentrals)
are no longer adopted while changing hosts because they can represent the stale
session that recovery is intended to replace.

Device acceptance checks for this update:

- Upgrade without deleting the existing Mac/Linux pairing; confirm the current
  host and assign a name if necessary.
- Save a second computer, switch in both directions, and verify that held input
  is released on the old host and new input goes only to the chosen host.
- Forget an inactive host; verify the active computer keeps working. Forget the
  active host and relaunch; verify it is not silently selected again.
- Compare reconnecting with KDE Connect active and inactive, keeping system
  pairing intact initially. Share the new connection log for each case before
  concluding that another Bluetooth profile prevents HID.

Host-store migration/isolation/forget and asynchronous advertising ordering have
automated checks in `Tests/DirectHIDTests.swift`; actual host switching, system
pairing, and coexistence require physical-device validation.

## Startup crash during GATT restoration (2.0.6)

A user-supplied crash report for 2.0.5 (21), iOS 26.6.1, shows SIGABRT shortly
after launch. Its last exception backtrace runs through
`-[CBPeripheralManager handleRestoringState:]` into
`-[CBMutableDescriptor initWithCharacteristic:dictionary:]` and
`-[CBMutableDescriptor initWithType:value:]`, ending in an assertion. This happens
inside CoreBluetooth before the application's `willRestoreState` callback; an
ordinary Swift error handler or a guard in that callback cannot prevent it.
The report does not include the assertion text or offending descriptor value,
so the exact persisted descriptor responsible is not established.

The HID peripheral no longer opts in with
[`CBPeripheralManagerOptionRestoreIdentifierKey`](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanageroptionrestoreidentifierkey).
It creates fresh services after Bluetooth powers on. The unused preserved-GATT
decoder has been removed. Live subscription adoption for switching hosts remains,
as do separately stored host names, selected host, and system Bluetooth bonds.
The same transport fix applies to the Share extension. The tradeoff is that iOS
will not restore/relaunch this peripheral after terminating the process; opening
the app starts HID again. Existing background Bluetooth modes remain enabled.

The main input screen displays a temporary `v<version> (<build>)` stamp at the
bottom right of its connection header, inside existing padding. It uses an overlay
with hit testing disabled, so it does not move controls or intercept touches.
The Settings version and shared connection log now include the build number too.

The crash requires preserved CoreBluetooth state on a physical iPhone. Report and
host-store tests plus a successful simulator/device build cannot reproduce that
OS restoration path. Device acceptance is to update without reinstalling, launch
repeatedly with direct Bluetooth selected, and confirm input after reconnecting.


The user subsequently confirmed that the startup crash was resolved after the
2.0.6 update. Mac/Linux host switching and reconnect behavior remain under device
testing; intermittent manual Bluetooth toggles/re-pairing have been reported,
followed by successful reconnects. These observations do not yet establish a
reliable multi-host switching sequence.

## Quick computer selection (2.0.7)

Tap the computer name/status in the Bluetooth connection strip to open a menu of
saved computers, both on the main input screen and in the compact keyboard strip.
The connected host has a checkmark; a selected host awaiting input subscriptions
has a clock. Selecting an entry uses the existing host-selection/release path.
Opening the menu itself does not scan, open pairing, or change the selected host.
The menu also links to pairing a new computer, including when the saved list is
empty. This is a UI shortcut; it does not change Bluetooth reconnect behavior.

## Reconnect after computer sleep (2.0.9)

Physical-device tests of 2.0.8 found two distinct failures: a Mac could wake
while the app still showed an HID-ready session that no longer delivered input,
and a Linux host could remain disconnected until the user selected the iPhone
again in the host Bluetooth UI. The old implementation ignored a peer-disconnect
event whenever `subscribedCentrals` still contained the host. Those entries can
outlive the working link, so they are no longer sufficient to overrule an
external disconnect event.

The browser now distinguishes an app-requested cancellation of its auxiliary
central-role link from an external link loss. Only the former may preserve a
still-subscribed HID peripheral session. A real peer disconnect immediately
clears HID readiness and queued input, keeps the HOGP advertisement available,
and reissues the remembered outgoing connection when CoreBluetooth can retrieve
the selected host. Incoming-only hosts still need the host OS to initiate the
HID connection, but they no longer depend on a short advertisement window.

The outgoing `connectPeripheral` request is no longer cancelled after 20 seconds.
Apple documents that these requests do not time out and can complete when the
peer becomes available, which is the desired behavior across computer sleep:
[Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).
The 20-second timer now changes only the explanatory status. The toolbar refresh
button performs a full removal and recreation of the HID GATT services, providing
an app-side recovery path for stale notification state without toggling Bluetooth
on the computer. The visible ready label says “HID ready” because
`updateValue` acceptance is transmission-queue state, not an acknowledgement
from the host:
[`peripheralManagerIsReady(toUpdateSubscribers:)`](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanagerdelegate/peripheralmanagerisready%28toupdatesubscribers%3A%29).

The iOS app publishes the BLE HID service and does not request an audio profile.
BlueZ's generic `Connect` operation attempts all eligible profiles, which explains
why selecting the whole iPhone in a Linux Bluetooth UI may also route iPhone
audio to the computer. BlueZ also exposes `ConnectProfile` for one remote service
UUID: [BlueZ Device API](https://bluez.readthedocs.io/en/latest/device-api/).
For diagnosis, a Linux host can request only the HID-over-GATT service with:

```
bluetoothctl connect <iPhone-device> 00001812-0000-1000-8000-00805f9b34fb
```

Whether KDE/BlueZ automatically reconnects that profile is host policy outside
the app's CoreBluetooth process. Test the new build first with the existing bond:
let Mac sleep and wake without toggling Bluetooth; on Linux compare the generic
UI connection with the HID-specific command, and check that audio remains on the
iPhone. The connection journal now records the disconnect cause and whether stale
report subscriptions were still present.

## Automatic staged recovery (2.1.2)

Physical tests of 2.0.9–2.1.1 refined the failure sequence. Selecting the Mac
could immediately show HID ready while no input arrived; one manual refresh then
made it work. Linux recovery after wake could require switching to ESP, switching
back to direct Bluetooth, and then refreshing. That sequence demonstrates that
both the CoreBluetooth manager lifetime and the host's cached GATT notification
state can matter.

Host selection no longer adopts entries from `subscribedCentrals` on the old
characteristic objects. It clears the session and republishes the services, so
only new `didSubscribeTo` callbacks can establish readiness. A reconnect to a
saved host is now staged:

1. Create or republish the HID services and let the host connect.
2. Once the host subscribes, or after 2.5 seconds without subscriptions, perform
   exactly one additional service refresh to invalidate cached notification
   state.
3. Expose the green ready state only after subscriptions arrive on that final
   service publication.

A small `HIDRecoveryPlan` state machine consumes the second-stage refresh once,
preventing a retry loop. A real peer disconnect performs a full recreation of
both CoreBluetooth managers before the staged service publication. The same full
recovery is scheduled when HID report subscriptions end. If the host resubscribes
before an unsubscribe-triggered restart, that restart is cancelled. Returning to
the app after at least three seconds in the background also runs full recovery,
as does the manual refresh button. This automates the user-tested ESP → Bluetooth
→ refresh sequence while retaining the refresh button as a manual fallback.

The Linux “full device” entry is a consequence of Bluetooth bonding rather than
an audio request by this app. HOGP characteristics require encryption, so pairing
the keyboard creates a bond with the physical iPhone. A dual-mode Bluetooth
implementation may use cross-transport key derivation to derive a BR/EDR key from
an LE key, allowing one pairing action to authorize both transports:
[Bluetooth Security Manager specification](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core_v6.3/out/en/host/security-manager-specification.html).
BlueZ's generic `Connect` then tries eligible profiles for that known device,
including system audio profiles exposed by iOS. The app still publishes only the
BLE HID, battery, and device-information services; it does not initiate A2DP or
HFP. Connecting the iPhone separately is not required for direct HID.

Physical acceptance checks are Mac sleep/wake without toggling Bluetooth, host
switching in both directions without pressing refresh, Linux sleep/wake with KDE
Bluetooth UI closed, and returning from iOS background. The journal should show
“Automatic second-stage HID service refresh” once per recovery and must not
repeat it continuously.

## Escalating reconnect recovery (2.1.3)

Physical tests of 2.1.2 on Linux reported that reconnect became reliable only
after force-quitting and reopening the app, and that the link could be started
only from the computer, where the desktop's generic connect also routed iPhone
audio there. Reviewing the transport against those two reports found the
following.

Every recovery path in 2.1.2 was edge triggered: a peer disconnect, a report
unsubscribe, a return from the background, or the manual refresh button. A
computer that simply stops reconnecting produces none of those edges, so the
transport waited indefinitely. Three specific ways to reach that state existed:

- `peripheralManagerDidStartAdvertising` recorded a failure and then called
  `refreshStatus(updateAdvertisement: false)`, deliberately skipping the retry.
  The advertising state machine also returns no action after a failed start.
  Nothing else reissued it, so a single failed start left the phone invisible
  until the process restarted. The 2.0.2 Linux log quoted above ends in exactly
  that sequence: both reports unsubscribing, then an advertising error.
- `disconnected(_:cause:)` returned early unless `session.host` matched the peer.
  A selected computer that dropped its link before subscribing to any report
  therefore produced no state change at all.
- The second-stage service refresh removes and re-adds the GATT database. When
  it ran against a host that had just subscribed, and that host did not
  resubscribe, no further callback arrived to recover from.

2.1.3 adds `HIDReconnectWatchdog`, an escalating ladder that runs whenever the
transport wants to be reachable and has no working session: reissue the
advertisement after 10 s, republish the HID services after another 20 s, then
rebuild both CoreBluetooth managers after another 40 s, staged exactly like a
relaunch. Each rung runs once; a report-map read or a report subscription
rewinds the ladder; an exhausted ladder keeps advertising and reports
"Немає відповіді" rather than restarting Bluetooth in a loop. An open pairing
window with no selected host only repairs visibility, because rebuilding the
stack there would close the window with nothing to reconnect to. The ladder is a
pure value type with checks in `Tests/DirectHIDTests.swift`; the wiring itself
still needs device validation.

The staged refresh is now conditional. A host that read the report map on the
current publication has re-discovered the database, which is what the refresh
exists to force, so consuming it there would tear down a session that had just
started working. This matters most on BlueZ, which keeps a cached GATT database
for bonded devices and need not resubscribe after an unnecessary republication.

`transmit` no longer reports backpressure for a report larger than the host's
`maximumUpdateValueLength`. Nothing had been handed to CoreBluetooth in that
case, so the readiness callback that would resume the queue could not arrive and
every later keystroke queued behind it. Such a report is now dropped and logged
once. Subscriptions also log the negotiated notification size.

### Linux connection direction and audio

Neither reported Linux behaviour is a defect in this app, and both now have
documented handling in [direct Bluetooth HID on Linux](linux-direct-hid.md):

- A BlueZ desktop is a GATT client and does not advertise over Bluetooth LE, so
  the phone cannot discover it and **Знайти комп'ютер** cannot list it. The
  computer initiates every connection; the phone's part is to stay advertising,
  which the ladder above now maintains. The pairing sheet says this explicitly
  instead of presenting phone-initiated discovery as a general path.
- `Connect()` connects every eligible profile of a bonded device, and the LE
  pairing authorises BR/EDR through cross-transport key derivation, so the
  iPhone's audio profiles become eligible. `ConnectProfile()` with the HID UUID
  connects one profile instead. `scripts/linux-hid-connect.sh` wraps that call,
  falls back to `busctl`/`dbus-send` on BlueZ older than 5.65, waits for the
  kernel to attach a HID device rather than trusting the bare link, and can watch
  the profile and disconnect audio that something else connected.

Device acceptance checks for this update:

- Let the Linux host sleep and wake without touching the app. The journal should
  show the ladder starting at "Recovery 1/3" and stopping as soon as the host
  subscribes, and input should return without a relaunch.
- Confirm "Recovery 3/3" appears at most once per outage and that the ladder does
  not repeat after it. A repeating ladder means readiness is being reported and
  lost, not that the ladder is looping.
- Connect with `scripts/linux-hid-connect.sh --trust` and verify that iPhone
  audio stays on the phone, then compare with the desktop applet's Connect.
- Reconnect on a host that keeps its GATT cache and confirm the journal shows
  either a report-map read followed by "second-stage refresh skipped", or one
  "Automatic second-stage HID service refresh" — never both, and never repeated.

## Rearming recovery after a descriptor read (2.1.4)

Device testing of 2.1.3 confirmed that reconnect after a Linux host slept and
woke now works without relaunching the app. Switching the selected computer to a
Mac did not: the app stayed on "Очікуємо клавіатуру й мишу" indefinitely.

The cause is in 2.1.3's own wiring. `didReceiveRead` treats a Report Map read as
evidence of progress and rewinds the recovery ladder, but that delegate method
never calls `refreshStatus`, which is the only place the next rung is scheduled.
Cancelling the pending step there therefore left no pending recovery at all. A
host that reads the descriptor and then goes quiet — a Mac performing GATT
discovery without attaching HID — put the transport back into the exact state
2.1.3 set out to remove. The read path now rearms explicitly.

The status line hid this too. `browser.requestedHost` stays set because the
outgoing connect request is deliberately never cancelled, so the branch reporting
"Очікуємо клавіатуру й мишу" ran ahead of the exhausted-ladder branch and an
abandoned reconnect still read as progress. Both waiting branches now share one
helper that reports "Немає відповіді" once the ladder is spent.

Neither fix is reachable from `Tests/DirectHIDTests.swift`: the defect is in the
CoreBluetooth delegate wiring, not in `HIDReconnectWatchdog`, whose value-type
behaviour was already correct and already covered. Device acceptance is to
switch the selected computer to a Mac and confirm that the journal shows the
ladder running — "Recovery 1/3" through "Recovery 3/3" — rather than falling
silent after "Report map read".

### Refused peers and the two identities of one computer

A 2.1.3 journal from a failing switch to a Mac shows the recovery ladder running
correctly — `Recovery 1/3` through `3/3`, one second-stage refresh per staged
reconnect — while every read and both report subscriptions are refused:

```
Selected: 14AE093E
Read rejected:        9B25BF0B; selected 14AE093E
Ignored subscription: 9B25BF0B, keyboard; selected 14AE093E
```

The recovery machinery cannot repair this, because the transport is refusing the
peer on purpose: `HIDHostSession.allows` pins input to the selected host. No
`Report map read` appears at all, since the read is refused before reaching that
case.

Which refusal this is cannot be told from the identifier. CoreBluetooth gives a
peer separate identifiers in the central and peripheral roles, so the selected
computer arriving as a GATT client is indistinguishable from a different machine
by identifier alone. Both readings fit that journal:

- The Mac under its `CBCentral` identity, while the saved entry holds the
  `CBPeripheral` identity learned by the browser. The fix would be to keep both
  identifiers against one saved computer.
- A previously bonded Linux host reconnecting on its own. The refusal is then
  correct, and the real fault is that the Mac never arrives.

Adopting the refused peer automatically is not safe under the second reading: it
would route input to the wrong computer, which is what the pinning exists to
prevent. The journal instead now records, once per peer per publication, the
name CoreBluetooth can resolve for the refused peer and whether this app's own
central-role link to the selected host is connected at that moment. Repeated
read refusals are no longer logged individually; they filled the 60-line journal
without adding anything.

Until that evidence arrives, the workaround is «Дозволити нове сполучення»,
which routes through `prepareHost(nil)` and clears the selected host, so
`allows` falls through to the pairing window and accepts the peer. It is saved
as a separate computer and can be renamed; the stale entry can be forgotten.

## Remote wake and the pairing window (2.1.5)

A 2.1.4 journal settles the host-switching question and raises two others.

Switching **to** the Mac works and is fast: selection, outgoing link, report map
read, both subscriptions and HID ready inside one second, with
"second-stage refresh skipped" confirming the 2.1.3 rule doing its job — the
host re-discovered the database, so no republication was spent tearing the new
session down.

Switching **back** to the Linux host does not. Its link connects, but it never
reads the report map and never subscribes; nothing arrives from it at all. The
recovery ladder ran in full and reported "Немає відповіді", which is the honest
answer: recovery can make the phone reachable, but it cannot make a host
subscribe. The refusals interleaved through that journal are the Mac
reconnecting on its own and being correctly refused while another host is
selected. Re-attaching the profile from the Linux side, which
`scripts/linux-hid-connect.sh` exists to do, is the path to test next.

### The pairing window went to whichever host reconnected first

`allows` fell through to `allowsPairing` for any peer once the selected host was
cleared, and `beginPairing` clears it. A bonded computer reconnects in about a
second, so opening the window to add a new computer handed it to a saved one
instead, which is the opposite of its purpose. A saved host is now refused
while the window is open: those are chosen from the list, which pins them
directly. Forgetting a computer removes it from that set, so re-pairing still
works.

### The host was told this device cannot wake it

The Mac does not wake from sleep for the app while a Logitech mouse does. HID
Information (`0x2A4A`) carried flags `0x02`: NormallyConnectable set,
**RemoteWake clear**. That bit is how a HOGP device declares it can wake a
sleeping host, and this one was declaring the opposite. The flags are now
`0x03`, and the value moved to `RemoteHIDDescriptor.information` so the bits are
covered by `Tests/DirectHIDTests.swift`.

Confirmed on device: with 2.1.5 the Mac wakes from sleep for the app, which it
did not do while the flag was clear. That establishes the flag as the cause of
the original symptom, and that macOS honours it without any per-device setup on
this pair. It does not establish the same for other hosts — remote wake still
depends on the host's own policy, and macOS keeps a per-device wake allowlist —
so Windows and Linux need their own check.

Waking is not instant: the host has to wake, reconnect and resubscribe, so
input returns after some seconds rather than immediately. That delay is the
computer waking up, not necessarily the recovery ladder; the journal
distinguishes them, since a rung that ran logs "Recovery n/3" before
"HID ready".

### What the app cannot supply

The pairing sheet suggested `bluetoothctl connect <MAC> 00001812-…`, leaving the
address to be looked up. iOS exposes no Bluetooth address to applications, and
the phone advertises with a rotating private address, so the app cannot fill it
in. The hint now points at `scripts/linux-hid-connect.sh`, which resolves the
paired device itself, and names `bluetoothctl devices Paired` for doing it by
hand.

## Removing the second-stage refresh (2.1.6)

A 2.1.5 journal shows the staged refresh doing exactly the damage it was meant
to prevent. Three seconds after each publication, before either host had read
the report map, it removed and re-added the whole GATT database:

```
16:40:36 Advertising HID
16:40:36 Outgoing BLE link connected: 9B25BF0B
16:40:39 Automatic second-stage HID service refresh; selected 9B25BF0B
16:40:39 Outgoing BLE disconnected ... Service registered x3 ... link connected
16:40:46 Recovery 1/3: reissuing the HID advertisement
```

Every host selection repeated it, so a user switching between two computers
rebuilt the database every few seconds and neither host could ever finish
discovery. The reported consequences were both hosts failing to connect, one Mac
eventually working after a very long delay, and that Mac asking to pair again
although it was already bonded — repeatedly tearing down and republishing
encrypted characteristics is enough to provoke that.

The mechanism came from 2.1.2, when a host that reconnected with a cached GATT
database appeared not to resubscribe. 2.1.3 narrowed it to skip the refresh once
the host had re-read the report map, which helped when the host got that far
inside the window and did nothing when it did not. The window was always the
flaw: 2.5 seconds is shorter than host discovery after a reconnect.

`HIDRecoveryPlan` and `scheduleServiceRefresh` are removed. Republishing the
services is now only a rung of `HIDReconnectWatchdog`, which is where a
cache-breaking republication belongs: it runs when nothing has arrived for a
while, rather than on a timer that starts before the host has had a chance.
This removes a mechanism that was never confirmed to fix anything on a device
and is now confirmed to break several. If a host with a cached database really
does fail to resubscribe, a ladder rung covers it, and the journal shows it as
"Recovery 2/3" rather than as an unexplained teardown.

### Switching computers stops republishing anything

The same teardown ran on every host selection, which is why switching cost tens
of seconds against about one second for a physical Bluetooth keyboard. That
comparison is the right bar, and the republication was never needed to meet it:
the GATT database is identical for every host, and choosing where input goes is
app-side state. `selectHost` now swaps the session and leaves the database
alone, and a computer still listed on both input characteristics is adopted
directly, so switching to a connected host is immediate.

2.1.2 had abandoned adoption because a `subscribedCentrals` entry can outlive
the link it describes. That reasoning weighed a stale entry against nothing; the
real alternative was a rediscovery on every switch. A stale entry now costs one
recovery delay, which is the cheaper of the two by a wide margin.

With the normal path clear of the ladder, its first rung can run sooner: 5 s to
reissue the advertisement, which disturbs no established link, then 25 s to
republish and 70 s to rebuild the managers. A genuinely new host still gets 25
undisturbed seconds, against 2.5 before.

Adoption lives in the CoreBluetooth delegate layer and needs a real `CBCentral`,
so `Tests/DirectHIDTests.swift` cannot reach it; only the ladder's schedule is
covered there. The device check is to switch between two connected computers and
see input follow immediately, with "Adopted live HID subscriptions" in the
journal and no "Service registered" lines.

## Suspend must not stop input (2.1.7)

Recovering a Mac from sleep left 2.1.6 stuck on "Комп'ютер призупинив ввід" until
the refresh button was pressed. The journal shows why:

```
19:45:16 HID ready: 9B25BF0B
19:45:16 Host suspended input
19:45:21 Recovery 1/3: reissuing the HID advertisement
19:45:30 Manual full Bluetooth restart
```

The Mac writes `0x00`, Suspend, to the HID Control Point as it sleeps.
`HIDHostSession.isReady` required `!suspended`, so the transport refused to send
anything — and Exit Suspend never arrives, because nothing wakes the host. The
deadlock is exact: waking the host requires sending a report, and sending was
forbidden precisely because the host was asleep. Only rebuilding the stack, which
discards the flag, escaped it.

HOGP asks a suspended device to reduce its own power, not to stop reporting. A
device that declares RemoteWake — which this one now does, since 2.1.5 — wakes its
host by sending an input report, and the host answers with Exit Suspend once
awake. Readiness no longer consults `suspended`.

Two supporting changes keep that from waking hosts by accident. Entering suspend
clears held input locally rather than transmitting releases, and
`releaseAllInput` does nothing but clear while suspended, so backgrounding the
app cannot light up a sleeping computer. Only deliberate input earns a wake.

The status line says "комп'ютер спить" beside "HID готовий" rather than blaming
the host for stopping input, and the recovery ladder no longer arms during
suspend, since it was only running because readiness was false.

The old behaviour had a test asserting it — "Host suspend prevents input" — so
the suite confirmed the wrong model rather than catching it. That check now
asserts the opposite, which is the property that matters: sending a report is
how remote wake works.

### The pairing prompt was our own refusal (2.1.7)

A 2.1.6 device report shows macOS asking to pair over and over, with a fresh
passkey each time, while the journal reads:

```
19:53:26 Refusing 9B25BF0B (schechu-us-la1); selected 04613D53 (KeeFRogBz)
19:53:26 Rejected read: 9B25BF0B
```

Reads and writes from a computer other than the selected one were answered with
`CBATTError.insufficientAuthorization`. On an already encrypted link that error
says the bond is not good enough for this attribute, so macOS did the reasonable
thing and tried to establish a better one — every reconnect, forever.

Refusing them bought nothing. A read carries no input, and the pinning that
matters is that only the selected host is notified, which `transmit` enforces by
sending to one central. Reads are now answered for any bonded computer, writes
are accepted and discarded unless they come from the selected host, and the
journal records the unrouted access instead of an ATT error.

### Selecting a host dropped the link it was about to use

The same report shows the handheld never connecting, with this in the journal:

```
19:54:26 Host selected: 04613D53
19:54:26 Outgoing BLE requested: 04613D53, state 3
19:54:26 Outgoing BLE disconnected: 04613D53, no error
```

State 3 is connected: the auxiliary central-role link was already up when the
host was selected. `selectHost` cancelled it and re-requested it in the same
breath, and the asynchronous cancellation landed after the new request, taking
the link with it. It now keeps a link that already points at the selected host
and only cancels one pointing somewhere else.

### The status line described the transport, not the situation

"Очікуємо клавіатуру й мишу · <host>" was the internal state read aloud: the
host has not yet subscribed to the keyboard and mouse report characteristics.
To the person holding the phone it says the app is waiting for a keyboard and a
mouse — which the app itself is. It also said "waiting" while the recovery
ladder was actively advertising and retrying, so it read as passive when it was
not.

The status now names the computer as the actor and says what is happening:
"Під'єднуємось до <host>…" while recovery still has rungs, and
"<host> не відповідає. Підключи iPhone на комп'ютері." once it has given up,
which is the only point where the next move really is the user's. The
distinction between having a link and not having one went with it: it was a
distinction in the transport, not in anything a user can act on.

The other strings got the same treatment — "Підготовка Bluetooth" became
"Готуємо Bluetooth", "Відновлення HID" became "Відновлюємо зв'язок з <host>",
and the pairing state now says where to look: "Готові до сполучення · знайди
«ESP Remote» на комп'ютері". Together with "Комп'ютер призупинив ввід" above,
this was the third status in a row that reported a protocol fact as if it were
the user's problem.

### Holding every computer's link instead of one

Switching still went through a fresh connection, because the browser held
exactly one central-role link and `connect(to:)` cancelled the previous host's
before requesting the next. Each switch therefore destroyed the other computer's
link, and switching back had to build it again — the cost the adoption path was
meant to remove, reintroduced one layer down.

A peripheral serves several subscribed centrals at once. The browser now holds a
link to every saved computer (`maintainLinks`), and switching only changes which
central `transmit` notifies. Forgetting a computer drops its link; nothing else
does.

### Why a physical mouse is instant, and this was not

The question that produced this section was the right one: a real mouse is ready
the moment you switch it on, so why can software not be? The answer is that a
mouse does three things, and the app was doing only two.

1. It advertises the instant it has nothing to talk to. The app does too — the
   advertisement stands for as long as a computer is selected.
2. The computer keeps it in an allowlist with a connect request already pending,
   so the link forms without anyone searching. The app relies on exactly the
   same mechanism.
3. **Its attribute table never changes.** The computer keeps the copy it cached
   at pairing time; reconnecting is a re-encrypt and a re-subscribe, not a
   rediscovery. This is the one the app kept breaking, by hand, several times a
   session.

Four separate paths republished the GATT database, each one invalidating the
cache on *every* paired computer at once:

- the recovery ladder's middle rung, at 25 s;
- the pairing window closing, which restored the selected host by rebuilding;
- a peer disconnecting, which scheduled a full stack restart 0.5 s later;
- an unsubscribe, which scheduled the same thing;
- and returning to the foreground, which forced one unconditionally — so
  glancing at another app for three seconds cost every computer its cache.

That last one is the whole of the reported symptom. The computer was not slow;
the app was throwing away the state that made it fast, and the rediscovery that
followed was blamed on the computer.

Now `installServices()` runs once per peripheral manager and nothing else calls
it. Switching computers, closing a pairing window, losing a peer, an unsubscribe
and a return from the background all leave the table alone. A disconnected
computer keeps its bond and its cache and can come back in about a second, on
its own, with the phone still advertising the whole time.

The ladder is down to two rungs because there is nothing useful in between:
reissue the advertisement at 5 s — a computer cannot reconnect to a phone it
cannot see, and this disturbs no established link — and, only if 30 s more pass
with nothing, rebuild both managers. That last rung does invalidate every cache,
which is exactly why it is last and why nothing else does it. The other timers
are a user-facing pairing window (120 s), a scan (15 s) and sub-second input
pacing.

So the achievable bound is not a compromise: switching between two connected
computers is a change of notification target, well under a second, and a
computer that dropped comes back at its own reconnect speed with its cache
intact — the same second a mouse takes. What is *not* achievable is forcing a
computer that has stopped trying to try again; that is what the ladder is for,
and it should almost never run.

### Fixes found by auditing the whole transport

Removing republication exposed four defects that the old rebuild-everything
paths had been papering over:

- **The pairing window never closed.** `armPairingTimeout` was armed from the
  service installation that used to follow every selection. Once selection
  stopped installing services, nothing armed it, and `allowsPairing` stayed
  true indefinitely. It is now armed where the window opens.
- **Forgetting a computer left its link up.** Links are held by
  `maintainLinks(to:)`, which never sets `requestedHost`, so `forget`'s
  `requestedHost == id` check never fired. It now cancels the peer directly.
- **Exit Suspend discarded the keystroke that caused it.** Both suspend
  directions ran `clearInput()`, which empties the pending report queue — so the
  key press that woke the computer lost its release. Only entering suspend
  clears now.
- **A boot-protocol host could not be adopted.** Adoption looked at
  `session.keyboardChannel`, which a freshly built session always reports as the
  report-protocol channel, so a host subscribed to the boot characteristics was
  never recognised. Adoption now tries both pairs and takes the protocol from
  whichever the host is actually holding.
