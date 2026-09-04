import UIKit

/// A persistent named pasteboard is available to the app and its extension
/// because SideStore signs both with the same Apple team. It avoids an App
/// Group entitlement, which a free signing profile cannot provision.
enum ShareTextInbox {
    private static let pasteboardName = UIPasteboard.Name("com.keefeere.ESPRemoteControl.shared-text")

    static func enqueue(_ text: String) -> Bool {
        guard !text.isEmpty, let pasteboard = UIPasteboard(name: pasteboardName, create: true) else {
            return false
        }
        pasteboard.setPersistent(true)
        pasteboard.string = text
        return true
    }

    static func take() -> String? {
        guard let pasteboard = UIPasteboard(name: pasteboardName, create: false),
              let text = pasteboard.string,
              !text.isEmpty else {
            return nil
        }
        pasteboard.items = []
        return text
    }
}
