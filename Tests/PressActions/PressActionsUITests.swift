import XCTest

@MainActor
final class PressActionsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    private func assertCounts(_ name: String, _ counts: String, file: StaticString = #filePath, line: UInt = #line) {
        let label = app.staticTexts[name + "Counts"]
        let correct = expectation(for: NSPredicate(format: "label == %@", counts), evaluatedWith: label)
        wait(for: [correct], timeout: 3)
        XCTAssertEqual(label.label, counts, file: file, line: line)
    }

    func testShortThenLongThenShortForBothButtonShapes() {
        for name in ["language", "orientation"] {
            let button = app.buttons[name + "Button"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            // Coordinates synthesize real touch sequences, rather than invoking
            // the accessibility action or calling an action closure directly.
            let center = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.tap()
            assertCounts(name, "1:0")
            center.press(forDuration: 0.8)
            assertCounts(name, "1:1")
            center.tap()
            assertCounts(name, "2:1")
            center.press(forDuration: 0.8)
            assertCounts(name, "2:2")
        }
    }

    func testDragOutAndDisabledButtonsDoNotActivate() {
        for name in ["language", "orientation"] {
            let center = app.buttons[name + "Button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -100)))
            assertCounts(name, "0:0")
        }
        app.buttons["disableControls"].tap()
        let disabled = expectation(for: NSPredicate(format: "label == 'disabled'"), evaluatedWith: app.staticTexts["enabledState"])
        wait(for: [disabled], timeout: 3)
        for name in ["language", "orientation"] {
            XCTAssertFalse(app.buttons[name + "Button"].isEnabled)
            let center = app.buttons[name + "Button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.tap()
            center.press(forDuration: 0.8)
            assertCounts(name, "0:0")
        }
    }
}
