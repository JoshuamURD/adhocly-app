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

    @MainActor func testTodayFilteringSortingGroupingAndCompletion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let input = app.textFields["Quick capture. Exclamation mark for due date, at sign for planned date, slash for project."]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        for text in ["Today Alpha @today 12am", "Today Bravo !today 12am", "Today Charlie @today 12am !today 12am", "Today Undated"] {
            input.tap()
            input.typeText(text)
            app.buttons["Add"].tap()
        }
        app.segmentedControls.buttons["Today"].tap()
        let alpha = app.buttons["Complete Today Alpha"]
        let bravo = app.buttons["Complete Today Bravo"]
        let charlie = app.buttons["Complete Today Charlie"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4))
        XCTAssertTrue(bravo.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Complete Today Charlie").count, 1)
        XCTAssertFalse(app.buttons["Complete Today Undated"].exists)

        app.buttons["today-sort"].tap()
        app.buttons["Alphabetical"].tap()
        XCTAssertLessThan(alpha.frame.minY, bravo.frame.minY)
        XCTAssertLessThan(bravo.frame.minY, charlie.frame.minY)
        app.buttons["today-group"].tap()
        app.buttons["Status"].tap()
        alpha.tap()
        XCTAssertTrue(app.buttons["Mark Today Alpha incomplete"].waitForExistence(timeout: 4))
        screenshot("iPhone — Today by status", app: app)

        app.terminate()
        app.launch()
        app.segmentedControls.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["today-sort"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["today-sort"].label.contains("Alphabetical"))
        XCTAssertTrue(app.buttons["today-group"].label.contains("Status"))
        XCTAssertTrue(app.buttons["Mark Today Alpha incomplete"].exists)
        app.buttons["today-group"].tap()
        app.buttons["None"].tap()
        XCTAssertTrue(app.buttons["today-group"].label.contains("None"))
    }

    @MainActor func testScheduleViewsNavigationAndTaskEditing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let input = app.textFields["Quick capture. Exclamation mark for due date, at sign for planned date, slash for project."]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let title = "Schedule \(UUID().uuidString.prefix(6))"
        input.tap()
        input.typeText("\(title) @today 9am !today 9am")
        app.buttons["Add"].tap()
        app.tabBars.buttons["Schedule"].tap()
        let picker = app.segmentedControls["schedule-period"]
        XCTAssertTrue(picker.waitForExistence(timeout: 4))
        picker.buttons["Day"].tap()
        let planned = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), Planned")).firstMatch
        let due = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), Due")).firstMatch
        XCTAssertTrue(planned.waitForExistence(timeout: 4))
        XCTAssertTrue(due.exists)
        planned.tap()
        XCTAssertTrue(app.navigationBars["Edit task"].waitForExistence(timeout: 4))
        app.buttons["Cancel"].tap()
        let range = app.staticTexts["schedule-range"].label
        app.buttons["schedule-next"].tap()
        XCTAssertNotEqual(app.staticTexts["schedule-range"].label, range)
        XCTAssertFalse(planned.exists)
        app.buttons["schedule-previous"].tap()
        XCTAssertTrue(planned.waitForExistence(timeout: 4))
        screenshot("iPhone — Schedule day", app: app)
        for view in ["3 days", "Week", "Month"] {
            picker.buttons[view].tap()
            XCTAssertTrue(picker.buttons[view].isSelected)
            screenshot("iPhone — Schedule \(view)", app: app)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let monthDay = app.buttons["schedule-day-\(today)"]
        if !monthDay.isHittable { app.swipeUp() }
        XCTAssertTrue(monthDay.waitForExistence(timeout: 4))
        monthDay.tap()
        XCTAssertTrue(picker.buttons["Day"].isSelected)
        XCTAssertTrue(due.waitForExistence(timeout: 4))
        app.buttons["schedule-next"].tap()
        app.buttons["schedule-today"].tap()
        XCTAssertTrue(planned.waitForExistence(timeout: 4))
    }

    @MainActor func testProjectCreationAndSlashAutocomplete() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Projects"].tap()
        app.buttons["New project"].tap()
        let name = "Launch \(UUID().uuidString.prefix(6))"
        let projectName = app.textFields["Project name"]
        XCTAssertTrue(projectName.waitForExistence(timeout: 4))
        projectName.tap()
        projectName.typeText(name)
        app.buttons["Create project"].tap()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 4))

        app.tabBars.buttons["Tasks"].tap()
        let input = app.textFields["Quick capture. Exclamation mark for due date, at sign for planned date, slash for project."]
        input.tap()
        input.typeText("Prepare launch /Launch")
        let suggestion = app.buttons["Use project \(name)"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 4))
        suggestion.tap()
        app.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["Complete Prepare launch"].waitForExistence(timeout: 4))

        let newName = "Research \(UUID().uuidString.prefix(6))"
        let capture = "Read notes /\(newName)"
        input.tap()
        input.typeText(capture)
        app.buttons["Add"].tap()
        XCTAssertTrue(projectName.waitForExistence(timeout: 4))
        XCTAssertEqual(projectName.value as? String, newName)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(input.value as? String, capture)
        XCTAssertFalse(app.buttons["Complete Read notes"].exists)
        app.buttons["Add"].tap()
        app.buttons["Create & add task"].tap()
        XCTAssertTrue(app.buttons["Complete Read notes"].waitForExistence(timeout: 4))
        app.tabBars.buttons["Projects"].tap()
        app.staticTexts[newName].firstMatch.tap()
        XCTAssertTrue(app.buttons["Complete Read notes"].waitForExistence(timeout: 4))
        screenshot("iPhone — Created project from capture", app: app)
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
