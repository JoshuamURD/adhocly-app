import Foundation
import XCTest
@testable import AdhoclyCore

final class CaptureTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func date(_ value: String) -> Date { LocalDateTime.date(from: value, calendar: calendar)! }
    private func parse(_ text: String, now: String = "2026-03-06T15:42", hour: Int = 9, minute: Int = 0) throws -> String {
        LocalDateTime.string(from: try NaturalDate.parse(text, now: date(now), defaultHour: hour, defaultMinute: minute, calendar: calendar), calendar: calendar)
    }

    func testRelativeDatesUseCalendarAcrossDSTAndConfigurableTime() throws {
        XCTAssertEqual(try parse("tomorrow"), "2026-03-07T09:00")
        XCTAssertEqual(try parse("two weeks from now"), "2026-03-20T09:00")
        XCTAssertEqual(try parse("in 2 weeks", hour: 10, minute: 45), "2026-03-20T10:45")
        XCTAssertEqual(try parse("Monday 9am"), "2026-03-09T09:00")
        XCTAssertEqual(try parse("tomorrow at 14:30"), "2026-03-07T14:30")
        XCTAssertEqual(try parse("tomorrow at 9"), "2026-03-07T09:00")
        XCTAssertEqual(try parse("tomorrow at noon"), "2026-03-07T12:00")
        XCTAssertEqual(try parse("in three hours"), "2026-03-06T18:42")
        XCTAssertEqual(try parse("next month", now: "2026-01-31T15:42"), "2026-02-28T09:00")
    }

    func testWeekdaysAndTimesChooseFutureOccurrence() throws {
        XCTAssertEqual(try parse("Monday 9am", now: "2026-03-09T08:00"), "2026-03-09T09:00")
        XCTAssertEqual(try parse("Monday 9am", now: "2026-03-09T10:00"), "2026-03-16T09:00")
        XCTAssertEqual(try parse("next Monday 9am", now: "2026-03-09T08:00"), "2026-03-16T09:00")
        XCTAssertEqual(try parse("9am", now: "2026-03-09T10:00"), "2026-03-10T09:00")
        XCTAssertEqual(try parse("Monday 12am"), "2026-03-09T00:00")
        XCTAssertEqual(try parse("2028-02-29 at 3pm"), "2028-02-29T15:00")
    }

    func testInvalidAndPartialDatesNeverSilentlyDropInput() {
        for text in ["tomorrow garbage", "some day", "2026-02-30", "tomorrow 25pm", "Monday 9:75am", "tomorrow and Friday"] {
            XCTAssertThrowsError(try parse(text), text)
        }
    }

    func testCapturePrefixesQuotesEscapesAndProjectMatching() throws {
        let projects = [Project(id: "inbox", name: "Inbox"), Project(id: "work", name: "Work / Personal")]
        let result = try Capture.parse("Send report !Monday 9am @two weeks from now /\"work / personal\"", projects: projects,
                                       now: date("2026-03-06T15:42"), calendar: calendar)
        XCTAssertEqual(result.task.title, "Send report")
        XCTAssertEqual(result.task.dueOn, "2026-03-09T09:00")
        XCTAssertEqual(result.task.plannedFor, "2026-03-20T09:00")
        XCTAssertEqual(result.task.projectId, "work")
        let literal = try Capture.parse(#"Email sam@example.com https://example.com \!important \@home \/folder"#, projects: projects)
        XCTAssertEqual(literal.task.title, "Email sam@example.com https://example.com !important @home /folder")
        XCTAssertNil(literal.task.dueOn)
        for text in ["Task !tomorrow !Monday", "Task /missing", "Task !", "!tomorrow", "Task /\"unclosed"] {
            XCTAssertThrowsError(try Capture.parse(text, projects: projects), text)
        }
    }

    func testInlineEditingPreservesUnspecifiedFieldsAndLiteralTitles() throws {
        let projects = [Project(id: "inbox", name: "Inbox"), Project(id: "work", name: "Work")]
        var original = TaskItem(title: #"Email sam@example.com \"draft\" !important @home /folder C:\notes"#)
        original.details = "Keep these notes"
        original.plannedFor = "2026-03-07T14:30"
        original.dueOn = "2026-03-09T16:00"
        original.completed = true
        original.statusId = "complete"
        original.properties = ["priority": "high"]
        original.repeatWeekday = 2
        original.reminders = [CustomReminder(kind: .due, offsetUnit: .days, offsetValue: 1)]
        let text = Capture.editingText(for: original.title)
        XCTAssertEqual(try Capture.parse(text, projects: projects).applying(to: original), original)
        for title in ["!important", "@home", "/path", "Read \\\"notes", "Task\\n@home", "https://example.com"] {
            XCTAssertEqual(try Capture.parse(Capture.editingText(for: title), projects: projects).task.title, title)
        }
        var expected = original
        expected.title = "Renamed"
        XCTAssertEqual(try Capture.parse("Renamed", projects: projects).applying(to: original), expected)
        expected.plannedFor = "2026-03-08T10:45"
        XCTAssertEqual(try Capture.parse("Renamed @2026-03-08 10:45", projects: projects, calendar: calendar).applying(to: original), expected)
        expected = original
        expected.title = "Moved"
        expected.projectId = "work"
        expected.project = "Work"
        expected.dueOn = "2026-03-10T09:00"
        XCTAssertEqual(try Capture.parse("Moved /Work !2026-03-10", projects: projects, calendar: calendar).applying(to: original), expected)
    }

    func testProjectCompletionAndNewProjectPreview() throws {
        let project = Project(id: "work", name: #"Work / Café ! @ \"quoted\""#)
        let projects = [Project(id: "inbox", name: "Inbox"), project]
        for input in ["Task /cafe !tomorrow @Monday", "Task !tomorrow /\"Work", "Task /"] {
            XCTAssertTrue(Capture.projectSuggestions(in: input, projects: projects).contains(project))
            let completed = Capture.completingProject(in: input, with: project)
            let result = try Capture.parse(completed, projects: projects, allowNewProject: true)
            XCTAssertEqual(result.task.projectId, project.id)
            XCTAssertNil(result.projectToCreate)
            if input.contains("!tomorrow") { XCTAssertNotNil(result.task.dueOn) }
            if input.contains("@Monday") { XCTAssertNotNil(result.task.plannedFor) }
        }
        for input in [#"Task \/work"#, "Task https://example.com", #"Task "/work""#, "Task /work /inbox"] {
            XCTAssertTrue(Capture.projectSuggestions(in: input, projects: projects).isEmpty, input)
            XCTAssertEqual(Capture.completingProject(in: input, with: project), input)
        }
        let result = try Capture.parse("Task /New project !tomorrow", projects: projects, allowNewProject: true)
        XCTAssertEqual(result.projectToCreate?.name, "New project")
        XCTAssertEqual(result.projectToCreate?.id, result.task.projectId)
        XCTAssertEqual(result.task.title, "Task")
        XCTAssertNotNil(result.task.dueOn)
        XCTAssertNil(try Capture.parse("Task /INBOX", projects: projects, allowNewProject: true).projectToCreate)
        for input in ["Task /New !invalid date", "Task /New /Another", "Task /", "/New", "Task /\"unclosed"] {
            XCTAssertThrowsError(try Capture.parse(input, projects: projects, allowNewProject: true), input)
        }
        let ambiguous = [Project(id: "a", name: "Work"), Project(id: "b", name: "work")]
        XCTAssertThrowsError(try Capture.parse("Task /WORK", projects: ambiguous, allowNewProject: true))
    }

    func testReminderPlanIncludesBothDatesAndRemovesCompletedDeletedPastTasks() {
        var task = TaskItem(title: "Reminder")
        task.plannedFor = "2026-03-07T09:00"
        task.dueOn = "2026-03-09T09:00"
        let plan = TaskReminders.upcoming(tasks: [task], now: date("2026-03-06T15:42"), calendar: calendar)
        XCTAssertEqual(plan.map(\.kind), ["planned", "due"])
        XCTAssertEqual(Set(plan.map(\.id)).count, 2)
        var changed = task
        changed.dueOn = "2026-03-10T09:00"
        let edited = TaskReminders.upcoming(tasks: [changed], now: date("2026-03-06T15:42"), calendar: calendar)
        XCTAssertEqual(edited.last?.id, plan.last?.id)
        XCTAssertNotEqual(edited.last?.date, plan.last?.date)
        task.completed = true
        XCTAssertTrue(TaskReminders.upcoming(tasks: [task], now: date("2026-03-06T15:42"), calendar: calendar).isEmpty)
        XCTAssertTrue(TaskReminders.upcoming(tasks: [], now: date("2026-03-06T15:42"), calendar: calendar).isEmpty)
        XCTAssertTrue(TaskReminders.upcoming(tasks: [changed], now: date("2027-01-01T00:00"), calendar: calendar).isEmpty)
    }
}

@MainActor
final class KanbanStoreTests: XCTestCase {
    private func file() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appending(path: "state.json")
    }

    func testOfflineStatusesPropertiesBoardsAndMovesSurviveRestart() throws {
        let file = file()
        let store = try TaskStore(fileURL: file)
        let original = store.statusField
        var status = original
        status.options[2].name = "Shipped"
        status.options.append(FieldOption(id: "review", name: "Review"))
        try store.saveField(status, replacing: original)
        let field = TaskField(id: "priority", name: "Priority", options: [FieldOption(id: "high", name: "High"), FieldOption(id: "low", name: "Low")])
        try store.saveField(field)
        let board = KanbanBoard(id: "priority", name: "Priorities", fieldId: field.id)
        try store.saveBoard(board)
        let task = TaskItem(title: "Offline card")
        try store.save(task)
        let lanes = Kanban.lanes(field: field, tasks: store.tasks, completeName: store.completeName)
        try store.move(task.id, to: lanes.first { $0.value == "high" }!, on: board)
        XCTAssertEqual(store.tasks[0].properties["priority"], "high")
        try store.move(task.id, to: lanes.last!, on: board)
        XCTAssertTrue(store.tasks[0].completed)
        XCTAssertEqual(store.tasks[0].statusId, "complete")
        try store.move(task.id, to: lanes.first { $0.value == "low" }!, on: board)
        XCTAssertFalse(store.tasks[0].completed)
        XCTAssertEqual(store.tasks[0].statusId, "todo")
        let statusLanes = Kanban.lanes(field: status, tasks: store.tasks, completeName: store.completeName)
        try store.move(task.id, to: statusLanes.first { $0.value == "review" }!, on: .status)
        let restored = try TaskStore(fileURL: file)
        XCTAssertEqual(restored.tasks[0].statusId, "review")
        XCTAssertEqual(restored.tasks[0].properties["priority"], "low")
        XCTAssertEqual(restored.completeName, "Shipped")
        XCTAssertEqual(restored.boards.count, 2)
        XCTAssertEqual(Kanban.laneID(task: restored.tasks[0], fieldId: "status"), "value:review")
        XCTAssertEqual(Kanban.laneID(task: restored.tasks[0], fieldId: "priority"), "value:low")
    }

    func testSpecialStatusesAndUsedOptionsCannotBeRemoved() throws {
        let store = try TaskStore(fileURL: file())
        let original = store.statusField
        var status = original
        status.options.removeAll { $0.id == "complete" }
        XCTAssertThrowsError(try store.saveField(status, replacing: original))
        status = original
        status.options.append(FieldOption(name: original.options[0].name))
        XCTAssertThrowsError(try store.saveField(status, replacing: original))
        var task = TaskItem(title: "Doing")
        task.statusId = "doing"
        try store.save(task)
        status = original
        status.options.removeAll { $0.id == "doing" }
        XCTAssertThrowsError(try store.saveField(status, replacing: original))
        task.properties["missing"] = "value"
        XCTAssertThrowsError(try store.save(task, replacing: store.tasks[0]))
    }

    func testStatusLaneOrderMatchesSettingsIncludingComplete() {
        var field = TaskField.status
        field.options.insert(field.options.remove(at: 2), at: 0)
        let lanes = Kanban.lanes(field: field, tasks: [], completeName: "Complete")
        XCTAssertEqual(lanes.map(\.name), field.options.map(\.name))
        XCTAssertTrue(lanes[0].isComplete)
    }

    func testTextAndNumberPropertyGroupingDoesNotMixCompleteWithValues() {
        let field = TaskField(id: "owner", name: "Owner", kind: .text)
        var first = TaskItem(title: "One")
        first.properties["owner"] = "Complete"
        var second = TaskItem(title: "Two")
        second.completed = true
        second.statusId = "complete"
        second.properties["owner"] = "Elsewhere"
        let lanes = Kanban.lanes(field: field, tasks: [first, second], completeName: "Done")
        XCTAssertEqual(lanes.map(\.id), ["unassigned", "value:Complete", "complete"])
        XCTAssertEqual(Kanban.laneID(task: first, fieldId: "owner"), "value:Complete")
        XCTAssertEqual(Kanban.laneID(task: second, fieldId: "owner"), "complete")
    }

    func testVersionOneOutboxMigratesWithoutChangingFrozenRequest() throws {
        let file = file()
        let store = try TaskStore(fileURL: file)
        try store.save(TaskItem(title: "Old pending task"))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json["formatVersion"] = 1
        var snapshot = json["snapshot"] as! [String: Any]
        snapshot.removeValue(forKey: "contexts"); snapshot.removeValue(forKey: "contacts"); snapshot.removeValue(forKey: "contextLinks"); snapshot.removeValue(forKey: "folders"); snapshot.removeValue(forKey: "boards"); snapshot.removeValue(forKey: "taskFields"); snapshot.removeValue(forKey: "protocolVersion")
        json["snapshot"] = snapshot
        var pending = json["pending"] as! [[String: Any]]
        var operation = pending[0]["operation"] as! [String: Any]
        var body = operation["body"] as! [String: Any]
        body.removeValue(forKey: "details"); body.removeValue(forKey: "reminders"); body.removeValue(forKey: "statusId"); body.removeValue(forKey: "properties")
        operation["body"] = body
        pending[0]["operation"] = operation
        var local = pending[0]["localTask"] as! [String: Any]
        local.removeValue(forKey: "details"); local.removeValue(forKey: "reminders"); local.removeValue(forKey: "statusId"); local.removeValue(forKey: "properties")
        pending[0]["localTask"] = local
        json["pending"] = pending
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let restored = try TaskStore(fileURL: file)
        XCTAssertEqual(restored.tasks[0].statusId, "todo")
        try restored.toggle(restored.tasks[0].id)
        let saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.formatVersion, 8)
        XCTAssertTrue(restored.folders.isEmpty)
        XCTAssertNil(restored.projects[0].folderId)
        XCTAssertNil(saved.pending[0].operation.body.details)
        XCTAssertEqual(restored.tasks[0].details, "")
        XCTAssertNil(saved.pending[0].operation.body.reminders)
        XCTAssertTrue(restored.tasks[0].reminders.isEmpty)
        XCTAssertNil(saved.pending[0].operation.body.statusId)
        XCTAssertNil(saved.pending[0].operation.body.properties)
        XCTAssertEqual(saved.pending[0].operation.id, operation["id"] as? String)
    }
}

extension CaptureTests {
    func testCustomRemindersKeepDefaultsFollowDatesAndPreserveWallClockAcrossDST() throws {
        var task = TaskItem(title: "Extra reminders")
        task.plannedFor = "2026-03-09T09:00"
        task.dueOn = "2026-03-10T09:00"
        task.reminders = [
            CustomReminder(at: "2026-03-06T18:00", urgent: true),
            CustomReminder(kind: .planned, offsetMinutes: 10_080),
            CustomReminder(kind: .due, offsetMinutes: 1_440),
            CustomReminder(kind: .due, offsetMinutes: 60)
        ]
        try TaskReminders.validate(task.reminders)
        let now = date("2026-03-01T00:00")
        let plan = TaskReminders.upcoming(tasks: [task], now: now, calendar: calendar)
        XCTAssertEqual(plan.count, 6)
        XCTAssertEqual(Set(plan.map(\.id)).count, 6)
        XCTAssertEqual(plan.map(\.wallClock), ["2026-03-02T09:00", "2026-03-06T18:00", "2026-03-09T09:00", "2026-03-09T09:00", "2026-03-10T08:00", "2026-03-10T09:00"])
        XCTAssertEqual(plan.filter(\.urgent).count, 1)
        let fixed = plan.first { $0.urgent }!
        task.plannedFor = "2026-03-16T09:00"
        task.reminders[0].urgent = false
        let changed = TaskReminders.upcoming(tasks: [task], now: now, calendar: calendar)
        XCTAssertEqual(changed.first { $0.id == fixed.id }?.wallClock, fixed.wallClock)
        XCTAssertEqual(changed.first { $0.id == fixed.id }?.urgent, false)
        XCTAssertEqual(changed.first { $0.id == plan[0].id }?.wallClock, "2026-03-09T09:00")
        task.dueOn = nil
        XCTAssertEqual(TaskReminders.upcoming(tasks: [task], now: now, calendar: calendar).count, 3)
        task.reminders.removeAll()
        XCTAssertEqual(TaskReminders.upcoming(tasks: [task], now: now, calendar: calendar).map(\.kind), ["planned"])
        task.completed = true
        XCTAssertTrue(TaskReminders.upcoming(tasks: [task], now: now, calendar: calendar).isEmpty)
    }

    func testReminderValidationAndPastDates() throws {
        let invalid = [
            CustomReminder(at: "2026-02-30T09:00"),
            CustomReminder(at: "2026-03-09T25:00"),
            CustomReminder(kind: .due, offsetMinutes: -60),
            CustomReminder(kind: .due, at: "2026-03-09T09:00", offsetMinutes: 60),
            CustomReminder(kind: .planned)
        ]
        for reminder in invalid { XCTAssertThrowsError(try TaskReminders.validate([reminder])) }
        let valid = CustomReminder(at: "2026-03-09T09:00")
        XCTAssertThrowsError(try TaskReminders.validate([valid, valid]))
        var task = TaskItem(title: "Past")
        task.reminders = [valid]
        try TaskReminders.validate(task.reminders)
        XCTAssertTrue(TaskReminders.upcoming(tasks: [task], now: date("2026-03-10T09:00"), calendar: calendar).isEmpty)
    }
}

extension KanbanStoreTests {
    func testBoardSortModesAndLegacyDefaults() throws {
        var a = TaskItem(title: "alpha"), b = TaskItem(title: "Bravo"), c = TaskItem(title: "Charlie")
        a.id = "a"; b.id = "b"; c.id = "c"
        a.createdAt = "2026-04-01T09:00:00Z"
        b.createdAt = "2026-04-01T09:00:00.100Z"
        c.createdAt = "2026-04-01T09:00:00.000Z"
        a.dueOn = "2026-04-03T09:00"; c.dueOn = "2026-04-02T09:00"
        b.plannedFor = "2026-04-03T09:00"; c.plannedFor = "2026-04-02T09:00"
        let tasks = [c, b, a]
        var board = try JSONDecoder().decode(KanbanBoard.self, from: Data(#"{"id":"status","name":"By status","fieldId":"status"}"#.utf8))
        XCTAssertEqual(board.sortMode, .created)
        XCTAssertTrue(board.manualOrder.isEmpty)
        for (mode, expected): (KanbanSort, [String]) in [(.created, ["b", "a", "c"]), (.due, ["c", "a", "b"]),
                                                        (.planned, ["c", "b", "a"]), (.alphabetical, ["a", "b", "c"])] {
            board.sortMode = mode
            XCTAssertEqual(Kanban.sorted(tasks, on: board).map(\.id), expected)
        }
        board.sortMode = .manual
        board.manualOrder = ["c", "a", "deleted"]
        XCTAssertEqual(Kanban.sorted(tasks, on: board).map(\.id), ["c", "a", "b"])
    }

    func testManualReorderingIsBoardSpecificDurableAndKeepsHiddenCards() throws {
        let file = file()
        let store = try TaskStore(fileURL: file)
        var cards: [TaskItem] = []
        for name in ["Alpha", "Bravo", "Charlie", "Delta"] {
            let task = TaskItem(title: name)
            try store.save(task)
            cards.append(task)
        }
        let second = KanbanBoard(name: "Independent", sortMode: .alphabetical)
        try store.saveBoard(second)
        var board = KanbanBoard.status
        board.sortMode = .alphabetical
        try store.saveBoard(board, replacing: .status)
        var manual = board
        manual.sortMode = .manual
        try store.saveBoard(manual, replacing: board)
        board = try XCTUnwrap(store.boards.first { $0.id == "status" })
        XCTAssertEqual(board.manualOrder, cards.map(\.id), "Entering manual mode keeps the displayed order")
        let lanes = Kanban.lanes(field: store.statusField, tasks: store.tasks, completeName: store.completeName)
        let todo = lanes[0], doing = lanes[1]
        let pending = store.pendingCount
        try store.move(cards[3].id, to: todo, on: board, relativeTo: cards[0].id)
        XCTAssertEqual(store.pendingCount, pending + 1, "Reordering must not edit task content or timestamps")
        board = try XCTUnwrap(store.boards.first { $0.id == "status" })
        XCTAssertEqual(board.manualOrder, [cards[3].id, cards[0].id, cards[1].id, cards[2].id])
        // Drop below Charlie, even if Bravo is hidden by search.
        try store.move(cards[0].id, to: todo, on: board, relativeTo: cards[2].id, after: true)
        board = try XCTUnwrap(store.boards.first { $0.id == "status" })
        XCTAssertEqual(board.manualOrder, [cards[3].id, cards[1].id, cards[2].id, cards[0].id])
        XCTAssertTrue(store.boards.contains(second))
        let unchanged = store.pendingCount
        try store.move(cards[0].id, to: todo, on: board, relativeTo: cards[0].id)
        XCTAssertEqual(store.pendingCount, unchanged)
        XCTAssertThrowsError(try store.move(cards[0].id, to: doing, on: board, relativeTo: cards[1].id))
        try store.move(cards[0].id, to: doing, on: board)
        board = try XCTUnwrap(store.boards.first { $0.id == "status" })
        try store.move(cards[1].id, to: doing, on: board, relativeTo: cards[0].id)
        let restored = try TaskStore(fileURL: file)
        let restoredBoard = try XCTUnwrap(restored.boards.first { $0.id == "status" })
        XCTAssertEqual(Kanban.sorted(restored.tasks, on: restoredBoard).filter { $0.statusId == "doing" }.map(\.id), [cards[1].id, cards[0].id])
        XCTAssertEqual(restoredBoard.sortMode, .manual)
        XCTAssertThrowsError(try store.move(cards[2].id, to: todo, on: board), "Stale boards cannot overwrite newer order")
        var invalid = restoredBoard
        invalid.manualOrder = [cards[0].id, cards[0].id]
        XCTAssertThrowsError(try restored.saveBoard(invalid, replacing: restoredBoard))
    }

    func testFailedManualMoveDoesNotPartiallyChangeLaneOrOrder() throws {
        let file = file()
        let store = try TaskStore(fileURL: file)
        let task = TaskItem(title: "Keep me")
        try store.save(task)
        var board = KanbanBoard.status
        board.sortMode = .manual
        try store.saveBoard(board, replacing: .status)
        board = try XCTUnwrap(store.boards.first { $0.id == "status" })
        let tasks = store.tasks, pending = store.pendingCount
        let lane = Kanban.lanes(field: store.statusField, tasks: tasks, completeName: store.completeName)[1]
        let directory = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory) // A file instead of a directory makes the atomic save fail.
        XCTAssertThrowsError(try store.move(task.id, to: lane, on: board))
        XCTAssertEqual(store.tasks, tasks)
        XCTAssertEqual(store.boards.first { $0.id == "status" }, board)
        XCTAssertEqual(store.pendingCount, pending)
    }
}


extension CaptureTests {
    func testDueCountdownUsesCalendarDaysRatherThan24Hours() {
        for (due, now, expected) in [
            ("2026-03-09T09:00", "2026-03-06T15:42", "Due in 3 days"),
            ("2026-03-09T00:01", "2026-03-08T23:59", "Due in 1 day"),
            ("2026-03-08T09:00", "2026-03-07T09:00", "Due in 1 day"), // 23-hour DST day
            ("2026-11-01T23:00", "2026-10-31T00:00", "Due in 1 day"), // 25-hour day
            ("2027-01-01T00:00", "2026-12-31T23:59", "Due in 1 day"),
            ("2026-03-09T18:00", "2026-03-09T09:00", "Due today"),
            ("2026-03-09T09:00", "2026-03-09T09:00", "Due today"),
            ("2026-03-09T09:00", "2026-03-09T18:00", "Overdue today"),
            ("2026-03-08T23:59", "2026-03-09T00:01", "1 day overdue"),
            ("2026-03-06T09:00", "2026-03-09T09:00", "3 days overdue")
        ] {
            XCTAssertEqual(LocalDateTime.dueLabel(for: date(due), now: date(now), calendar: calendar), expected)
        }
    }

    func testReminderUnitsAmountsMonthEndsAndLegacyRoundTrips() throws {
        var task = TaskItem(title: "Calendar offsets")
        for (unit, amount, anchor, expected): (CustomReminder.Unit, Int, String, String) in [
            (.minutes, 45, "2026-03-09T09:00", "2026-03-09T08:15"),
            (.hours, 3, "2026-03-09T09:00", "2026-03-09T06:00"),
            (.days, 4, "2026-03-09T09:00", "2026-03-05T09:00"),
            (.weeks, 2, "2026-03-09T09:00", "2026-02-23T09:00"),
            (.months, 1, "2026-03-31T09:00", "2026-02-28T09:00"),
            (.months, 1, "2028-03-31T09:00", "2028-02-29T09:00"),
            (.months, 3, "2026-03-31T09:00", "2025-12-31T09:00")
        ] {
            task.dueOn = anchor
            let reminder = CustomReminder(kind: .due, offsetUnit: unit, offsetValue: amount)
            try TaskReminders.validate([reminder])
            XCTAssertEqual(reminder.date(for: task, calendar: calendar), date(expected))
            XCTAssertEqual(try JSONDecoder().decode(CustomReminder.self, from: JSONEncoder().encode(reminder)), reminder)
        }
        for minutes in CustomReminder.offsets {
            let json = Data("{\"id\":\"old\",\"kind\":\"due\",\"offsetMinutes\":\(minutes),\"urgent\":false}".utf8)
            let reminder = try JSONDecoder().decode(CustomReminder.self, from: json)
            try TaskReminders.validate([reminder])
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(reminder)) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: json) as? NSDictionary)
            var edited = reminder
            let offset = try XCTUnwrap(reminder.relativeOffset)
            edited.setOffset(unit: offset.unit, value: offset.value)
            XCTAssertEqual(edited.date(for: task, calendar: calendar), reminder.date(for: task, calendar: calendar))
        }
        for reminder in [
            CustomReminder(kind: .due, offsetUnit: .days),
            CustomReminder(kind: .due, offsetValue: 1),
            CustomReminder(kind: .due, offsetUnit: .days, offsetValue: 0),
            CustomReminder(kind: .due, offsetUnit: .months, offsetValue: -1),
            CustomReminder(kind: .due, offsetUnit: .weeks, offsetValue: 1_000),
            CustomReminder(kind: .due, offsetMinutes: 60, offsetUnit: .hours, offsetValue: 1),
            CustomReminder(at: "2026-03-09T09:00", offsetUnit: .days, offsetValue: 1)
        ] { XCTAssertThrowsError(try TaskReminders.validate([reminder])) }
    }
}
