import Foundation

enum ShareBridgeState {
    private static let originalAppGroupIdentifier = "group.com.keefeere.ESPRemoteControl"

    static var appGroupIdentifier: String {
        let resignedGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
        return resignedGroups?.first(where: { $0.contains("ESPRemoteControl") })
            ?? originalAppGroupIdentifier
    }

    private static let pendingTextKey = "pendingSharedText"
    private static let targetLayoutKey = "targetKeyboardLayout"
    private static let layoutShortcutKey = "hostLayoutShortcut"
    private static let lastPeripheralKey = "lastBridgePeripheralIdentifier"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static var isSharedContainerAvailable: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) != nil
    }

    static var storedTargetLayout: KeyboardLayout? {
        guard isSharedContainerAvailable,
              let rawValue = defaults?.string(forKey: targetLayoutKey) else {
            return nil
        }
        return KeyboardLayout(rawValue: rawValue)
    }

    static var targetLayout: KeyboardLayout {
        get {
            storedTargetLayout ?? .englishUS
        }
        set {
            defaults?.set(newValue.rawValue, forKey: targetLayoutKey)
        }
    }

    static var storedLayoutShortcut: HostLayoutShortcut? {
        guard isSharedContainerAvailable,
              let rawValue = defaults?.string(forKey: layoutShortcutKey) else {
            return nil
        }
        return HostLayoutShortcut(rawValue: rawValue)
    }

    static var layoutShortcut: HostLayoutShortcut {
        get {
            storedLayoutShortcut ?? .controlSpace
        }
        set {
            defaults?.set(newValue.rawValue, forKey: layoutShortcutKey)
        }
    }

    static var lastPeripheralIdentifier: UUID? {
        get {
            guard let value = defaults?.string(forKey: lastPeripheralKey) else {
                return nil
            }
            return UUID(uuidString: value)
        }
        set {
            defaults?.set(newValue?.uuidString, forKey: lastPeripheralKey)
        }
    }

    @discardableResult
    static func enqueue(_ text: String) -> Bool {
        guard isSharedContainerAvailable, !text.isEmpty else { return false }
        var values = defaults?.stringArray(forKey: pendingTextKey) ?? []
        if !values.contains(text) {
            values.append(text)
        }
        defaults?.set(values, forKey: pendingTextKey)
        return defaults?.synchronize() ?? false
    }

    static func removeQueuedText(_ text: String) {
        guard isSharedContainerAvailable else { return }
        var values = defaults?.stringArray(forKey: pendingTextKey) ?? []
        values.removeAll(where: { $0 == text })
        if values.isEmpty {
            defaults?.removeObject(forKey: pendingTextKey)
        } else {
            defaults?.set(values, forKey: pendingTextKey)
        }
    }

    static var pendingText: String? {
        guard isSharedContainerAvailable else { return nil }

        let values = defaults?.stringArray(forKey: pendingTextKey)
            ?? defaults?.string(forKey: pendingTextKey).map { [$0] }
            ?? []
        guard !values.isEmpty else { return nil }
        return values.joined(separator: "\n")
    }

    static func clearPendingText() {
        defaults?.removeObject(forKey: pendingTextKey)
    }
}
