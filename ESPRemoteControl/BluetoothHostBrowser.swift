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
    var onPeerDisconnected: ((UUID, HIDPeerDisconnectCause) -> Void)?
    var onNameDiscovered: ((UUID, String) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private var manager: CBCentralManager?
    private var peers: [UUID: CBPeripheral] = [:]
    private var scanRequested = false
    private var scanTimer: DispatchWorkItem?
    private var connectionTimer: DispatchWorkItem?
    private var intentionallyCancelled: Set<UUID> = []
    private var knownHosts: [SavedHIDHost] = []
    private var discoveredNames: [UUID: String] = [:]

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
        intentionallyCancelled.removeAll()
        peers.removeAll()
        discoveredNames.removeAll()
        devices.removeAll()
        statusText = ""
    }

    func scan() {
        scanRequested = true
        guard let manager, manager.state == .poweredOn else { start(); return }
        stopScan()
        scanRequested = true
        addKnownHosts()
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
            markIntentionalCancellation(requestedHost)
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
        knownHosts.first { $0.id == id }?.name ?? resolvedName(for: id) ?? "Комп’ютер · \(id.uuidString.prefix(8))"
    }

    func resolvedName(for id: UUID) -> String? {
        discoveredNames[id] ?? peers[id]?.name
    }

    func resolveName(for id: UUID) {
        guard let manager, manager.state == .poweredOn,
              let peer = peers[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first else { return }
        remember(peer, name: peer.name, signal: nil, connectable: true)
    }

    func setKnownHosts(_ hosts: [SavedHIDHost]) {
        knownHosts = hosts
        addKnownHosts()
    }

    func forget(_ id: UUID) {
        if requestedHost == id { cancelConnection() }
        knownHosts.removeAll { $0.id == id }
        peers.removeValue(forKey: id)
        discoveredNames.removeValue(forKey: id)
        devices.removeAll { $0.id == id }
    }

    func connect(to id: UUID) {
        guard let manager, manager.state == .poweredOn,
              let peer = peers[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first else {
            statusText = "Очікуємо комп’ютер. Підключи iPhone у його налаштуваннях Bluetooth або повтори пошук."
            return
        }
        stopScan()
        connectionTimer?.cancel()
        if let oldID = requestedHost, oldID != id, let old = peers[oldID] {
            markIntentionalCancellation(oldID)
            manager.cancelPeripheralConnection(old)
        }
        peers[id] = peer
        requestedHost = id
        statusText = "З’єднання з \(name(for: id))…"
        onDiagnostic?("Outgoing BLE requested: \(id.uuidString.prefix(8)), state \(peer.state.rawValue)")
        if peer.state == .connected {
            connected(peer)
        } else {
            manager.connect(peer, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        }
        let timer = DispatchWorkItem { [weak self, weak peer] in
            guard let self, self.requestedHost == id, let peer, peer.state != .connected else { return }
            // CoreBluetooth keeps connect requests pending and completes them
            // when the peer becomes available. Keep that request alive across
            // computer sleep instead of cancelling it on an arbitrary timeout.
            self.statusText = "Комп’ютер ще не відповів. Запит на з’єднання лишається активним."
            self.onDiagnostic?("Outgoing BLE still pending: \(id.uuidString.prefix(8)), state \(peer.state.rawValue)")
        }
        connectionTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timer)
    }

    func reconnectRememberedHost(ifMatching preferredHost: UUID?) {
        guard requestedHost == nil, let preferredHost,
              knownHosts.contains(where: { $0.id == preferredHost }) else { return }
        // A host first learned through an incoming HID subscription may still
        // be retrievable in our central role after pairing. Trying it is safe;
        // connect(to:) leaves incoming-only hosts waiting for their own OS.
        addKnownHosts()
        connect(to: preferredHost)
    }

    func rememberReadyHost(_ id: UUID) {
        if requestedHost == id { statusText = "Ввід підключено" }
    }

    private func addKnownHosts() {
        guard let manager, manager.state == .poweredOn else { return }
        for host in knownHosts {
            guard let peer = manager.retrievePeripherals(withIdentifiers: [host.id]).first else { continue }
            remember(peer, name: peer.name ?? host.discoveredName, signal: nil, connectable: true)
        }
    }

    private func remember(_ peer: CBPeripheral, name: String?, signal: Int?, connectable: Bool) {
        peers[peer.identifier] = peer
        let previous = devices.first { $0.id == peer.identifier }
        if let name = (name ?? peer.name)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, discoveredNames[peer.identifier] != name {
            discoveredNames[peer.identifier] = name
            onNameDiscovered?(peer.identifier, name)
        }
        let entry = BluetoothHostCandidate(
            id: peer.identifier,
            name: resolvedName(for: peer.identifier) ?? previous?.name ?? "Без назви · \(peer.identifier.uuidString.prefix(8))",
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
        intentionallyCancelled.remove(peer.identifier)
        statusText = "BLE-з’єднання є; очікуємо клавіатуру й мишу…"
        onLinkConnected?(peer.identifier)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        if central.state == .poweredOn {
            // Receive system links too, including hosts already known to iOS.
            central.registerForConnectionEvents(options: nil)
            addKnownHosts()
            onPoweredOn?()
            if scanRequested { scan() }
        } else {
            stopScan()
            let disconnectedHost = requestedHost
            requestedHost = nil
            intentionallyCancelled.removeAll()
            if let disconnectedHost {
                onPeerDisconnected?(disconnectedHost, .bluetoothUnavailable)
            }
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
        onDiagnostic?("Outgoing BLE failed: \(peripheral.identifier.uuidString.prefix(8)), \(errorDetails(error))")
        onPeerDisconnected?(peripheral.identifier, .connectionFailed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === manager else { return }
        let cause = disconnectCause(for: peripheral.identifier)
        if requestedHost == peripheral.identifier {
            connectionTimer?.cancel()
            requestedHost = nil
            statusText = error?.localizedDescription ?? "З’єднання завершено"
        }
        onDiagnostic?("Outgoing BLE disconnected: \(peripheral.identifier.uuidString.prefix(8)), \(errorDetails(error))")
        onPeerDisconnected?(peripheral.identifier, cause)
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent,
                        for peripheral: CBPeripheral) {
        guard central === manager else { return }
        switch event {
        case .peerConnected:
            onDiagnostic?("System BLE connected: \(peripheral.identifier.uuidString.prefix(8))")
            remember(peripheral, name: peripheral.name, signal: nil, connectable: true)
        case .peerDisconnected:
            onDiagnostic?("System BLE disconnected: \(peripheral.identifier.uuidString.prefix(8))")
            if requestedHost == peripheral.identifier {
                connectionTimer?.cancel()
                requestedHost = nil
            }
            onPeerDisconnected?(peripheral.identifier, disconnectCause(for: peripheral.identifier))
        @unknown default: break
        }
    }

    private func errorDetails(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "no error" }
        return "\(error.domain)/\(error.code): \(error.localizedDescription)"
    }

    private func markIntentionalCancellation(_ id: UUID) {
        intentionallyCancelled.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.intentionallyCancelled.remove(id)
        }
    }

    private func disconnectCause(for id: UUID) -> HIDPeerDisconnectCause {
        intentionallyCancelled.contains(id) ? .appCancelledOutgoingLink : .linkLost
    }
}
