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
    private static func shortUUID(_ uuid: CBUUID) -> String {
        let string = uuid.uuidString.uppercased()
        if string.count == 4 { return string }
        if string.hasPrefix("0000"), string.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(string.dropFirst(4).prefix(4))
        }
        return string
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
        browser.onPeerDisconnected = { [weak self] id in self?.disconnected(id) }
        browser.onLinkConnected = { [weak self] id in
            guard let self, self.isRunning else { return }
            self.record("Outgoing BLE link connected: \(id.uuidString.prefix(8))")
            self.refreshStatus()
        }
    }

    var diagnosticText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let selected = selectedHostID.map { String($0.uuidString.prefix(8)) } ?? "none"
        let connected = connectedHostID.map { String($0.uuidString.prefix(8)) } ?? "none"
        return "ESP Remote \(version) · iOS \(UIDevice.current.systemVersion)\n\(statusText)\nSelected: \(selected); HID ready: \(connected)\n" + diagnostics.joined(separator: "\n")
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        let preferred = hostStore.selectedHostID
        session = HIDHostSession(preferredHost: preferred, allowsPairing: hostStore.shouldPairOnStart)
        isPairing = hostStore.shouldPairOnStart
        selectedHostID = preferred
        browser.setKnownHosts(hostStore.hosts)
        record("Starting HID; selected \(peerTag(preferred)); pairing \(isPairing)")
        statusText = "Запуск прямого Bluetooth…"
        // Register system connection events before exposing HID services.
        browser.start()
    }

    private func startPeripheral() {
        guard isRunning, manager == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        manager = CBPeripheralManager(delegate: self, queue: .main, options: [
            CBPeripheralManagerOptionRestoreIdentifierKey: "com.keefeere.ESPRemoteControl.hidPeripheral",
            CBPeripheralManagerOptionShowPowerAlertKey: true
        ])
    }

    func stop(completion: @escaping () -> Void) {
        drainReleases { [weak self] in
            guard let self else { completion(); return }
            self.isRunning = false
            self.canPair = false
            self.isPairing = false
            self.pairingTimer?.cancel()
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
            drainReleases { [weak self] in
                guard let self else { return }
                self.browser.cancelConnection()
                self.pairingTimer?.cancel()
                self.host = nil
                self.session = HIDHostSession(preferredHost: nil, allowsPairing: false)
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
        guard !(session.host == id && session.isReady) else { return }
        prepareHost(id)
    }

    private func prepareHost(_ id: UUID?) {
        guard canPair, afterDrain == nil else { return }
        drainReleases { [weak self] in
            guard let self, self.isRunning else { return }
            self.lastError = nil
            self.browser.cancelConnection()
            self.host = nil
            self.session = HIDHostSession(preferredHost: id, allowsPairing: true)
            self.isPairing = true
            self.record(id == nil ? "Pairing window opened" : "Host selected: \(self.peerTag(id))")
            self.armPairingTimeout()
            if let id {
                self.hostStore.select(id, name: self.browser.resolvedName(for: id), supportsOutgoing: false)
                self.savedHosts = self.hostStore.hosts
                self.browser.setKnownHosts(self.savedHosts)
                self.restoreSubscriptions()
                if !self.session.isReady { self.browser.connect(to: id) }
            }
            self.refreshStatus()
        }
    }

    func reconnectNow() {
        guard isRunning, afterDrain == nil else { return }
        if !servicesInstalled, manager?.state == .poweredOn {
            lastError = nil
            installServices()
            return
        }
        let preferred = session.preferredHost
        drainReleases { [weak self] in
            guard let self else { return }
            self.lastError = nil
            self.host = nil
            self.session = HIDHostSession(preferredHost: preferred, allowsPairing: self.isPairing)
            self.browser.setKnownHosts(self.hostStore.hosts)
            self.restoreSubscriptions()
            if !self.session.isReady { self.browser.reconnectRememberedHost(ifMatching: preferred) }
            self.refreshStatus()
        }
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
                    self.session = HIDHostSession(preferredHost: self.hostStore.selectedHostID, allowsPairing: false)
                    self.restoreSubscriptions()
                    self.refreshStatus()
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
            browser.reconnectRememberedHost(ifMatching: session.preferredHost)
            return
        }
        addingService = serviceQueue.removeFirst()
        manager?.add(addingService!)
    }

    private func advertise() {
        let wanted = isRunning && servicesInstalled && manager?.state == .poweredOn
            && !session.isReady && afterDrain == nil && (isPairing || session.preferredHost != nil)
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
                statusText = "Підключено · \(hostName(for: id))"
            }
        } else if let lastError {
            statusText = lastError
        } else if afterDrain != nil {
            statusText = "Відпускання клавіш…"
        } else if !servicesInstalled {
            statusText = "Підготовка Bluetooth…"
        } else if session.suspended {
            statusText = "Комп’ютер призупинив ввід"
        } else if let id = session.host ?? browser.requestedHost {
            statusText = "Очікуємо клавіатуру й мишу · \(hostName(for: id))"
        } else if let id = session.preferredHost {
            statusText = "Очікуємо · \(hostName(for: id))"
        } else if isPairing {
            statusText = "Готовий до сполучення · \(advertisedName)"
        } else {
            statusText = "Вибери комп’ютер або відкрий сполучення"
        }
        if !ready { lastReadyHostID = nil }
        isReady = ready
        if updateAdvertisement { advertise() }
    }

    private func clearInput() {
        sendWork?.cancel()
        sendWork = nil
        queue.removeAll()
        afterInputQueueDrains = nil
        state = HIDInputState()
        lastKeyboard = state.keyboard.data
        lastMouse = state.mouse().data
    }

    func releaseAllInput() {
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
        guard data.count <= host.maximumUpdateValueLength else { return false }
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

    private func disconnected(_ id: UUID) {
        guard session.host == id else { return }
        // Cancelling our central-role connection does not necessarily close
        // the host's HID connection to our peripheral role.
        let stillSubscribed = inputs.contains { channel, characteristic in
            session.subscriptions.contains(channel)
                && (characteristic.subscribedCentrals ?? []).contains { $0.identifier == id }
        }
        if stillSubscribed {
            record("BLE link ended; HID subscriptions remain: \(peerTag(id))")
            return
        }
        record("HID disconnected: \(peerTag(id))")
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
            if servicesInstalled {
                canPair = true
                restoreSubscriptions()
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
            record("Ignored subscription: \(peerTag(central.identifier)), \(channel); selected \(peerTag(session.preferredHost))")
            return
        }
        host = central
        record("Subscribed: \(channel), host \(peerTag(central.identifier))")
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
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        scheduleSend()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard isRunning, session.allows(request.central.identifier) else {
            record("Read rejected: \(peerTag(request.central.identifier)); selected \(peerTag(session.preferredHost))")
            peripheral.respond(to: request, withResult: .insufficientAuthorization)
            return
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
            record("Report map read: \(peerTag(request.central.identifier)), offset \(request.offset)")
        case .information: value = Data([0x11, 0x01, 0, 0x02])
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
        for request in requests {
            guard isRunning, session.allows(request.central.identifier) else {
                peripheral.respond(to: first, withResult: .insufficientAuthorization); return
            }
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
                record(value == 0 ? "Host suspended input" : "Host resumed input")
                releaseAllInput()
            default: break
            }
        }
        peripheral.respond(to: first, withResult: .success)
        refreshStatus()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        guard let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] else { return }
        attributes.removeAll()
        inputs.removeAll()
        for service in services {
            for item in service.characteristics ?? [] {
                guard let item = item as? CBMutableCharacteristic else { continue }
                let attribute: Attribute?
                switch Self.shortUUID(item.uuid) {
                case "2A4A": attribute = .information
                case "2A4B": attribute = .reportMap
                case "2A4C": attribute = .controlPoint
                case "2A4E": attribute = .protocolMode
                case "2A22": attribute = .input(.bootKeyboard)
                case "2A33": attribute = .input(.bootMouse)
                case "2A32": attribute = .leds
                case "2A19": attribute = .battery
                case "2A29": attribute = .manufacturer
                case "2A24": attribute = .model
                case "2A50": attribute = .pnpID
                case "2A4D":
                    let descriptor = item.descriptors?.first { Self.shortUUID($0.uuid) == "2908" }
                    if let bytes = descriptor?.value as? Data, bytes.count == 2 {
                        if bytes[0] == 1, bytes[1] == 1 { attribute = .input(.keyboard) }
                        else if bytes[0] == 2, bytes[1] == 1 { attribute = .input(.mouse) }
                        else if bytes[0] == 1, bytes[1] == 2 { attribute = .leds }
                        else { attribute = nil }
                    } else { attribute = nil }
                default: attribute = nil
                }
                if let attribute {
                    attributes[ObjectIdentifier(item)] = attribute
                    if case .input(let channel) = attribute { inputs[channel] = item }
                }
            }
        }
        servicesInstalled = inputs.count == 4 && attributes.count == 14
        record(servicesInstalled ? "Restored GATT services" : "GATT restore incomplete; will rebuild")
    }

    private func restoreSubscriptions() {
        for (channel, characteristic) in inputs {
            for central in characteristic.subscribedCentrals ?? [] {
                if session.subscribe(channel, from: central.identifier) { host = central }
            }
        }
        releaseAllInput()
        refreshStatus()
    }
}
