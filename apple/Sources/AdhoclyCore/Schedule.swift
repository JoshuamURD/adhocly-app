import Foundation

public enum SchedulePeriod: String, CaseIterable, Sendable {
    case day, threeDays, week, month

    public var name: String {
        switch self {
        case .day: "Day"
        case .threeDays: "3 days"
        case .week: "Week"
        case .month: "Month"
        }
    }

    public func days(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let start: Date
        let count: Int
        switch self {
        case .day, .threeDays:
            start = calendar.startOfDay(for: date)
            count = self == .day ? 1 : 3
        case .week:
            start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
            count = 7
        case .month:
            let month = calendar.dateInterval(of: .month, for: date)!
            start = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
            let days = calendar.dateComponents([.day], from: start, to: month.end).day!
            count = ((days + 6) / 7) * 7
        }
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    public func moving(_ date: Date, by direction: Int, calendar: Calendar = .current) -> Date {
        if self == .month {
            // Navigate from the month boundary so January 31 cannot skip February.
            return calendar.date(byAdding: .month, value: direction,
                                 to: calendar.dateInterval(of: .month, for: date)!.start)!
        }
        let days = self == .week ? 7 : self == .threeDays ? 3 : 1
        return calendar.date(byAdding: .day, value: days * direction, to: date)!
    }
}

public struct ScheduleEntry: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case planned, due
        public var name: String { self == .planned ? "Planned" : "Due" }
        public var symbol: String { self == .planned ? "calendar" : "flag" }
    }

    public var id: String { "\(task.id):\(kind.rawValue)" }
    public let task: TaskItem
    public let kind: Kind
    public let date: Date
}

public enum Schedule {
    public static func entries(_ tasks: [TaskItem], days: [Date], calendar: Calendar = .current) -> [ScheduleEntry] {
        guard let start = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        return tasks.flatMap { task in
            [(ScheduleEntry.Kind.planned, task.plannedFor), (.due, task.dueOn)].compactMap { kind, value in
                guard let value, let date = LocalDateTime.date(from: value, calendar: calendar),
                      date >= start, date < end else { return nil as ScheduleEntry? }
                return ScheduleEntry(task: task, kind: kind, date: date)
            }
        }.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            let comparison = lhs.task.title.localizedStandardCompare(rhs.task.title)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }
}
