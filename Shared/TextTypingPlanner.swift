import Foundation

struct TextTypingPlan {
    let taps: [(modifiers: UInt8, keycode: UInt8)]
    let finalLayout: KeyboardLayout
    let unsupportedCharacters: [Character]
}

enum TextTypingPlanner {
    static func makePlan(
        for text: String,
        startingLayout: KeyboardLayout,
        layoutShortcut: HostLayoutShortcut
    ) -> TextTypingPlan {
        var taps: [(modifiers: UInt8, keycode: UInt8)] = []
        var unsupported: [Character] = []
        var activeLayout = startingLayout
        var previousWasCarriageReturn = false

        for character in text {
            if character == "\n" {
                if !previousWasCarriageReturn {
                    taps.append((0, HID.keyEnter))
                }
                previousWasCarriageReturn = false
                continue
            }

            if character == "\r" {
                taps.append((0, HID.keyEnter))
                previousWasCarriageReturn = true
                continue
            }

            previousWasCarriageReturn = false

            if let inferredLayout = KeyboardLayout.inferred(from: character),
               inferredLayout != activeLayout {
                let shortcut = layoutShortcut.command
                taps.append((shortcut.modifiers, shortcut.keycode))
                activeLayout = inferredLayout
            }

            if let command = HID.mapCharacterToHID(character, layout: activeLayout) {
                taps.append((command.modifiers, command.keycode))
            } else {
                unsupported.append(character)
            }
        }

        return TextTypingPlan(
            taps: taps,
            finalLayout: activeLayout,
            unsupportedCharacters: unsupported
        )
    }
}
