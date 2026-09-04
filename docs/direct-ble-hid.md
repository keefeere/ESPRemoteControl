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
  encrypted report subscriptions, peripheral restoration, and connection logs.
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
The [current subscribers](https://developer.apple.com/documentation/corebluetooth/cbmutablecharacteristic/subscribedcentrals)
and input subscription callbacks remain the authority for HID readiness.

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
