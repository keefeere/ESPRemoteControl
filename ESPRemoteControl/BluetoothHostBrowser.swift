import Combine
import CoreBluetooth
import Foundation

struct BluetoothHostCandidate: Identifiable {
    let id: UUID
    var name: String
    var signal: Int?
    var isConnectable: Bool
}

/// Creates the BLE link from the phone when a host (especially a Mac) is
/// already advertising. HID readiness is determined by the peripheral role.
final class BluetoothHostBrowser: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var devices: [BluetoothHostCandidate] = []
    @Published private(set) var isScanning = false
    @Published private(set) var statusText = ""
    @Published private(set) var requestedHost: UUID?
    var onPoweredOn: (() -> Void)?
    var onUnavailable: ((String) -> Void)?
    var onLinkConnected: ((UUID) -> Void)?
    var onPeerDisconnected: ((UUID) -> Void)?

    private var manager: CBCentralManager?
    private var peers: [UUID: CBPeripheral] = [:]
    private var scanRequested = false
    private var scanTimer: DispatchWorkItem?
    private var connectionTimer: DispatchWorkItem?
    private let rememberedIDKey = "directHID.outgoingHost"
    private let rememberedNameKey = "directHID.outgoingHostName"

    func start() {
        guard manager == nil else {
            if manager?.state == .poweredOn { onPoweredOn?() }
            return
        }
        manager = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    func stop() {
        stopScan()
        connectionTimer?.cancel()
        if let requestedHost, let peer = peers[requestedHost] {
            manager?.cancelPeripheralConnection(peer)
        }
        manager?.delegate = nil
        manager = nil
        requestedHost = nil
        peers.removeAll()
        devices.removeAll()
        statusText = ""
    }

    func scan() {
        scanRequested = true
        guard let manager, manager.state == .poweredOn else { start(); return }
        stopScan()
        scanRequested = true
        addRememberedHost()
        // Discoverability is independent of whether a host offers HID itself.
        manager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        isScanning = true
        statusText = "Пошук пристроїв…"
        let timer = DispatchWorkItem { [weak self] in
            self?.stopScan()
            self?.statusText = "Пошук завершено"
        }
        scanTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timer)
    }

    func cancelConnection() {
        connectionTimer?.cancel()
        if let requestedHost, let peer = peers[requestedHost] {
            manager?.cancelPeripheralConnection(peer)
        }
        requestedHost = nil
    }

    func stopScan() {
        scanRequested = false
        scanTimer?.cancel()
        scanTimer = nil
        manager?.stopScan()
        isScanning = false
    }

    func name(for id: UUID) -> String {
        devices.first { $0.id == id }?.name ?? "Комп’ютер · \(id.uuidString.prefix(4))"
    }

    func connect(to id: UUID) {
        guard let manager, manager.state == .poweredOn,
              let peer = peers[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first else {
            statusText = "Пристрій недоступний. Повтори пошук."
            return
        }
        stopScan()
        connectionTimer?.cancel()
        if let oldID = requestedHost, oldID != id, let old = peers[oldID] {
            manager.cancelPeripheralConnection(old)
        }
        peers[id] = peer
        requestedHost = id
        statusText = "З’єднання з \(name(for: id))…"
        if peer.state == .connected {
            connected(peer)
        } else {
            manager.connect(peer, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        }
        let timer = DispatchWorkItem { [weak self, weak peer] in
            guard let self, self.requestedHost == id, let peer, peer.state != .connected else { return }
            self.requestedHost = nil
            self.manager?.cancelPeripheralConnection(peer)
            self.statusText = "Час з’єднання минув. Відкрий Bluetooth на комп’ютері та повтори."
        }
        connectionTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timer)
    }

    func reconnectRememberedHost(ifMatching preferredHost: UUID?) {
        guard requestedHost == nil, let preferredHost,
              UserDefaults.standard.string(forKey: rememberedIDKey) == preferredHost.uuidString else { return }
        addRememberedHost()
        connect(to: preferredHost)
    }

    func rememberReadyHost(_ id: UUID) {
        guard requestedHost == id else { return }
        UserDefaults.standard.set(id.uuidString, forKey: rememberedIDKey)
        UserDefaults.standard.set(name(for: id), forKey: rememberedNameKey)
        statusText = "Ввід підключено"
    }

    private func addRememberedHost() {
        guard let manager, let value = UserDefaults.standard.string(forKey: rememberedIDKey),
              let id = UUID(uuidString: value),
              let peer = manager.retrievePeripherals(withIdentifiers: [id]).first else { return }
        remember(peer, name: UserDefaults.standard.string(forKey: rememberedNameKey), signal: nil, connectable: true)
    }

    private func remember(_ peer: CBPeripheral, name: String?, signal: Int?, connectable: Bool) {
        peers[peer.identifier] = peer
        let previous = devices.first { $0.id == peer.identifier }
        let entry = BluetoothHostCandidate(
            id: peer.identifier,
            name: name ?? peer.name ?? previous?.name ?? "Без назви · \(peer.identifier.uuidString.prefix(4))",
            signal: signal ?? previous?.signal,
            isConnectable: connectable
        )
        devices.removeAll { $0.id == entry.id }
        devices.append(entry)
        devices.sort { ($0.signal ?? -200) > ($1.signal ?? -200) }
    }

    private func connected(_ peer: CBPeripheral) {
        guard requestedHost == peer.identifier else { return }
        connectionTimer?.cancel()
        statusText = "BLE-з’єднання є; очікуємо клавіатуру й мишу…"
        onLinkConnected?(peer.identifier)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        if central.state == .poweredOn {
            // Receive system links too, including hosts already known to iOS.
            central.registerForConnectionEvents(options: nil)
            addRememberedHost()
            onPoweredOn?()
            if scanRequested { scan() }
        } else {
            stopScan()
            if let requestedHost { onPeerDisconnected?(requestedHost) }
            requestedHost = nil
            statusText = central.state == .unauthorized ? "Немає дозволу на Bluetooth" : "Bluetooth недоступний"
            onUnavailable?(statusText)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === manager, isScanning else { return }
        remember(peripheral,
                 name: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                 signal: RSSI.intValue == 127 ? nil : RSSI.intValue,
                 connectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager else { return }
        connected(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === manager, requestedHost == peripheral.identifier else { return }
        connectionTimer?.cancel()
        requestedHost = nil
        statusText = error?.localizedDescription ?? "Не вдалося з’єднатися"
        onPeerDisconnected?(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === manager else { return }
        if requestedHost == peripheral.identifier {
            requestedHost = nil
            statusText = error?.localizedDescription ?? "З’єднання завершено"
        }
        onPeerDisconnected?(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent,
                        for peripheral: CBPeripheral) {
        guard central === manager else { return }
        switch event {
        case .peerConnected:
            remember(peripheral, name: peripheral.name, signal: nil, connectable: true)
        case .peerDisconnected:
            onPeerDisconnected?(peripheral.identifier)
        @unknown default: break
        }
    }
}
