# InpuDeck

Turn your iPhone into an additional keyboard, trackpad, and control deck for
multiple computers over direct Bluetooth or an optional ESP32-S3 USB bridge.

## Why This Exists

Ever tried typing a password on a computer or Smart TV without a convenient
keyboard nearby? InpuDeck turns the iPhone already in your hand into a
full-featured keyboard, trackpad, scanner, and hardware control surface.

Direct Bluetooth HID needs no companion app or network connection on the
computer. When USB HID or pre-OS input is required, the optional ESP32-S3
bridge presents itself as a physical USB keyboard and mouse.

## Features

- **English and Ukrainian input** - Automatic alphabet detection with physical US and Ukrainian Enhanced HID mappings
- **Two keyboard modes** - Use the native iOS keyboard beside the trackpad or the dedicated full-screen keyboard tab
- **Layout synchronization** - Configurable Ctrl+Space, Ctrl+Shift, Alt+Shift, Shift+Space, or Win+Space host shortcut
- **Shortcuts sharing** - Send text or URLs from the iOS Share sheet through a one-time Shortcuts setup; the main app waits for BLE and types it reliably
- **Clipboard typing** - Send text from the iPhone clipboard in one tap
- **Precision trackpad** - Cursor movement, two-finger scrolling/right click, pinch-to-zoom, tap-drag, edge scrolling, and three-finger middle click
- **Keyboard trackpad** - Uses the free portrait space below the full keyboard without extra mouse buttons
- **Hardware control deck** - System, media, audio, microphone-mute, and numpad HID controls
- **QR and barcode scanner** - Scan into the composer or automatically type codes, including an optional batch mode
- **Mouse jiggler** - Configurable foreground pointer movement with a selectable movement interval
- **Universal compatibility** - Works with any device that accepts USB HID devices (Smart TVs, computers, streaming boxes, embedded systems)
- **Zero configuration** - No drivers, no network setup, just plug and play
- **Low latency** - Direct Bluetooth LE connection for responsive input
- **Multiple hosts** - Remembers paired computers and lets you select the active destination
- **Optional hardware bridge** - Uses an ESP32-S3 for USB HID and pre-OS input when needed
- **Warm-reboot recovery** - Recovers a stalled USB HID endpoint when a host reboots without removing USB power
- **Optional privacy mask** - Keep the typing composer visible or mask it when entering passwords
- **Hardware key hold** - Every on-screen key sends real HID key-down/key-up events, including multi-finger chords; modifiers can also be tapped to latch

## Direct Bluetooth

Direct BLE HID is the default on a new installation. Keyboard and mouse
input have worked on macOS and Linux, but reconnect remains unreliable across
host/app lifecycle transitions. Bazzite testing of **2.2.9 (53)** confirmed input
and repeated app background/foreground cycles, followed by failures after
logout and reboot. A captured Linux LE connection failure matches an upstream
kernel fix missing from the tested host; a helper alone cannot fix that defect.
See the [Linux validation report](docs/linux-direct-hid-validation.md).
Windows remains untested. The app remembers the selected mode and host.

1. In the connection status strip, open **ESP** and choose **Direct Bluetooth**.
2. Open the pairing button beside the status. To connect from the computer,
   enable pairing in the app and select **InpuDeck** (or the iPhone name) in
   the computer's Bluetooth settings. Confirm any system pairing prompt.
3. To initiate the connection from the iPhone, open Bluetooth settings on the
   computer, choose **Find computer** in the app, then select the computer.
   This path needs the host to advertise over BLE. A BLE link alone is not an
   HID connection; wait until the app reports keyboard and mouse connected.
4. Use the existing keyboard and trackpad. Return to **ESP adapter** to use the
   USB bridge. Switching releases held input and cancels queued text.
5. On Linux, start the connection from the computer using explicit LE; see
   [the Linux guide](docs/linux-direct-hid.md) and
   `./scripts/inpudeck-hid.sh`. The helper requires `python3-dbus` and the
   experimental BlueZ LE bearer API described in the guide. After testing it,
   `--install` adds the on-demand command; a background service is optional
   (`--install-service`). Installation leaves audio settings unchanged.
   Audio prevention for a single phone remains unresolved.
   To disable reception from **all phones** while retaining headphones, the
   optional `python3 scripts/inpudeck-audio-receiver.py install` adds a KDE menu
   switch, **Bluetooth audio receiver**. See the guide for activation and rollback.
   A typical BlueZ desktop does not advertise over BLE by default, so step 3
   may not find it. Its generic "Connect" can also bring up phone audio profiles.
6. If input does not become ready, use **Share log** in the pairing
   panel. The log includes connection stages, not typed text. During prototype
   updates a host may retain old GATT services. Start with the Linux guide's
   diagnostics; a missing cached HID service alone is not a reason to re-pair.

Pairing is open for two minutes. Once connected, input is pinned to that host;
use the pairing panel to select a different computer. The app clears held and
queued input when it moves to the background or loses its HID session.

Run `./scripts/test-direct-hid.sh` on a Swift-equipped machine to check HID report
encoding, queue backpressure, host selection, and descriptor sizes. The IPA
workflow runs these checks for pull requests and pushes to the v2 branch before
building the app. Version 2.0.0 (16) passed these tests and the Xcode 26.6 iOS
build on 2026-09-04 ([Actions run and IPA artifact](https://github.com/keefeere/ESPRemoteControl/actions/runs/33843087676)).
Broader pairing and reconnect tests remain pending; see the macOS result above.

CI uses [path filters](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushpull_requestpull_request_targetpathspaths-ignore)
to avoid unrelated runs. **Test button presses** runs on PRs changing
`ShortAndLongPressButtonStyle.swift`, `Tests/PressActions/`, its runner script,
or its workflow; it can also be started manually. iOS builds watch app/extension
code, the Xcode project, and their own tests/scripts. Linux helper changes run
the separate Linux checks. PR filters consider the whole PR diff against its
base, so a PR that already changes the button style still runs its UI test on
subsequent updates.

## Requirements

- **iPhone** running iOS 17+
- A computer with Bluetooth LE HID support

The optional USB bridge additionally requires an **ESP32-S3** development board
with native USB support and a data-capable USB-C cable.

Popular ESP32-S3 boards that work:
- Waveshare ESP32-S3-Zero
- ESP32-S3-DevKitC-1
- Adafruit QT Py ESP32-S3
- Seeed Studio XIAO ESP32S3

## Quick Start

### 1. Flash the optional ESP32 bridge

1. Install [Arduino IDE](https://www.arduino.cc/en/software)
2. Add ESP32 board support: `File > Preferences > Additional Board Manager URLs`
   ```
   https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
   ```
3. Install [NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino):
   `Tools > Manage Libraries > Search "NimBLE-Arduino"`
4. Open `inpudeck_bridge/inpudeck_bridge.ino`
5. Select your ESP32-S3 board and set `Tools > USB Mode > USB-OTG (TinyUSB)`
6. Upload the sketch

For the Waveshare ESP32-S3-Zero, the `Build ESP32-S3 firmware` GitHub Actions
workflow also produces a complete 4 MB merged image and its SHA-256 checksum.
Flash the downloaded image from the ROM bootloader with:

```bash
esptool \
  --chip esp32s3 \
  --port /dev/ttyACM0 \
  --before no-reset \
  --after no-reset \
  write-flash 0x0 InpuDeck-ESP32-S3-Zero.bin
```

Press RESET after flashing. The serial device number can change after USB
re-enumeration, so verify the port before writing.

### 2. Install the iOS App

1. Open `InpuDeck.xcodeproj` in Xcode
2. Connect your iPhone and build/install the app
3. Grant Bluetooth permissions when prompted

#### SideStore without a permanent Mac

The `Build unsigned iOS IPA` GitHub Actions workflow builds an unsigned
`InpuDeck-unsigned.ipa` on a `macos-26` runner. Run the workflow from
the repository's Actions tab, download the artifact, and install the IPA with
SideStore. SideStore can then refresh the app's development signature without
rebuilding it.

Tagged builds named `ios-v*` are also attached to a GitHub Release:

```text
ios-v3.0.0
```

#### Automatic SideStore updates

Add the repository's AltSource to SideStore once:

```text
https://raw.githubusercontent.com/keefeere/InpuDeck/main/sidestore-source.json
```

Or open this one-tap URL on the iPhone:

```text
sidestore://source?url=https://raw.githubusercontent.com/keefeere/InpuDeck/main/sidestore-source.json
```

Every tagged build updates this source after its IPA is attached to the GitHub
Release. SideStore will then detect the new version; enable LocalDevVPN and
confirm the update to sign and install it.

#### Migrating from ESP Remote Control

InpuDeck intentionally uses a new app identity and a new SideStore source.
Remove ESP Remote Control and its old source, add the InpuDeck source above,
then install and pair InpuDeck as a new app. Existing 2.x releases remain in
the repository history but are not copied into the new feed.

On Linux, installing either InpuDeck helper removes the corresponding files
managed by ESP Remote Control before writing the new command and service.
Unrelated files without the old ownership marker are refused and left intact.

#### Cutting a release

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, then land the change on
`main` with `release-tag-<version>` in the merge commit message — putting it in
the pull request title is enough, since GitHub copies that into the merge
commit. `Auto release tag` then checks the marker against `MARKETING_VERSION`,
creates `ios-v<version>`, and starts `Build unsigned iOS IPA` against that tag,
which attaches the IPA and its checksum to a new GitHub Release and updates
`sidestore-source.json`.

The tag has to be dispatched explicitly rather than left to fire on its own: a
tag pushed with `GITHUB_TOKEN` does not start a workflow run. A release
therefore builds twice — once for the push to `main`, once for the tag — and the
tag build also runs the simulator button tests. Tagging by hand
(`git tag -a ios-v<version> && git push origin ios-v<version>`) still works and
skips the first build; do not create the release through the GitHub UI, because
the workflow creates it and would fail on one that already exists.

To build the same unsigned IPA on a Mac locally:

```bash
./scripts/build-unsigned-ipa.sh
```

### 3. Connect and Use

1. Open InpuDeck and pair the computer from **Direct Bluetooth**. To use the
   optional bridge instead, flash the firmware above, connect the ESP32-S3 to
   the target over USB, and select **ESP adapter** in the connection strip.
2. Choose the target computer's layout shortcut in Settings.
3. Type with the native iOS keyboard or use the dedicated keyboard tab:
   - tap `EN`/`UA` to switch both the phone and target computer
   - hold `EN`/`UA` (or `UA/EN` on the full keyboard) for 0.5 seconds to change
     only the on-screen layout, without sending the host shortcut
   - on the full keyboard, tap the orientation lock to freeze the current
     orientation or unlock it; hold it for 0.5 seconds to force landscape
   - use the globe beside the text field to resend only the host shortcut
4. In **Settings → Shortcuts**, open the app’s shortcut page, then create a new shortcut with **Send to InpuDeck**:
   - tap its `Text` field → **Select Variable** → **Shortcut Input**
   - in the shortcut’s Details, enable **Show in Share Sheet** and allow **Text** and **URLs**
5. From another iOS app, choose `Share` → the shortcut. InpuDeck opens, waits for the selected output if needed, then types the input.
6. Use the trackpad area for mouse control:
   - **Drag** to move cursor
   - **Tap** for left click  
   - **Two-finger tap** for right click
   - **Two-finger drag** to scroll
   - **Pinch** to zoom
   - **Three-finger tap** for middle click
   - **Double-tap and hold the second tap** to drag
   - **Drag along the right edge** for one-finger scrolling

## How It Works

In direct mode, the computer sees the iPhone as a standard Bluetooth LE HID
keyboard and mouse:

```text
iPhone App (SwiftUI) → Bluetooth LE HID → Target Computer
```

The optional bridge adds a BLE-to-USB path:

```text
iPhone App (SwiftUI) 
    ↓ Bluetooth LE
ESP32-S3 Firmware 
    ↓ USB HID
Target Computer
```

The ESP32 acts as both a Bluetooth peripheral (receiving from iPhone) and USB
HID device (sending to the computer). It translates touch input and keystrokes
into standard HID keyboard/mouse commands.

## Technical Details

- **Protocol**: Batched TLV command frames over Bluetooth LE, with compatibility for the original 3-byte protocol
- **Battery**: ESP32 powered by target computer via USB
- **Compatibility**: Works with any OS that supports USB HID (Windows, macOS, Linux, etc.)
- **USB recovery**: Idle keyboard reports act as a health check; two consecutive transfer timeouts restart the ESP32-S3 so keyboard and mouse remain available across a host warm reboot. Verified on ASUS ROG Xbox Ally X, including pre-OS input.

## Project Structure

```
InpuDeck/
├── InpuDeck/           # Main iOS SwiftUI app
│   ├── ContentView.swift       # Main UI with keyboard and trackpad
│   └── BLEKeyboardBridge.swift # Bluetooth LE communication
├── Shared/                     # HID mapping and typing plan
└── inpudeck_bridge/    # ESP32-S3 Arduino firmware
    └── inpudeck_bridge.ino
```

## Use Cases

- **Smart TV control** - Type passwords, search content, and navigate streaming apps naturally
- **Home theater PC** - Control media centers from your couch
- **Presentation remote** - Wireless control during demos

## Troubleshooting

**ESP32 not detected by computer:**
- Ensure you selected "USB-OTG (TinyUSB)" mode before uploading
- Try a different USB cable (some are power-only)
- Check that your ESP32-S3 board supports native USB

**iPhone app won't connect:**
- Make sure ESP32 is powered and running (check serial monitor)
- Restart Bluetooth on iPhone
- Ensure you're within Bluetooth range
- Analyse with BLE monitoring tools

**Typing feels laggy:**
- Move iPhone closer to ESP32
- Check for Bluetooth interference from other devices
- Restart both devices

**Keyboard or mouse stops working after a host reboot:**
- Use a current firmware build; it includes automatic recovery for stalled USB HID transfers
- If recovery still fails, press the ESP32 RESET button once and report the host model and firmware build

## Contributing

This project solves a real problem with a unique hardware approach. Contributions welcome for:

- Additional gesture support
- Protocol optimizations  
- Support for other microcontrollers
- Android app version

## Roadmap

- **Direct BLE HID validation (current priority)** - macOS is stable and current Linux testing is successful; continue monitoring both while validating pairing, input, reconnect, and sleep/wake behavior on Windows. Retain ESP32 mode for USB HID and pre-OS input.
- **LAN host mode (formerly v3, deferred)** - Revisit exact Unicode and bidirectional clipboard only if a concrete need remains after direct BLE HID validation.
- **Adaptive layouts for iPhone Duo and iPad (wishlist)** - Once the iPhone Duo simulator is available, verify the app in full-screen and half-screen configurations. Also test representative iPad sizes and multitasking widths (Split View and Stage Manager), then consider layouts that make better use of the additional space.

See [direct BLE HID research and implementation plan](docs/direct-ble-hid.md) for
the CoreBluetooth approach, evidence, and remaining device checks, and
[direct Bluetooth HID on Linux](docs/linux-direct-hid.md) for pairing, HID-only
connection, and reconnect on a BlueZ desktop. Direct mode is the default for a
new installation, but Windows and additional sleep/wake scenarios still need
physical-device validation.

### Completed in iOS 2.2

- **Hardware controls** - System, media, audio, microphone-mute, and numpad keys are available on the Tools tab.
- **QR and barcode scanner** - Separate QR/2D and barcode modes can fill the composer or type automatically, with optional batch scanning.
- **Mouse Jiggler** - Configurable foreground pointer movement runs at the selected interval, prevents display sleep while active, warns about battery use, and disables itself when the app enters the background.
- **Multi-touch trackpads** - Both input screens support two-finger scrolling/right click, pinch-to-zoom, tap-drag, edge scrolling, and three-finger middle click. The layout, scanner button, and middle-click behavior were confirmed on-device in 2.2.9 (53).
- **Russian characters from the Ukrainian keyboard** - `Alt+і/є/'/ї` sends AltGr combinations for `ы/э/ё/ъ`, updates the visible legends while Alt is active, and uses Shift for uppercase. Automatic text typing recognizes the same letters. Confirmed on-device in 2.2.14 (58); the host's Ukrainian layout must provide these AltGr levels.
- **Dual keyboard legends** - Character keys show both EN and UA legends, with settings for visibility, portrait-only hiding, and scale. Confirmed on-device in 2.2.14 (58).
- **Native iOS dictation** - The input composer accepts voice typing from the system iOS keyboard and correctly forwards committed text and later dictation corrections. Confirmed on-device in 2.2.14 (58).
- **Background Jiggler investigation** - Continuous timer-driven movement is not reliable in the background on iOS 17–25. The supported foreground implementation keeps the screen awake and was confirmed on-device in 2.2.14 (58); see [the feasibility notes](docs/background-mouse-jiggler.md).

## Origins and acknowledgements

This repository is based on
[ESPRemoteControl](https://github.com/KoStard/ESPRemoteControl) by
[Ruben Kostandyan](https://github.com/KoStard). It has since evolved with
direct Bluetooth HID, multiple-host support, expanded keyboard and trackpad
controls, and an optional ESP32 USB bridge.

The ESP32 firmware uses
[NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino), distributed under
the Apache License 2.0.

The app icon incorporates the MIT-licensed `keyboard` outline from
[Tabler Icons](https://github.com/tabler/tabler-icons). See
[the attribution notices](ATTRIBUTIONS.md) for details about the original
project and third-party components.

## License

The original repository describes the project as MIT-licensed but does not
currently include the referenced license file. See
[the attribution notices](ATTRIBUTIONS.md) for provenance and licensing
details that could be verified.

---

**Star this repo if it saved you from hunting for a physical keyboard! ⭐**
