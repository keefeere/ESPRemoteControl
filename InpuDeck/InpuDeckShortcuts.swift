import AppIntents
import Combine
import Foundation

@MainActor
final class ShortcutInbox: ObservableObject {
    static let shared = ShortcutInbox()

    @Published private(set) var pendingText: String?

    private let pendingTextKey = "shortcutInboxPendingText"

    private init() {
        pendingText = UserDefaults.standard.string(forKey: pendingTextKey)
    }

    func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        UserDefaults.standard.set(text, forKey: pendingTextKey)
        pendingText = text
    }

    func takePendingText() -> String? {
        guard let text = pendingText, !text.isEmpty else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingTextKey)
        pendingText = nil
        return text
    }
}

struct SendToInpuDeckIntent: AppIntent {
    static var title: LocalizedStringResource = "Send to InpuDeck"
    static var description = IntentDescription("Opens InpuDeck and types the supplied text through the selected Bluetooth connection.")
    static var openAppWhenRun = true

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to InpuDeck")
    }

    init() {}

    init(text: String) {
        self.text = text
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        ShortcutInbox.shared.enqueue(text)
        return .result(dialog: "Opening InpuDeck")
    }
}

struct InpuDeckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToInpuDeckIntent(),
            phrases: [
                "Send text with \(.applicationName)",
                "Send text to \(.applicationName)"
            ],
            shortTitle: "Send to InpuDeck",
            systemImageName: "keyboard"
        )
    }
}
