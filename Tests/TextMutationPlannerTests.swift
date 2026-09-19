import Foundation

@main
struct TextMutationPlannerTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        check(
            TextMutationPlanner.makePlan(from: "", to: "Привіт")
                == TextMutationPlan(deletedCharacterCount: 0, insertedText: "Привіт"),
            "A newly dictated phrase is appended"
        )
        check(
            TextMutationPlanner.makePlan(from: "Привіт світе", to: "Привіт, світе")
                == TextMutationPlan(deletedCharacterCount: 6, insertedText: ", світе"),
            "A dictation correction rewrites the changed suffix"
        )
        check(
            TextMutationPlanner.makePlan(from: "тест помилка", to: "тест правильно")
                == TextMutationPlan(deletedCharacterCount: 6, insertedText: "равильно"),
            "A revised final word becomes backspaces followed by replacement text"
        )
        check(
            TextMutationPlanner.makePlan(from: "слово", to: "слово")
                == TextMutationPlan(deletedCharacterCount: 0, insertedText: ""),
            "An unchanged callback sends nothing"
        )
        print("PASS: native text and dictation mutation planning")
    }
}
