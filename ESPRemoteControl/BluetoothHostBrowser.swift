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
    private var maintained: Set<UUID> = []
    private var discoveredNames: [UUID: String] = [:]
    private var linkRetries: [UUID: DispatchWorkItem] = [:]
    private var linkFailures: [UUID: Int] = [:]

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
        cancelLinkRetries()
        maintained.removeAll()
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
        let saved = knownHosts.first { $0.id == id }
        return saved?.customName ?? resolvedName(for: id) ?? saved?.discoveredName ?? "Без назви"
    }

    func peerTag(_ id: UUID) -> String { "\(name(for: id)) [\(id.uuidString.prefix(8))]" }

    func linkState(for id: UUID) -> String {
        guard let peer = peers[id] else { return "unknown" }
        switch peer.state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    func resolvedName(for id: UUID) -> String? {
        discoveredNames[id] ?? peers[id]?.name
    }

    func isConnected(_ id: UUID) -> Bool {
        peers[id]?.state == .connected
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
        cancelLinkRetry(id)
        maintained.remove(id)
        if requestedHost == id { cancelConnection() }
        if let peer = peers[id], peer.state != .disconnected {
            markIntentionalCancellation(id)
            manager?.cancelPeripheralConnection(peer)
        }
        knownHosts.removeAll { $0.id == id }
        peers.removeValue(forKey: id)
        discoveredNames.removeValue(forKey: id)
        devices.removeAll { $0.id == id }
    }

    func connect(to id: UUID) {
        guard let manager, manager.state == .poweredOn,
              let peer = peers[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first else {
            statusText = "Очікуємо пристрій. Підключи iPhone у його налаштуваннях Bluetooth або повтори пошук."
            return
        }
        stopScan()
        connectionTimer?.cancel()
        maintained.insert(id)
        peers[id] = peer
        requestedHost = id
        statusText = "З’єднання з \(name(for: id))…"
        cancelLinkRetry(id)
        onDiagnostic?("Outgoing BLE requested: \(peerTag(id)), state \(linkState(for: id))")
        if peer.state == .connected {
            connected(peer)
        } else if peer.state == .disconnected {
            manager.connect(peer, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        }
        let timer = DispatchWorkItem { [weak self, weak peer] in
            guard let self, self.requestedHost == id, let peer, peer.state != .connected else { return }
            self.statusText = "Пристрій ще не відповів. Запит на з’єднання лишається активним."
            self.onDiagnostic?("Outgoing BLE still pending: \(self.peerTag(id)), state \(self.linkState(for: id))")
        }
        connectionTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timer)
    }

    func maintainLinks(to ids: [UUID]) {
        guard let manager, manager.state == .poweredOn else { return }
        let wanted = Set(ids)
        for id in maintained.subtracting(wanted) {
            cancelLinkRetry(id)
            guard let peer = peers[id] else { continue }
            onDiagnostic?("Dropping outgoing link: \(peerTag(id))")
            markIntentionalCancellation(id)
            manager.cancelPeripheralConnection(peer)
        }
        maintained = wanted
        addKnownHosts()
        for id in wanted {
            guard let peer = peers[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first else { continue }
            peers[id] = peer
            guard peer.state == .disconnected, linkRetries[id] == nil else { continue }
            onDiagnostic?("Holding outgoing link request: \(peerTag(id))")
            manager.connect(peer, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        }
    }

    func isLinkHeld(_ id: UUID) -> Bool { maintained.contains(id) }

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
            name: resolvedName(for: peer.identifier) ?? previous?.name ?? "Пристрій без назви",
            signal: signal ?? previous?.signal,
            isConnectable: connectable
        )
        devices.removeAll { $0.id == entry.id }
        devices.append(entry)
        devices.sort { ($0.signal ?? -200) > ($1.signal ?? -200) }
    }

    private func connected(_ peer: CBPeripheral) {
        guard maintained.contains(peer.identifier) || requestedHost == peer.identifier else { return }
        cancelLinkRetry(peer.identifier)
        if requestedHost == peer.identifier { connectionTimer?.cancel() }
        intentionallyCancelled.remove(peer.identifier)
        statusText = "BLE-з’єднання є; очікуємо клавіатуру й мишу…"
        onLinkConnected?(peer.identifier)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        if central.state == .poweredOn {
            central.registerForConnectionEvents(options: nil)
            addKnownHosts()
            onPoweredOn?()
            if scanRequested { scan() }
        } else {
            stopScan()
            cancelLinkRetries()
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
        let id = peripheral.identifier
        guard central === manager, maintained.contains(id) || requestedHost == id else { return }
        if requestedHost == id {
            connectionTimer?.cancel()
            requestedHost = nil
            statusText = error?.localizedDescription ?? "Не вдалося з’єднатися"
        }
        onDiagnostic?("Outgoing BLE failed: \(peerTag(id)), \(errorDetails(error))")
        onPeerDisconnected?(peripheral.identifier, .connectionFailed)
        scheduleLinkRetry(id)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === manager else { return }
        let cause = disconnectCause(for: peripheral.identifier)
        if requestedHost == peripheral.identifier {
            connectionTimer?.cancel()
            requestedHost = nil
            statusText = error?.localizedDescription ?? "З’єднання завершено"
        }
        onDiagnostic?("Outgoing BLE disconnected: \(peerTag(peripheral.identifier)), \(errorDetails(error))")
        onPeerDisconnected?(peripheral.identifier, cause)
        if cause != .appCancelledOutgoingLink { scheduleLinkRetry(peripheral.identifier) }
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent,
                        for peripheral: CBPeripheral) {
        guard central === manager else { return }
        switch event {
        case .peerConnected:
            remember(peripheral, name: peripheral.name, signal: nil, connectable: true)
            onDiagnostic?("System BLE connected: \(peerTag(peripheral.identifier))")
        case .peerDisconnected:
            onDiagnostic?("System BLE disconnected: \(peerTag(peripheral.identifier))")
            if requestedHost == peripheral.identifier {
                connectionTimer?.cancel()
                requestedHost = nil
            }
            let cause = disconnectCause(for: peripheral.identifier)
            onPeerDisconnected?(peripheral.identifier, cause)
            if cause != .appCancelledOutgoingLink { scheduleLinkRetry(peripheral.identifier) }
        @unknown default: break
        }
    }

    private func scheduleLinkRetry(_ id: UUID) {
        guard maintained.contains(id), manager?.state == .poweredOn,
              linkRetries[id] == nil else { return }
        let delays: [TimeInterval] = [1, 2, 5, 10, 20, 30]
        let failures = min(linkFailures[id, default: 0], delays.count - 1)
        let delay = delays[failures]
        linkFailures[id] = min(failures + 1, delays.count - 1)
        onDiagnostic?("Outgoing BLE retry in \(Int(delay)) s: \(peerTag(id))")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.linkRetries.removeValue(forKey: id)
            guard self.maintained.contains(id), let manager = self.manager,
                  manager.state == .poweredOn,
                  let peer = self.peers[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first else { return }
            self.peers[id] = peer
            switch peer.state {
            case .disconnected:
                self.onDiagnostic?("Reissuing outgoing BLE link: \(self.peerTag(id))")
                manager.connect(peer, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            case .disconnecting:
                self.scheduleLinkRetry(id)
            case .connected, .connecting:
                break
            @unknown default: break
            }
        }
        linkRetries[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelLinkRetry(_ id: UUID) {
        linkRetries.removeValue(forKey: id)?.cancel()
        linkFailures.removeValue(forKey: id)
    }

    private func cancelLinkRetries() {
        linkRetries.values.forEach { $0.cancel() }
        linkRetries.removeAll()
        linkFailures.removeAll()
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
