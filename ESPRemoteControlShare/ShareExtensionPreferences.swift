import Foundation

enum ShareExtensionPreferences {
    private static let targetLayoutKey = "shareTargetKeyboardLayout"
    private static let layoutShortcutKey = "shareHostLayoutShortcut"
    private static let lastPeripheralKey = "shareLastBridgePeripheralIdentifier"

    static var targetLayout: KeyboardLayout {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: targetLayoutKey) else {
                return .englishUS
            }
            return KeyboardLayout(rawValue: rawValue) ?? .englishUS
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: targetLayoutKey)
        }
    }

    static var layoutShortcut: HostLayoutShortcut {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: layoutShortcutKey) else {
                return .controlSpace
            }
            return HostLayoutShortcut(rawValue: rawValue) ?? .controlSpace
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: layoutShortcutKey)
        }
    }

    static var lastPeripheralIdentifier: UUID? {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: lastPeripheralKey) else {
                return nil
            }
            return UUID(uuidString: rawValue)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: lastPeripheralKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastPeripheralKey)
            }
        }
    }
}
