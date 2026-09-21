import XCTest

final class KanbanCaptureTests: XCTestCase {
    @MainActor func testCaptureAndKanban() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let input = app.textFields["Quick capture. Exclamation mark for due date, at sign for planned date, slash for project."]
        XCTAssertTrue(input.waitForExistence(timeout: 4))
        XCTAssertTrue(input.waitForExistence(timeout: 4))
        input.tap()
        input.typeText("Kanban smoke !tomorrow @Monday 9am /Inbox")
        XCTAssertTrue(app.staticTexts["Kanban smoke"].firstMatch.waitForExistence(timeout: 4))
        app.buttons["Add"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.alerts.firstMatch.waitForExistence(timeout: 4), system.buttons["Allow"].exists { system.buttons["Allow"].tap() }
        XCTAssertTrue(app.staticTexts["Kanban smoke"].firstMatch.waitForExistence(timeout: 4))
        app.tabBars.buttons["Boards"].tap()
        app.staticTexts["By status"].firstMatch.tap()
        let menu = app.buttons["Move or edit Kanban smoke"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Due in 1 day")).firstMatch.exists)
        // Details and custom/relative reminders persist alongside both task-date defaults.
        menu.tap()
        app.buttons["Edit"].tap()
        let details = app.textViews["Task details"].exists ? app.textViews["Task details"] : app.textFields["Task details"]
        details.tap()
        details.typeText("Longer description\nWith a second line of context.")
        let addReminder = app.buttons["Add reminder"]
        for _ in 0..<5 where !addReminder.isHittable { app.swipeUp() }
        XCTAssertTrue(addReminder.isHittable)
        addReminder.tap()
        let kinds = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remind me,"))
        for _ in 0..<5 where !kinds.firstMatch.isHittable { app.swipeUp() }
        kinds.firstMatch.tap()
        app.buttons["On a date and time"].tap()
        for _ in 0..<5 where !app.switches["Urgent"].firstMatch.isHittable { app.swipeUp() }
        app.switches["Urgent"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["Urgent"].firstMatch.value as? String, "1")
        addReminder.tap()
        app.swipeUp()
        let unit = app.buttons["reminder-unit"]
        for _ in 0..<5 where !unit.isHittable { app.swipeUp() }
        unit.tap()
        app.buttons["Months"].tap()
        let amount = app.steppers["reminder-amount"]
        for _ in 0..<5 where !amount.isHittable { app.swipeUp() }
        amount.buttons["reminder-amount-Increment"].tap()
        amount.buttons["reminder-amount-Increment"].tap()
        XCTAssertEqual(amount.value as? String, "3 months before")
        app.buttons["Save"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 4))
        menu.tap()
        app.buttons["Edit"].tap()
        XCTAssertEqual(details.value as? String, "Longer description\nWith a second line of context.")
        for _ in 0..<5 where !app.buttons["Remove reminder"].firstMatch.isHittable { app.swipeUp() }
        XCTAssertEqual(app.buttons.matching(identifier: "Remove reminder").count, 2)
        XCTAssertEqual(app.switches["Urgent"].firstMatch.value as? String, "1")
        app.buttons["Remove reminder"].firstMatch.tap()
        for _ in 0..<5 where !amount.isHittable { app.swipeUp() }
        XCTAssertEqual(amount.value as? String, "3 months before")
        app.buttons["Save"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 4))

        menu.tap()
        app.buttons["Move to In progress"].tap()
        app.buttons["More actions"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Task statuses"].tap()
        app.buttons["Add status"].tap()
        let option = try XCTUnwrap(app.textFields.matching(identifier: "Option name").allElementsBoundByIndex.last)
        XCTAssertTrue(option.waitForExistence(timeout: 4))
        option.tap()
        option.typeText("Ready")
        app.buttons["Save"].firstMatch.tap()
        app.buttons["Cancel"].tap()
        // Columns remain horizontally scrollable, including newly added ones.
        for _ in 0..<5 where !app.staticTexts["Ready"].firstMatch.isHittable {
            app.swipeLeft()
        }
        XCTAssertTrue(app.staticTexts["Ready"].firstMatch.isHittable)
    }
}

extension KanbanCaptureTests {
    @MainActor func testManualSortingSupportsDraggingAboveAndBelowCards() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let input = app.textFields["Quick capture. Exclamation mark for due date, at sign for planned date, slash for project."]
        XCTAssertTrue(input.waitForExistence(timeout: 4))
        for title in ["Sorting Alpha", "Sorting Bravo"] {
            input.tap()
            input.typeText(title)
            app.buttons["Add"].tap()
        }
        app.tabBars.buttons["Boards"].tap()
        app.staticTexts["By status"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Sort cards"].waitForExistence(timeout: 5))
        // Dismiss capture's keyboard before dragging; offscreen accessibility frames are not drop targets.
        app.swipeDown()
        app.buttons["Sort cards"].tap()
        app.buttons["Alphabetical (A–Z)"].tap()
        let alpha = app.otherElements["Card: Sorting Alpha"].firstMatch
        let bravo = app.otherElements["Card: Sorting Bravo"].firstMatch
        XCTAssertTrue(alpha.waitForExistence(timeout: 4))
        XCTAssertLessThan(alpha.frame.minY, bravo.frame.minY)
        app.buttons["Sort cards"].tap()
        app.buttons["Manual"].tap()
        // Upper half inserts before; lower half inserts after.
        bravo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.6, thenDragTo: alpha.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertTrue(app.buttons["Move or edit Sorting Bravo"].waitForExistence(timeout: 4))
        XCTAssertLessThan(bravo.frame.minY, alpha.frame.minY)
        bravo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.6, thenDragTo: alpha.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertLessThan(alpha.frame.minY, bravo.frame.minY)
        app.buttons["Move or edit Sorting Bravo"].tap()
        app.buttons["Move up"].tap()
        XCTAssertLessThan(bravo.frame.minY, alpha.frame.minY)
        app.terminate()
        app.launch()
        if !app.buttons["Sort cards"].waitForExistence(timeout: 2) {
            app.tabBars.buttons["Boards"].tap()
            app.staticTexts["By status"].firstMatch.tap()
        }
        XCTAssertTrue(bravo.waitForExistence(timeout: 4))
        XCTAssertLessThan(bravo.frame.minY, alpha.frame.minY)
    }
}
