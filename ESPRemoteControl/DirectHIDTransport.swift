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
    }
    private static func uuid(_ short: String) -> CBUUID {
        CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB")
    }

    private let hostStore: HIDHostStore
    private var advertising = HIDAdvertisingState()
    private var advertisingError: String?
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
    private var leds: UInt8 = 0
    private var sendWork: DispatchWorkItem?
    private var pairingTimer: DispatchWorkItem?
    private var afterDrain: (() -> Void)?
    private var afterInputQueueDrains: (() -> Void)?
    private var drainTimer: DispatchWorkItem?
    private var finishingDrain = false
    private var stackRecoveryWork: DispatchWorkItem?
    private var watchdog = HIDReconnectWatchdog()
    private var watchdogWork: DispatchWorkItem?
    private var rejectedPeers: Set<UUID> = []
    private var loggedOversizedReport = false

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
            self.record("Outgoing BLE link connected: \(id.uuidString.prefix(8))")
            self.refreshStatus()
        }
    }

    var diagnosticText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let selected = selectedHostID.map { String($0.uuidString.prefix(8)) } ?? "none"
        let connected = connectedHostID.map { String($0.uuidString.prefix(8)) } ?? "none"
        return "ESP Remote \(version) (\(build)) · iOS \(UIDevice.current.systemVersion)\n\(statusText)\nSelected: \(selected); HID ready: \(connected)\n" + diagnostics.joined(separator: "\n")
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
        // Register system connection events before exposing HID services.
        browser.start()
    }

    private func startPeripheral() {
        guard isRunning, manager == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        // Do not opt in to CoreBluetooth state restoration for this HID GATT
        // database. iOS can assert while reconstructing a persisted descriptor,
        // inside handleRestoringState, before willRestoreState reaches the app.
        // Rebuild services on poweredOn; HIDHostStore independently preserves
        // computer names/selection, and system Bluetooth bonds remain intact.
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
        let forget = { [weak self] in
            guard let self else { return }
            self.hostStore.forget(id)
            self.savedHosts = self.hostStore.hosts
            self.browser.forget(id)
            self.browser.setKnownHosts(self.savedHosts)
            self.record("Forgot host in app: \(self.peerTag(id)); system bond unchanged")
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
    func connect(to id: UUID) {
        prepareHost(id)
    }

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
        }
    }

    func reconnectNow() {
        guard isRunning, afterDrain == nil else { return }
        cancelRecovery()
        watchdog.reset()
        let preferred = session.preferredHost ?? hostStore.selectedHostID
        drainReleases { [weak self] in
            guard let self, self.isRunning else { return }
            self.lastError = nil
            self.restartBluetoothStack(
                preferredHost: preferred,
                allowsPairing: self.isPairing,
                reason: "Manual full Bluetooth restart"
            )
        }
    }

    func recoverAfterForeground() {
        guard isRunning, hostStore.selectedHostID != nil else { return }
        watchdog.reset()
        scheduleStackRecovery(reason: "App returned to foreground", force: true, delay: 0.15)
    }

    /// Redirecting input to another computer needs no new GATT database: the
    /// services are identical, and republishing them makes the newly selected
    /// host rediscover everything, which is what made switching cost tens of
    /// seconds. A physical multi-host keyboard holds its links and simply
    /// changes where it sends, and so does this now.
    private func selectHost(_ id: UUID?, allowsPairing: Bool, reason: String) {
        stackRecoveryWork?.cancel()
        stackRecoveryWork = nil
        host = nil
        session = makeSession(preferredHost: id, allowsPairing: allowsPairing)
        clearInput()
        browser.setKnownHosts(hostStore.hosts)
        record(reason)
        // Every saved computer keeps its link, including the one just left.
        // Switching is then a change of notification target, not a fresh
        // connection, which is the difference between instant and tens of
        // seconds.
        browser.maintainLinks(to: hostStore.hosts.map(\.id))
        if let id, adoptLiveSubscriptions(of: id) {
            record("Adopted live HID subscriptions: \(peerTag(id))")
        }
        refreshStatus()
    }

    /// A central still listed on both input characteristics is being notified
    /// right now, so its session resumes without a republication. A stale entry
    /// costs one recovery delay, where republishing cost a rediscovery on every
    /// single switch — which is why 2.1.2 abandoning adoption was the wrong
    /// trade.
    private func adoptLiveSubscriptions(of id: UUID) -> Bool {
        guard servicesInstalled else { return false }
        let keyboard = inputs[session.keyboardChannel]?.subscribedCentrals ?? []
        let mouse = inputs[session.mouseChannel]?.subscribedCentrals ?? []
        guard let central = keyboard.first(where: { $0.identifier == id }),
              mouse.contains(where: { $0.identifier == id }) else { return false }
        guard session.subscribe(session.keyboardChannel, from: id),
              session.subscribe(session.mouseChannel, from: id) else { return false }
        host = central
        // A baseline report lets the host resynchronise its view of held input.
        _ = queue.append([state.keyboard, state.mouse()])
        scheduleSend()
        return true
    }

    private func rebuildHIDServices(
        preferredHost: UUID?,
        allowsPairing: Bool,
        reason: String
    ) {
        stackRecoveryWork?.cancel()
        stackRecoveryWork = nil
        host = nil
        session = makeSession(preferredHost: preferredHost, allowsPairing: allowsPairing)
        clearInput()
        browser.setKnownHosts(hostStore.hosts)
        record(reason)
        if manager?.state == .poweredOn {
            installServices()
        } else {
            refreshStatus()
        }
    }

    private func restartBluetoothStack(
        preferredHost: UUID?,
        allowsPairing: Bool,
        reason: String
    ) {
        guard isRunning else { return }
        cancelRecovery()
        pairingTimer?.cancel()
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager?.delegate = nil
        manager = nil
        browser.stop()
        advertising = HIDAdvertisingState()
        advertisingError = nil
        servicesInstalled = false
        serviceQueue.removeAll()
        addingService = nil
        inputs.removeAll()
        attributes.removeAll()
        canPair = false
        host = nil
        session = makeSession(preferredHost: preferredHost, allowsPairing: allowsPairing)
        clearInput()
        connectedHostID = nil
        lastReadyHostID = nil
        isReady = false
        statusText = "Перезапускаємо Bluetooth…"
        browser.setKnownHosts(hostStore.hosts)
        record("\(reason); rebuilding Bluetooth managers; selected \(peerTag(preferredHost))")
        browser.start()
        // Cover the restart itself: a manager that never reaches poweredOn
        // produces no callback, and no other timer is watching this window.
        updateWatchdog()
    }

    private func scheduleStackRecovery(reason: String, force: Bool, delay: TimeInterval = 0.5) {
        guard isRunning, (session.preferredHost ?? hostStore.selectedHostID) != nil else { return }
        stackRecoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.stackRecoveryWork = nil
            guard force || !self.session.isReady else {
                self.record("Automatic stack restart cancelled; fresh HID subscriptions arrived")
                return
            }
            let preferred = self.session.preferredHost ?? self.hostStore.selectedHostID
            self.restartBluetoothStack(
                preferredHost: preferred,
                allowsPairing: self.isPairing,
                reason: reason
            )
        }
        stackRecoveryWork = work
        record("Automatic stack restart scheduled: \(reason)")
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelRecovery() {
        stackRecoveryWork?.cancel()
        stackRecoveryWork = nil
        watchdogWork?.cancel()
        watchdogWork = nil
        // The ladder itself is not rewound here: every escalation calls this,
        // and resetting the attempt count would make recovery loop forever.
    }

    /// Schedules the next escalation whenever the transport wants to be
    /// reachable but has no working HID session, and stands down once one
    /// exists. Both directions run from `refreshStatus`.
    private func updateWatchdog() {
        let wantsHost = isRunning && afterDrain == nil
            && (isPairing || session.preferredHost != nil)
        guard wantsHost, !session.isReady else {
            cancelWatchdog(rewind: true)
            return
        }
        // Bluetooth being off or unauthorised is not something recovery can
        // repair, and powering on republishes services anyway. A manager that
        // does not exist yet is different: that is the window a stalled
        // restart never leaves on its own.
        if let state = manager?.state, state != .poweredOn {
            cancelWatchdog(rewind: true)
            return
        }
        // A scheduled stack restart already owns the timeline; escalating on
        // top of one would only interrupt it.
        guard watchdogWork == nil, stackRecoveryWork == nil else { return }
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
        let preferred = session.preferredHost ?? hostStore.selectedHostID
        let position = "\(watchdog.attempt)/\(HIDReconnectWatchdog.schedule.count)"
        switch step {
        case .restartAdvertising:
            record("Recovery \(position): reissuing the HID advertisement")
            restartAdvertising()
        case .republishServices:
            record("Recovery \(position): republishing HID services")
            rebuildHIDServices(
                preferredHost: preferred,
                allowsPairing: isPairing,
                reason: "Automatic HID service republication; selected \(peerTag(preferred))"
            )
        case .restartStack:
            record("Recovery \(position): rebuilding the Bluetooth managers")
            restartBluetoothStack(
                preferredHost: preferred,
                allowsPairing: isPairing,
                reason: "Automatic Bluetooth restart after no HID subscriptions"
            )
        }
        refreshStatus()
    }

    /// Reissues the advertisement without touching the GATT database. A start
    /// that failed or stopped leaves the phone invisible, and a host cannot
    /// reconnect to a phone it cannot see.
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
            guard let self, self.isPairing, !self.session.isReady else { return }
            self.isPairing = false
            self.session.allowsPairing = false
            self.record("Pairing window closed")
            // An incomplete new pairing must not replace the last saved host.
            if self.session.preferredHost != self.hostStore.selectedHostID {
                self.drainReleases { [weak self] in
                    guard let self else { return }
                    self.host = nil
                    let preferred = self.hostStore.selectedHostID
                    self.rebuildHIDServices(
                        preferredHost: preferred,
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
            report(.keyboard, channel: .keyboard), output, report(.mouse, channel: .mouse),
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
            && afterDrain == nil && (isPairing || session.preferredHost != nil)
        applyAdvertising(advertising.update(wanted: wanted))
    }

    private func applyAdvertising(_ action: HIDAdvertisingState.Action?) {
        guard let manager else { return }
        switch action {
        case .start:
            record("Advertising requested; selected \(peerTag(session.preferredHost))")
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

    /// This app *is* the keyboard and mouse, so it must never report waiting
    /// for one: what it is really waiting for is the computer to accept it,
    /// and until recovery gives up it is actively advertising and retrying.
    /// The outgoing connect request stays pending indefinitely by design, so
    /// its presence alone must not keep the status reading as progress once
    /// recovery has given up.
    private func connectingStatus(for id: UUID) -> String {
        watchdog.isExhausted
            ? "\(hostName(for: id)) не відповідає. Підключи iPhone на комп’ютері."
            : "Під’єднуємось до \(hostName(for: id))…"
    }

    /// Refusing a peer that is not the selected computer is the intended
    /// pinning, but the identifier alone cannot say what was refused: a peer
    /// has separate CoreBluetooth identifiers in the central and peripheral
    /// roles, so the selected computer arriving as a GATT client looks exactly
    /// like a different machine. Record once per peer what distinguishes them —
    /// the name CoreBluetooth can resolve for it, and whether our own link to
    /// the selected host is up at that moment. Later refusals from the same
    /// peer only repeat for subscriptions; reads would otherwise bury the
    /// journal without adding anything.
    private func noteRejectedPeer(_ id: UUID, action: String, repeating: Bool) {
        let first = rejectedPeers.insert(id).inserted
        if first {
            browser.resolveName(for: id)
            let peerName = browser.resolvedName(for: id) ?? "no name"
            let selected = session.preferredHost
            let link = selected.map { browser.isConnected($0) ? "connected" : "not connected" } ?? "none"
            record("Refusing \(peerTag(id)) (\(peerName)); selected \(peerTag(selected)) (\(selected.map { hostName(for: $0) } ?? "none")), our link to it \(link)")
        }
        if first || repeating { record("Rejected \(action): \(peerTag(id))") }
    }

    /// Every session carries the saved computers, so an open pairing window
    /// can tell a genuinely new host from one that is merely reconnecting.
    private func makeSession(preferredHost: UUID?, allowsPairing: Bool) -> HIDHostSession {
        var session = HIDHostSession(preferredHost: preferredHost, allowsPairing: allowsPairing)
        session.knownHosts = Set(hostStore.hosts.map(\.id))
        return session
    }

    private func peerTag(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(8)) } ?? "none"
    }

    private func record(_ event: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        diagnostics.append("\(time) \(event)")
        if diagnostics.count > 60 { diagnostics.removeFirst(diagnostics.count - 60) }
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
                    ? "HID готовий · \(hostName(for: id)) · комп’ютер спить"
                    : "HID готовий · \(hostName(for: id))"
            }
        } else if let lastError {
            statusText = lastError
        } else if stackRecoveryWork != nil {
            if let id = session.preferredHost {
                statusText = "Відновлюємо зв’язок з \(hostName(for: id))…"
            } else {
                statusText = "Відновлюємо зв’язок…"
            }
        } else if afterDrain != nil {
            statusText = "Відпускання клавіш…"
        } else if !servicesInstalled {
            statusText = "Готуємо Bluetooth…"
        } else if let id = session.host ?? browser.requestedHost ?? session.preferredHost {
            statusText = connectingStatus(for: id)
        } else if isPairing {
            statusText = "Готові до сполучення · знайди «\(advertisedName)» на комп’ютері"
        } else {
            statusText = "Вибери комп’ютер або відкрий сполучення"
        }
        if !ready { lastReadyHostID = nil }
        isReady = ready
        if updateAdvertisement { advertise() }
        updateWatchdog()
    }

    private func clearInput() {
        sendWork?.cancel()
        sendWork = nil
        loggedOversizedReport = false
        queue.removeAll()
        afterInputQueueDrains = nil
        state = HIDInputState()
        lastKeyboard = state.keyboard.data
        lastMouse = state.mouse().data
    }

    func releaseAllInput() {
        // Releasing into a suspended host would wake it for nothing — putting
        // the app in the background must not light up a sleeping computer.
        // Only deliberate input earns a wake.
        guard !session.suspended else {
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
            // Resume only from peripheralManagerIsReady(toUpdateSubscribers:).
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
        guard let manager, manager.state == .poweredOn, let host else { return true }
        let channel = report.kind == .keyboard ? session.keyboardChannel : session.mouseChannel
        guard session.subscriptions.contains(channel), let characteristic = inputs[channel] else { return true }
        let data = channel == .bootMouse ? Data(report.data.prefix(3)) : report.data
        guard data.count <= host.maximumUpdateValueLength else {
            // Reporting backpressure here would wait for a readiness callback
            // that cannot arrive, because nothing was handed to CoreBluetooth.
            // Every later keystroke would then queue behind this one report.
            if !loggedOversizedReport {
                loggedOversizedReport = true
                record("Dropped a \(data.count) B report; host accepts \(host.maximumUpdateValueLength) B")
            }
            return true
        }
        guard manager.updateValue(data, for: characteristic, onSubscribedCentrals: [host]) else { return false }
        if report.kind == .keyboard {
            lastKeyboard = report.data
        } else {
            // Relative motion must not be replayed by a subsequent ATT read.
            lastMouse = Data([report.data[0], 0, 0, 0, 0])
        }
        return true
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
        // Reject oversized text before allocating a report for every character.
        guard taps.count <= queue.capacity / 3 else {
            lastError = "Текст завеликий. Надішли меншими частинами."
            return
        }
        enqueue(taps.flatMap { state.tap($0.keycode, modifiers: $0.modifiers) })
    }

    /// Sends a text batch and calls `completion` after all reports have been
    /// accepted by CoreBluetooth. This is useful to short-lived clients such as
    /// a Share extension, which must not terminate while reports remain queued.
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
            // A selected computer can drop its link before subscribing to any
            // report. That produces no unsubscribe callback, so without this
            // the transport waits forever for a host that is already gone.
            // Recovery is left to the watchdog ladder, which refreshStatus
            // arms: restarting the stack on every failed attempt of a host
            // that keeps retrying would only interrupt its next attempt.
            if session.preferredHost == id, cause != .appCancelledOutgoingLink, isRunning {
                record("Selected host link lost before HID subscriptions: \(peerTag(id)); cause \(cause.rawValue)")
                refreshStatus()
            }
            return
        }
        // Cancelling our central-role connection does not necessarily close
        // the host's HID connection to our peripheral role. Every external
        // loss is authoritative even if subscribedCentrals is briefly stale.
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
        scheduleStackRecovery(reason: "Peer disconnected: \(cause.rawValue)", force: true)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager, isRunning else { return }
        record("Peripheral state: \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn {
            advertising = HIDAdvertisingState(isAdvertising: peripheral.isAdvertising)
            lastError = nil
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
        } else {
            if lastError == advertisingError { lastError = nil }
            advertisingError = nil
            record("Advertising HID")
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
        // A baseline report lets the host finish initializing the input device.
        _ = queue.append([state.keyboard, state.mouse()])
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
        if !session.isReady {
            scheduleStackRecovery(reason: "HID report subscription ended", force: false)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        scheduleSend()
    }

    // Reads are answered for any bonded computer, not only the selected one.
    // Refusing them with an ATT security error told macOS its bond was
    // inadequate, and it responded by asking to pair again on every reconnect.
    // Reads carry no input anyway: the pinning that matters is that only the
    // selected host is ever notified, which `transmit` enforces.
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard isRunning else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        if !session.allows(request.central.identifier) {
            noteRejectedPeer(request.central.identifier, action: "read (answered, not routed)", repeating: false)
        }
        guard let attribute = attributes[ObjectIdentifier(request.characteristic)] else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        let value: Data
        switch attribute {
        case .input(.keyboard), .input(.bootKeyboard): value = lastKeyboard
        case .input(.mouse): value = lastMouse
        case .input(.bootMouse): value = Data(lastMouse.prefix(3))
        case .leds: value = Data([leds])
        case .protocolMode: value = Data([session.bootProtocol ? 0 : 1])
        case .controlPoint:
            peripheral.respond(to: request, withResult: .readNotPermitted)
            return
        case .reportMap:
            value = RemoteHIDDescriptor.reportMap
            // Reads never reach refreshStatus, so this rung has to be rearmed
            // here. Rewinding alone leaves a host that reads the descriptor and
            // then goes quiet — a Mac discovering without attaching HID — with
            // no pending recovery at all.
            cancelWatchdog(rewind: true)
            updateWatchdog()
            record("Report map read: \(peerTag(request.central.identifier)), offset \(request.offset)")
        case .information: value = RemoteHIDDescriptor.information
        case .battery: value = Data([UInt8(max(0, min(100, Int(UIDevice.current.batteryLevel * 100))))])
        case .manufacturer: value = Data("ESP Remote Control".utf8)
        case .model: value = Data("Direct HID v2".utf8)
        // Prototype identity, not a claim to another manufacturer's USB VID.
        case .pnpID: value = Data([1, 0xFF, 0xFF, 1, 0, 0, 2])
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = Data(value.dropFirst(request.offset))
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // Validate the whole transaction before changing any state.
        guard isRunning else {
            peripheral.respond(to: first, withResult: .unlikelyError); return
        }
        // Another computer's writes are accepted and discarded rather than
        // refused, for the same reason as reads: a security error provokes a
        // fresh pairing attempt. Only the selected host changes our state.
        let routed = session.allows(first.central.identifier)
        for request in requests {
            guard request.offset == 0 else {
                peripheral.respond(to: first, withResult: .invalidOffset); return
            }
            guard let value = request.value, value.count == 1 else {
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength); return
            }
            switch attributes[ObjectIdentifier(request.characteristic)] {
            case .leds: break
            case .protocolMode, .controlPoint:
                guard value[0] <= 1 else {
                    peripheral.respond(to: first, withResult: .requestNotSupported); return
                }
            default: peripheral.respond(to: first, withResult: .writeNotPermitted); return
            }
        }
        guard routed else {
            noteRejectedPeer(first.central.identifier, action: "write (answered, not applied)", repeating: false)
            peripheral.respond(to: first, withResult: .success)
            return
        }
        for request in requests {
            let value = request.value![0]
            switch attributes[ObjectIdentifier(request.characteristic)] {
            case .leds: leds = value & 0x1F
            case .protocolMode:
                session.bootProtocol = value == 0
                record("Protocol: \(value == 0 ? "boot" : "report")")
                releaseAllInput()
            case .controlPoint:
                session.suspended = value == 0
                record(value == 0
                    ? "Host entered suspend; input will wake it"
                    : "Host exited suspend")
                // Drop held keys without transmitting: sending here would wake
                // the host the moment it went to sleep.
                clearInput()
            default: break
            }
        }
        peripheral.respond(to: first, withResult: .success)
        refreshStatus()
    }

}
