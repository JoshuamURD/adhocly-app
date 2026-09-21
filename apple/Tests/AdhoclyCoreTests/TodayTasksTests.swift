import Foundation
import XCTest
@testable import AdhoclyCore

final class TodayTasksTests: XCTestCase {
    private func task(_ id: String, title: String? = nil, planned: String? = nil, due: String? = nil,
                      project: String = "Inbox", status: String = "todo") -> TaskItem {
        var task = TaskItem(title: title ?? id, projectId: project.lowercased(), project: project)
        task.id = id
        task.plannedFor = planned
        task.dueOn = due
        task.statusId = status
        task.completed = status == "complete"
        return task
    }

    func testTodayIncludesEitherDateOnceAndAllStatusesInLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Local March 8, but already March 9 in UTC; also the spring DST transition.
        let now = LocalDateTime.date(from: "2026-03-08T23:30", calendar: calendar)!
        let tasks = [
            task("planned", planned: "2026-03-08T00:00"),
            task("due", due: "2026-03-08T23:59"),
            task("both", planned: "2026-03-08T09:00", due: "2026-03-08T17:00"),
            task("done", due: "2026-03-08T08:00", status: "complete"),
            task("future-plan", planned: "2026-03-09T10:00", due: "2026-03-08T11:00"),
            task("overdue", due: "2026-03-07T23:59"),
            task("tomorrow", due: "2026-03-09T00:00"),
            task("undated")
        ]
        XCTAssertEqual(TodayTasks.matching(tasks, now: now, calendar: calendar).map(\.id),
                       ["planned", "due", "both", "done", "future-plan"])
        let tomorrow = LocalDateTime.date(from: "2026-03-09T00:00", calendar: calendar)!
        XCTAssertEqual(TodayTasks.matching(tasks, now: tomorrow, calendar: calendar).map(\.id),
                       ["future-plan", "tomorrow"])
    }

    func testDateWindowsUseLocalCalendarDaysAcrossDSTAndDateRollovers() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (day, yesterday, tomorrow, afterTomorrow, lastDay, endDay) in [
            ("2026-03-07", "2026-03-06", "2026-03-08", "2026-03-09", "2026-03-13", "2026-03-14"),
            ("2026-10-31", "2026-10-30", "2026-11-01", "2026-11-02", "2026-11-06", "2026-11-07"),
            ("2026-12-31", "2026-12-30", "2027-01-01", "2027-01-02", "2027-01-06", "2027-01-07"),
            ("2028-02-28", "2028-02-27", "2028-02-29", "2028-03-01", "2028-03-05", "2028-03-06")
        ] {
            let tasks = [
                task("today-planned", planned: day + "T00:00"),
                task("today-due", due: day + "T23:59"),
                task("tomorrow-planned", planned: tomorrow + "T00:00"),
                task("tomorrow-due", due: tomorrow + "T23:59"),
                task("both", planned: tomorrow + "T09:00", due: tomorrow + "T17:00"),
                task("done", due: tomorrow + "T08:00", status: "complete"),
                task("outside-plan", planned: endDay + "T09:00", due: tomorrow + "T11:00"),
                task("outside-due", planned: tomorrow + "T11:00", due: yesterday + "T09:00"),
                task("after-tomorrow", due: afterTomorrow + "T00:00"),
                task("last-planned", planned: lastDay + "T23:59"),
                task("last-due", due: lastDay + "T23:59"),
                task("overdue", due: yesterday + "T23:59"),
                task("beyond-planned", planned: endDay + "T00:00"),
                task("beyond-due", due: endDay + "T00:00"),
                task("undated")
            ]
            let todayIDs = ["today-planned", "today-due"]
            let tomorrowIDs = ["tomorrow-planned", "tomorrow-due", "both", "done", "outside-plan", "outside-due"]
            let weekIDs = todayIDs + tomorrowIDs + ["after-tomorrow", "last-planned", "last-due"]
            // Late local time is already the next UTC day; results must not depend on the current hour.
            for time in ["T00:00", "T23:30"] {
                let now = LocalDateTime.date(from: day + time, calendar: calendar)!
                for (window, expected) in [(TaskDateWindow.today, todayIDs), (.tomorrow, tomorrowIDs), (.thisWeek, weekIDs)] {
                    XCTAssertEqual(TodayTasks.matching(tasks, in: window, now: now, calendar: calendar).map(\.id),
                                   expected, "\(window) at \(day)\(time)")
                    XCTAssertTrue(TodayTasks.matching([], in: window, now: now, calendar: calendar).isEmpty)
                }
                let nextDay = LocalDateTime.date(from: tomorrow + time, calendar: calendar)!
                XCTAssertEqual(TodayTasks.matching(tasks, in: .tomorrow, now: nextDay, calendar: calendar).map(\.id),
                               ["after-tomorrow"])
            }
        }
    }

    func testEverySortAndGroupPreservesTasksAndOrdersWithinGroups() {
        let statuses = [FieldOption(id: "doing", name: "Working"), FieldOption(id: "todo", name: "Ready"),
                        FieldOption(id: "complete", name: "Shipped")]
        let tasks = [
            task("c", title: "Charlie", planned: "2026-03-08T08:00", project: "Work", status: "complete"),
            task("b", title: "beta", planned: "2026-03-09T08:00", due: "2026-03-08T17:00", project: "Inbox"),
            task("a", title: "Alpha", due: "2026-03-08T09:00", project: "Work", status: "doing"),
            task("d", title: "apple", planned: "2026-03-08T10:00", due: "2026-03-09T09:00", project: "Inbox")
        ]
        let expected: [TodayTaskOrder: [String]] = [
            .project: ["d", "b", "a", "c"], .due: ["a", "b", "d", "c"],
            .planned: ["c", "d", "b", "a"], .alphabetical: ["a", "d", "b", "c"],
            .status: ["a", "d", "b", "c"]
        ]
        for sort in TodayTaskOrder.allCases {
            XCTAssertEqual(TodayTasks.sorted(tasks, by: sort, statuses: statuses).map(\.id), expected[sort])
            for grouping in TodayTaskOrder.allCases {
                let groups = TodayTasks.groups(tasks, by: grouping, sort: sort, statuses: statuses)
                XCTAssertEqual(groups.flatMap(\.tasks).count, tasks.count)
                XCTAssertEqual(Set(groups.flatMap(\.tasks).map(\.id)), Set(tasks.map(\.id)))
                for group in groups {
                    XCTAssertEqual(group.tasks.map(\.id), expected[sort]!.filter { id in group.tasks.contains { $0.id == id } })
                }
            }
        }
        func groups(_ by: TodayTaskOrder) -> [TodayTaskGroup] {
            TodayTasks.groups(tasks, by: by, sort: .alphabetical, statuses: statuses)
        }
        XCTAssertEqual(groups(.project).map(\.name), ["Inbox", "Work"])
        XCTAssertEqual(groups(.status).map(\.name), ["Working", "Ready", "Shipped"])
        XCTAssertEqual(groups(.alphabetical).map(\.name), ["A", "B", "C"])
        XCTAssertEqual(groups(.due).map(\.id), ["2026-03-08", "2026-03-09", ""])
        XCTAssertEqual(groups(.due).first?.tasks.map(\.id), ["a", "b"])
        XCTAssertEqual(groups(.due).last?.name, "No due date")
        XCTAssertEqual(groups(.planned).map(\.id), ["2026-03-08", "2026-03-09", ""])
        XCTAssertEqual(groups(.planned).last?.name, "No planned date")
        XCTAssertTrue(TodayTasks.groups([], by: .project, sort: .due, statuses: statuses).isEmpty)
    }

    func testDuplicateNamesStayDistinctAndTiesAreDeterministic() {
        let a = task("a", title: "Same", due: "2026-03-08T09:00")
        var b = a
        b.id = "b"
        b.projectId = "second-inbox"
        b.statusId = "missing-status"
        for sort in TodayTaskOrder.allCases {
            XCTAssertEqual(TodayTasks.sorted([b, a], by: sort, statuses: TaskField.status.options).map(\.id), ["a", "b"])
        }
        XCTAssertEqual(TodayTasks.groups([a, b], by: .project, sort: .due, statuses: []).count, 2)
        XCTAssertEqual(TodayTasks.groups([b], by: .status, sort: .due, statuses: []).first?.name, "missing-status")
    }
}
