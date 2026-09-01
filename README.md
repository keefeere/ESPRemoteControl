# ESP Remote Control

Turn your iPhone into a wireless keyboard and mouse for any computer using an ESP32-S3 microcontroller.

[![Demo](https://img.youtube.com/vi/NFtp6ubC3DU/maxresdefault.jpg)](https://youtu.be/NFtp6ubC3DU)


## Why This Exists

Ever tried typing a password on your Smart TV using the remote? Or needed to control a computer from across the room? This project creates a true wireless input bridge - your iPhone becomes a fully functional keyboard and trackpad that works with any device via USB.

Unlike software solutions that require network setup or specific operating systems, this works at the hardware level. The computer sees it as a real USB keyboard and mouse.

## Features

- **English and Ukrainian input** - Automatic alphabet detection with physical US and Ukrainian Enhanced HID mappings
- **Two keyboard modes** - Use the native iOS keyboard beside the trackpad or the dedicated full-screen keyboard tab
- **Layout synchronization** - Configurable Ctrl+Space, Ctrl+Shift, Alt+Shift, Shift+Space, or Win+Space host shortcut
- **Share extension** - Send text or URLs from the iOS Share sheet directly through the ESP32 bridge
- **Clipboard typing** - Send text from the iPhone clipboard in one tap
- **Precision trackpad** - Multi-touch gestures for cursor control, clicking, and scrolling  
- **Keyboard trackpad** - Uses the free portrait space below the full keyboard without extra mouse buttons
- **Universal compatibility** - Works with any device that accepts USB HID devices (Smart TVs, computers, streaming boxes, embedded systems)
- **Zero configuration** - No drivers, no network setup, just plug and play
- **Low latency** - Direct Bluetooth LE connection for responsive input
- **Reliable reconnect** - Remembers the last ESP32 and reconnects with backoff
- **Warm-reboot recovery** - Recovers a stalled USB HID endpoint when a host reboots without removing USB power
- **Optional privacy mask** - Keep the typing composer visible or mask it when entering passwords
- **Hardware key hold** - Every on-screen key sends real HID key-down/key-up events, including multi-finger chords; modifiers can also be tapped to latch

## Hardware Requirements

- **ESP32-S3** development board (must have native USB support)
- **iPhone** running iOS 17+
- USB-C cable to connect ESP32 to target computer

Popular ESP32-S3 boards that work:
- Waveshare ESP32-S3-Zero
- ESP32-S3-DevKitC-1
- Adafruit QT Py ESP32-S3
- Seeed Studio XIAO ESP32S3

## Quick Start

### 1. Flash the ESP32

1. Install [Arduino IDE](https://www.arduino.cc/en/software)
2. Add ESP32 board support: `File > Preferences > Additional Board Manager URLs`
   ```
   https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
   ```
3. Install the NimBLE library: `Tools > Manage Libraries > Search "NimBLE-Arduino"`
4. Open `sketch_uid_keyboard_ble/sketch_uid_keyboard_ble.ino`
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
  write-flash 0x0 ESPRemoteControl-ESP32-S3-Zero.bin
```

Press RESET after flashing. The serial device number can change after USB
re-enumeration, so verify the port before writing.

### 2. Install the iOS App

1. Open `ESPRemoteControl.xcodeproj` in Xcode
2. Connect your iPhone and build/install the app
3. Grant Bluetooth permissions when prompted

#### SideStore without a permanent Mac

The `Build unsigned iOS IPA` GitHub Actions workflow builds an unsigned
`ESPRemoteControl-unsigned.ipa` on a `macos-26` runner. Run the workflow from
the repository's Actions tab, download the artifact, and install the IPA with
SideStore. SideStore can then refresh the app's development signature without
rebuilding it.

Tagged builds named `ios-v*` are also attached to a GitHub Release:

```text
ios-v1.0.0
```

#### Automatic SideStore updates

Add the repository's AltSource to SideStore once:

```text
https://raw.githubusercontent.com/keefeere/ESPRemoteControl/main/sidestore-source.json
```

Or open this one-tap URL on the iPhone:

```text
sidestore://source?url=https://raw.githubusercontent.com/keefeere/ESPRemoteControl/main/sidestore-source.json
```

Every tagged build updates this source after its IPA is attached to the GitHub
Release. SideStore will then detect the new version; enable LocalDevVPN and
confirm the update to sign and install it.

To build the same unsigned IPA on a Mac locally:

```bash
./scripts/build-unsigned-ipa.sh
```

### 3. Connect and Use

1. Plug the ESP32 into your target computer or Smart TV via USB
2. Open the iOS app - it will automatically scan and connect to the ESP32
3. Choose the target computer's layout shortcut in Settings
4. Type with the native iOS keyboard or use the dedicated keyboard tab:
   - tap `EN`/`UA` to switch both the phone and target computer
   - hold `EN`/`UA` to change only the phone indicator
   - use the globe beside the text field to resend only the host shortcut
5. From another iOS app, choose `Share` → `ESP Remote`, review the text or URL, confirm the host layout, and tap `Send`
6. Use the trackpad area for mouse control:
   - **Drag** to move cursor
   - **Tap** for left click  
   - **Two-finger tap** for right click
   - **Two-finger drag** to scroll

## How It Works

The system uses a custom Bluetooth LE protocol to send HID commands from iPhone to ESP32:

```
iPhone App (SwiftUI) 
    ↓ Bluetooth LE
ESP32-S3 Firmware 
    ↓ USB HID
Target Computer
```

The ESP32 acts as both a Bluetooth peripheral (receiving from iPhone) and USB HID device (sending to computer). It translates touch input and keystrokes into standard HID keyboard/mouse commands.

## Technical Details

- **Protocol**: Batched TLV command frames over Bluetooth LE, with compatibility for the original 3-byte protocol
- **Battery**: ESP32 powered by target computer via USB
- **Compatibility**: Works with any OS that supports USB HID (Windows, macOS, Linux, etc.)
- **USB recovery**: Idle keyboard reports act as a health check; two consecutive transfer timeouts restart the ESP32-S3 so keyboard and mouse remain available across a host warm reboot. Verified on ASUS ROG Xbox Ally X, including pre-OS input.

## Project Structure

```
ESPRemoteControl/
├── ESPRemoteControl/           # Main iOS SwiftUI app
│   ├── ContentView.swift       # Main UI with keyboard and trackpad
│   └── BLEKeyboardBridge.swift # Bluetooth LE communication
├── ESPRemoteControlShare/      # Embedded iOS Share Extension
├── Shared/                     # HID mapping and typing plan shared by both targets
└── sketch_uid_keyboard_ble/    # ESP32-S3 Arduino firmware
    └── sketch_uid_keyboard_ble.ino
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

- **v2** - Direct BLE HID mode that works without the ESP32 adapter
- **v3** - Optional LAN host mode for exact Unicode and bidirectional clipboard

## Artwork

The app icon incorporates the MIT-licensed `keyboard` outline from
[Tabler Icons](https://github.com/tabler/tabler-icons). See
[`ATTRIBUTIONS.md`](ATTRIBUTIONS.md) for details.

## License

MIT License - see LICENSE file for details.

---

**Star this repo if it saved you from hunting for a physical keyboard! ⭐**
