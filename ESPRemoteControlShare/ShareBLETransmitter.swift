import CoreBluetooth
import Foundation

final class ShareBLETransmitter: NSObject {
    enum TransmitError: LocalizedError {
        case bluetoothUnavailable
        case bridgeUnavailable
        case missingService
        case missingCommandChannel
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable: "Bluetooth недоступний"
            case .bridgeUnavailable: "ESP32 не знайдено"
            case .missingService: "ESP32 не має потрібного BLE-сервісу"
            case .missingCommandChannel: "ESP32 не має каналу команд"
            case .writeFailed: "Не вдалося надіслати команди"
            }
        }
    }

    var onStatusChange: ((String) -> Void)?

    private let serviceUUID = CBUUID(string: "2D2A0001-8A5A-4E76-A2E3-1E57D9A1B001")
    private let writeCharUUID = CBUUID(string: "2D2A0002-8A5A-4E76-A2E3-1E57D9A1B001")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var pendingTaps: [(modifiers: UInt8, keycode: UInt8)] = []
    private var pendingPackets: [Data] = []
    private var writeWithResponseInFlight = false
    private var completion: ((Result<Void, Error>) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completionWorkItem: DispatchWorkItem?

    func send(
        _ taps: [(modifiers: UInt8, keycode: UInt8)],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard central == nil else { return }
        pendingTaps = taps
        self.completion = completion
        onStatusChange?("Підготовка Bluetooth…")

        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(TransmitError.bridgeUnavailable))
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func cancel() {
        timeoutWorkItem?.cancel()
        completionWorkItem?.cancel()
        central?.stopScan()
        if let peripheral, peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(peripheral)
        }
        completion = nil
        central = nil
    }

    private func connectToBridge() {
        guard let central, central.state == .poweredOn else { return }

        if let identifier = ShareBridgeState.lastPeripheralIdentifier,
           let remembered = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            peripheral = remembered
            remembered.delegate = self
            onStatusChange?("Підключення до збереженого ESP32…")
            central.connect(remembered, options: nil)
            return
        }

        if let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            peripheral = connected
            connected.delegate = self
            onStatusChange?("Підключення до активного ESP32…")
            central.connect(connected, options: nil)
            return
        }

        onStatusChange?("Пошук ESP32…")
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func preparePackets() {
        guard let peripheral, let writeCharacteristic else { return }

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        let writeType: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        let maximumLength = max(20, peripheral.maximumWriteValueLength(for: writeType))
        var packet: [UInt8] = [0xAA, 0x01]

        for tap in pendingTaps {
            let frame: [UInt8]
            if tap.keycode == 0 {
                frame = [0x01, 0x01, tap.modifiers, 0x01, 0x01, 0x00]
            } else {
                frame = [0x04, 0x02, tap.modifiers, tap.keycode]
            }

            if packet.count + frame.count > maximumLength {
                pendingPackets.append(Data(packet))
                packet = [0xAA, 0x01]
            }
            packet.append(contentsOf: frame)
        }

        if packet.count > 2 {
            pendingPackets.append(Data(packet))
        }

        onStatusChange?("Надсилання \(pendingTaps.count) клавіш…")
        drainWriteQueue(type: writeType)
    }

    private func drainWriteQueue(type: CBCharacteristicWriteType? = nil) {
        guard let peripheral, let writeCharacteristic else { return }
        let resolvedType = type ?? (writeCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse)

        switch resolvedType {
        case .withoutResponse:
            while peripheral.canSendWriteWithoutResponse, !pendingPackets.isEmpty {
                peripheral.writeValue(
                    pendingPackets.removeFirst(),
                    for: writeCharacteristic,
                    type: .withoutResponse
                )
            }
            if pendingPackets.isEmpty {
                scheduleSuccessfulCompletion()
            }
        case .withResponse:
            guard !writeWithResponseInFlight else { return }
            guard !pendingPackets.isEmpty else {
                scheduleSuccessfulCompletion()
                return
            }
            writeWithResponseInFlight = true
            peripheral.writeValue(
                pendingPackets.removeFirst(),
                for: writeCharacteristic,
                type: .withResponse
            )
        @unknown default:
            finish(.failure(TransmitError.writeFailed))
        }
    }

    private func scheduleSuccessfulCompletion() {
        guard completionWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.success(()))
        }
        completionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        timeoutWorkItem?.cancel()
        completionWorkItem?.cancel()
        central?.stopScan()
        self.completion = nil
        completion(result)
    }
}

extension ShareBLETransmitter: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .unknown, central.state != .resetting {
                finish(.failure(TransmitError.bluetoothUnavailable))
            }
            return
        }
        connectToBridge()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        onStatusChange?("Підключення до ESP32…")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        ShareBridgeState.lastPeripheralIdentifier = peripheral.identifier
        onStatusChange?("Перевірка BLE-сервісу…")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        finish(.failure(error ?? TransmitError.bridgeUnavailable))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if completion != nil {
            finish(.failure(error ?? TransmitError.bridgeUnavailable))
        }
    }
}

extension ShareBLETransmitter: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            finish(.failure(error ?? TransmitError.missingService))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            finish(.failure(TransmitError.missingService))
            return
        }
        peripheral.discoverCharacteristics([writeCharUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            finish(.failure(error ?? TransmitError.missingCommandChannel))
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == writeCharUUID }) else {
            finish(.failure(TransmitError.missingCommandChannel))
            return
        }
        writeCharacteristic = characteristic
        preparePackets()
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
        guard error == nil else {
            finish(.failure(error ?? TransmitError.writeFailed))
            return
        }
        drainWriteQueue(type: .withResponse)
    }
}
