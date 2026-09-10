import Combine
import CoreBluetooth
import Foundation
import UIKit

/// HOGP peripheral implemented with public CoreBluetooth APIs. SIG UUIDs use
/// their canonical 128-bit representation when publishing on iOS.
final class DirectHIDTransport: NSObject, ObservableObject, InputTransport, CBPeripheralManagerDelegate {
    @Published private(set) var isReady = false
    @Published private(set) var statusText = "Прямий Bluetooth вимкнено"
    @Published private(set) var canPair = false
    @Published private(set) var isPairing = false
    @Published private(set) var lastError: String?
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var savedHosts: [SavedHIDHost] = []
    @Published private(set) var selectedHostID: UUID?
    @Published private(set) var connectedHostID: UUID?
    let advertisedName = "ESP Remote"
    let browser = BluetoothHostBrowser()

    private enum Attribute {
        case input(HIDInputChannel), leds, protocolMode, controlPoint
        case reportMap, information, battery, manufacturer, model, pnpID

        var label: String {
            switch self {
            case .input(let channel): return "report/\(channel)"
            case .leds: return "leds"
            case .protocolMode: return "protocolMode"
            case .controlPoint: return "controlPoint"
            case .reportMap: return "reportMap"
            case .information: return "hidInformation"
            case .battery: return "battery"
            case .manufacturer: return "manufacturer"
            case .model: return "model"
            case .pnpID: return "pnpID"
            }
        }
    }
    private static func uuid(_ short: String) -> CBUUID {
        CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB")
    }

    private let hostStore: HIDHostStore
    private var advertising = HIDAdvertisingState()
    private var advertisingError: String?
    private var advertisingRetry: DispatchWorkItem?
    private var advertisingFailures = 0
    private var lastReadyHostID: UUID?
    private var manager: CBPeripheralManager?
    private var isRunning = false
    private var servicesInstalled = false
    private var serviceQueue: [CBMutableService] = []
    private var addingService: CBMutableService?
    private var attributes: [ObjectIdentifier: Attribute] = [:]
    private var inputs: [HIDInputChannel: CBMutableCharacteristic] = [:]
    private var host: CBCentral?
    private var session = HIDHostSession(preferredHost: nil, allowsPairing: false)
    private var state = HIDInputState()
    private var queue = HIDReportQueue()
    private var lastKeyboard = HIDInputState().keyboard.data
    private var lastMouse = HIDInputState().mouse().data
    private var lastConsumer = HIDInputState().consumer.data
    private var leds: UInt8 = 0
    private var sendWork: DispatchWorkItem?
    private var pairingTimer: DispatchWorkItem?
    private var afterDrain: (() -> Void)?
    private var afterInputQueueDrains: (() -> Void)?
    private var drainTimer: DispatchWorkItem?
    private var finishingDrain = false
    private var watchdog = HIDReconnectWatchdog()
    private var watchdogWork: DispatchWorkItem?
    private var rejectedPeers: Set<UUID> = []
    private var loggedATT: Set<String> = []
    private var loggedOversizedReport = false
    private var wakeProbeReportsRemaining = 0
    private var wakeProbeBlocked = false

    init(hostKey: String = "directHID.selectedHost") {
        hostStore = HIDHostStore(hostKey: hostKey)
        super.init()
        savedHosts = hostStore.hosts
        selectedHostID = hostStore.selectedHostID
        browser.onDiagnostic = { [weak self] event in self?.record(event) }
        browser.onNameDiscovered = { [weak self] id, name in
            guard let self, self.hostStore.host(id) != nil else { return }
            self.hostStore.updateDiscoveredName(name, for: id)
            self.savedHosts = self.hostStore.hosts
            if self.isRunning { self.refreshStatus() }
        }
        browser.onPoweredOn = { [weak self] in self?.startPeripheral() }
        browser.onUnavailable = { [weak self] message in
            guard let self, self.isRunning else { return }
            self.lastError = message
            self.refreshStatus()
        }
        browser.onPeerDisconnected = { [weak self] id, cause in self?.disconnected(id, cause: cause) }
        browser.onLinkConnected = { [weak self] id in
            guard let self, self.isRunning else { return }
            self.record("Outgoing BLE link connected: \(self.peerTag(id))")
            self.refreshStatus()
        }
    }

    var diagnosticText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let hosts = savedHosts.map { "\(hostName(for: $0.id)) · UUID: \($0.id.uuidString)" }.joined(separator: "\n")
        return "ESP Remote \(version) (\(build)) · iOS \(UIDevice.current.systemVersion)\n\(statusText)\n"
            + "Selected: \(peerTag(selectedHostID)); HID ready: \(peerTag(connectedHostID))\n"
            + "Host identifiers are iOS UUIDs, not Bluetooth MAC addresses.\n\(hosts)\n"
            + connectionSnapshot + "\n" + diagnostics.joined(separator: "\n")
    }

    private var connectionSnapshot: String {
        let ids = Set(savedHosts.map(\.id) + [session.host, session.preferredHost].compactMap { $0 })
        let links = ids.sorted { $0.uuidString < $1.uuidString }.map { id in
            let subscriptions = inputs.compactMap { channel, characteristic -> String? in
                (characteristic.subscribedCentrals ?? []).contains { $0.identifier == id }
                    ? String(describing: channel) : nil
            }.sorted().joined(separator: ",")
            return "Peer \(peerTag(id)): outgoing=\(browser.linkState(for: id)); HID subscriptions=[\(subscriptions)]"
        }
        return (["State: selected=\(peerTag(session.preferredHost)); ready=\(isReady); protocol=\(session.bootProtocol ? "boot" : "report"); suspend=\(session.suspended); queued=\(queue.count)"] + links).joined(separator: "\n")
    }

    func recordConnectionSnapshot() {
        for line in connectionSnapshot.split(separator: "\n") { record(String(line)) }
    }

    func requestWakeProbe() {
        record("Wake probe requested: \(peerTag(session.preferredHost))")
        recordConnectionSnapshot()
        guard isReady, afterDrain == nil, session.host == session.preferredHost else {
            record("Wake probe not sent: selected host has no ready HID session")
            return
        }
        guard queue.isEmpty, wakeProbeReportsRemaining == 0,
              state.modifiers == 0, state.keys.isEmpty, state.buttons == 0,
              state.consumerUsage == 0 else {
            record("Wake probe not sent: release held input and wait for the queue to drain")
            return
        }
        let reports = HIDInputState.wakeProbe
        guard queue.append(reports) else { return }
        wakeProbeReportsRemaining = reports.count
        wakeProbeBlocked = false
        record("Wake probe queued: Shift press/release to \(peerTag(session.host))")
        scheduleSend()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        let preferred = hostStore.selectedHostID
        session = makeSession(preferredHost: preferred, allowsPairing: hostStore.shouldPairOnStart)
        watchdog.reset()
        isPairing = hostStore.shouldPairOnStart
        selectedHostID = preferred
        browser.setKnownHosts(hostStore.hosts)
        record("Starting HID; selected \(peerTag(preferred)); pairing \(isPairing)")
        statusText = "Вмикаємо прямий Bluetooth…"
        browser.start()
    }

    private func startPeripheral() {
        guard isRunning, manager == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        record("Creating fresh HID peripheral; GATT restoration disabled")
        manager = CBPeripheralManager(delegate: self, queue: .main, options: [
            CBPeripheralManagerOptionShowPowerAlertKey: true
        ])
    }

    func stop(completion: @escaping () -> Void) {
        cancelRecovery()
        drainReleases { [weak self] in
            guard let self else { completion(); return }
            self.isRunning = false
            self.canPair = false
            self.isPairing = false
            self.pairingTimer?.cancel()
            self.cancelRecovery()
            self.watchdog.reset()
            self.sendWork?.cancel()
            self.manager?.stopAdvertising()
            self.advertising = HIDAdvertisingState()
            self.manager?.removeAllServices()
            self.manager?.delegate = nil
            self.manager = nil
            self.browser.stop()
            self.servicesInstalled = false
            self.addingService = nil
            self.inputs.removeAll()
            self.attributes.removeAll()
            self.clearInput()
            self.host = nil
            self.connectedHostID = nil
            self.lastReadyHostID = nil
            self.isReady = false
            self.statusText = "Прямий Bluetooth вимкнено"
            completion()
        }
    }

    func hostName(for id: UUID) -> String {
        hostStore.host(id)?.name ?? browser.name(for: id)
    }

    func renameHost(_ id: UUID, to name: String) {
        hostStore.rename(id, to: name)
        savedHosts = hostStore.hosts
        browser.setKnownHosts(savedHosts)
        if isRunning { refreshStatus() }
    }

    func forgetHost(_ id: UUID) {
        guard afterDrain == nil else { return }
        let forgottenTag = peerTag(id)
        let forget = { [weak self] in
            guard let self else { return }
            self.hostStore.forget(id)
            self.savedHosts = self.hostStore.hosts
            self.browser.forget(id)
            self.browser.setKnownHosts(self.savedHosts)
            self.record("Forgot host in app: \(forgottenTag); system bond unchanged")
        }
        if session.preferredHost == id || hostStore.selectedHostID == id {
            cancelRecovery()
            drainReleases { [weak self] in
                guard let self else { return }
                self.browser.cancelConnection()
                self.pairingTimer?.cancel()
                self.host = nil
                self.session = self.makeSession(preferredHost: nil, allowsPairing: false)
                self.isPairing = false
                self.lastError = nil
                forget()
                self.refreshStatus()
            }
        } else {
            forget()
            if isRunning { refreshStatus() }
        }
    }

    func beginPairing() { prepareHost(nil) }
    func connect(to id: UUID) { prepareHost(id) }

    private func prepareHost(_ id: UUID?) {
        guard canPair, afterDrain == nil else { return }
        cancelRecovery()
        watchdog.reset()
        drainReleases { [weak self] in
            guard let self, self.isRunning else { return }
            self.lastError = nil
            self.isPairing = true
            if let id {
                self.hostStore.select(id, name: self.browser.resolvedName(for: id), supportsOutgoing: false)
                self.savedHosts = self.hostStore.hosts
            }
            self.selectHost(
                id,
                allowsPairing: true,
                reason: id == nil ? "Pairing window opened" : "Host selected: \(self.peerTag(id))"
            )
            guard id == nil else { self.armPairingTimeout(); return }
            self.browser.cancelConnection()
            if self.manager?.state == .poweredOn {
                self.installServices()
            } else {
                self.armPairingTimeout()
            }
        }
    }

    func reconnectNow() {
        guard isRunning, afterDrain == nil else { return }
        cancelRecovery()
        watchdog.reset()
        drainReleases { [weak self] in
            guard let self, self.isRunning else { return }
            self.lastError = nil
            self.record("Manual reconnect; preserving Bluetooth managers, services and host links")
            self.retryHostLinks()
        }
    }

    func recoverAfterForeground() {
        guard isRunning else { return }
        loggedATT.removeAll()
        record("App returned to foreground; selected \(peerTag(hostStore.selectedHostID))")
        guard hostStore.selectedHostID != nil else { refreshStatus(); return }
        watchdog.reset()
        restartAdvertising()
        refreshStatus()
    }

    private func selectHost(_ id: UUID?, allowsPairing: Bool, reason: String) {
        host = nil
        session = makeSession(preferredHost: id, allowsPairing: allowsPairing)
        clearInput()
        browser.setKnownHosts(hostStore.hosts)
        record(reason)
        browser.maintainLinks(to: hostStore.hosts.map(\.id))
        if let id, adoptLiveSubscriptions(of: id) {
            record("Adopted live HID subscriptions: \(peerTag(id))")
        }
        refreshStatus()
    }

    private func adoptLiveSubscriptions(of id: UUID) -> Bool {
        guard servicesInstalled else { return false }
        func subscribed(_ channel: HIDInputChannel) -> CBCentral? {
            (inputs[channel]?.subscribedCentrals ?? []).first { $0.identifier == id }
        }
        let boot = session.bootProtocol
        session.bootProtocol = false
        var central = subscribed(.keyboard)
        if central == nil || subscribed(.mouse) == nil {
            session.bootProtocol = true
            central = subscribed(.bootKeyboard)
            if central == nil || subscribed(.bootMouse) == nil {
                session.bootProtocol = boot
                return false
            }
        }
        guard let central else { session.bootProtocol = boot; return false }
        guard session.subscribe(session.keyboardChannel, from: id),
              session.subscribe(session.mouseChannel, from: id) else {
            session.bootProtocol = boot
            return false
        }
        if subscribed(.consumer) != nil {
            _ = session.subscribe(.consumer, from: id)
        }
        host = central
        _ = queue.append([state.keyboard, state.mouse(), state.consumer])
        scheduleSend()
        return true
    }

    private func retryHostLinks() {
        browser.maintainLinks(to: hostStore.hosts.map(\.id))
        restartAdvertising()
        recordConnectionSnapshot()
        refreshStatus()
    }

    private func cancelRecovery() {
        advertisingRetry?.cancel()
        advertisingRetry = nil
        watchdogWork?.cancel()
        watchdogWork = nil
    }

    private func updateWatchdog() {
        let wantsHost = isRunning && afterDrain == nil
            && (isPairing || session.preferredHost != nil)
        guard wantsHost, !session.isReady else {
            cancelWatchdog(rewind: true)
            return
        }
        if let state = manager?.state, state != .poweredOn {
            cancelWatchdog(rewind: true)
            return
        }
        guard watchdogWork == nil else { return }
        guard let next = watchdog.next(pairingOnly: session.preferredHost == nil) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.watchdogWork = nil
            self.runWatchdogStep(next.step)
        }
        watchdogWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.delay, execute: work)
    }

    private func cancelWatchdog(rewind: Bool) {
        watchdogWork?.cancel()
        watchdogWork = nil
        if rewind { watchdog.reset() }
    }

    private func runWatchdogStep(_ step: HIDReconnectWatchdog.Step) {
        guard isRunning else { return }
        guard !session.isReady, afterDrain == nil else { refreshStatus(); return }
        let position = "\(watchdog.attempt)/\(HIDReconnectWatchdog.schedule.count)"
        switch step {
        case .restartAdvertising:
            record("Recovery \(position): reissuing the HID advertisement")
            restartAdvertising()
        case .retryLinks:
            record("Recovery \(position): checking host links; preserving HID services and subscriptions")
            retryHostLinks()
        }
        refreshStatus()
    }

    private func scheduleAdvertisingRetry() {
        guard isRunning, advertisingRetry == nil else { return }
        let backoff: [TimeInterval] = [2, 5, 10, 20, 30]
        let delay = backoff[min(advertisingFailures, backoff.count - 1)]
        advertisingFailures += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.advertisingRetry = nil
            self.record("Retrying the advertisement after a failed start")
            self.restartAdvertising()
        }
        advertisingRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func restartAdvertising() {
        guard let manager, manager.state == .poweredOn, servicesInstalled else { return }
        manager.stopAdvertising()
        advertising = HIDAdvertisingState()
        if lastError == advertisingError { lastError = nil }
        advertisingError = nil
        advertise()
    }

    private func armPairingTimeout() {
        pairingTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.isPairing else { return }
            self.isPairing = false
            self.session.allowsPairing = false
            self.record("Pairing window closed")
            guard !self.session.isReady else { self.refreshStatus(); return }
            if self.session.preferredHost != self.hostStore.selectedHostID {
                self.drainReleases { [weak self] in
                    guard let self else { return }
                    self.host = nil
                    let preferred = self.hostStore.selectedHostID
                    self.selectHost(
                        preferred,
                        allowsPairing: false,
                        reason: "Pairing timed out; restoring selected host"
                    )
                }
            }
            self.refreshStatus()
        }
        pairingTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timer)
    }

    private func characteristic(_ uuid: String, _ attribute: Attribute,
                                properties: CBCharacteristicProperties,
                                permissions: CBAttributePermissions) -> CBMutableCharacteristic {
        let characteristic = CBMutableCharacteristic(type: Self.uuid(uuid), properties: properties,
                                                      value: nil, permissions: permissions)
        attributes[ObjectIdentifier(characteristic)] = attribute
        if case .input(let channel) = attribute { inputs[channel] = characteristic }
        return characteristic
    }

    private func report(_ kind: HIDReportKind, channel: HIDInputChannel) -> CBMutableCharacteristic {
        let item = characteristic("2A4D", .input(channel), properties: [.read, .notifyEncryptionRequired],
                                  permissions: .readEncryptionRequired)
        item.descriptors = [CBMutableDescriptor(type: Self.uuid("2908"),
                                                value: NSData(data: Data([kind.rawValue, 1])))]
        return item
    }

    private func installServices() {
        guard let manager, manager.state == .poweredOn else { return }
        canPair = false
        servicesInstalled = false
        rejectedPeers.removeAll()
        loggedATT.removeAll()
        manager.stopAdvertising()
        advertising = HIDAdvertisingState()
        manager.removeAllServices()
        attributes.removeAll()
        inputs.removeAll()
        let info = CBMutableService(type: Self.uuid("180A"), primary: true)
        info.characteristics = [
            characteristic("2A29", .manufacturer, properties: .read, permissions: .readable),
            characteristic("2A24", .model, properties: .read, permissions: .readable),
            characteristic("2A50", .pnpID, properties: .read, permissions: .readable)
        ]
        let battery = CBMutableService(type: Self.uuid("180F"), primary: true)
        battery.characteristics = [characteristic("2A19", .battery, properties: .read, permissions: .readable)]
        let hid = CBMutableService(type: Self.uuid("1812"), primary: true)
        let output = characteristic("2A4D", .leds, properties: [.read, .write, .writeWithoutResponse],
                                    permissions: [.readEncryptionRequired, .writeEncryptionRequired])
        output.descriptors = [CBMutableDescriptor(type: Self.uuid("2908"), value: NSData(data: Data([1, 2])))]
        hid.characteristics = [
            characteristic("2A4A", .information, properties: .read, permissions: .readable),
            characteristic("2A4B", .reportMap, properties: .read, permissions: .readEncryptionRequired),
            characteristic("2A4E", .protocolMode, properties: [.read, .writeWithoutResponse],
                           permissions: [.readEncryptionRequired, .writeEncryptionRequired]),
            characteristic("2A4C", .controlPoint, properties: .writeWithoutResponse, permissions: .writeEncryptionRequired),
            report(.keyboard, channel: .keyboard), output,
            report(.mouse, channel: .mouse), report(.consumer, channel: .consumer),
            characteristic("2A22", .input(.bootKeyboard), properties: [.read, .notifyEncryptionRequired],
                           permissions: .readEncryptionRequired),
            characteristic("2A32", .leds, properties: [.read, .write, .writeWithoutResponse],
                           permissions: [.readEncryptionRequired, .writeEncryptionRequired]),
            characteristic("2A33", .input(.bootMouse), properties: [.read, .notifyEncryptionRequired],
                           permissions: .readEncryptionRequired)
        ]
        serviceQueue = [info, battery, hid]
        addNextService()
    }

    private func addNextService() {
        guard !serviceQueue.isEmpty else {
            addingService = nil
            servicesInstalled = true
            canPair = true
            refreshStatus()
            if isPairing { armPairingTimeout() }
            browser.maintainLinks(to: hostStore.hosts.map(\.id))
            return
        }
        addingService = serviceQueue.removeFirst()
        manager?.add(addingService!)
    }

    private func advertise() {
        let wanted = isRunning && servicesInstalled && manager?.state == .poweredOn
        applyAdvertising(advertising.update(wanted: wanted))
    }

    private func applyAdvertising(_ action: HIDAdvertisingState.Action?) {
        guard let manager else { return }
        switch action {
        case .start:
            manager.startAdvertising([
                CBAdvertisementDataLocalNameKey: advertisedName,
                CBAdvertisementDataServiceUUIDsKey: [Self.uuid("1812")]
            ])
        case .stop:
            manager.stopAdvertising()
        case nil:
            break
        }
    }

    private func connectingStatus(for id: UUID) -> String {
        watchdog.isExhausted
            ? "\(hostName(for: id)) не відповідає. Підключи iPhone на пристрої."
            : "Під’єднуємось до \(hostName(for: id))…"
    }

    private func noteRejectedPeer(_ id: UUID, action: String, repeating: Bool) {
        let first = rejectedPeers.insert(id).inserted
        if first {
            browser.resolveName(for: id)
            let selected = session.preferredHost
            let link = selected.map { browser.isConnected($0) ? "connected" : "not connected" } ?? "none"
            record("Not routing \(peerTag(id)); selected \(peerTag(selected)); outgoing link to selected host \(link)")
        }
        if first || repeating { record("Not routed \(action): \(peerTag(id))") }
    }

    private func makeSession(preferredHost: UUID?, allowsPairing: Bool) -> HIDHostSession {
        var session = HIDHostSession(preferredHost: preferredHost, allowsPairing: allowsPairing)
        session.knownHosts = Set(hostStore.hosts.map(\.id))
        return session
    }

    private func peerTag(_ id: UUID?) -> String {
        id.map { "\(hostName(for: $0)) [\($0.uuidString.prefix(8))]" } ?? "none"
    }

    private func record(_ event: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        diagnostics.append("\(time) \(event)")
        if diagnostics.count > 400 { diagnostics.removeFirst(diagnostics.count - 400) }
    }

    private func noteATT(_ action: String, _ attribute: String, _ peer: UUID,
                         _ result: String, detail: String = "") {
        if loggedATT.count > 400 { loggedATT.removeAll() }
        guard loggedATT.insert("\(peer.uuidString)/\(action)/\(attribute)/\(result)").inserted else { return }
        record("ATT \(action) \(attribute) from \(peerTag(peer)): \(result)"
               + (detail.isEmpty ? "" : " (\(detail))"))
    }

    private func refreshStatus(updateAdvertisement: Bool = true) {
        let ready = isRunning && afterDrain == nil && session.isReady
        selectedHostID = session.preferredHost
        connectedHostID = ready ? session.host : nil
        if ready {
            isPairing = false
            session.allowsPairing = false
            pairingTimer?.cancel()
            if let id = session.host {
                if lastReadyHostID != id {
                    lastReadyHostID = id
                    hostStore.connected(id, name: browser.resolvedName(for: id), supportsOutgoing: browser.requestedHost == id)
                    savedHosts = hostStore.hosts
                    record("HID ready: \(peerTag(id))")
                    browser.resolveName(for: id)
                }
                browser.rememberReadyHost(id)
                statusText = session.suspended
                    ? "HID готовий · \(hostName(for: id)) · пристрій спить"
                    : "HID готовий · \(hostName(for: id))"
            }
        } else if let lastError {
            statusText = lastError
        } else if afterDrain != nil {
            statusText = "Відпускання клавіш…"
        } else if !servicesInstalled {
            statusText = "Готуємо Bluetooth…"
        } else if let id = session.host ?? browser.requestedHost ?? session.preferredHost {
            statusText = connectingStatus(for: id)
        } else if isPairing {
            statusText = "Готові до сполучення · знайди «\(advertisedName)» на пристрої"
        } else {
            statusText = "Вибери пристрій або відкрий сполучення"
        }
        if !ready { lastReadyHostID = nil }
        isReady = ready
        if updateAdvertisement { advertise() }
        updateWatchdog()
    }

    private func clearInput() {
        cancelWakeProbe()
        sendWork?.cancel()
        sendWork = nil
        loggedOversizedReport = false
        queue.removeAll()
        afterInputQueueDrains = nil
        state = HIDInputState()
        lastKeyboard = state.keyboard.data
        lastMouse = state.mouse().data
        lastConsumer = state.consumer.data
    }

    func releaseAllInput() {
        let releaseWakeProbe = wakeProbeReportsRemaining == 1
        cancelWakeProbe()
        guard !session.suspended || releaseWakeProbe else {
            clearInput()
            return
        }
        sendWork?.cancel()
        sendWork = nil
        queue.removeAll()
        let reports = state.releaseAll()
        _ = queue.append(reports)
        scheduleSend()
    }

    private func drainReleases(_ completion: @escaping () -> Void) {
        drainTimer?.cancel()
        afterDrain = completion
        finishingDrain = false
        isReady = false
        releaseAllInput()
        let timer = DispatchWorkItem { [weak self] in self?.finishDrain() }
        drainTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timer)
        refreshStatus()
    }

    private func finishDrain() {
        guard let completion = afterDrain else { return }
        afterDrain = nil
        drainTimer?.cancel()
        drainTimer = nil
        clearInput()
        finishingDrain = false
        completion()
    }

    private func scheduleSend() {
        guard sendWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sendWork = nil
            self.sendNext()
        }
        sendWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008, execute: work)
    }

    private func sendNext() {
        guard isRunning else { return }
        switch queue.sendNext({ [self] report in transmit(report) }) {
        case .blocked:
            break
        case .sent:
            scheduleSend()
        case .empty:
            if let completion = afterInputQueueDrains {
                afterInputQueueDrains = nil
                completion()
            }
            if afterDrain != nil, !finishingDrain {
                finishingDrain = true
                let work = DispatchWorkItem { [weak self] in self?.finishDrain() }
                sendWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
        }
    }

    private func transmit(_ report: HIDInputReport) -> Bool {
        guard let manager, manager.state == .poweredOn, let host else {
            if report.isWakeProbe { cancelWakeProbe() }
            return true
        }
        let channel: HIDInputChannel
        switch report.kind {
        case .keyboard: channel = session.keyboardChannel
        case .mouse: channel = session.mouseChannel
        case .consumer: channel = .consumer
        }
        guard session.subscriptions.contains(channel), let characteristic = inputs[channel] else {
            if report.isWakeProbe { cancelWakeProbe() }
            return true
        }
        let data = channel == .bootMouse ? Data(report.data.prefix(3)) : report.data
        guard data.count <= host.maximumUpdateValueLength else {
            if !loggedOversizedReport {
                loggedOversizedReport = true
                record("Dropped a \(data.count) B report; host accepts \(host.maximumUpdateValueLength) B")
            }
            if report.isWakeProbe { cancelWakeProbe() }
            return true
        }
        guard manager.updateValue(data, for: characteristic, onSubscribedCentrals: [host]) else {
            if report.isWakeProbe, !wakeProbeBlocked {
                wakeProbeBlocked = true
                record("Wake probe blocked by CoreBluetooth backpressure: \(peerTag(host.identifier)); report remains queued")
            }
            return false
        }
        if report.isWakeProbe {
            record("Wake probe report accepted by CoreBluetooth: \(peerTag(host.identifier)); \(channel), \(data.count) B; suspend=\(session.suspended)")
            if wakeProbeReportsRemaining > 0 {
                wakeProbeReportsRemaining -= 1
                if wakeProbeReportsRemaining == 0 {
                    record("Wake probe submitted; host delivery and wake are not confirmed")
                }
            }
        }
        switch report.kind {
        case .keyboard:
            lastKeyboard = report.data
        case .mouse:
            lastMouse = Data([report.data[0], 0, 0, 0, 0])
        case .consumer:
            lastConsumer = report.data
        }
        return true
    }

    private func cancelWakeProbe() {
        if wakeProbeReportsRemaining > 0 {
            record("Wake probe interrupted: \(peerTag(session.host)); \(wakeProbeReportsRemaining) reports not submitted")
        }
        wakeProbeReportsRemaining = 0
        wakeProbeBlocked = false
    }

    private func enqueue(_ reports: [HIDInputReport]) {
        guard isReady else { return }
        if !queue.append(reports) {
            lastError = "Забагато тексту в черзі. Надішли меншими частинами."
            record("Input queue capacity exceeded; input released")
            releaseAllInput()
        }
        scheduleSend()
    }

    func setModifiers(_ mask: UInt8) {
        guard isReady else { return }
        enqueue([state.setModifiers(mask)])
    }
    func sendKeyDown(modifiersMask: UInt8, keycode: UInt8) {
        guard isReady else { return }
        enqueue([state.keyDown(keycode, modifiers: modifiersMask)])
    }
    func sendKeyUp(keycode: UInt8) {
        guard isReady else { return }
        enqueue([state.keyUp(keycode)])
    }
    func sendKeyTap(modifiers: UInt8, hidKeycode: UInt8) {
        enqueue(state.tap(hidKeycode, modifiers: modifiers))
    }
    func sendKeyTaps(_ taps: [(modifiers: UInt8, keycode: UInt8)]) {
        guard isReady else { return }
        guard taps.count <= queue.capacity / 3 else {
            lastError = "Текст завеликий. Надішли меншими частинами."
            return
        }
        enqueue(taps.flatMap { state.tap($0.keycode, modifiers: $0.modifiers) })
    }

    @discardableResult
    func sendKeyTaps(
        _ taps: [(modifiers: UInt8, keycode: UInt8)],
        whenDrained completion: @escaping () -> Void
    ) -> Bool {
        guard isReady else { return false }
        guard taps.count <= queue.capacity / 3 else {
            lastError = "Текст завеликий. Надішли меншими частинами."
            return false
        }
        afterInputQueueDrains = completion
        enqueue(taps.flatMap { state.tap($0.keycode, modifiers: $0.modifiers) })
        return true
    }

    func sendConsumerDown(usage: UInt16) {
        guard isReady else { return }
        enqueue([state.consumerDown(usage)])
    }

    func sendConsumerUp() {
        guard isReady else { return }
        enqueue([state.consumerUp()])
    }

    func sendMouseMove(dx: Int8, dy: Int8) { enqueue([state.mouse(dx: dx, dy: dy)]) }
    func sendMouseScroll(dx: Int8, dy: Int8) { enqueue([state.mouse(wheel: dy, pan: dx)]) }
    func sendMouseClick(button: UInt8) { enqueue(state.click(button)) }
    func sendMouseButtonDown(button: UInt8) {
        guard isReady else { return }
        enqueue([state.buttonDown(button)])
    }
    func sendMouseButtonUp(button: UInt8) {
        guard isReady else { return }
        enqueue([state.buttonUp(button)])
    }

    private func disconnected(_ id: UUID, cause: HIDPeerDisconnectCause) {
        guard session.host == id else {
            if session.preferredHost == id, cause != .appCancelledOutgoingLink, isRunning {
                record("Selected host link lost before HID subscriptions: \(peerTag(id)); cause \(cause.rawValue)")
                refreshStatus()
            }
            return
        }
        let stillSubscribed = inputs.contains { channel, characteristic in
            session.subscriptions.contains(channel)
                && (characteristic.subscribedCentrals ?? []).contains { $0.identifier == id }
        }
        guard HIDDisconnectPolicy.invalidatesSession(
            cause: cause,
            reportsStillSubscribed: stillSubscribed
        ) else {
            record("App cancelled outgoing BLE; HID subscriptions remain: \(peerTag(id))")
            return
        }
        record("HID disconnected: \(peerTag(id)); cause \(cause.rawValue); subscribed \(stillSubscribed)")
        session.disconnect(id)
        host = nil
        clearInput()
        refreshStatus()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager, isRunning else { return }
        record("Peripheral state: \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn {
            advertising = HIDAdvertisingState(isAdvertising: peripheral.isAdvertising)
            lastError = nil
            cancelWatchdog(rewind: true)
            if servicesInstalled {
                canPair = true
                refreshStatus()
            } else {
                installServices()
            }
        } else {
            canPair = false
            servicesInstalled = false
            advertising = HIDAdvertisingState()
            addingService = nil
            serviceQueue.removeAll()
            if let id = session.host { session.disconnect(id) }
            host = nil
            clearInput()
            lastError = peripheral.state == .unauthorized ? "Немає дозволу на Bluetooth" : "Bluetooth недоступний"
            refreshStatus()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager, isRunning, service.uuid == addingService?.uuid else { return }
        if let error {
            lastError = "Не вдалося створити HID: \(error.localizedDescription)"
            record("Service \(service.uuid): \(error.localizedDescription)")
            cancelRecovery()
            addingService = nil
            serviceQueue.removeAll()
            refreshStatus()
            return
        }
        record("Service registered: \(service.uuid)")
        addNextService()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager, isRunning else { return }
        applyAdvertising(advertising.didStart(succeeded: error == nil))
        if let error = error as NSError? {
            advertisingError = "Помилка видимості Bluetooth: \(error.localizedDescription)"
            if !session.isReady { lastError = advertisingError }
            record("Advertising failed: \(error.domain)/\(error.code): \(error.localizedDescription)")
            scheduleAdvertisingRetry()
        } else {
            if lastError == advertisingError { lastError = nil }
            advertisingError = nil
            advertisingFailures = 0
            advertisingRetry?.cancel()
            advertisingRetry = nil
            record("Advertising HID; selected \(peerTag(session.preferredHost))")
        }
        refreshStatus(updateAdvertisement: false)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === manager, isRunning,
              case .input(let channel)? = attributes[ObjectIdentifier(characteristic)] else { return }
        guard session.subscribe(channel, from: central.identifier) else {
            noteRejectedPeer(central.identifier, action: "\(channel) subscription", repeating: true)
            return
        }
        host = central
        cancelWatchdog(rewind: true)
        record("Subscribed: \(channel), host \(peerTag(central.identifier)), \(central.maximumUpdateValueLength) B notifications")
        _ = queue.append([state.keyboard, state.mouse(), state.consumer])
        scheduleSend()
        refreshStatus()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === manager, isRunning, session.host == central.identifier,
              case .input(let channel)? = attributes[ObjectIdentifier(characteristic)] else { return }
        session.unsubscribe(channel, from: central.identifier)
        record("Unsubscribed: \(channel), host \(peerTag(central.identifier))")
        clearInput()
        if session.host == nil { host = nil }
        refreshStatus()
        releaseAllInput()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        scheduleSend()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let peer = request.central.identifier
        guard isRunning else {
            noteATT("read", "-", peer, "unlikelyError", detail: "transport stopped")
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        if !session.allows(peer) {
            noteRejectedPeer(peer, action: "read (answered, not routed)", repeating: false)
        }
        guard let attribute = attributes[ObjectIdentifier(request.characteristic)] else {
            noteATT("read", request.characteristic.uuid.uuidString, peer, "attributeNotFound")
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        let value: Data
        switch attribute {
        case .input(.keyboard), .input(.bootKeyboard): value = lastKeyboard
        case .input(.mouse): value = lastMouse
        case .input(.consumer): value = lastConsumer
        case .input(.bootMouse): value = Data(lastMouse.prefix(3))
        case .leds: value = Data([leds])
        case .protocolMode: value = Data([session.bootProtocol ? 0 : 1])
        case .controlPoint:
            noteATT("read", attribute.label, peer, "readNotPermitted")
            peripheral.respond(to: request, withResult: .readNotPermitted)
            return
        case .reportMap:
            value = RemoteHIDDescriptor.reportMap
            if session.allows(peer) {
                cancelWatchdog(rewind: true)
                updateWatchdog()
            }
        case .information: value = RemoteHIDDescriptor.information
        case .battery: value = Data([UInt8(max(0, min(100, Int(UIDevice.current.batteryLevel * 100))))])
        case .manufacturer: value = Data("ESP Remote Control".utf8)
        case .model: value = Data("Direct HID v2".utf8)
        case .pnpID: value = Data([1, 0xFF, 0xFF, 1, 0, 0, 2])
        }
        guard request.offset <= value.count else {
            noteATT("read", attribute.label, peer, "invalidOffset", detail: "offset \(request.offset)")
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = Data(value.dropFirst(request.offset))
        noteATT("read", attribute.label, peer, "success",
                detail: "\(value.count) B, offset \(request.offset)")
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        let peer = first.central.identifier
        guard isRunning else {
            noteATT("write", "-", peer, "unlikelyError", detail: "transport stopped")
            peripheral.respond(to: first, withResult: .unlikelyError); return
        }
        let routed = session.allows(first.central.identifier)
        for request in requests {
            let attribute = attributes[ObjectIdentifier(request.characteristic)]
            let label = attribute?.label ?? request.characteristic.uuid.uuidString
            guard request.offset == 0 else {
                noteATT("write", label, peer, "invalidOffset", detail: "offset \(request.offset)")
                peripheral.respond(to: first, withResult: .invalidOffset); return
            }
            guard let value = request.value, value.count == 1 else {
                noteATT("write", label, peer, "invalidAttributeValueLength",
                        detail: "\(request.value?.count ?? 0) B")
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength); return
            }
            switch attribute {
            case .leds: break
            case .protocolMode, .controlPoint:
                guard value[0] <= 1 else {
                    noteATT("write", label, peer, "requestNotSupported", detail: "value \(value[0])")
                    peripheral.respond(to: first, withResult: .requestNotSupported); return
                }
            default:
                noteATT("write", label, peer, "writeNotPermitted")
                peripheral.respond(to: first, withResult: .writeNotPermitted); return
            }
        }
        guard routed else {
            noteRejectedPeer(peer, action: "write (answered, not applied)", repeating: false)
            peripheral.respond(to: first, withResult: .success)
            return
        }
        for request in requests {
            let value = request.value![0]
            switch attributes[ObjectIdentifier(request.characteristic)] {
            case .leds: leds = value & 0x1F
            case .protocolMode:
                session.bootProtocol = value == 0
                record("Protocol: \(value == 0 ? "boot" : "report"); host \(peerTag(peer))")
                releaseAllInput()
            case .controlPoint:
                session.suspended = value == 0
                record(value == 0
                    ? "Host entered suspend: \(peerTag(peer)); input remains enabled for remote wake"
                    : "Host exited suspend: \(peerTag(peer))")
                if value == 0 { clearInput() }
            default: break
            }
        }
        for request in requests {
            let label = attributes[ObjectIdentifier(request.characteristic)]?.label
                ?? request.characteristic.uuid.uuidString
            noteATT("write", label, peer, "success", detail: "value \(request.value![0])")
        }
        peripheral.respond(to: first, withResult: .success)
        refreshStatus()
    }
}
