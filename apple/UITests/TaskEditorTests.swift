#if os(macOS)
import XCTest

final class TaskEditorTests: XCTestCase {
    @MainActor func testInlineEditingClickAwayAndValidation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let capture = app.textFields["Quick capture. Exclamation mark for due date, at sign for planned date, slash for project."]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        let name = "Inline \(UUID().uuidString.prefix(6))"
        capture.click()
        capture.typeText(name)
        app.buttons["Add"].click()
        let edit = app.buttons["Edit title: \(name)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        let input = app.textFields["Inline task title"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeKey("a", modifierFlags: .command)
        input.typeText("\(name) revised /In")
        app.buttons["Use project Inbox"].click()
        XCTAssertTrue(input.exists, "Choosing a suggestion must not close the editor")
        // A real mouse event on blank workspace, not an AX action on another control.
        let outside = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.7))
        outside.click()
        let revised = app.buttons["Edit title: \(name) revised"]
        XCTAssertTrue(revised.waitForExistence(timeout: 5))
        XCTAssertFalse(input.exists)
        revised.click()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeKey("a", modifierFlags: .command)
        input.typeText("\(name) @not-a-date")
        outside.click()
        XCTAssertTrue(input.exists, "An invalid edit must not be silently discarded")
        XCTAssertFalse(app.buttons["Save title"].isEnabled)
        app.buttons["Cancel"].click()
        XCTAssertTrue(revised.waitForExistence(timeout: 5))
    }

    @MainActor func testDescriptionLayoutPlaceholderAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["new-task"].click()
        let title = app.textFields["Task title"]
        let details = app.textViews["Task details"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(details.exists)
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        // A full-width text editor, not a trailing value beside a permanent form label.
        XCTAssertGreaterThan(details.frame.width, title.frame.width * 0.8)
        XCTAssertLessThan(abs(details.frame.minX - title.frame.minX), 24)

        let name = "Editor \(UUID().uuidString.prefix(6))"
        let notes = "First line of notes.\nSecond line stays on the left."
        title.click()
        title.typeText(name)
        details.click()
        details.typeText(notes)
        XCTAssertEqual(details.value as? String, notes)
        XCTAssertFalse(app.staticTexts["Add a longer description, notes, or context…"].exists)
        app.buttons["Save"].click()
        let edit = app.buttons["Details for \(name)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertEqual(details.value as? String, notes)
        details.click()
        details.typeKey("a", modifierFlags: .command)
        details.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(details.value as? String, "")
        app.buttons["Save"].click()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertEqual(details.value as? String, "")
        app.buttons["Cancel"].click()
    }
}
#endif
