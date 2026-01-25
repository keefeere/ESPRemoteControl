//
//  HID.swift
//  ESPRemoteControl
//
//  Created by Ruben Kostandyan on 14/12/2025.
//

import Foundation

struct HIDCommand {
    let modifiers: UInt8
    let keycode: UInt8
}

/// Comprehensive USB HID Usage ID mapping for standard US keyboard layout.
enum HID {
    // Modifiers bitmask (standard HID)
    static let modLeftCtrl: UInt8  = 0x01
    static let modLeftShift: UInt8 = 0x02
    static let modLeftAlt: UInt8   = 0x04
    static let modLeftGUI: UInt8   = 0x08
    static let modRightCtrl: UInt8 = 0x10
    static let modRightShift: UInt8 = 0x20
    static let modRightAlt: UInt8  = 0x40
    static let modRightGUI: UInt8  = 0x80

    // Keycodes (USB HID Usage IDs)
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
    static let keyMinus: UInt8 = 0x2D          // - and _
    static let keyEqual: UInt8 = 0x2E          // = and +
    static let keyLeftBracket: UInt8 = 0x2F    // [ and {
    static let keyRightBracket: UInt8 = 0x30   // ] and }
    static let keyBackslash: UInt8 = 0x31      // \ and |
    static let keySemicolon: UInt8 = 0x33      // ; and :
    static let keyQuote: UInt8 = 0x34          // ' and "
    static let keyGrave: UInt8 = 0x35          // ` and ~
    static let keyComma: UInt8 = 0x36          // , and <
    static let keyPeriod: UInt8 = 0x37         // . and >
    static let keySlash: UInt8 = 0x38          // / and ?

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

    // Character to HID mapping dictionary for fast lookup
    private static let charMap: [Character: HIDCommand] = {
        var map = [Character: HIDCommand]()
        
        // Lowercase letters
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[c] = HIDCommand(modifiers: 0x00, keycode: UInt8(0x04 + i))
        }
        
        // Uppercase letters
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            map[c] = HIDCommand(modifiers: modLeftShift, keycode: UInt8(0x04 + i))
        }
        
        // Digits
        map["1"] = HIDCommand(modifiers: 0x00, keycode: key1)
        map["2"] = HIDCommand(modifiers: 0x00, keycode: key2)
        map["3"] = HIDCommand(modifiers: 0x00, keycode: key3)
        map["4"] = HIDCommand(modifiers: 0x00, keycode: key4)
        map["5"] = HIDCommand(modifiers: 0x00, keycode: key5)
        map["6"] = HIDCommand(modifiers: 0x00, keycode: key6)
        map["7"] = HIDCommand(modifiers: 0x00, keycode: key7)
        map["8"] = HIDCommand(modifiers: 0x00, keycode: key8)
        map["9"] = HIDCommand(modifiers: 0x00, keycode: key9)
        map["0"] = HIDCommand(modifiers: 0x00, keycode: key0)
        
        // Shifted number row: ! @ # $ % ^ & * ( )
        map["!"] = HIDCommand(modifiers: modLeftShift, keycode: key1)
        map["@"] = HIDCommand(modifiers: modLeftShift, keycode: key2)
        map["#"] = HIDCommand(modifiers: modLeftShift, keycode: key3)
        map["$"] = HIDCommand(modifiers: modLeftShift, keycode: key4)
        map["%"] = HIDCommand(modifiers: modLeftShift, keycode: key5)
        map["^"] = HIDCommand(modifiers: modLeftShift, keycode: key6)
        map["&"] = HIDCommand(modifiers: modLeftShift, keycode: key7)
        map["*"] = HIDCommand(modifiers: modLeftShift, keycode: key8)
        map["("] = HIDCommand(modifiers: modLeftShift, keycode: key9)
        map[")"] = HIDCommand(modifiers: modLeftShift, keycode: key0)
        
        // Punctuation (unshifted)
        map["-"] = HIDCommand(modifiers: 0x00, keycode: keyMinus)
        map["="] = HIDCommand(modifiers: 0x00, keycode: keyEqual)
        map["["] = HIDCommand(modifiers: 0x00, keycode: keyLeftBracket)
        map["]"] = HIDCommand(modifiers: 0x00, keycode: keyRightBracket)
        map["\\"] = HIDCommand(modifiers: 0x00, keycode: keyBackslash)
        map[";"] = HIDCommand(modifiers: 0x00, keycode: keySemicolon)
        map["'"] = HIDCommand(modifiers: 0x00, keycode: keyQuote)
        map["`"] = HIDCommand(modifiers: 0x00, keycode: keyGrave)
        map[","] = HIDCommand(modifiers: 0x00, keycode: keyComma)
        map["."] = HIDCommand(modifiers: 0x00, keycode: keyPeriod)
        map["/"] = HIDCommand(modifiers: 0x00, keycode: keySlash)
        
        // Punctuation (shifted)
        map["_"] = HIDCommand(modifiers: modLeftShift, keycode: keyMinus)
        map["+"] = HIDCommand(modifiers: modLeftShift, keycode: keyEqual)
        map["{"] = HIDCommand(modifiers: modLeftShift, keycode: keyLeftBracket)
        map["}"] = HIDCommand(modifiers: modLeftShift, keycode: keyRightBracket)
        map["|"] = HIDCommand(modifiers: modLeftShift, keycode: keyBackslash)
        map[":"] = HIDCommand(modifiers: modLeftShift, keycode: keySemicolon)
        map["\""] = HIDCommand(modifiers: modLeftShift, keycode: keyQuote)
        map["~"] = HIDCommand(modifiers: modLeftShift, keycode: keyGrave)
        map["<"] = HIDCommand(modifiers: modLeftShift, keycode: keyComma)
        map[">"] = HIDCommand(modifiers: modLeftShift, keycode: keyPeriod)
        map["?"] = HIDCommand(modifiers: modLeftShift, keycode: keySlash)
        
        // Whitespace
        map[" "] = HIDCommand(modifiers: 0x00, keycode: keySpace)
        map["\t"] = HIDCommand(modifiers: 0x00, keycode: keyTab)
        
        return map
    }()

    static func mapCharacterToHID(_ ch: Character) -> HIDCommand? {
        return charMap[ch]
    }
}
