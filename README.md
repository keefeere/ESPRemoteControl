# ESP Remote Control

Turn your iPhone into a wireless keyboard and mouse for any computer using an ESP32-S3 microcontroller.

[![Demo](https://img.youtube.com/vi/NFtp6ubC3DU/maxresdefault.jpg)](https://youtu.be/NFtp6ubC3DU)


## Why This Exists

Ever tried typing a password on your Smart TV using the remote? Or needed to control a computer from across the room? This project creates a true wireless input bridge - your iPhone becomes a fully functional keyboard and trackpad that works with any device via USB.

Unlike software solutions that require network setup or specific operating systems, this works at the hardware level. The computer sees it as a real USB keyboard and mouse.

## Features

- **Full keyboard input** - Type naturally on your iPhone, including symbols, punctuation, and special keys
- **Precision trackpad** - Multi-touch gestures for cursor control, clicking, and scrolling  
- **Universal compatibility** - Works with any device that accepts USB HID devices (Smart TVs, computers, streaming boxes, embedded systems)
- **Zero configuration** - No drivers, no network setup, just plug and play
- **Low latency** - Direct Bluetooth LE connection for responsive input
- **Privacy focused** - Text appears as bullets (•) on screen, nothing stored or transmitted beyond keystrokes

## Hardware Requirements

- **ESP32-S3** development board (must have native USB support)
- **iPhone** running iOS 17+
- USB-C cable to connect ESP32 to target computer

Popular ESP32-S3 boards that work:
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

To build the same unsigned IPA on a Mac locally:

```bash
./scripts/build-unsigned-ipa.sh
```

### 3. Connect and Use

1. Plug the ESP32 into your target computer or Smart TV via USB
2. Open the iOS app - it will automatically scan and connect to the ESP32
3. Start typing! The keyboard appears immediately and your input is sent to the computer
4. Use the trackpad area for mouse control:
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

- **Protocol**: Custom 3-byte command format over Bluetooth LE
- **Battery**: ESP32 powered by target computer via USB
- **Compatibility**: Works with any OS that supports USB HID (Windows, macOS, Linux, etc.)

## Project Structure

```
ESPRemoteControl/
├── ESPRemoteControl/          # iOS SwiftUI app
│   ├── ContentView.swift      # Main UI with keyboard and trackpad
│   ├── BLEKeyboardBridge.swift # Bluetooth LE communication
│   ├── HID.swift              # Character to HID keycode mapping
│   └── ...
└── sketch_uid_keyboard_ble/   # ESP32-S3 Arduino firmware
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

## Contributing

This project solves a real problem with a unique hardware approach. Contributions welcome for:

- Additional gesture support
- Protocol optimizations  
- Support for other microcontrollers
- Android app version

## License

MIT License - see LICENSE file for details.

---

**Star this repo if it saved you from hunting for a physical keyboard! ⭐**
