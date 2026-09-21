import XCTest

final class WorkspaceTests: XCTestCase {
    @MainActor func testNavigationCaptureAndCompletion() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let input = app.textFields["Quick capture. Exclamation mark for due date, at sign for planned date, slash for project."]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.buttons["new-task"].tap()
        XCTAssertTrue(app.textFields["Task title"].exists || app.textViews["Task title"].exists)
        app.buttons["Cancel"].tap()

        input.tap()
        input.typeText("Plan a quieter week")
        app.buttons["Add"].tap()
        let complete = app.buttons["Complete Plan a quieter week"]
        XCTAssertTrue(complete.waitForExistence(timeout: 4))
        screenshot("iPhone — Tasks", app: app)
        complete.tap()
        app.segmentedControls.buttons["Completed"].tap()
        let reopen = app.buttons["Mark Plan a quieter week incomplete"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 4))
        reopen.tap()
        app.segmentedControls.buttons["To do"].tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 4))

        app.tabBars.buttons["Projects"].tap()
        app.staticTexts["Inbox"].firstMatch.tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 4))
        app.tabBars.buttons["Boards"].tap()
        app.staticTexts["By status"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Move or edit Plan a quieter week"].waitForExistence(timeout: 4))
        screenshot("iPhone — Board", app: app)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 4))
        app.buttons["Date & project shortcuts"].tap()
        XCTAssertTrue(app.staticTexts["A task, in a sentence."].waitForExistence(timeout: 4))
        app.buttons["Got it"].tap()
    }

    @MainActor func testDarkModeAndLargeText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleInterfaceStyle", "Dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launch()
        XCTAssertTrue(app.buttons["new-task"].waitForExistence(timeout: 5))
        screenshot("iPhone — Dark, large text", app: app)
        app.tabBars.buttons["Projects"].tap()
        XCTAssertTrue(app.staticTexts["Inbox"].firstMatch.waitForExistence(timeout: 4))
        screenshot("iPhone — Projects, large text", app: app)
    }

    @MainActor private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
