import Foundation

@main
struct HIDMappingTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        let expected: [(Character, Character, UInt8)] = [
            ("і", "ы", HID.keyS),
            ("є", "э", HID.keyQuote),
            ("'", "ё", HID.keyGrave),
            ("ї", "ъ", HID.keyRightBracket)
        ]

        for (ukrainianKey, russianCharacter, keycode) in expected {
            let lower = HID.mapCharacterToHID(russianCharacter, layout: .ukrainianEnhanced)
            check(lower == HIDCommand(modifiers: HID.modRightAlt, keycode: keycode),
                  "Lowercase Russian alternate uses AltGr")
            check(HID.russianAlternateForUkrainianKey(ukrainianKey, uppercase: false) == lower,
                  "Ukrainian Alt shortcut resolves to lowercase Russian alternate")
            check(HID.russianAlternateCharacterForUkrainianKey(
                ukrainianKey,
                uppercase: false
            ) == russianCharacter, "Ukrainian Alt shortcut exposes its visible legend")

            let uppercaseCharacter = Character(String(russianCharacter).uppercased())
            let upper = HID.mapCharacterToHID(uppercaseCharacter, layout: .ukrainianEnhanced)
            check(upper == HIDCommand(
                modifiers: HID.modRightAlt | HID.modLeftShift,
                keycode: keycode
            ), "Uppercase Russian alternate uses AltGr+Shift")
            check(HID.russianAlternateForUkrainianKey(ukrainianKey, uppercase: true) == upper,
                  "Ukrainian Alt shortcut resolves to uppercase Russian alternate")
            check(KeyboardLayout.inferred(from: russianCharacter) == .ukrainianEnhanced,
                  "Russian alternate selects the Ukrainian layout")
        }

        check(HID.russianAlternateForUkrainianKey("а", uppercase: false) == nil,
              "Ordinary Ukrainian keys keep normal Alt behavior")
        print("PASS: Ukrainian AltGr Russian letter mappings")
    }
}
