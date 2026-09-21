#if os(macOS)
import XCTest

final class TaskEditorTests: XCTestCase {
    @MainActor func testReusableContextAppearsOnTask() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let name = "Matter \(UUID().uuidString.prefix(6))"
        app.descendants(matching: .any)["workspace-contexts"].firstMatch.click()
        XCTAssertEqual(app.sheets.count, 0, "Contexts is a workspace, not a modal")
        app.descendants(matching: .any)["new-context"].firstMatch.click()
        app.menuItems["Blank context"].click()
        let contextName = app.textFields["Context name"]
        XCTAssertTrue(contextName.waitForExistence(timeout: 5))
        contextName.click()
        contextName.typeText(name)
        app.menuButtons["Add field"].click()
        app.menuItems["Identifier"].click()
        let fieldName = app.textFields["Field name"]
        fieldName.click()
        fieldName.typeText("Matter number")
        let value = app.textFields["Matter number"]
        value.click()
        value.typeText("MAT-123")
        app.buttons["Save"].click()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["workspace-active"].firstMatch.click()
        app.buttons["new-task"].click()
        let title = app.textFields["Task title"]
        title.click()
        title.typeText(name)
        app.buttons["Save"].click()
        let details = app.buttons["Details for \(name)"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        app.buttons["Edit title: \(name)"].rightClick()
        app.menuItems["Attach context"].click()
        app.menuItems[name].click()
        XCTAssertEqual(app.sheets.count, 0, "Quick attachment saves without opening an editor")
        app.buttons["Edit title: \(name)"].rightClick()
        app.menuItems["Attach context"].click()
        XCTAssertFalse(app.menuItems[name].isEnabled, "A direct attachment cannot be added twice")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        details.click()
        app.buttons["Attach or override contexts…"].click()
        XCTAssertTrue(app.staticTexts["MAT-123"].waitForExistence(timeout: 5))
        app.buttons["save-context-attachments"].click()
        XCTAssertTrue(app.staticTexts["Matter number: MAT-123"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertEqual(app.buttons["Edit title: \(name)"].value as? String, "\(name) · MAT-123")

        app.descendants(matching: .any)["workspace-contexts"].firstMatch.click()
        app.buttons[name].click()
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertTrue(app.buttons["Edit title: \(name)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Attached to task"].exists)
        XCTAssertTrue(app.buttons["Open project Inbox"].exists)
        let filter = app.textFields["Filter tasks in this context"]
        filter.click()
        filter.typeText("does not match")
        XCTAssertTrue(app.staticTexts["No tasks match these filters."].exists)
        filter.typeKey("a", modifierFlags: .command)
        filter.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.buttons["Edit title: \(name)"].exists)
        app.buttons["Open project Inbox"].click()
        XCTAssertTrue(app.buttons["new-task"].waitForExistence(timeout: 5))
        app.buttons["project-inbox"].rightClick()
        app.menuItems["Attach context"].click()
        app.menuItems[name].click()
        XCTAssertEqual(app.sheets.count, 0)
        app.buttons["new-task"].click()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Inherited \(name)")
        app.buttons["Save"].click()
        let inherited = app.buttons["Edit title: Inherited \(name)"]
        XCTAssertTrue(inherited.waitForExistence(timeout: 5))
        XCTAssertEqual(inherited.value as? String, "\(name) · MAT-123")
    }

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
