import SwiftUI

struct ControlPadPage: View {
    @ObservedObject var ble: BLEKeyboardBridge

    @State private var latchedModifiers: UInt8 = 0x00
    @State private var momentaryModifiers: UInt8 = 0x00

    private var activeModifiers: UInt8 { latchedModifiers | momentaryModifiers }

    var body: some View {
        VStack(spacing: 12) {
            PressableKeyButton(
                title: "⎋ ESC",
                isActive: false,
                isProminent: true,
                minHeight: 56,
                onPress: { ble.sendKeyDown(modifiersMask: activeModifiers, keycode: HID.keyEscape) },
                onRelease: { ble.sendKeyUp(keycode: HID.keyEscape) }
            )
            .frame(maxWidth: .infinity)

            scrollRow(title: "F-Keys", items: fKeys)
            scrollRow(title: "Numbers", items: numbers)
            scrollRow(title: "Letters", items: letters)

            // Backspace / Up / Delete
            HStack(spacing: 10) {
                keyButton(title: "⌫", keycode: HID.keyBackspace)
                keyButton(title: "↑", keycode: HID.keyUpArrow)
                keyButton(title: "⌦", keycode: HID.keyDelete)
            }

            // Left / Down / Right
            HStack(spacing: 10) {
                keyButton(title: "←", keycode: HID.keyLeftArrow)
                keyButton(title: "↓", keycode: HID.keyDownArrow)
                keyButton(title: "→", keycode: HID.keyRightArrow)
            }

            // Tab / Space / Enter
            HStack(spacing: 10) {
                keyButton(title: "⇥", keycode: HID.keyTab)
                PressableKeyButton(
                    title: "Space",
                    onPress: { ble.sendKeyDown(modifiersMask: activeModifiers, keycode: HID.keySpace) },
                    onRelease: { ble.sendKeyUp(keycode: HID.keySpace) }
                )
                .frame(maxWidth: .infinity)

                keyButton(title: "↵", keycode: HID.keyEnter)
            }

            // Ctrl / Win / Alt (tap = sticky, hold = momentary)
            HStack(spacing: 10) {
                modifierButton(title: "CTRL", mask: HID.modLeftCtrl)
                modifierButton(title: "WIN", mask: HID.modLeftGUI)
                modifierButton(title: "ALT", mask: HID.modLeftAlt)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 16)
        .onChange(of: activeModifiers) { _, newValue in
            ble.setModifiers(newValue)
        }
    }

    private func keyButton(title: String, keycode: UInt8) -> some View {
        PressableKeyButton(
            title: title,
            onPress: { ble.sendKeyDown(modifiersMask: activeModifiers, keycode: keycode) },
            onRelease: { ble.sendKeyUp(keycode: keycode) }
        )
        .frame(maxWidth: .infinity)
    }

    private func scrollRow(title: String, items: [(label: String, keycode: UInt8)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items, id: \.label) { item in
                        PressableKeyButton(
                            title: item.label,
                            onPress: { ble.sendKeyDown(modifiersMask: activeModifiers, keycode: item.keycode) },
                            onRelease: { ble.sendKeyUp(keycode: item.keycode) }
                        )
                        .frame(minWidth: 46)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    private func modifierButton(title: String, mask: UInt8) -> some View {
        ModifierKeyButton(
            title: title,
            mask: mask,
            latchedModifiers: $latchedModifiers,
            momentaryModifiers: $momentaryModifiers
        )
        .frame(maxWidth: .infinity)
    }

    private var fKeys: [(label: String, keycode: UInt8)] {
        [
            ("F1", HID.keyF1), ("F2", HID.keyF2), ("F3", HID.keyF3), ("F4", HID.keyF4),
            ("F5", HID.keyF5), ("F6", HID.keyF6), ("F7", HID.keyF7), ("F8", HID.keyF8),
            ("F9", HID.keyF9), ("F10", HID.keyF10), ("F11", HID.keyF11), ("F12", HID.keyF12)
        ]
    }

    private var numbers: [(label: String, keycode: UInt8)] {
        [("1", HID.key1), ("2", HID.key2), ("3", HID.key3), ("4", HID.key4), ("5", HID.key5),
         ("6", HID.key6), ("7", HID.key7), ("8", HID.key8), ("9", HID.key9), ("0", HID.key0)]
    }

    private var letters: [(label: String, keycode: UInt8)] {
        // Alphabetical order (single row, horizontally scrollable)
        [
            ("A", HID.keyA), ("B", HID.keyB), ("C", HID.keyC), ("D", HID.keyD), ("E", HID.keyE),
            ("F", HID.keyF), ("G", HID.keyG), ("H", HID.keyH), ("I", HID.keyI), ("J", HID.keyJ),
            ("K", HID.keyK), ("L", HID.keyL), ("M", HID.keyM), ("N", HID.keyN), ("O", HID.keyO),
            ("P", HID.keyP), ("Q", HID.keyQ), ("R", HID.keyR), ("S", HID.keyS), ("T", HID.keyT),
            ("U", HID.keyU), ("V", HID.keyV), ("W", HID.keyW), ("X", HID.keyX), ("Y", HID.keyY),
            ("Z", HID.keyZ)
        ]
    }
}

private struct ModifierKeyButton: View {
    let title: String
    let mask: UInt8

    @Binding var latchedModifiers: UInt8
    @Binding var momentaryModifiers: UInt8

    @State private var isHolding: Bool = false
    @State private var holdWork: DispatchWorkItem?

    private var isActive: Bool { ((latchedModifiers | momentaryModifiers) & mask) != 0 }

    private let holdThreshold: TimeInterval = 0.25

    var body: some View {
        PressableKeyButton(
            title: title,
            isActive: isActive,
            onPress: handleDown,
            onRelease: handleUp
        )
    }

    private func handleDown() {
        isHolding = false
        holdWork?.cancel()

        let work = DispatchWorkItem {
            isHolding = true
            momentaryModifiers |= mask
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
    }

    private func handleUp() {
        holdWork?.cancel()
        holdWork = nil

        if isHolding {
            momentaryModifiers &= ~mask
            isHolding = false
        } else {
            latchedModifiers ^= mask
        }
    }
}
