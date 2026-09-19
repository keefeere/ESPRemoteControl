import Foundation

/// Localizes strings that flow through UIKit or model state instead of a SwiftUI
/// `LocalizedStringKey`. Keeping the Ukrainian source text as the key makes new
/// untranslated UI fall back to the project's original language.
func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: .current, arguments: arguments)
}
