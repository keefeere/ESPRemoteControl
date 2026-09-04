import Foundation

/// Compact URL handoff between the Share extension and its containing app.
/// Keeping the Bluetooth session in the app preserves the selected route and
/// the existing paired direct-HID host.
enum ShareTextHandoff {
    static let scheme = "espremote"
    static let host = "send"

    static func url(for text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url
    }

    static func text(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
              !text.isEmpty else {
            return nil
        }
        return text
    }
}
