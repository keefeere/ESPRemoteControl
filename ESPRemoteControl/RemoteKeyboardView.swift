import Foundation
import SwiftUI

private struct TypingKey {
    let character: Character
    let usesCase: Bool
}

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
    private let keySpacing: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let usesWideLayout = geometry.size.width >= 600
            let showsTrackpad = geometry.size.height > geometry.size.width
            let keyboardRowCount = usesWideLayout ? 6 : 7
            let spacing = geometry.size.height < 600 ? CGFloat(3) : CGFloat(5)
            let statusHeight = usesWideLayout ? CGFloat(32) : CGFloat(38)
            let keyHeight = max(
                27,
                min(
                    usesWideLayout ? 46 : 48,
                    (geometry.size.height
                        - statusHeight
                        - 12
                        - (spacing * CGFloat(keyboardRowCount + 1)))
                        / CGFloat(keyboardRowCount)
                )
            )
            let availableWidth = geometry.size.width - 12

            VStack(spacing: spacing) {
                connectionStatus
                    .frame(height: statusHeight)

                if usesWideLayout {
                    functionRow(
                        labels: ["Esc"]
                            + (1...12).map { "F\($0)" }
                            + ["Home", "End", "Del"],
                        keycodes: [HID.keyEscape]
                            + functionKeys
                            + [HID.keyHome, HID.keyEnd, HID.keyDelete],
                        height: keyHeight
                    )
                } else {
                    functionRow(
                        labels: ["Esc", "F1", "F2", "F3", "F4", "F5", "F6", "Home"],
                        keycodes: [HID.keyEscape]
                            + Array(functionKeys.prefix(6))
                            + [HID.keyHome],
                        height: keyHeight
                    )
                    functionRow(
                        labels: ["F7", "F8", "F9", "F10", "F11", "F12", "Del", "End"],
                        keycodes: Array(functionKeys.suffix(6))
                            + [HID.keyDelete, HID.keyEnd],
                        height: keyHeight
                    )
                }

                numberRow(
                    height: keyHeight,
                    availableWidth: availableWidth,
                    includesOuterSymbols: usesWideLayout
                )
                tabRow(height: keyHeight, availableWidth: availableWidth)
                homeRow(height: keyHeight, availableWidth: availableWidth)
                shiftRow(height: keyHeight, availableWidth: availableWidth)
                commandRow(height: keyHeight, availableWidth: availableWidth)

                if showsTrackpad {
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

    private func numberRow(
        height: CGFloat,
        availableWidth: CGFloat,
        includesOuterSymbols: Bool
    ) -> some View {
        let values = numberRowCharacters(includesOuterSymbols: includesOuterSymbols)
        let weights = Array(repeating: CGFloat(1), count: values.count) + [1.8]
        let widths = resolvedWidths(weights: weights, availableWidth: availableWidth)

        return HStack(spacing: keySpacing) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, character in
                characterKey(
                    character,
                    usesCase: false,
                    width: widths[index],
                    height: height
                )
            }
            actionKey(
                "⌫",
                keycode: HID.keyBackspace,
                width: widths[values.count],
                height: height
            )
        }
    }

    private func tabRow(height: CGFloat, availableWidth: CGFloat) -> some View {
        let keys = topTypingKeys
        let weights = [CGFloat(1.35)] + Array(repeating: CGFloat(1), count: keys.count)
        let widths = resolvedWidths(weights: weights, availableWidth: availableWidth)

        return HStack(spacing: keySpacing) {
            actionKey("Tab", keycode: HID.keyTab, width: widths[0], height: height)
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                characterKey(
                    key.character,
                    usesCase: key.usesCase,
                    width: widths[index + 1],
                    height: height
                )
            }
        }
    }

    private func homeRow(height: CGFloat, availableWidth: CGFloat) -> some View {
        let keys = homeTypingKeys
        let weights = [CGFloat(1.45)]
            + Array(repeating: CGFloat(1), count: keys.count)
            + [1.9]
        let widths = resolvedWidths(weights: weights, availableWidth: availableWidth)

        return HStack(spacing: keySpacing) {
            actionKey(
                "Caps",
                keycode: HID.keyCapsLock,
                active: capsLock,
                width: widths[0],
                height: height,
                onReleased: { capsLock.toggle() }
            )

            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                characterKey(
                    key.character,
                    usesCase: key.usesCase,
                    width: widths[index + 1],
                    height: height
                )
            }

            actionKey(
                "Enter",
                keycode: HID.keyEnter,
                width: widths[keys.count + 1],
                height: height
            )
        }
    }

    private func shiftRow(height: CGFloat, availableWidth: CGFloat) -> some View {
        let keys = bottomTypingKeys
        let commandWidths = resolvedWidths(
            weights: commandRowWeights,
            availableWidth: availableWidth
        )
        let arrowWidths = Array(commandWidths.suffix(3))
        let arrowClusterWidth = arrowWidths[1] + arrowWidths[2] + keySpacing
        let typingWidth = availableWidth - arrowClusterWidth - keySpacing
        let typingWeights = [CGFloat(1.55)]
            + Array(repeating: CGFloat(1), count: keys.count)
        let typingWidths = resolvedWidths(
            weights: typingWeights,
            availableWidth: typingWidth
        )

        return HStack(spacing: keySpacing) {
            modifierKey(
                "Shift",
                mask: HID.modLeftShift,
                width: typingWidths[0],
                height: height
            )

            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                characterKey(
                    key.character,
                    usesCase: key.usesCase,
                    width: typingWidths[index + 1],
                    height: height
                )
            }

            HStack(spacing: keySpacing) {
                actionKey(
                    "↑",
                    keycode: HID.keyUpArrow,
                    width: arrowWidths[1],
                    height: height
                )
                Color.clear
                    .frame(width: arrowWidths[2], height: height)
                    .accessibilityHidden(true)
            }
            .frame(width: arrowClusterWidth, height: height)
        }
    }

    private func commandRow(height: CGFloat, availableWidth: CGFloat) -> some View {
        let widths = resolvedWidths(
            weights: commandRowWeights,
            availableWidth: availableWidth
        )

        return HStack(spacing: keySpacing) {
            layoutKey(width: widths[0], height: height)
            modifierKey("Ctrl", mask: HID.modLeftCtrl, width: widths[1], height: height)
            modifierKey("Win", mask: HID.modLeftGUI, width: widths[2], height: height)
            modifierKey("Alt", mask: HID.modLeftAlt, width: widths[3], height: height)
            actionKey("Space", keycode: HID.keySpace, width: widths[4], height: height)
            actionKey("←", keycode: HID.keyLeftArrow, width: widths[5], height: height)
            actionKey("↓", keycode: HID.keyDownArrow, width: widths[6], height: height)
            actionKey("→", keycode: HID.keyRightArrow, width: widths[7], height: height)
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
        width: CGFloat? = nil,
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
        .frame(maxWidth: width == nil ? .infinity : nil, minHeight: height, maxHeight: height)
        .frame(width: width)
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

    private func layoutKey(width: CGFloat, height: CGFloat) -> some View {
        PressableKeyButton(
            title: "UA/EN",
            isCompact: true,
            fontSize: height < 34 ? 8 : 10,
            minHeight: height,
            onPress: {},
            onRelease: { changeLayout(synchronizeHost: true) }
        )
        .frame(width: width, height: height)
    }

    private func modifierKey(
        _ title: String,
        mask: UInt8,
        width: CGFloat? = nil,
        height: CGFloat
    ) -> some View {
        PressableKeyButton(
            title: title,
            isActive: effectiveModifiers & mask != 0,
            isCompact: true,
            minHeight: height,
            onPress: { beginModifierPress(mask) },
            onRelease: { endModifierPress(mask) }
        )
        .frame(maxWidth: width == nil ? .infinity : nil, minHeight: height, maxHeight: height)
        .frame(width: width)
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

    private var commandRowWeights: [CGFloat] {
        [1.35, 1, 1, 1, 3.2, 1, 1, 1]
    }

    private var topTypingKeys: [TypingKey] {
        var keys = layout.letterRows[0].map {
            TypingKey(character: $0, usesCase: true)
        }
        switch layout {
        case .englishUS:
            let punctuation = shiftIsActive ? Array("{}|") : Array("[]\\")
            keys += punctuation.map { TypingKey(character: $0, usesCase: false) }
        case .ukrainianEnhanced:
            keys.append(TypingKey(character: "ґ", usesCase: true))
        }
        return keys
    }

    private var homeTypingKeys: [TypingKey] {
        var keys = layout.letterRows[1].map {
            TypingKey(character: $0, usesCase: true)
        }
        if layout == .englishUS {
            let punctuation = shiftIsActive ? Array(":\"") : Array(";'")
            keys += punctuation.map { TypingKey(character: $0, usesCase: false) }
        }
        return keys
    }

    private var bottomTypingKeys: [TypingKey] {
        var keys = layout.letterRows[2].map {
            TypingKey(character: $0, usesCase: true)
        }
        switch layout {
        case .englishUS:
            let punctuation = shiftIsActive ? Array("<>?") : Array(",./")
            keys += punctuation.map { TypingKey(character: $0, usesCase: false) }
        case .ukrainianEnhanced:
            keys.append(
                TypingKey(character: shiftIsActive ? "," : ".", usesCase: false)
            )
        }
        return keys
    }

    private func numberRowCharacters(includesOuterSymbols: Bool) -> [Character] {
        let numbers = shiftedNumberCharacters
        guard includesOuterSymbols else { return numbers }

        let leading: Character
        switch layout {
        case .englishUS:
            leading = shiftIsActive ? "~" : "`"
        case .ukrainianEnhanced:
            leading = "'"
        }

        let trailing = shiftIsActive ? Array("_+") : Array("-=")
        return [leading] + numbers + trailing
    }

    private func resolvedWidths(
        weights: [CGFloat],
        availableWidth: CGFloat
    ) -> [CGFloat] {
        guard !weights.isEmpty else { return [] }
        let gapsWidth = keySpacing * CGFloat(weights.count - 1)
        let contentWidth = max(0, availableWidth - gapsWidth)
        let totalWeight = weights.reduce(0, +)
        return weights.map { contentWidth * ($0 / totalWeight) }
    }

    private var functionKeys: [UInt8] {
        [
            HID.keyF1, HID.keyF2, HID.keyF3, HID.keyF4, HID.keyF5, HID.keyF6,
            HID.keyF7, HID.keyF8, HID.keyF9, HID.keyF10, HID.keyF11, HID.keyF12
        ]
    }
}
