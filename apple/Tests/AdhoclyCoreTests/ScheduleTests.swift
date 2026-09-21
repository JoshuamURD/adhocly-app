import Foundation
import XCTest
@testable import AdhoclyCore

final class ScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ value: String) -> Date {
        LocalDateTime.date(from: value, calendar: calendar)!
    }

    private func keys(_ dates: [Date]) -> [String] {
        dates.map { String(LocalDateTime.string(from: $0, calendar: calendar).prefix(10)) }
    }

    func testDayThreeDayAndWeekRangesRespectLocalDaysAndWeekStart() {
        let anchor = date("2026-03-07T23:30")
        XCTAssertEqual(keys(SchedulePeriod.day.days(containing: anchor, calendar: calendar)), ["2026-03-07"])
        let days = SchedulePeriod.threeDays.days(containing: anchor, calendar: calendar)
        XCTAssertEqual(keys(days), ["2026-03-07", "2026-03-08", "2026-03-09"])
        XCTAssertEqual(days[2].timeIntervalSince(days[1]), 23 * 3600)
        let week = SchedulePeriod.week.days(containing: anchor, calendar: calendar)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(keys([week.first!, week.last!]), ["2026-03-02", "2026-03-08"])
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        XCTAssertEqual(keys([SchedulePeriod.week.days(containing: anchor, calendar: sundayFirst).first!]), ["2026-03-01"])
        let fall = SchedulePeriod.threeDays.days(containing: date("2026-10-31T12:00"), calendar: calendar)
        XCTAssertEqual(keys(fall), ["2026-10-31", "2026-11-01", "2026-11-02"])
        XCTAssertEqual(fall[2].timeIntervalSince(fall[1]), 25 * 3600)
    }

    func testMonthPaddingLeapYearAndNavigation() {
        let february = SchedulePeriod.month.days(containing: date("2024-02-20T09:00"), calendar: calendar)
        XCTAssertEqual(february.count, 35)
        XCTAssertEqual(keys([february.first!, february.last!]), ["2024-01-29", "2024-03-03"])
        XCTAssertTrue(keys(february).contains("2024-02-29"))
        let march = SchedulePeriod.month.days(containing: date("2026-03-20T09:00"), calendar: calendar)
        XCTAssertEqual(march.count, 42)
        XCTAssertEqual(keys([march.first!, march.last!]), ["2026-02-23", "2026-04-05"])
        let feb = SchedulePeriod.month.moving(date("2026-01-31T12:00"), by: 1, calendar: calendar)
        XCTAssertEqual(keys([feb]), ["2026-02-01"])
        XCTAssertEqual(keys([SchedulePeriod.month.moving(feb, by: 1, calendar: calendar)]), ["2026-03-01"])
        XCTAssertEqual(keys([SchedulePeriod.month.moving(date("2026-01-01T12:00"), by: -1, calendar: calendar)]), ["2025-12-01"])
        for (period, expected) in [(SchedulePeriod.day, "2026-03-08"), (.threeDays, "2026-03-10"), (.week, "2026-03-14")] {
            let start = date("2026-03-07T12:00")
            let next = period.moving(start, by: 1, calendar: calendar)
            XCTAssertEqual(keys([next]), [expected])
            XCTAssertEqual(calendar.component(.hour, from: next), 12)
            XCTAssertEqual(period.moving(next, by: -1, calendar: calendar), start)
        }
    }

    func testEntriesIncludeBothDatesAndCompletedTasksButNotUndatedOrOutsideRange() {
        var both = TaskItem(title: "Both")
        both.id = "both"
        both.plannedFor = "2026-03-08T00:00"
        both.dueOn = "2026-03-08T23:59"
        var crossing = TaskItem(title: "Crossing")
        crossing.id = "crossing"
        crossing.plannedFor = "2026-03-07T23:59"
        crossing.dueOn = "2026-03-08T08:00"
        crossing.completed = true
        var outside = TaskItem(title: "Outside")
        outside.plannedFor = "2026-03-09T00:00"
        outside.dueOn = "invalid"
        let days = SchedulePeriod.day.days(containing: date("2026-03-08T12:00"), calendar: calendar)
        let tasks = [outside, crossing, TaskItem(title: "Undated"), both]
        let entries = Schedule.entries(tasks, days: days, calendar: calendar)
        XCTAssertEqual(entries.map(\.id), ["both:planned", "crossing:due", "both:due"])
        XCTAssertTrue(entries[1].task.completed)
        XCTAssertTrue(Schedule.entries(tasks, days: [], calendar: calendar).isEmpty)
        both.dueOn = both.plannedFor
        let sameTime = Schedule.entries([both], days: days, calendar: calendar)
        XCTAssertEqual(Set(sameTime.map(\.kind)), [.due, .planned])
        XCTAssertEqual(Set(sameTime.map(\.id)).count, 2)
        let fullMonth = SchedulePeriod.month.days(containing: date("2026-03-08T12:00"), calendar: calendar)
        XCTAssertEqual(Schedule.entries([crossing], days: fullMonth, calendar: calendar).count, 2)
    }
}
