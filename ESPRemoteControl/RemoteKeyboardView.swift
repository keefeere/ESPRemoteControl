import SwiftUI

struct RemoteKeyboardView: View {
    @ObservedObject var ble: BLEKeyboardBridge
    @Binding var layout: KeyboardLayout
    let onLayoutChange: (KeyboardLayout) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var shift = false
    @State private var capsLock = false
    @State private var stickyModifiers: UInt8 = 0

    private var uppercaseLetters: Bool { shift != capsLock }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    connectionStatus
                    functionRow
                    numberRow

                    ForEach(Array(layout.letterRows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(spacing: 5) {
                            if rowIndex == 2 {
                                actionKey("⇧", active: shift) {
                                    shift.toggle()
                                }
                            }

                            ForEach(Array(row.enumerated()), id: \.offset) { _, character in
                                characterKey(character)
                            }

                            if rowIndex == 2 {
                                actionKey("⌫") {
                                    sendKey(HID.keyBackspace, preserveModifiers: true)
                                }
                            }
                        }
                    }

                    punctuationRow
                    modifierRow
                    navigationRow
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Remote Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(layout.shortName) {
                        let next: KeyboardLayout = layout == .englishUS ? .ukrainianEnhanced : .englishUS
                        onLayoutChange(next)
                    }
                    .buttonStyle(.borderedProminent)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        releaseModifiers()
                        dismiss()
                    }
                }
            }
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ble.isReady ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(ble.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(layout.displayName)
                .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 6)
    }

    private var functionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                actionKey("Esc") { sendKey(HID.keyEscape) }
                ForEach(Array(functionKeys.enumerated()), id: \.offset) { index, keycode in
                    actionKey("F\(index + 1)") { sendKey(keycode) }
                }
            }
        }
    }

    private var numberRow: some View {
        let values = shiftedNumberCharacters
        return HStack(spacing: 5) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, character in
                characterKey(character, usesCase: false)
            }
        }
    }

    private var punctuationRow: some View {
        HStack(spacing: 5) {
            ForEach(Array(punctuationCharacters.enumerated()), id: \.offset) { _, character in
                characterKey(character, usesCase: false)
            }
            actionKey("Space", width: 120) { sendKey(HID.keySpace) }
            actionKey("↵") { sendKey(HID.keyEnter) }
        }
    }

    private var modifierRow: some View {
        HStack(spacing: 6) {
            modifierKey("Ctrl", mask: HID.modLeftCtrl)
            modifierKey("Win", mask: HID.modLeftGUI)
            modifierKey("Alt", mask: HID.modLeftAlt)
            actionKey("Caps", active: capsLock) {
                capsLock.toggle()
            }
            actionKey("Tab") { sendKey(HID.keyTab) }
        }
    }

    private var navigationRow: some View {
        HStack(spacing: 6) {
            actionKey("Home") { sendKey(HID.keyHome) }
            actionKey("←") { sendKey(HID.keyLeftArrow, preserveModifiers: true) }
            actionKey("↑") { sendKey(HID.keyUpArrow, preserveModifiers: true) }
            actionKey("↓") { sendKey(HID.keyDownArrow, preserveModifiers: true) }
            actionKey("→") { sendKey(HID.keyRightArrow, preserveModifiers: true) }
            actionKey("End") { sendKey(HID.keyEnd) }
            actionKey("Del") { sendKey(HID.keyDelete, preserveModifiers: true) }
        }
    }

    private func characterKey(_ base: Character, usesCase: Bool = true) -> some View {
        let character: Character
        if usesCase, uppercaseLetters {
            character = Character(String(base).uppercased())
        } else {
            character = base
        }

        return Button {
            sendCharacter(character)
        } label: {
            Text(String(character))
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(RemoteKeyButtonStyle())
    }

    private func actionKey(
        _ title: String,
        active: Bool = false,
        width: CGFloat? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(maxWidth: width == nil ? .infinity : nil, minHeight: 42)
                .frame(width: width)
                .contentShape(Rectangle())
        }
        .buttonStyle(RemoteKeyButtonStyle(active: active))
    }

    private func modifierKey(_ title: String, mask: UInt8) -> some View {
        actionKey(title, active: stickyModifiers & mask != 0) {
            stickyModifiers ^= mask
            ble.setModifiers(stickyModifiers)
        }
    }

    private func sendCharacter(_ character: Character) {
        guard let command = HID.mapCharacterToHID(character, layout: layout) else { return }
        ble.sendKeyTap(
            modifiers: command.modifiers | stickyModifiers,
            hidKeycode: command.keycode
        )
        finishOneShotModifiers()
    }

    private func sendKey(_ keycode: UInt8, preserveModifiers: Bool = false) {
        ble.sendKeyTap(modifiers: stickyModifiers, hidKeycode: keycode)
        if !preserveModifiers {
            finishOneShotModifiers()
        }
    }

    private func finishOneShotModifiers() {
        shift = false
        if stickyModifiers != 0 {
            stickyModifiers = 0
            ble.setModifiers(0)
        }
    }

    private func releaseModifiers() {
        stickyModifiers = 0
        ble.setModifiers(0)
    }

    private var shiftedNumberCharacters: [Character] {
        guard shift else { return Array("1234567890") }
        switch layout {
        case .englishUS:
            return Array("!@#$%^&*()")
        case .ukrainianEnhanced:
            return Array("!\"№;%:?*()")
        }
    }

    private var punctuationCharacters: [Character] {
        switch layout {
        case .englishUS:
            return Array(",./'")
        case .ukrainianEnhanced:
            return [",", ".", "'", "ґ"]
        }
    }

    private var functionKeys: [UInt8] {
        [
            HID.keyF1, HID.keyF2, HID.keyF3, HID.keyF4, HID.keyF5, HID.keyF6,
            HID.keyF7, HID.keyF8, HID.keyF9, HID.keyF10, HID.keyF11, HID.keyF12
        ]
    }
}

private struct RemoteKeyButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(
                active
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.72 : 1)
                    : Color(.secondarySystemGroupedBackground).opacity(configuration.isPressed ? 0.62 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }
}
