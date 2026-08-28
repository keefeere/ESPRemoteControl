import Combine
import CoreBluetooth
import Foundation

protocol InputTransport: AnyObject {
    func start()
    func sendKeyDown(modifiersMask: UInt8, keycode: UInt8)
    func sendKeyUp(keycode: UInt8)
    func sendKeyTap(modifiers: UInt8, hidKeycode: UInt8)
    func sendKeyTaps(_ taps: [(modifiers: UInt8, keycode: UInt8)])
    func sendMouseMove(dx: Int8, dy: Int8)
    func sendMouseScroll(dx: Int8, dy: Int8)
    func sendMouseClick(button: UInt8)
    func sendMouseButtonDown(button: UInt8)
    func sendMouseButtonUp(button: UInt8)
}

/// CoreBluetooth central for the ESP32-S3 BLE-to-USB bridge.
final class BLEKeyboardBridge: NSObject, ObservableObject, InputTransport {
    private let serviceUUID = CBUUID(string: "2D2A0001-8A5A-4E76-A2E3-1E57D9A1B001")
    private let writeCharUUID = CBUUID(string: "2D2A0002-8A5A-4E76-A2E3-1E57D9A1B001")
    private let restoreIdentifier = "com.keefeere.ESPRemoteControl.central"
    private let lastPeripheralKey = "lastBridgePeripheralIdentifier"

    @Published var statusText = "Bluetooth: ініціалізація…"
    @Published var isReady = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0

    private var pendingWrites: [Data] = []
    private var writeWithResponseInFlight = false

    func start() {
        guard central == nil else {
            if central?.state == .poweredOn, !isReady {
                connectToRememberedBridgeOrScan()
            }
            return
        }

        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    func reconnectNow() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0

        if let peripheral, peripheral.state == .connected {
            central?.cancelPeripheralConnection(peripheral)
        } else {
            connectToRememberedBridgeOrScan()
        }
    }

    private struct V2Frame {
        let command: UInt8
        let payload: [UInt8]
    }

    private enum V2 {
        static let magic: UInt8 = 0xAA
        static let version: UInt8 = 0x01
        static let setModifiers: UInt8 = 0x01
        static let keyDown: UInt8 = 0x02
        static let keyUp: UInt8 = 0x03
        static let keyTap: UInt8 = 0x04
        static let mouseMove: UInt8 = 0x10
        static let mouseScroll: UInt8 = 0x11
        static let mouseClick: UInt8 = 0x12
        static let mouseButtonDown: UInt8 = 0x13
        static let mouseButtonUp: UInt8 = 0x14
    }

    private var lastSentModifiersMask: UInt8 = 0

    private func writeV2(_ frames: [V2Frame]) {
        guard let peripheral, let writeChar, !frames.isEmpty else { return }

        let writeType: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        let maximumLength = max(20, peripheral.maximumWriteValueLength(for: writeType))
        var packets: [Data] = []
        var frameIndex = 0

        while frameIndex < frames.count {
            var bytes: [UInt8] = [V2.magic, V2.version]

            while frameIndex < frames.count {
                let frame = frames[frameIndex]
                guard frame.payload.count <= 0xFF else {
                    frameIndex += 1
                    continue
                }

                let encodedLength = 2 + frame.payload.count
                if bytes.count + encodedLength > maximumLength {
                    break
                }

                bytes.append(frame.command)
                bytes.append(UInt8(frame.payload.count))
                bytes.append(contentsOf: frame.payload)
                frameIndex += 1
            }

            if bytes.count > 2 {
                packets.append(Data(bytes))
            } else {
                break
            }
        }

        pendingWrites.append(contentsOf: packets)
        drainWriteQueue(type: writeType)
    }

    private func drainWriteQueue(type: CBCharacteristicWriteType? = nil) {
        guard let peripheral, let writeChar, !pendingWrites.isEmpty else { return }
        let resolvedType = type ?? (writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)

        switch resolvedType {
        case .withoutResponse:
            while peripheral.canSendWriteWithoutResponse, !pendingWrites.isEmpty {
                peripheral.writeValue(pendingWrites.removeFirst(), for: writeChar, type: .withoutResponse)
            }
        case .withResponse:
            guard !writeWithResponseInFlight else { return }
            writeWithResponseInFlight = true
            peripheral.writeValue(pendingWrites.removeFirst(), for: writeChar, type: .withResponse)
        @unknown default:
            break
        }
    }

    private func modifierFrameIfNeeded(_ mask: UInt8) -> [V2Frame] {
        guard mask != lastSentModifiersMask else { return [] }
        lastSentModifiersMask = mask
        return [V2Frame(command: V2.setModifiers, payload: [mask])]
    }

    func setModifiers(_ mask: UInt8) {
        writeV2(modifierFrameIfNeeded(mask))
    }

    func sendKeyDown(modifiersMask: UInt8, keycode: UInt8) {
        var frames = modifierFrameIfNeeded(modifiersMask)
        frames.append(V2Frame(command: V2.keyDown, payload: [keycode]))
        writeV2(frames)
    }

    func sendKeyUp(keycode: UInt8) {
        writeV2([V2Frame(command: V2.keyUp, payload: [keycode])])
    }

    func sendKeyTap(modifiers: UInt8, hidKeycode: UInt8) {
        if hidKeycode == 0 {
            sendModifierChord(modifiers)
            return
        }
        writeV2([V2Frame(command: V2.keyTap, payload: [modifiers, hidKeycode])])
    }

    func sendKeyTaps(_ taps: [(modifiers: UInt8, keycode: UInt8)]) {
        var frames: [V2Frame] = []
        for tap in taps {
            if tap.keycode == 0 {
                frames.append(V2Frame(command: V2.setModifiers, payload: [tap.modifiers]))
                frames.append(V2Frame(command: V2.setModifiers, payload: [0]))
                lastSentModifiersMask = 0
            } else {
                frames.append(V2Frame(command: V2.keyTap, payload: [tap.modifiers, tap.keycode]))
            }
        }
        writeV2(frames)
    }

    private func sendModifierChord(_ modifiers: UInt8) {
        lastSentModifiersMask = 0
        writeV2([
            V2Frame(command: V2.setModifiers, payload: [modifiers]),
            V2Frame(command: V2.setModifiers, payload: [0])
        ])
    }

    func sendMouseMove(dx: Int8, dy: Int8) {
        writeV2([V2Frame(command: V2.mouseMove, payload: [UInt8(bitPattern: dx), UInt8(bitPattern: dy)])])
    }

    func sendMouseClick(button: UInt8) {
        writeV2([V2Frame(command: V2.mouseClick, payload: [button])])
    }

    func sendMouseScroll(dx: Int8, dy: Int8) {
        writeV2([V2Frame(command: V2.mouseScroll, payload: [UInt8(bitPattern: dx), UInt8(bitPattern: dy)])])
    }

    func sendMouseButtonDown(button: UInt8) {
        writeV2([V2Frame(command: V2.mouseButtonDown, payload: [button])])
    }

    func sendMouseButtonUp(button: UInt8) {
        writeV2([V2Frame(command: V2.mouseButtonUp, payload: [button])])
    }

    private func connectToRememberedBridgeOrScan() {
        guard let central, central.state == .poweredOn else { return }
        guard peripheral?.state != .connecting, peripheral?.state != .connected else { return }

        if let identifierString = UserDefaults.standard.string(forKey: lastPeripheralKey),
           let identifier = UUID(uuidString: identifierString),
           let remembered = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            peripheral = remembered
            remembered.delegate = self
            statusText = "Bluetooth: підключення до збереженого адаптера…"
            central.connect(remembered, options: nil)
            return
        }

        scanForBridge()
    }

    private func scanForBridge() {
        guard let central, central.state == .poweredOn else { return }
        statusText = "Bluetooth: пошук ESP32…"
        isReady = false
        central.stopScan()
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        reconnectAttempt += 1
        let delay = min(pow(2, Double(reconnectAttempt - 1)), 8)
        statusText = "Bluetooth: перепідключення через \(Int(delay)) с…"

        let work = DispatchWorkItem { [weak self] in
            self?.connectToRememberedBridgeOrScan()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resetConnectionState() {
        isReady = false
        writeChar = nil
        pendingWrites.removeAll()
        writeWithResponseInFlight = false
        lastSentModifiersMask = 0
    }
}

extension BLEKeyboardBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectToRememberedBridgeOrScan()
        case .poweredOff:
            statusText = "Bluetooth вимкнено"
            resetConnectionState()
        case .unauthorized:
            statusText = "Немає дозволу на Bluetooth"
            resetConnectionState()
        case .unsupported:
            statusText = "Bluetooth LE не підтримується"
            resetConnectionState()
        case .resetting:
            statusText = "Bluetooth перезапускається…"
            resetConnectionState()
        case .unknown:
            statusText = "Bluetooth: невідомий стан"
            resetConnectionState()
        @unknown default:
            statusText = "Bluetooth: невідомий стан"
            resetConnectionState()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else {
            return
        }
        peripheral = restored
        restored.delegate = self
        statusText = "Bluetooth: відновлення з’єднання…"
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        self.peripheral = peripheral
        peripheral.delegate = self
        statusText = "Bluetooth: підключення до ESP32…"
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastPeripheralKey)
        statusText = "Bluetooth: перевірка сервісу…"
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        resetConnectionState()
        self.peripheral = nil
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        resetConnectionState()
        self.peripheral = nil
        scheduleReconnect()
    }
}

extension BLEKeyboardBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            statusText = "Помилка BLE-сервісу: \(error.localizedDescription)"
            scheduleReconnect()
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            statusText = "ESP32 не має потрібного BLE-сервісу"
            return
        }
        peripheral.discoverCharacteristics([writeCharUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            statusText = "Помилка BLE-команди: \(error.localizedDescription)"
            scheduleReconnect()
            return
        }

        guard let characteristic = service.characteristics?.first(where: { $0.uuid == writeCharUUID }) else {
            statusText = "ESP32 не має каналу команд"
            return
        }
        writeChar = characteristic
        statusText = "ESP32 підключено"
        isReady = true
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainWriteQueue(type: .withoutResponse)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        writeWithResponseInFlight = false
        if error == nil {
            drainWriteQueue(type: .withResponse)
        }
    }
}
