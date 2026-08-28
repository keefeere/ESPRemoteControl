import SwiftUI

struct RemoteKeyboardView: View {
    @ObservedObject var ble: BLEKeyboardBridge
    @Binding var layout: KeyboardLayout
    let onLayoutChange: (KeyboardLayout, Bool) -> Void

    @State private var shift = false
    @State private var capsLock = false
    @State private var stickyModifiers: UInt8 = 0

    private var uppercaseLetters: Bool { shift != capsLock }

    var body: some View {
        GeometryReader { geometry in
            let spacing = geometry.size.height < 600 ? CGFloat(3) : CGFloat(5)
            let keyHeight = max(
                27,
                min(46, (geometry.size.height - 66 - (spacing * 8)) / 8)
            )

            VStack(spacing: spacing) {
                connectionStatus
                    .frame(height: 38)

                functionRow(
                    labels: ["Esc", "F1", "F2", "F3", "F4", "F5", "F6"],
                    keycodes: [HID.keyEscape] + Array(functionKeys.prefix(6)),
                    height: keyHeight
                )
                functionRow(
                    labels: ["F7", "F8", "F9", "F10", "F11", "F12", "Del"],
                    keycodes: Array(functionKeys.suffix(6)) + [HID.keyDelete],
                    height: keyHeight
                )
                numberRow(height: keyHeight)

                ForEach(Array(layout.letterRows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 3) {
                        if rowIndex == 2 {
                            actionKey("⇧", active: shift, height: keyHeight) {
                                shift.toggle()
                            }
                        }

                        ForEach(Array(row.enumerated()), id: \.offset) { _, character in
                            characterKey(character, height: keyHeight)
                        }

                        if rowIndex == 2 {
                            actionKey("⌫", height: keyHeight) {
                                sendKey(HID.keyBackspace, preserveModifiers: true)
                            }
                        }
                    }
                }

                punctuationRow(height: keyHeight, availableWidth: geometry.size.width - 12)
                commandRow(height: keyHeight)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .background(Color(.systemGroupedBackground))
        .onDisappear(perform: releaseModifiers)
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
            Spacer(minLength: 4)
            Text(layout.shortName)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .contentShape(Capsule())
                .onTapGesture {
                    changeLayout(synchronizeHost: true)
                }
                .onLongPressGesture(minimumDuration: 0.55) {
                    changeLayout(synchronizeHost: false)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Розкладка \(layout.shortName)")
                .accessibilityHint("Натисни для синхронного перемикання; утримуй, щоб змінити лише на телефоні")
                .accessibilityAction {
                    changeLayout(synchronizeHost: true)
                }
        }
        .padding(.horizontal, 4)
    }

    private func functionRow(labels: [String], keycodes: [UInt8], height: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                actionKey(label, height: height) {
                    sendKey(keycodes[index], preserveModifiers: label == "Del")
                }
            }
        }
    }

    private func numberRow(height: CGFloat) -> some View {
        let values = shiftedNumberCharacters
        return HStack(spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, character in
                characterKey(character, usesCase: false, height: height)
            }
        }
    }

    private func punctuationRow(height: CGFloat, availableWidth: CGFloat) -> some View {
        let spaceWidth = max(86, availableWidth * 0.30)
        return HStack(spacing: 3) {
            ForEach(Array(punctuationCharacters.enumerated()), id: \.offset) { _, character in
                characterKey(character, usesCase: false, height: height)
            }
            actionKey("Space", width: spaceWidth, height: height) {
                sendKey(HID.keySpace)
            }
            actionKey("↵", height: height) {
                sendKey(HID.keyEnter)
            }
        }
    }

    private func commandRow(height: CGFloat) -> some View {
        HStack(spacing: 3) {
            modifierKey("Ctrl", mask: HID.modLeftCtrl, height: height)
            modifierKey("Win", mask: HID.modLeftGUI, height: height)
            modifierKey("Alt", mask: HID.modLeftAlt, height: height)
            actionKey("Caps", active: capsLock, height: height) {
                capsLock.toggle()
            }
            actionKey("Tab", height: height) { sendKey(HID.keyTab) }
            actionKey("Home", height: height) { sendKey(HID.keyHome) }
            actionKey("←", height: height) { sendKey(HID.keyLeftArrow, preserveModifiers: true) }
            actionKey("↑", height: height) { sendKey(HID.keyUpArrow, preserveModifiers: true) }
            actionKey("↓", height: height) { sendKey(HID.keyDownArrow, preserveModifiers: true) }
            actionKey("→", height: height) { sendKey(HID.keyRightArrow, preserveModifiers: true) }
            actionKey("End", height: height) { sendKey(HID.keyEnd) }
        }
    }

    private func characterKey(
        _ base: Character,
        usesCase: Bool = true,
        height: CGFloat
    ) -> some View {
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
                .font(.system(size: height < 34 ? 14 : 17, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(RemoteKeyButtonStyle())
    }

    private func actionKey(
        _ title: String,
        active: Bool = false,
        width: CGFloat? = nil,
        height: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: height < 34 ? 9 : 11, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .frame(maxWidth: width == nil ? .infinity : nil, minHeight: height, maxHeight: height)
                .frame(width: width)
                .contentShape(Rectangle())
        }
        .buttonStyle(RemoteKeyButtonStyle(active: active))
    }

    private func modifierKey(_ title: String, mask: UInt8, height: CGFloat) -> some View {
        actionKey(title, active: stickyModifiers & mask != 0, height: height) {
            stickyModifiers ^= mask
            ble.setModifiers(stickyModifiers)
        }
    }

    private func changeLayout(synchronizeHost: Bool) {
        releaseModifiers()
        let next: KeyboardLayout = layout == .englishUS ? .ukrainianEnhanced : .englishUS
        onLayoutChange(next, synchronizeHost)
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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }
}
