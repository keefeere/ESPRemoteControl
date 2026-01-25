//
//  BLEKeyboardBridge.swift
//  ESPRemoteControl
//
//  Created by Ruben Kostandyan on 14/12/2025.
//

import Foundation
import CoreBluetooth
import Combine

/// BLE Central that connects to the ESP32 peripheral and writes keystroke commands.
final class BLEKeyboardBridge: NSObject, ObservableObject {
    // Must match the ESP32 sketch UUIDs.
    private let serviceUUID = CBUUID(string: "2D2A0001-8A5A-4E76-A2E3-1E57D9A1B001")
    private let writeCharUUID = CBUUID(string: "2D2A0002-8A5A-4E76-A2E3-1E57D9A1B001")

    @Published var statusText: String = "Bluetooth: initializing..."
    @Published var isReady: Bool = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Protocol (v2)

    private struct V2Frame {
        let cmd: UInt8
        let payload: [UInt8]
    }

    private enum V2 {
        static let magic: UInt8 = 0xAA
        static let version: UInt8 = 0x01

        // Keyboard
        static let setModifiers: UInt8 = 0x01      // payload: [mask]
        static let keyDown: UInt8 = 0x02           // payload: [keycode]
        static let keyUp: UInt8 = 0x03             // payload: [keycode]
        static let keyTap: UInt8 = 0x04            // payload: [mask, keycode]

        // Mouse
        static let mouseMove: UInt8 = 0x10         // payload: [dx, dy]
        static let mouseScroll: UInt8 = 0x11       // payload: [dx, dy]
        static let mouseClick: UInt8 = 0x12        // payload: [button]
        static let mouseButtonDown: UInt8 = 0x13   // payload: [button]
        static let mouseButtonUp: UInt8 = 0x14     // payload: [button]
    }

    private var lastSentModifiersMask: UInt8 = 0x00

    private func writeV2(_ frames: [V2Frame]) {
        guard let p = peripheral, let c = writeChar else { return }
        guard !frames.isEmpty else { return }

        let writeType: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let maxLen = max(20, p.maximumWriteValueLength(for: writeType))

        var i = 0
        while i < frames.count {
            var bytes: [UInt8] = [V2.magic, V2.version]

            while i < frames.count {
                let f = frames[i]
                let len = f.payload.count
                guard len <= 0xFF else { break }

                let frameLen = 2 + len // cmd + len + payload
                if bytes.count + frameLen > maxLen {
                    break
                }

                bytes.append(f.cmd)
                bytes.append(UInt8(len))
                bytes.append(contentsOf: f.payload)
                i += 1
            }

            p.writeValue(Data(bytes), for: c, type: writeType)
        }
    }

    private func setModifiersFrameIfNeeded(_ mask: UInt8) -> [V2Frame] {
        guard mask != lastSentModifiersMask else { return [] }
        lastSentModifiersMask = mask
        return [V2Frame(cmd: V2.setModifiers, payload: [mask])]
    }

    /// Set the current modifiers state on the ESP32 (sticky + momentary support).
    func setModifiers(_ mask: UInt8) {
        writeV2(setModifiersFrameIfNeeded(mask))
    }

    /// True key-down event (chordable). Includes a modifiers sync frame if needed.
    func sendKeyDown(modifiersMask: UInt8, keycode: UInt8) {
        var frames = setModifiersFrameIfNeeded(modifiersMask)
        frames.append(V2Frame(cmd: V2.keyDown, payload: [keycode]))
        writeV2(frames)
    }

    /// True key-up event.
    func sendKeyUp(keycode: UInt8) {
        writeV2([V2Frame(cmd: V2.keyUp, payload: [keycode])])
    }

    /// A non-disruptive tap (press+release) with a temporary modifiers mask.
    func sendKeyTap(modifiers: UInt8, hidKeycode: UInt8) {
        writeV2([V2Frame(cmd: V2.keyTap, payload: [modifiers, hidKeycode])])
    }

    /// Batch key taps efficiently (used for diff-based typing).
    func sendKeyTaps(_ taps: [(modifiers: UInt8, keycode: UInt8)]) {
        let frames = taps.map { V2Frame(cmd: V2.keyTap, payload: [$0.modifiers, $0.keycode]) }
        writeV2(frames)
    }

    /// Send mouse movement delta to the ESP32.
    func sendMouseMove(dx: Int8, dy: Int8) {
        let payload: [UInt8] = [UInt8(bitPattern: dx), UInt8(bitPattern: dy)]
        writeV2([V2Frame(cmd: V2.mouseMove, payload: payload)])
    }

    /// Send mouse click to the ESP32.
    func sendMouseClick(button: UInt8) {
        writeV2([V2Frame(cmd: V2.mouseClick, payload: [button])])
    }

    /// Send mouse scroll to the ESP32.
    func sendMouseScroll(dx: Int8, dy: Int8) {
        let payload: [UInt8] = [UInt8(bitPattern: dx), UInt8(bitPattern: dy)]
        writeV2([V2Frame(cmd: V2.mouseScroll, payload: payload)])
    }

    /// Optional: mouse button down (future-ready).
    func sendMouseButtonDown(button: UInt8) {
        writeV2([V2Frame(cmd: V2.mouseButtonDown, payload: [button])])
    }

    /// Optional: mouse button up (future-ready).
    func sendMouseButtonUp(button: UInt8) {
        writeV2([V2Frame(cmd: V2.mouseButtonUp, payload: [button])])
    }
}

extension BLEKeyboardBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            statusText = "Bluetooth: scanning for bridge..."
            isReady = false
            central.scanForPeripherals(withServices: [serviceUUID], options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])

        case .poweredOff:
            statusText = "Bluetooth: powered off"
            isReady = false

        case .unauthorized:
            statusText = "Bluetooth: unauthorized (check Settings / permissions)"
            isReady = false

        case .unsupported:
            statusText = "Bluetooth: unsupported on this device"
            isReady = false

        case .resetting:
            statusText = "Bluetooth: resetting..."
            isReady = false

        case .unknown:
            fallthrough
        @unknown default:
            statusText = "Bluetooth: unknown state"
            isReady = false
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        self.peripheral?.delegate = self

        statusText = "Bluetooth: connecting..."
        isReady = false
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        statusText = "Bluetooth: discovering services..."
        isReady = false
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        statusText = "Bluetooth: connect failed (\(error?.localizedDescription ?? "unknown"))"
        isReady = false
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        statusText = "Bluetooth: disconnected, rescanning..."
        isReady = false
        self.writeChar = nil
        self.peripheral = nil
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }
}

extension BLEKeyboardBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            statusText = "Bluetooth: service discovery error (\(error.localizedDescription))"
            isReady = false
            return
        }
        guard let services = peripheral.services else { return }
        for s in services where s.uuid == serviceUUID {
            peripheral.discoverCharacteristics([writeCharUUID], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            statusText = "Bluetooth: characteristic discovery error (\(error.localizedDescription))"
            isReady = false
            return
        }
        guard let chars = service.characteristics else { return }
        for c in chars where c.uuid == writeCharUUID {
            writeChar = c
            statusText = "Bluetooth: ready (bridge connected)"
            isReady = true
        }
    }
}
