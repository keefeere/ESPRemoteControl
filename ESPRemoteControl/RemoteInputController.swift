import Combine
import Foundation

enum RemoteInputMode: String, CaseIterable, Identifiable {
    case esp
    case bluetooth
    var id: String { rawValue }
    var title: String { self == .esp ? "ESP-адаптер" : "Прямий Bluetooth" }
}

/// Owns exactly one active input route. Switching waits for release reports
/// before the next route can receive input.
final class RemoteInputController: ObservableObject {
    @Published private(set) var mode: RemoteInputMode
    @Published private(set) var isReady = false
    @Published private(set) var isSwitching = false
    @Published private(set) var statusText = "Підключення…"
    @Published private(set) var inputEpoch = 0
    let direct = DirectHIDTransport()
    private let esp = BLEKeyboardBridge()
    private var subscriptions: Set<AnyCancellable> = []
    private let modeKey = "inputTransportMode"
    private var backgroundedAt: Date?

    init() {
        // Keep the established ESP default during the direct-Bluetooth trial.
        mode = RemoteInputMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .esp
        esp.$isReady.combineLatest(esp.$statusText).sink { [weak self] ready, text in
            self?.publish(ready: ready, text: text, from: .esp)
        }.store(in: &subscriptions)
        direct.$isReady.combineLatest(direct.$statusText).sink { [weak self] ready, text in
            self?.publish(ready: ready, text: text, from: .bluetooth)
        }.store(in: &subscriptions)
    }

    private var active: any InputTransport {
        if mode == .esp { return esp }
        return direct
    }

    private func publish(ready: Bool, text: String, from source: RemoteInputMode) {
        guard source == mode, !isSwitching else { return }
        if isReady, !ready { inputEpoch += 1 }
        statusText = text
        isReady = ready
    }

    func start() {
        guard !isSwitching else { return }
        active.start()
    }

    func selectMode(_ next: RemoteInputMode) {
        guard next != mode, !isSwitching else { return }
        isSwitching = true
        isReady = false
        inputEpoch += 1
        statusText = "Перемикання підключення…"
        active.stop { [weak self] in
            guard let self else { return }
            self.mode = next
            UserDefaults.standard.set(next.rawValue, forKey: self.modeKey)
            self.isSwitching = false
            self.start()
        }
    }

    func reconnectNow() {
        guard !isSwitching else { return }
        inputEpoch += 1
        if mode == .esp { esp.reconnectNow() } else { direct.reconnectNow() }
    }

    func releaseAllInput() {
        guard !isSwitching else { return }
        inputEpoch += 1
        active.releaseAllInput()
    }

    func enteredBackground() {
        backgroundedAt = Date()
        direct.browser.stopScan()
        releaseAllInput()
    }

    func becameActive() {
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil
        guard mode == .bluetooth else { return }
        if Date().timeIntervalSince(backgroundedAt) >= 3 {
            inputEpoch += 1
            direct.recoverAfterForeground()
        }
    }

    func setModifiers(_ mask: UInt8) {
        guard isReady else { return }
        active.setModifiers(mask)
    }
    func sendKeyDown(modifiersMask: UInt8, keycode: UInt8) {
        guard isReady else { return }
        active.sendKeyDown(modifiersMask: modifiersMask, keycode: keycode)
    }
    func sendKeyUp(keycode: UInt8) {
        guard isReady else { return }
        active.sendKeyUp(keycode: keycode)
    }
    func sendKeyTap(modifiers: UInt8, hidKeycode: UInt8) {
        guard isReady else { return }
        active.sendKeyTap(modifiers: modifiers, hidKeycode: hidKeycode)
    }
    func sendKeyTaps(_ taps: [(modifiers: UInt8, keycode: UInt8)]) {
        guard isReady else { return }
        active.sendKeyTaps(taps)
    }
    func sendMouseMove(dx: Int8, dy: Int8) {
        guard isReady else { return }
        active.sendMouseMove(dx: dx, dy: dy)
    }
    func sendMouseScroll(dx: Int8, dy: Int8) {
        guard isReady else { return }
        active.sendMouseScroll(dx: dx, dy: dy)
    }
    func sendMouseClick(button: UInt8) {
        guard isReady else { return }
        active.sendMouseClick(button: button)
    }
    func sendMouseButtonDown(button: UInt8) {
        guard isReady else { return }
        active.sendMouseButtonDown(button: button)
    }
    func sendMouseButtonUp(button: UInt8) {
        guard isReady else { return }
        active.sendMouseButtonUp(button: button)
    }
}
