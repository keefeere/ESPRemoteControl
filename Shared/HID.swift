import Foundation

struct HIDCommand: Equatable {
    let modifiers: UInt8
    let keycode: UInt8
}

enum KeyboardLayout: String, CaseIterable, Identifiable {
    case englishUS
    case ukrainianEnhanced

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .englishUS: "EN"
        case .ukrainianEnhanced: "UA"
        }
    }

    var displayName: String {
        switch self {
        case .englishUS: "English (US)"
        case .ukrainianEnhanced: "Українська"
        }
    }

    var letterRows: [[Character]] {
        switch self {
        case .englishUS:
            [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        case .ukrainianEnhanced:
            [Array("йцукенгшщзхї"), Array("фівапролджє"), Array("ячсмитьбю")]
        }
    }

    /// Infers only from letters. Digits, whitespace and punctuation keep the
    /// current layout because they do not identify a keyboard alphabet.
    static func inferred(from character: Character) -> KeyboardLayout? {
        if Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").contains(character) {
            return .englishUS
        }
        if Set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюяАБВГҐДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯ")
            .contains(character) {
            return .ukrainianEnhanced
        }
        return nil
    }
}

enum HostLayoutShortcut: String, CaseIterable, Identifiable {
    case controlSpace
    case controlShift
    case altShift
    case shiftSpace
    case superSpace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .controlSpace: "Ctrl + Space"
        case .controlShift: "Ctrl + Shift"
        case .altShift: "Alt + Shift"
        case .shiftSpace: "Shift + Space"
        case .superSpace: "Win + Space"
        }
    }

    var command: HIDCommand {
        switch self {
        case .controlSpace:
            HIDCommand(modifiers: HID.modLeftCtrl, keycode: HID.keySpace)
        case .controlShift:
            HIDCommand(modifiers: HID.modLeftCtrl | HID.modLeftShift, keycode: 0)
        case .altShift:
            HIDCommand(modifiers: HID.modLeftAlt | HID.modLeftShift, keycode: 0)
        case .shiftSpace:
            HIDCommand(modifiers: HID.modLeftShift, keycode: HID.keySpace)
        case .superSpace:
            HIDCommand(modifiers: HID.modLeftGUI, keycode: HID.keySpace)
        }
    }
}

/// USB HID Usage IDs and character mappings for physical US and Ukrainian
/// Enhanced layouts. HID transports key positions, not Unicode characters,
/// so the selected layout must match the target computer.
enum HID {
    static let modLeftCtrl: UInt8 = 0x01
    static let modLeftShift: UInt8 = 0x02
    static let modLeftAlt: UInt8 = 0x04
    static let modLeftGUI: UInt8 = 0x08
    static let modRightCtrl: UInt8 = 0x10
    static let modRightShift: UInt8 = 0x20
    static let modRightAlt: UInt8 = 0x40
    static let modRightGUI: UInt8 = 0x80

    static let keyA: UInt8 = 0x04
    static let keyB: UInt8 = 0x05
    static let keyC: UInt8 = 0x06
    static let keyD: UInt8 = 0x07
    static let keyE: UInt8 = 0x08
    static let keyF: UInt8 = 0x09
    static let keyG: UInt8 = 0x0A
    static let keyH: UInt8 = 0x0B
    static let keyI: UInt8 = 0x0C
    static let keyJ: UInt8 = 0x0D
    static let keyK: UInt8 = 0x0E
    static let keyL: UInt8 = 0x0F
    static let keyM: UInt8 = 0x10
    static let keyN: UInt8 = 0x11
    static let keyO: UInt8 = 0x12
    static let keyP: UInt8 = 0x13
    static let keyQ: UInt8 = 0x14
    static let keyR: UInt8 = 0x15
    static let keyS: UInt8 = 0x16
    static let keyT: UInt8 = 0x17
    static let keyU: UInt8 = 0x18
    static let keyV: UInt8 = 0x19
    static let keyW: UInt8 = 0x1A
    static let keyX: UInt8 = 0x1B
    static let keyY: UInt8 = 0x1C
    static let keyZ: UInt8 = 0x1D

    static let key1: UInt8 = 0x1E
    static let key2: UInt8 = 0x1F
    static let key3: UInt8 = 0x20
    static let key4: UInt8 = 0x21
    static let key5: UInt8 = 0x22
    static let key6: UInt8 = 0x23
    static let key7: UInt8 = 0x24
    static let key8: UInt8 = 0x25
    static let key9: UInt8 = 0x26
    static let key0: UInt8 = 0x27

    static let keyEnter: UInt8 = 0x28
    static let keyEscape: UInt8 = 0x29
    static let keyBackspace: UInt8 = 0x2A
    static let keyTab: UInt8 = 0x2B
    static let keySpace: UInt8 = 0x2C
    static let keyMinus: UInt8 = 0x2D
    static let keyEqual: UInt8 = 0x2E
    static let keyLeftBracket: UInt8 = 0x2F
    static let keyRightBracket: UInt8 = 0x30
    static let keyBackslash: UInt8 = 0x31
    static let keySemicolon: UInt8 = 0x33
    static let keyQuote: UInt8 = 0x34
    static let keyGrave: UInt8 = 0x35
    static let keyComma: UInt8 = 0x36
    static let keyPeriod: UInt8 = 0x37
    static let keySlash: UInt8 = 0x38

    static let keyCapsLock: UInt8 = 0x39
    static let keyF1: UInt8 = 0x3A
    static let keyF2: UInt8 = 0x3B
    static let keyF3: UInt8 = 0x3C
    static let keyF4: UInt8 = 0x3D
    static let keyF5: UInt8 = 0x3E
    static let keyF6: UInt8 = 0x3F
    static let keyF7: UInt8 = 0x40
    static let keyF8: UInt8 = 0x41
    static let keyF9: UInt8 = 0x42
    static let keyF10: UInt8 = 0x43
    static let keyF11: UInt8 = 0x44
    static let keyF12: UInt8 = 0x45

    static let keyPrintScreen: UInt8 = 0x46
    static let keyScrollLock: UInt8 = 0x47
    static let keyPause: UInt8 = 0x48
    static let keyInsert: UInt8 = 0x49
    static let keyHome: UInt8 = 0x4A
    static let keyPageUp: UInt8 = 0x4B
    static let keyDelete: UInt8 = 0x4C
    static let keyEnd: UInt8 = 0x4D
    static let keyPageDown: UInt8 = 0x4E
    static let keyRightArrow: UInt8 = 0x4F
    static let keyLeftArrow: UInt8 = 0x50
    static let keyDownArrow: UInt8 = 0x51
    static let keyUpArrow: UInt8 = 0x52

    private static let englishUSMap = makeEnglishUSMap()
    private static let ukrainianEnhancedMap = makeUkrainianEnhancedMap()

    static func mapCharacterToHID(
        _ character: Character,
        layout: KeyboardLayout = .englishUS
    ) -> HIDCommand? {
        switch layout {
        case .englishUS:
            englishUSMap[character]
        case .ukrainianEnhanced:
            ukrainianEnhancedMap[character]
        }
    }

    private static func makeEnglishUSMap() -> [Character: HIDCommand] {
        var map: [Character: HIDCommand] = [:]

        for (index, character) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[character] = HIDCommand(modifiers: 0, keycode: UInt8(0x04 + index))
        }
        for (index, character) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            map[character] = HIDCommand(modifiers: modLeftShift, keycode: UInt8(0x04 + index))
        }

        addNumberRow(to: &map)
        add([
            ("-", keyMinus), ("=", keyEqual), ("[", keyLeftBracket), ("]", keyRightBracket),
            ("\\", keyBackslash), (";", keySemicolon), ("'", keyQuote), ("`", keyGrave),
            (",", keyComma), (".", keyPeriod), ("/", keySlash)
        ], modifiers: 0, to: &map)
        add([
            ("_", keyMinus), ("+", keyEqual), ("{", keyLeftBracket), ("}", keyRightBracket),
            ("|", keyBackslash), (":", keySemicolon), ("\"", keyQuote), ("~", keyGrave),
            ("<", keyComma), (">", keyPeriod), ("?", keySlash),
            ("!", key1), ("@", key2), ("#", key3), ("$", key4), ("%", key5),
            ("^", key6), ("&", key7), ("*", key8), ("(", key9), (")", key0)
        ], modifiers: modLeftShift, to: &map)
        addWhitespace(to: &map)
        return map
    }

    private static func makeUkrainianEnhancedMap() -> [Character: HIDCommand] {
        var map: [Character: HIDCommand] = [:]

        let letters: [(Character, UInt8)] = [
            ("й", keyQ), ("ц", keyW), ("у", keyE), ("к", keyR), ("е", keyT),
            ("н", keyY), ("г", keyU), ("ш", keyI), ("щ", keyO), ("з", keyP),
            ("х", keyLeftBracket), ("ї", keyRightBracket), ("ґ", keyBackslash),
            ("ф", keyA), ("і", keyS), ("в", keyD), ("а", keyF), ("п", keyG),
            ("р", keyH), ("о", keyJ), ("л", keyK), ("д", keyL), ("ж", keySemicolon),
            ("є", keyQuote), ("я", keyZ), ("ч", keyX), ("с", keyC), ("м", keyV),
            ("и", keyB), ("т", keyN), ("ь", keyM), ("б", keyComma), ("ю", keyPeriod)
        ]

        for (character, keycode) in letters {
            map[character] = HIDCommand(modifiers: 0, keycode: keycode)
            let uppercase = Character(String(character).uppercased())
            map[uppercase] = HIDCommand(modifiers: modLeftShift, keycode: keycode)
        }

        addNumberRow(to: &map)
        add([
            ("'", keyGrave), ("’", keyGrave), ("-", keyMinus), ("=", keyEqual),
            (".", keySlash)
        ], modifiers: 0, to: &map)
        add([
            ("_", keyMinus), ("+", keyEqual), (",", keySlash), ("!", key1),
            ("\"", key2), ("№", key3), (";", key4), ("%", key5), (":", key6),
            ("?", key7), ("*", key8), ("(", key9), (")", key0)
        ], modifiers: modLeftShift, to: &map)
        addWhitespace(to: &map)
        return map
    }

    private static func addNumberRow(to map: inout [Character: HIDCommand]) {
        add([
            ("1", key1), ("2", key2), ("3", key3), ("4", key4), ("5", key5),
            ("6", key6), ("7", key7), ("8", key8), ("9", key9), ("0", key0)
        ], modifiers: 0, to: &map)
    }

    private static func addWhitespace(to map: inout [Character: HIDCommand]) {
        map[" "] = HIDCommand(modifiers: 0, keycode: keySpace)
        map["\t"] = HIDCommand(modifiers: 0, keycode: keyTab)
    }

    private static func add(
        _ entries: [(Character, UInt8)],
        modifiers: UInt8,
        to map: inout [Character: HIDCommand]
    ) {
        for (character, keycode) in entries {
            map[character] = HIDCommand(modifiers: modifiers, keycode: keycode)
        }
    }
}
