import Foundation

struct TextMutationPlan: Equatable {
    let deletedCharacterCount: Int
    let insertedText: String
}

/// Converts the native editor's latest committed value into suffix operations
/// for the remote computer. This covers ordinary typing, paste, and iOS
/// dictation revising the end of an already committed phrase.
enum TextMutationPlanner {
    static func makePlan(from oldText: String, to newText: String) -> TextMutationPlan {
        let commonPrefixLength = zip(oldText, newText).prefix { $0 == $1 }.count
        return TextMutationPlan(
            deletedCharacterCount: oldText.count - commonPrefixLength,
            insertedText: String(newText.dropFirst(commonPrefixLength))
        )
    }
}
