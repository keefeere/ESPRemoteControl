import Foundation

/// HID report payloads exclude the Report ID in HOGP; the 0x2908 descriptor
/// identifies each characteristic. These bytes also match the boot keyboard.
enum HIDReportKind: UInt8 {
    case keyboard = 1
    case mouse = 2
    case consumer = 3
    case systemMicrophoneMute = 4
}

enum HIDConsumerUsage {
    static let power: UInt16 = 0x0030
    static let sleep: UInt16 = 0x0032
    static let brightnessIncrement: UInt16 = 0x006F
    static let brightnessDecrement: UInt16 = 0x0070
    static let fastForward: UInt16 = 0x00B3
    static let rewind: UInt16 = 0x00B4
    static let nextTrack: UInt16 = 0x00B5
    static let previousTrack: UInt16 = 0x00B6
    static let randomPlay: UInt16 = 0x00B9
    static let repeatTrack: UInt16 = 0x00BC
    static let playPause: UInt16 = 0x00CD
    static let mute: UInt16 = 0x00E2
    static let volumeIncrement: UInt16 = 0x00E9
    static let volumeDecrement: UInt16 = 0x00EA
}

struct HIDInputReport: Equatable {
    let kind: HIDReportKind
    let data: Data
    // Local metadata only; it is never included in the Bluetooth payload.
    var isWakeProbe = false
}

struct HIDInputState {
    private(set) var modifiers: UInt8 = 0
    private(set) var keys: [UInt8] = []
    private(set) var buttons: UInt8 = 0
    private(set) var consumerUsage: UInt16 = 0
    private(set) var systemMicrophoneMutePressed = false

    /// A deliberate wake attempt sends a Shift press and release, without
    /// typing a character or activating a button on the sleeping computer.
    static var wakeProbe: [HIDInputReport] {
        HIDInputState().tap(0, modifiers: 0x02).map { report in
            var tagged = report
            tagged.isWakeProbe = true
            return tagged
        }
    }

    var keyboard: HIDInputReport {
        let usages = keys.count > 6 ? [UInt8](repeating: 1, count: 6)
            : keys + [UInt8](repeating: 0, count: 6 - keys.count)
        return HIDInputReport(kind: .keyboard, data: Data([modifiers, 0] + usages))
    }

    var consumer: HIDInputReport {
        HIDInputReport(
            kind: .consumer,
            data: Data([UInt8(consumerUsage & 0xFF), UInt8((consumerUsage >> 8) & 0xFF)])
        )
    }

    var systemMicrophoneMute: HIDInputReport {
        HIDInputReport(
            kind: .systemMicrophoneMute,
            data: Data([systemMicrophoneMutePressed ? 1 : 0])
        )
    }

    func mouse(dx: Int8 = 0, dy: Int8 = 0, wheel: Int8 = 0, pan: Int8 = 0) -> HIDInputReport {
        // Report map describes -127...127, not the full Int8 range.
        let movement = [dx, dy, wheel, pan].map { UInt8(bitPattern: max(-127, $0)) }
        return HIDInputReport(kind: .mouse, data: Data([buttons] + movement))
    }

    mutating func setModifiers(_ value: UInt8) -> HIDInputReport {
        modifiers = value
        return keyboard
    }

    mutating func keyDown(_ key: UInt8, modifiers value: UInt8) -> HIDInputReport {
        modifiers = value
        if key >= 4, key <= 0xDD, !keys.contains(key) { keys.append(key) }
        return keyboard
    }

    mutating func keyUp(_ key: UInt8) -> HIDInputReport {
        keys.removeAll { $0 == key }
        return keyboard
    }

    /// A tap temporarily changes the report, then restores held keys/modifiers.
    func tap(_ key: UInt8, modifiers value: UInt8) -> [HIDInputReport] {
        var temporary = self
        var reports: [HIDInputReport] = []
        if key != 0, keys.contains(key) { reports.append(temporary.keyUp(key)) }
        reports.append(temporary.keyDown(key, modifiers: value))
        reports.append(keyboard)
        return reports
    }

    mutating func consumerDown(_ usage: UInt16) -> HIDInputReport {
        consumerUsage = usage
        return consumer
    }

    mutating func consumerUp() -> HIDInputReport {
        consumerUsage = 0
        return consumer
    }

    mutating func systemMicrophoneMuteDown() -> HIDInputReport {
        systemMicrophoneMutePressed = true
        return systemMicrophoneMute
    }

    mutating func systemMicrophoneMuteUp() -> HIDInputReport {
        systemMicrophoneMutePressed = false
        return systemMicrophoneMute
    }

    mutating func buttonDown(_ mask: UInt8) -> HIDInputReport {
        buttons |= mask & 7
        return mouse()
    }

    mutating func buttonUp(_ mask: UInt8) -> HIDInputReport {
        buttons &= ~(mask & 7)
        return mouse()
    }

    func click(_ mask: UInt8) -> [HIDInputReport] {
        var temporary = self
        return [temporary.buttonDown(mask), mouse()]
    }

    mutating func releaseAll() -> [HIDInputReport] {
        self = HIDInputState()
        return [keyboard, mouse(), consumer, systemMicrophoneMute]
    }
}

/// A bounded FIFO. A rejected notification remains at the head until the
/// Bluetooth delegate reports available capacity. Transitions are never merged.
struct HIDReportQueue {
    enum SendResult { case empty, blocked, sent }
    private var storage: [HIDInputReport] = []
    private var head = 0
    let capacity: Int
    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    init(capacity: Int = 32_768) { self.capacity = capacity }

    mutating func append(_ reports: [HIDInputReport]) -> Bool {
        guard reports.count <= capacity - count else { return false }
        storage.append(contentsOf: reports)
        return true
    }

    mutating func sendNext(_ send: (HIDInputReport) -> Bool) -> SendResult {
        guard !isEmpty else { return .empty }
        guard send(storage[head]) else { return .blocked }
        head += 1
        if head == storage.count {
            removeAll()
        } else if head >= 256, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return .sent
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
    }
}

enum HIDInputChannel: Hashable {
    case keyboard, mouse, consumer, systemMicrophoneMute, bootKeyboard, bootMouse
}

/// Why the auxiliary central-role link to a computer ended. Cancelling that
/// link ourselves must not tear down a still-subscribed HID peripheral session;
/// every external loss invalidates it even if CoreBluetooth has not yet removed
/// stale entries from `subscribedCentrals`.
enum HIDPeerDisconnectCause: String {
    case appCancelledOutgoingLink
    case connectionFailed
    case linkLost
    case bluetoothUnavailable
}

enum HIDDisconnectPolicy {
    static func invalidatesSession(
        cause: HIDPeerDisconnectCause,
        reportsStillSubscribed: Bool
    ) -> Bool {
        switch cause {
        case .appCancelledOutgoingLink, .connectionFailed:
            return !reportsStillSubscribed
        case .linkLost, .bluetoothUnavailable:
            return true
        }
    }
}

/// Bounded recovery without destroying the shared GATT database. An absent
/// selected host must not tear down another computer's HID or wake connection.
struct HIDReconnectWatchdog {
    enum Step: Equatable {
        /// Reissue the advertisement. A failed or stalled start otherwise
        /// leaves the phone invisible, and an invisible phone is unreachable.
        case restartAdvertising
        /// Rearm ended outgoing requests and record the current HID state.
        /// Pending/connected requests and the published services stay intact.
        case retryLinks
    }

    /// Wait before each attempt. After these attempts, keep advertising and
    /// holding pending links; an offline host does not justify a stack reset.
    static let schedule: [TimeInterval] = [5, 30]

    private(set) var attempt = 0
    var isExhausted: Bool { attempt >= Self.schedule.count }

    mutating func reset() { attempt = 0 }

    /// The next escalation, or nil once the ladder is exhausted. An open
    /// pairing window with no selected host has nothing to reconnect to, so it
    /// only repairs visibility.
    mutating func next(pairingOnly: Bool) -> (step: Step, delay: TimeInterval)? {
        guard !isExhausted else { return nil }
        let delay = Self.schedule[attempt]
        let step: Step
        switch attempt {
        case 0: step = .restartAdvertising
        default: step = .retryLinks
        }
        attempt += 1
        return (pairingOnly ? .restartAdvertising : step, delay)
    }
}

/// Only one selected host receives input, regardless of how many BLE peers
/// connect. GAP connection events alone never make an HID session ready.
struct HIDHostSession {
    var preferredHost: UUID?
    var allowsPairing: Bool
    /// Computers already in the app's list. A pairing window exists to add a
    /// new one; a bonded host reconnects in about a second, so letting saved
    /// hosts claim the window makes it unusable for its only purpose.
    var knownHosts: Set<UUID> = []
    private(set) var host: UUID?
    private(set) var subscriptions: Set<HIDInputChannel> = []
    var bootProtocol = false
    /// The host told us it is entering suspend. It does not stop input: a
    /// device that declares RemoteWake wakes its host precisely by sending a
    /// report, and the host answers with Exit Suspend once it is awake.
    /// Refusing to send here is a deadlock — the host cannot ask to be woken.
    var suspended = false

    var keyboardChannel: HIDInputChannel { bootProtocol ? .bootKeyboard : .keyboard }
    var mouseChannel: HIDInputChannel { bootProtocol ? .bootMouse : .mouse }
    var isReady: Bool {
        host != nil && subscriptions.contains(keyboardChannel)
            && subscriptions.contains(mouseChannel)
    }

    func allows(_ id: UUID) -> Bool {
        if let host { return host == id }
        if let preferredHost { return preferredHost == id }
        // A saved computer is chosen from the list, which pins it directly;
        // it must not win the pairing window away from the new one.
        return allowsPairing && !knownHosts.contains(id)
    }

    mutating func subscribe(_ channel: HIDInputChannel, from id: UUID) -> Bool {
        guard allows(id) else { return false }
        host = id
        preferredHost = id
        subscriptions.insert(channel)
        return true
    }

    mutating func unsubscribe(_ channel: HIDInputChannel, from id: UUID) {
        guard host == id else { return }
        subscriptions.remove(channel)
        if subscriptions.isEmpty { disconnect(id) }
    }

    mutating func disconnect(_ id: UUID) {
        guard host == id else { return }
        host = nil
        subscriptions.removeAll()
        bootProtocol = false
        suspended = false
    }
}

/// USB HID 1.11 / HID Usage Tables: 6-key keyboard with LED output (ID 1),
/// relative three-button mouse with vertical wheel and Consumer AC Pan (ID 2),
/// a 16-bit Consumer Control usage selector (ID 3), and HUTRR110 System
/// Microphone Mute with matching LED output (ID 4).
enum RemoteHIDDescriptor {
    /// HID Information: bcdHID 1.11, no country code, then the flags byte.
    /// Bit 0 is RemoteWake and bit 1 is NormallyConnectable. Without
    /// RemoteWake the host is told this device cannot wake it from sleep,
    /// which is what a real Bluetooth keyboard or mouse declares that it can.
    static let information = Data([0x11, 0x01, 0, 0x03])

    static let reportMap = Data([
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x75, 0x08, 0x95, 0x01, 0x81, 0x01,
        0x19, 0x00, 0x29, 0xDD, 0x15, 0x00, 0x26, 0xDD, 0x00,
        0x75, 0x08, 0x95, 0x06, 0x81, 0x00,
        0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x05, 0x91, 0x02,
        0x75, 0x03, 0x95, 0x01, 0x91, 0x01, 0xC0,
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02,
        0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x03, 0x81, 0x02,
        0x75, 0x05, 0x95, 0x01, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
        0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
        0x05, 0x0C, 0x0A, 0x38, 0x02,
        0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0xC0, 0xC0,
        0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x03,
        0x15, 0x00, 0x26, 0xFF, 0x03,
        0x19, 0x00, 0x2A, 0xFF, 0x03,
        0x75, 0x10, 0x95, 0x01, 0x81, 0x00, 0xC0,
        // HUTRR110 System Microphone Mute / LED, Report ID 4.
        0x05, 0x01, 0x09, 0x80, 0xA1, 0x01, 0x85, 0x04,
        0x09, 0xA9, 0x15, 0x00, 0x25, 0x01,
        0x95, 0x01, 0x75, 0x01, 0x81, 0x06,
        0x75, 0x07, 0x81, 0x03,
        0x05, 0x08, 0x09, 0x57,
        0x75, 0x01, 0x91, 0x06,
        0x75, 0x07, 0x91, 0x03, 0xC0
    ])
}
