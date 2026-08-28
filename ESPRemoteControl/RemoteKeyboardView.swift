import Foundation
import SwiftUI

struct RemoteKeyboardView: View {
    @ObservedObject var ble: BLEKeyboardBridge
    @Binding var layout: KeyboardLayout
    let onLayoutChange: (KeyboardLayout, Bool) -> Void

    @State private var capsLock = false
    @State private var stickyModifiers: UInt8 = 0
    @State private var momentaryModifiers: UInt8 = 0
    @State private var usedMomentaryModifiers: UInt8 = 0
    @State private var modifierPressStartedAt: [UInt8: TimeInterval] = [:]
    @State private var pressedKeycodes: Set<UInt8> = []

    private var effectiveModifiers: UInt8 { stickyModifiers | momentaryModifiers }
    private var shiftIsActive: Bool { effectiveModifiers & HID.modLeftShift != 0 }
    private var uppercaseLetters: Bool { shiftIsActive != capsLock }

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
                            modifierKey("⇧", mask: HID.modLeftShift, height: keyHeight)
                        }

                        ForEach(Array(row.enumerated()), id: \.offset) { _, character in
                            characterKey(character, height: keyHeight)
                        }

                        if rowIndex == 2 {
                            actionKey(
                                "⌫",
                                keycode: HID.keyBackspace,
                                height: keyHeight
                            )
                        }
                    }
                }

                punctuationRow(height: keyHeight, availableWidth: geometry.size.width - 12)
                commandRow(height: keyHeight)

                if geometry.size.height > geometry.size.width {
                    keyboardTrackpad
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 72)
                        .padding(.top, 3)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .background(Color(.systemGroupedBackground))
        .onDisappear(perform: releaseAllInput)
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
                actionKey(
                    label,
                    keycode: keycodes[index],
                    height: height
                )
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
            actionKey("Space", keycode: HID.keySpace, width: spaceWidth, height: height)
            actionKey("↵", keycode: HID.keyEnter, height: height)
        }
    }

    private func commandRow(height: CGFloat) -> some View {
        HStack(spacing: 3) {
            modifierKey("Ctrl", mask: HID.modLeftCtrl, height: height)
            modifierKey("Win", mask: HID.modLeftGUI, height: height)
            modifierKey("Alt", mask: HID.modLeftAlt, height: height)
            actionKey(
                "Caps",
                keycode: HID.keyCapsLock,
                active: capsLock,
                height: height,
                onReleased: { capsLock.toggle() }
            )
            actionKey("Tab", keycode: HID.keyTab, height: height)
            actionKey("Home", keycode: HID.keyHome, height: height)
            actionKey("←", keycode: HID.keyLeftArrow, height: height)
            actionKey("↑", keycode: HID.keyUpArrow, height: height)
            actionKey("↓", keycode: HID.keyDownArrow, height: height)
            actionKey("→", keycode: HID.keyRightArrow, height: height)
            actionKey("End", keycode: HID.keyEnd, height: height)
        }
    }

    private var keyboardTrackpad: some View {
        TrackpadView(
            onMove: { ble.sendMouseMove(dx: $0, dy: $1) },
            onTap: { fingers in
                ble.sendMouseClick(button: fingers >= 2 ? 2 : 1)
            },
            onScroll: { ble.sendMouseScroll(dx: $0, dy: $1) },
            onDragStart: { ble.sendMouseButtonDown(button: 1) },
            onDragEnd: { ble.sendMouseButtonUp(button: 1) }
        )
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.09), Color(.secondarySystemGroupedBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            VStack(spacing: 3) {
                Image(systemName: "rectangle.and.hand.point.up.left")
                    .font(.title3)
                Text("Тачпад · 2 пальці — скрол / правий клік")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
                .allowsHitTesting(false)
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

        let transmittedCharacter = usesCase ? base : character
        let command = HID.mapCharacterToHID(transmittedCharacter, layout: layout)

        return PressableKeyButton(
            title: String(character),
            isCompact: true,
            fontSize: height < 34 ? 14 : 17,
            minHeight: height,
            onPress: {
                guard let command else { return }
                pressKey(command.keycode, additionalModifiers: command.modifiers)
            },
            onRelease: {
                guard let command else { return }
                releaseKey(command.keycode)
            }
        )
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }

    private func actionKey(
        _ title: String,
        keycode: UInt8,
        active: Bool = false,
        width: CGFloat? = nil,
        height: CGFloat,
        onReleased: (() -> Void)? = nil
    ) -> some View {
        PressableKeyButton(
            title: title,
            isActive: active,
            isCompact: true,
            fontSize: height < 34 ? 9 : 11,
            minHeight: height,
            onPress: { pressKey(keycode) },
            onRelease: {
                releaseKey(keycode)
                onReleased?()
            }
        )
        .frame(maxWidth: width == nil ? .infinity : nil, minHeight: height, maxHeight: height)
        .frame(width: width)
    }

    private func modifierKey(_ title: String, mask: UInt8, height: CGFloat) -> some View {
        PressableKeyButton(
            title: title,
            isActive: effectiveModifiers & mask != 0,
            isCompact: true,
            minHeight: height,
            onPress: { beginModifierPress(mask) },
            onRelease: { endModifierPress(mask) }
        )
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }

    private func beginModifierPress(_ mask: UInt8) {
        modifierPressStartedAt[mask] = ProcessInfo.processInfo.systemUptime
        let nextMomentary = momentaryModifiers | mask
        momentaryModifiers = nextMomentary
        ble.setModifiers(stickyModifiers | nextMomentary)
    }

    private func endModifierPress(_ mask: UInt8) {
        let startedAt = modifierPressStartedAt.removeValue(forKey: mask)
            ?? ProcessInfo.processInfo.systemUptime
        let heldLongEnough = ProcessInfo.processInfo.systemUptime - startedAt >= 0.35
        let wasUsedForChord = usedMomentaryModifiers & mask != 0
        usedMomentaryModifiers &= ~mask

        let nextMomentary = momentaryModifiers & ~mask
        momentaryModifiers = nextMomentary
        if !heldLongEnough, !wasUsedForChord {
            stickyModifiers ^= mask
        }
        ble.setModifiers(stickyModifiers | nextMomentary)
    }

    private func changeLayout(synchronizeHost: Bool) {
        releaseAllInput()
        let next: KeyboardLayout = layout == .englishUS ? .ukrainianEnhanced : .englishUS
        onLayoutChange(next, synchronizeHost)
    }

    private func pressKey(_ keycode: UInt8, additionalModifiers: UInt8 = 0) {
        guard !pressedKeycodes.contains(keycode) else { return }
        pressedKeycodes.insert(keycode)
        usedMomentaryModifiers |= momentaryModifiers
        ble.sendKeyDown(
            modifiersMask: effectiveModifiers | additionalModifiers,
            keycode: keycode
        )
    }

    private func releaseKey(_ keycode: UInt8) {
        guard pressedKeycodes.contains(keycode) else { return }
        pressedKeycodes.remove(keycode)
        ble.sendKeyUp(keycode: keycode)
        stickyModifiers = 0
        ble.setModifiers(effectiveModifiers)
    }

    private func releaseAllInput() {
        for keycode in pressedKeycodes.sorted() {
            ble.sendKeyUp(keycode: keycode)
        }
        pressedKeycodes.removeAll()
        releaseModifiers()
    }

    private func releaseModifiers() {
        stickyModifiers = 0
        momentaryModifiers = 0
        usedMomentaryModifiers = 0
        modifierPressStartedAt.removeAll()
        ble.setModifiers(0)
    }

    private var shiftedNumberCharacters: [Character] {
        guard shiftIsActive else { return Array("1234567890") }
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
