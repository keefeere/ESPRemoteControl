import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var ble = BLEKeyboardBridge()

    @AppStorage("targetKeyboardLayout") private var layoutRawValue = KeyboardLayout.englishUS.rawValue
    @AppStorage("hostLayoutShortcut") private var shortcutRawValue = HostLayoutShortcut.controlSpace.rawValue

    @State private var inputText = ""
    @State private var wantsFocus = false
    @State private var isSecureInput = false
    @State private var selectedTab = 0
    @State private var showsSettings = false
    @State private var inputWarning: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            inputPage
                .tabItem { Label("Ввід", systemImage: "keyboard") }
                .tag(0)

            RemoteKeyboardView(
                ble: ble,
                layout: layoutBinding,
                onLayoutChange: selectLayout
            )
            .tabItem { Label("Клавіатура", systemImage: "keyboard.fill") }
            .tag(1)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if selectedTab == 0 {
                connectionHeader
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue != 0 {
                wantsFocus = false
            }
        }
        .onAppear {
            ble.start()
        }
        .onOpenURL(perform: handleIncomingURL)
        .sheet(isPresented: $showsSettings) {
            settingsView
        }
    }

    private var inputPage: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    typingCard
                    trackpadCard
                    mouseButtons
                }
                .padding(.horizontal)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("ESP Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        wantsFocus = false
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }

    private var connectionHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: ble.isReady ? "cable.connector" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(ble.isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(ble.isReady ? "ESP32 готовий" : "Пошук адаптера")
                    .font(.subheadline.weight(.semibold))
                Text(ble.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                ble.reconnectNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Перепідключити ESP32")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var typingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Клавіатура", systemImage: "character.cursor.ibeam")
                    .font(.headline)
                Spacer()
                Text("Авто · \(selectedLayout.shortName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                KeyCaptureTextField(
                    text: $inputText,
                    wantsFirstResponder: $wantsFocus,
                    isSecure: isSecureInput,
                    onTextChange: handleTextChange,
                    onReturn: handleReturnKey,
                    onBackspaceWhenEmpty: handleBackspaceWhenEmpty
                )
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .layoutPriority(1)

                Button {
                    sendLayoutShortcut()
                } label: {
                    Image(systemName: "globe")
                        .frame(width: 30, height: 42)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel("Перемкнути розкладку на комп’ютері")

                Button {
                    isSecureInput.toggle()
                } label: {
                    Image(systemName: isSecureInput ? "eye.slash" : "eye")
                        .frame(width: 34, height: 42)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel(isSecureInput ? "Показати текст" : "Приховати текст")
            }
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    pasteClipboard()
                } label: {
                    Label("Вставити", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Button {
                    inputText = ""
                    inputWarning = nil
                } label: {
                    Label("Очистити", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Spacer()

                Menu {
                    ForEach(HostLayoutShortcut.allCases) { shortcut in
                        Button {
                            shortcutRawValue = shortcut.rawValue
                        } label: {
                            if shortcut == selectedShortcut {
                                Label(shortcut.displayName, systemImage: "checkmark")
                            } else {
                                Text(shortcut.displayName)
                            }
                        }
                    }
                } label: {
                    Label(selectedShortcut.displayName, systemImage: "switch.2")
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.caption.weight(.semibold))

            if let inputWarning {
                Label(inputWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("EN/UA визначається за літерами. Перемикання на комп’ютері задається в налаштуваннях.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var trackpadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left")
                    .font(.headline)
                Spacer()
                Text("1 палець — клік · 2 — правий")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            TrackpadView(
                onMove: { ble.sendMouseMove(dx: $0, dy: $1) },
                onTap: { fingers in
                    ble.sendMouseClick(button: fingers >= 2 ? 2 : 1)
                },
                onScroll: { ble.sendMouseScroll(dx: $0, dy: $1) },
                onDragStart: { ble.sendMouseButtonDown(button: 1) },
                onDragEnd: { ble.sendMouseButtonUp(button: 1) }
            )
            .frame(height: 250)
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.10), Color(.tertiarySystemGroupedBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var mouseButtons: some View {
        HStack(spacing: 12) {
            PressableKeyButton(
                title: "Ліва кнопка",
                minHeight: 48,
                onPress: { ble.sendMouseButtonDown(button: 1) },
                onRelease: { ble.sendMouseButtonUp(button: 1) }
            )
            .frame(maxWidth: .infinity)

            PressableKeyButton(
                title: "Права кнопка",
                minHeight: 48,
                onPress: { ble.sendMouseButtonDown(button: 2) },
                onRelease: { ble.sendMouseButtonUp(button: 2) }
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Перемикання розкладки на комп’ютері") {
                    Picker("Комбінація", selection: shortcutBinding) {
                        ForEach(HostLayoutShortcut.allCases) { shortcut in
                            Text(shortcut.displayName).tag(shortcut)
                        }
                    }
                    Text("Коротке натискання EN/UA змінює розкладку телефона й надсилає цю комбінацію. Довге натискання змінює лише розкладку телефона.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Bluetooth") {
                    LabeledContent("Стан", value: ble.statusText)
                    Button("Перепідключити ESP32") {
                        ble.reconnectNow()
                    }
                }

                Section("Версія") {
                    LabeledContent("ESP Remote Control", value: "1.1.2")
                    Text("Іконка клавіатури: Tabler Icons, MIT License.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Налаштування")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showsSettings = false }
                }
            }
        }
    }

    private var selectedLayout: KeyboardLayout {
        KeyboardLayout(rawValue: layoutRawValue) ?? .englishUS
    }

    private var selectedShortcut: HostLayoutShortcut {
        HostLayoutShortcut(rawValue: shortcutRawValue) ?? .controlSpace
    }

    private var layoutBinding: Binding<KeyboardLayout> {
        Binding(
            get: { selectedLayout },
            set: { selectLayout($0, synchronizeHost: true) }
        )
    }

    private var shortcutBinding: Binding<HostLayoutShortcut> {
        Binding(
            get: { selectedShortcut },
            set: { shortcutRawValue = $0.rawValue }
        )
    }

    private func selectLayout(_ layout: KeyboardLayout, synchronizeHost: Bool) {
        guard layout != selectedLayout else { return }
        layoutRawValue = layout.rawValue
        inputWarning = nil

        if synchronizeHost {
            let command = selectedShortcut.command
            ble.sendKeyTap(modifiers: command.modifiers, hidKeycode: command.keycode)
        }
    }

    private func sendLayoutShortcut() {
        let command = selectedShortcut.command
        ble.sendKeyTap(modifiers: command.modifiers, hidKeycode: command.keycode)
    }

    private func handleReturnKey() {
        ble.sendKeyTap(modifiers: 0, hidKeycode: HID.keyEnter)
    }

    private func handleBackspaceWhenEmpty() {
        ble.sendKeyTap(modifiers: 0, hidKeycode: HID.keyBackspace)
    }

    private func handleTextChange(oldText: String, newText: String) {
        guard !newText.contains("\n"), !newText.contains("\r") else {
            handleReturnKey()
            return
        }

        let commonPrefixLength = zip(oldText, newText).prefix { $0 == $1 }.count
        let deletedCount = oldText.count - commonPrefixLength
        let insertedCharacters = newText.dropFirst(commonPrefixLength)
        var taps: [(modifiers: UInt8, keycode: UInt8)] = []
        var unsupported: [Character] = []
        var activeLayout = selectedLayout

        taps.append(contentsOf: repeatElement(
            (modifiers: UInt8(0), keycode: HID.keyBackspace),
            count: max(0, deletedCount)
        ))

        for character in insertedCharacters {
            if let inferredLayout = KeyboardLayout.inferred(from: character),
               inferredLayout != activeLayout {
                let layoutCommand = selectedShortcut.command
                taps.append((layoutCommand.modifiers, layoutCommand.keycode))
                activeLayout = inferredLayout
            }

            if let command = HID.mapCharacterToHID(character, layout: activeLayout) {
                taps.append((command.modifiers, command.keycode))
            } else {
                unsupported.append(character)
            }
        }

        if activeLayout != selectedLayout {
            layoutRawValue = activeLayout.rawValue
        }

        if !taps.isEmpty {
            ble.sendKeyTaps(taps)
        }

        if unsupported.isEmpty {
            inputWarning = nil
        } else {
            let sample = String(unsupported.prefix(6))
            inputWarning = "Немає HID-клавіш для: \(sample)"
        }
    }

    private func pasteClipboard() {
        guard let clipboardText = UIPasteboard.general.string, !clipboardText.isEmpty else {
            inputWarning = "Буфер обміну порожній"
            return
        }
        let oldText = inputText
        let newText = oldText + clipboardText
        inputText = newText
        handleTextChange(oldText: oldText, newText: newText)
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "espremote", url.host == "send",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
              !text.isEmpty else {
            return
        }

        selectedTab = 0
        let oldText = inputText
        let newText = oldText + text
        inputText = newText
        handleTextChange(oldText: oldText, newText: newText)
    }
}

#Preview {
    ContentView()
}
