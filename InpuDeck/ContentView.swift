import SwiftUI
import AppIntents
import UIKit

struct ContentView: View {
    @StateObject private var ble = RemoteInputController()
    @StateObject private var shortcutInbox = ShortcutInbox.shared

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("targetKeyboardLayout") private var layoutRawValue = KeyboardLayout.englishUS.rawValue
    @AppStorage("hostLayoutShortcut") private var shortcutRawValue = HostLayoutShortcut.controlSpace.rawValue
    @AppStorage("trackpadZoomShortcut") private var trackpadZoomShortcutRawValue = TrackpadZoomShortcut.control.rawValue
    @AppStorage("jigglerIntervalIndex") private var jigglerIntervalIndex = 7
    @AppStorage("scannerBatchMode") private var scannerBatchMode = false
    @AppStorage("developerMode") private var developerMode = false
    @AppStorage("keepScreenAwake") private var keepScreenAwake = false
    @AppStorage("expertMode") private var expertMode = false
    @AppStorage("showAlternateKeyLegends") private var showAlternateKeyLegends = true
    @AppStorage("hideAlternateKeyLegendsInPortrait") private var hideAlternateKeyLegendsInPortrait = false
    @AppStorage("alternateKeyLegendScalePercent") private var alternateKeyLegendScalePercent = 72.0

    @State private var inputText = ""
    @State private var wantsFocus = false
    @State private var isSecureInput = false
    @State private var selectedTab = 0
    @State private var showsSettings = false
    @State private var inputWarning: String?
    @State private var pendingShortcutText: String?
    @State private var sendStatus: String?
    @State private var sendStatusToken = 0
    @State private var showsLayoutHelp = false
    @State private var showsPrivacyHelp = false
    @State private var jigglerEnabled = false
    @State private var showsJigglerNotice = false

    private let jigglerIntervals: [Double] = [0.5, 1, 2, 5, 7, 10, 15, 20]

    var body: some View {
        TabView(selection: $selectedTab) {
            inputPage
                .tabItem { tabItemLabel("Ввід", systemImage: "keyboard", assetName: "InputTabIcon") }
                .tag(0)

            RemoteKeyboardView(
                ble: ble,
                layout: layoutBinding,
                onLayoutChange: selectLayout,
                onShowSettings: showSettings
            )
            .tabItem { tabItemLabel("Клавіатура", systemImage: "keyboard") }
            .tag(1)

            toolsPage
                .tabItem { tabItemLabel("Інструменти", systemImage: "switch.2") }
                .tag(2)
        }
        .id(expertMode)
        .simultaneousGesture(tabSwipeGesture)
        .safeAreaInset(edge: .top, spacing: 0) {
            if selectedTab == 2 {
                connectionHeader
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue != 0 {
                wantsFocus = false
            }
        }
        .onChange(of: ble.isReady) { _, isReady in
            if isReady {
                sendPendingShortcutTextIfPossible()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                ble.becameActive()
                receiveSharedTextIfNeeded()
                receiveShortcutTextIfNeeded()
            } else if newPhase == .background {
                jigglerEnabled = false
                ble.enteredBackground()
            }
            updateIdleTimer()
        }
        .onChange(of: jigglerEnabled) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: keepScreenAwake) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: shortcutInbox.pendingText) { _, _ in
            receiveShortcutTextIfNeeded()
        }
        .onAppear {
            ble.start()
            receiveSharedTextIfNeeded()
            receiveShortcutTextIfNeeded()
            updateIdleTimer()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .task(id: "\(jigglerEnabled)-\(jigglerIntervalIndex)") {
            await runJiggler()
        }
        .sheet(isPresented: $showsSettings) {
            settingsView
        }
        .alert("Mouse Jiggler активний", isPresented: $showsJigglerNotice) {
            Button("Зрозуміло", role: .cancel) {}
        } message: {
            Text("Поки Jiggler увімкнений, iPhone не гаситиме екран. Це збільшує витрату батареї; при згортанні застосунку Jiggler автоматично вимкнеться.")
        }
    }

    private var inputPage: some View {
        VStack(spacing: 0) {
            // Keep the connection controls in normal layout flow rather than a
            // root safeAreaInset. The inset changed the ScrollView's effective
            // content origin on iPhone and allowed the first card to scroll under
            // the header, which also made its scanner/layout/privacy buttons
            // untappable.
            connectionHeader

            ScrollView {
                VStack(spacing: 12) {
                    typingCard
                    trackpadCard
                    mouseButtons
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(
                KeyboardDismissTapView {
                    wantsFocus = false
                }
            )
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
    }

    private var toolsPage: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    systemKeysCard
                    mediaKeysCard
                    audioDisplayKeysCard
                    numpadCard
                    mouseJigglerCard
                }
                .padding(.horizontal)
                .padding(.vertical, 14)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Інструменти")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var connectionHeader: some View {
        HStack(spacing: 8) {
            ConnectionStatusView(input: ble)

            Divider()
                .frame(height: 20)

            Button {
                showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Налаштування")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onEnded { value in
                let horizontalDistance = value.translation.width
                let verticalDistance = value.translation.height
                let edgeWidth = CGFloat(28)
                let screenWidth = UIScreen.main.bounds.width
                let startedAtLeftEdge = value.startLocation.x <= edgeWidth
                let startedAtRightEdge = value.startLocation.x >= screenWidth - edgeWidth

                guard startedAtLeftEdge || startedAtRightEdge,
                      abs(horizontalDistance) >= 120,
                      abs(horizontalDistance) > abs(verticalDistance) * 1.25 else {
                    return
                }

                withAnimation(.easeOut(duration: 0.2)) {
                    if startedAtRightEdge, horizontalDistance < 0, selectedTab < 2 {
                        selectedTab += 1
                    } else if startedAtLeftEdge, horizontalDistance > 0, selectedTab > 0 {
                        selectedTab -= 1
                    }
                }
            }
    }

    private func showSettings() {
        wantsFocus = false
        showsSettings = true
    }

    @ViewBuilder
    private func tabItemLabel(
        _ title: LocalizedStringKey,
        systemImage: String,
        assetName: String? = nil
    ) -> some View {
        if expertMode {
            if let assetName {
                tabAssetIcon(assetName)
                    .accessibilityLabel(title)
            } else {
                Image(systemName: systemImage)
                    .accessibilityLabel(title)
            }
        } else if let assetName {
            Label {
                Text(title)
            } icon: {
                tabAssetIcon(assetName)
            }
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private func tabAssetIcon(_ name: String) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 21)
    }

    @ViewBuilder
    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        if expertMode {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 24, height: 22)
                .frame(maxWidth: .infinity)
        } else {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
    }

    private var typingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if !expertMode {
                    Text("Авто · \(selectedLayout.shortName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                CodeScannerButton(
                    text: $inputText,
                    isReady: ble.isReady,
                    onPrepare: { wantsFocus = false },
                    onImmediateSend: { value in
                        sendText(value)
                        showSendStatus(localizedFormat("Скановано й надіслано через %@", ble.mode.title))
                    }
                )

                Button {
                    sendLayoutShortcut()
                } label: {
                    Image(systemName: "globe")
                        .frame(width: expertMode ? 26 : 30, height: expertMode ? 26 : 32)
                }
                .buttonStyle(ShortAndLongPressButtonStyle(
                    longPressLabel: localized("Пояснення кнопки"),
                    onLongPress: { if !expertMode { showsLayoutHelp = true } }
                ))
                .accessibilityLabel("Перемкнути розкладку на комп’ютері")
                .help("Надіслати скорочення зміни мови на комп’ютер")
                .popover(isPresented: $showsLayoutHelp) {
                    Text("Перемкнути розкладку на комп’ютері · \(selectedShortcut.displayName)")
                        .font(.callout)
                        .padding(12)
                        .presentationCompactAdaptation(.popover)
                }

                Button {
                    isSecureInput.toggle()
                } label: {
                    Image(systemName: isSecureInput ? "eye.slash" : "eye")
                        .frame(width: expertMode ? 26 : 32, height: expertMode ? 26 : 32)
                }
                .buttonStyle(ShortAndLongPressButtonStyle(
                    longPressLabel: localized("Пояснення кнопки"),
                    onLongPress: { if !expertMode { showsPrivacyHelp = true } }
                ))
                .accessibilityLabel(localized(isSecureInput ? "Показати текст" : "Приховати текст"))
                .help(localized(isSecureInput ? "Показати текст" : "Приховати текст"))
                .popover(isPresented: $showsPrivacyHelp) {
                    Text(localized(isSecureInput ? "Показати введений текст" : "Приховати введений текст"))
                        .font(.callout)
                        .padding(12)
                        .presentationCompactAdaptation(.popover)
                }
            }

            KeyCaptureTextField(
                text: $inputText,
                wantsFirstResponder: $wantsFocus,
                isSecure: isSecureInput,
                hidesPlaceholder: expertMode,
                onBeginEditing: {
                    if inputText.isEmpty, pendingShortcutText == nil {
                        isSecureInput = false
                    }
                },
                onTextChange: handleTextChange,
                onBackspaceWhenEmpty: handleBackspaceWhenEmpty
            )
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }

            HStack(spacing: 10) {
                Button {
                    pasteClipboard()
                } label: {
                    actionLabel("Вставити", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Вставити")

                Button {
                    wantsFocus = false
                    inputText = ""
                    inputWarning = nil
                } label: {
                    actionLabel("Очистити", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Очистити")

                Button {
                    resendInputText()
                } label: {
                    actionLabel("Надіслати", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.isEmpty || !ble.isReady)
                .accessibilityLabel("Надіслати")
            }
            .font(.caption.weight(.semibold))

            if let pendingShortcutText {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Переданий текст готовий", systemImage: "square.and.arrow.down")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(localized(ble.isReady ? "Надсилання…" : "Очікується підключення"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(maskedPendingText(pendingShortcutText))
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            sendPendingShortcutTextIfPossible()
                        } label: {
                            actionLabel("Надіслати", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!ble.isReady)
                        .accessibilityLabel("Надіслати")

                        Button(role: .destructive) {
                            self.pendingShortcutText = nil
                        } label: {
                            actionLabel("Скасувати", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Скасувати")
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let sendStatus {
                Label(sendStatus, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .task(id: sendStatusToken) {
                        do {
                            try await Task.sleep(for: .seconds(3))
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        self.sendStatus = nil
                    }
            }

            if let inputWarning {
                Label(inputWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !expertMode {
                Text("Мова визначається автоматично. Для голосового введення натисніть мікрофон на системній клавіатурі iOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var trackpadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !expertMode {
                HStack {
                    Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left")
                        .font(.headline)
                    Spacer()
                    Text("1 — клік · 2 — правий · 3 — середній")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            TrackpadView(
                onMove: { ble.sendMouseMove(dx: $0, dy: $1) },
                onTap: { fingers in
                    let button: UInt8 = switch fingers {
                    case 3: 3
                    case 2: 2
                    default: 1
                    }
                    ble.sendMouseClick(button: button)
                },
                onScroll: { ble.sendMouseScroll(dx: $0, dy: $1) },
                onZoom: { sendTrackpadZoom($0) },
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

            if !expertMode {
                Text("Подвійний тап + утримання другого дотику — drag. Вертикальний рух уздовж правої грані — edge scroll.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var mouseButtons: some View {
        HStack(spacing: 10) {
            PressableKeyButton(
                title: expertMode ? "" : localized("Ліва кнопка"),
                minHeight: 48,
                onPress: { ble.sendMouseButtonDown(button: 1) },
                onRelease: { ble.sendMouseButtonUp(button: 1) }
            )
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Ліва кнопка")

            PressableKeyButton(
                title: expertMode ? "" : localized("Права кнопка"),
                minHeight: 48,
                onPress: { ble.sendMouseButtonDown(button: 2) },
                onRelease: { ble.sendMouseButtonUp(button: 2) }
            )
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Права кнопка")
        }
    }

    private var systemKeysCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Системні клавіші", systemImage: "keyboard.badge.ellipsis")
                .font(.headline)

            toolGrid {
                keyboardToolKey("Print Screen", keycode: HID.keyPrintScreen)
                keyboardToolKey("Context Menu", keycode: HID.keyApplication)
                keyboardToolKey("Lock PC · Win+L", keycode: HID.keyL, modifiers: HID.modLeftGUI)
                keyboardToolKey("Pause", keycode: HID.keyPause)
                keyboardToolKey("Page Up", keycode: HID.keyPageUp)
                keyboardToolKey("Page Down", keycode: HID.keyPageDown)
                keyboardToolKey("Scroll Lock", keycode: HID.keyScrollLock)
                consumerToolKey("Power", usage: HIDConsumerUsage.power, prominent: true)
                consumerToolKey("Sleep", usage: HIDConsumerUsage.sleep)
            }

            if !expertMode {
                Text("Кнопки поводяться як клавіші апаратної клавіатури: натискання тримає HID usage, відпускання його відпускає. Power, Sleep і Win+L залежать від підтримки та політик ОС.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var mediaKeysCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Медіа", systemImage: "playpause")
                .font(.headline)

            toolGrid {
                consumerToolKey("Play / Pause", usage: HIDConsumerUsage.playPause)
                consumerToolKey("Next", usage: HIDConsumerUsage.nextTrack)
                consumerToolKey("Previous", usage: HIDConsumerUsage.previousTrack)
                consumerToolKey("Fast Forward", usage: HIDConsumerUsage.fastForward)
                consumerToolKey("Rewind", usage: HIDConsumerUsage.rewind)
                consumerToolKey("Shuffle", usage: HIDConsumerUsage.randomPlay)
                consumerToolKey("Repeat", usage: HIDConsumerUsage.repeatTrack)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var audioDisplayKeysCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Звук і дисплей", systemImage: "speaker.wave.2")
                .font(.headline)

            toolGrid {
                consumerToolKey("Volume +", usage: HIDConsumerUsage.volumeIncrement)
                consumerToolKey("Volume −", usage: HIDConsumerUsage.volumeDecrement)
                consumerToolKey("Mute", usage: HIDConsumerUsage.mute)
                systemMicrophoneMuteToolKey("Mute microphone")
                consumerToolKey("Brightness +", usage: HIDConsumerUsage.brightnessIncrement)
                consumerToolKey("Brightness −", usage: HIDConsumerUsage.brightnessDecrement)
            }

            if !expertMode {
                Text("Mute microphone використовує стандарт USB-IF HUTRR110 System Microphone Mute. Підтримка системного mute залежить від ОС.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var numpadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Numpad", systemImage: "rectangle.grid.3x2")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                keyboardToolKey("Num", keycode: HID.keyNumLock)
                keyboardToolKey("/", keycode: HID.keyKeypadSlash)
                keyboardToolKey("*", keycode: HID.keyKeypadAsterisk)
                keyboardToolKey("−", keycode: HID.keyKeypadMinus)
                keyboardToolKey("7", keycode: HID.keyKeypad7)
                keyboardToolKey("8", keycode: HID.keyKeypad8)
                keyboardToolKey("9", keycode: HID.keyKeypad9)
                keyboardToolKey("+", keycode: HID.keyKeypadPlus)
                keyboardToolKey("4", keycode: HID.keyKeypad4)
                keyboardToolKey("5", keycode: HID.keyKeypad5)
                keyboardToolKey("6", keycode: HID.keyKeypad6)
                keyboardToolKey("Enter", keycode: HID.keyKeypadEnter)
                keyboardToolKey("1", keycode: HID.keyKeypad1)
                keyboardToolKey("2", keycode: HID.keyKeypad2)
                keyboardToolKey("3", keycode: HID.keyKeypad3)
                keyboardToolKey(".", keycode: HID.keyKeypadPeriod)
                keyboardToolKey("0", keycode: HID.keyKeypad0)
            }

            if !expertMode {
                Text("Це окремі Keyboard/Keypad HID usages, а не цифри верхнього ряду. Num Lock і поведінка десяткової клавіші залежать від ОС та активної розкладки клавіатури.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var mouseJigglerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Mouse Jiggler", systemImage: "cursorarrow.motionlines")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { jigglerEnabled },
                    set: { enabled in
                        jigglerEnabled = enabled
                        if enabled, !expertMode { showsJigglerNotice = true }
                    }
                ))
                    .labelsHidden()
            }

            Text(localizedFormat(
                jigglerEnabled ? "Активний · пауза %@ с" : "Вимкнений · пауза %@ с",
                jigglerIntervalLabel(jigglerInterval)
            ))
            .font(.caption.weight(.semibold))
            .foregroundStyle(jigglerEnabled ? Color.accentColor : Color.secondary)

            Slider(
                value: Binding(
                    get: { Double(safeJigglerIntervalIndex) },
                    set: { jigglerIntervalIndex = Int($0.rounded()) }
                ),
                in: 0...Double(jigglerIntervals.count - 1),
                step: 1
            )
            .accessibilityLabel("Пауза Mouse Jiggler")
            .accessibilityValue(localizedFormat("%@ секунд", jigglerIntervalLabel(jigglerInterval)))

            HStack(spacing: 0) {
                ForEach(Array(jigglerIntervals.enumerated()), id: \.offset) { index, interval in
                    VStack(spacing: 2) {
                        Capsule()
                            .fill(index == safeJigglerIntervalIndex ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: 2, height: 6)
                        Text(jigglerIntervalLabel(interval))
                            .font(.system(size: 9, weight: index == safeJigglerIntervalIndex ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(index == safeJigglerIntervalIndex ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            if !expertMode {
                Text("Рухається на 1 HID-крок і повертається назад, тому курсор практично не зміщується. Поки Jiggler активний, екран не гасне; при переході iOS у background він автоматично вимикається.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func toolGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            content()
        }
    }

    private func keyboardToolKey(
        _ title: String,
        keycode: UInt8,
        modifiers: UInt8 = 0
    ) -> some View {
        PressableKeyButton(
            title: title,
            isCompact: true,
            fontSize: 13,
            minHeight: 46,
            onPress: {
                ble.sendKeyDown(modifiersMask: modifiers, keycode: keycode)
            },
            onRelease: {
                ble.sendKeyUp(keycode: keycode)
                if modifiers != 0 { ble.setModifiers(0) }
            }
        )
        .frame(maxWidth: .infinity)
        .disabled(!ble.isReady)
    }

    private func consumerToolKey(
        _ title: String,
        usage: UInt16,
        prominent: Bool = false
    ) -> some View {
        PressableKeyButton(
            title: title,
            isProminent: prominent,
            isCompact: true,
            fontSize: 13,
            minHeight: 46,
            onPress: { ble.sendConsumerDown(usage: usage) },
            onRelease: { ble.sendConsumerUp() }
        )
        .frame(maxWidth: .infinity)
        .disabled(!ble.isReady)
    }

    private func systemMicrophoneMuteToolKey(_ title: String) -> some View {
        PressableKeyButton(
            title: title,
            isCompact: true,
            fontSize: 13,
            minHeight: 46,
            onPress: { ble.sendSystemMicrophoneMuteDown() },
            onRelease: { ble.sendSystemMicrophoneMuteUp() }
        )
        .frame(maxWidth: .infinity)
        .disabled(!ble.isReady)
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Не вимикати екран", isOn: $keepScreenAwake)
                    Toggle("Режим експерта", isOn: $expertMode)
                } footer: {
                    if !expertMode {
                        Text("Не дає iPhone автоматично гасити екран, поки InpuDeck відкритий. Звичайне блокування екрана відновлюється у background або після вимкнення цього режиму; тривала робота збільшує витрату батареї.")
                        Text("Режим експерта ховає необов’язкові пояснення, підписи action-кнопок і текст у зонах тачпада. Назви налаштувань, стани, помилки та підписи клавіш залишаються.")
                    }
                }

                Section("Перемикання розкладки на комп’ютері") {
                    Picker("Комбінація", selection: shortcutBinding) {
                        ForEach(HostLayoutShortcut.allCases) { shortcut in
                            Text(shortcut.displayName).tag(shortcut)
                        }
                    }
                    if !expertMode {
                        Text("Коротке натискання EN/UA змінює розкладку телефона й надсилає цю комбінацію. Довге натискання змінює лише розкладку телефона.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Позначення клавіш") {
                    Toggle("Показувати другу розкладку", isOn: $showAlternateKeyLegends)
                    Toggle(
                        "Ховати у портретній орієнтації",
                        isOn: $hideAlternateKeyLegendsInPortrait
                    )
                    .disabled(!showAlternateKeyLegends)

                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(
                            "Розмір додаткових символів",
                            value: "\(Int(alternateKeyLegendScalePercent.rounded()))%"
                        )
                        Slider(
                            value: $alternateKeyLegendScalePercent,
                            in: 40...100,
                            step: 5
                        )
                    }
                    .disabled(!showAlternateKeyLegends)

                    if !expertMode {
                        Text("Активна розкладка показується по центру. Друга — у нижньому правому куті; відсоток задає її розмір відносно основного символу.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Тачпад") {
                    Picker("Pinch zoom", selection: $trackpadZoomShortcutRawValue) {
                        ForEach(TrackpadZoomShortcut.allCases) { shortcut in
                            Text(shortcut.displayName).tag(shortcut.rawValue)
                        }
                    }
                    if !expertMode {
                        Text("2 пальці скролять; pinch вмикається лише після помітної зміни відстані між пальцями. Подвійний тап + утримання другого дотику — drag; права грань — однопальцевий edge scroll; 2-finger tap — правий клік, 3-finger tap — середній.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Сканер") {
                    Toggle("Batch mode", isOn: $scannerBatchMode)
                    if !expertMode {
                        Text("У Batch mode камера не закривається після коду: кожен код одразу надсилається через HID, після нього автоматично надсилається Enter. Режим QR / 2D або Штрихкод перемикається у самому сканері й запам’ятовується.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Bluetooth") {
                    ConnectionStatusView(input: ble)
                }

                Section {
                    Toggle("Режим розробника", isOn: $developerMode)
                } footer: {
                    if !expertMode {
                        Text("Показує журнал підключення, ідентифікатори пристроїв і засоби діагностики Bluetooth.")
                    }
                }

                Section("Shortcuts") {
                    if !expertMode {
                        Text("Щоб надсилати з меню Share, у Shortcuts додай дію «Send to InpuDeck», підстав «Shortcut Input» у поле Text і в Details увімкни Show in Share Sheet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ShortcutsLink()
                }

                Section("Версія") {
                    LabeledContent("InpuDeck", value: appVersion)
                    if !expertMode {
                        Text("Іконка клавіатури: Tabler Icons, MIT License.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

    private var selectedTrackpadZoomShortcut: TrackpadZoomShortcut {
        TrackpadZoomShortcut(rawValue: trackpadZoomShortcutRawValue) ?? .control
    }

    private var safeJigglerIntervalIndex: Int {
        min(max(jigglerIntervalIndex, 0), jigglerIntervals.count - 1)
    }

    private var jigglerInterval: Double {
        jigglerIntervals[safeJigglerIntervalIndex]
    }

    private func jigglerIntervalLabel(_ interval: Double) -> String {
        interval == 0.5 ? "0.5" : String(Int(interval))
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = (keepScreenAwake || jigglerEnabled) && scenePhase == .active
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return developerMode ? "\(version) (\(build))" : version
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

    private func sendTrackpadZoom(_ step: Int) {
        guard step != 0 else { return }
        let command = selectedTrackpadZoomShortcut.command(for: step)
        ble.sendKeyTap(modifiers: command.modifiers, hidKeycode: command.keycode)
    }

    private func handleBackspaceWhenEmpty() {
        ble.sendKeyTap(modifiers: 0, hidKeycode: HID.keyBackspace)
    }

    private func handleTextChange(oldText: String, newText: String) {
        let mutation = TextMutationPlanner.makePlan(from: oldText, to: newText)
        var taps: [(modifiers: UInt8, keycode: UInt8)] = []

        taps.append(contentsOf: repeatElement(
            (modifiers: UInt8(0), keycode: HID.keyBackspace),
            count: mutation.deletedCharacterCount
        ))

        if !taps.isEmpty {
            ble.sendKeyTaps(taps)
        }

        if mutation.insertedText.isEmpty {
            inputWarning = nil
        }

        sendText(mutation.insertedText)
    }

    private func pasteClipboard() {
        guard let clipboardText = UIPasteboard.general.string, !clipboardText.isEmpty else {
            inputWarning = localized("Буфер обміну порожній")
            return
        }
        let oldText = inputText
        let newText = oldText + clipboardText
        inputText = newText
        handleTextChange(oldText: oldText, newText: newText)
    }

    private func receiveShortcutTextIfNeeded() {
        guard let text = shortcutInbox.takePendingText() else { return }
        queueIncomingText(text)
    }

    private func receiveSharedTextIfNeeded() {
        guard let text = ShareTextInbox.take() else { return }
        queueIncomingText(text)
    }

    private func queueIncomingText(_ text: String) {
        guard !text.isEmpty else { return }
        selectedTab = 0
        wantsFocus = false
        isSecureInput = true
        sendStatus = nil

        if let pendingShortcutText, !pendingShortcutText.isEmpty {
            self.pendingShortcutText = pendingShortcutText + "\n" + text
        } else {
            pendingShortcutText = text
        }

        sendPendingShortcutTextIfPossible()
    }

    private func sendPendingShortcutTextIfPossible() {
        guard ble.isReady, let text = pendingShortcutText, !text.isEmpty else { return }
        pendingShortcutText = nil
        sendText(text)
        showSendStatus(localizedFormat("Надіслано через %@", ble.mode.title))
    }

    private func resendInputText() {
        guard ble.isReady, !inputText.isEmpty else { return }
        sendText(inputText)
        showSendStatus(localizedFormat("Надіслано через %@", ble.mode.title))
    }

    private func sendText(_ text: String) {
        guard !text.isEmpty else { return }

        let plan = TextTypingPlanner.makePlan(
            for: text,
            startingLayout: selectedLayout,
            layoutShortcut: selectedShortcut
        )

        if plan.finalLayout != selectedLayout {
            layoutRawValue = plan.finalLayout.rawValue
        }

        if !plan.taps.isEmpty {
            ble.sendKeyTaps(plan.taps)
        }

        if plan.unsupportedCharacters.isEmpty {
            inputWarning = nil
        } else {
            let sample = String(plan.unsupportedCharacters.prefix(6))
            inputWarning = localizedFormat("Немає HID-клавіш для: %@", sample)
        }
    }

    private func showSendStatus(_ message: String) {
        sendStatus = message
        sendStatusToken += 1
    }

    private func maskedPendingText(_ text: String) -> String {
        guard isSecureInput else { return text }
        return String(repeating: "•", count: min(max(text.count, 8), 24))
    }

    private func runJiggler() async {
        guard jigglerEnabled else { return }

        while !Task.isCancelled, jigglerEnabled {
            let pauseMilliseconds = Int64(jigglerInterval * 1_000)
            do {
                try await Task.sleep(for: .milliseconds(pauseMilliseconds))
            } catch {
                return
            }

            guard jigglerEnabled, scenePhase == .active else { continue }
            ble.sendMouseMove(dx: 1, dy: 0)

            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }

            guard jigglerEnabled, scenePhase == .active else { continue }
            ble.sendMouseMove(dx: -1, dy: 0)
        }
    }
}

#Preview {
    ContentView()
}
