import Foundation

public struct CustomReminder: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case custom, planned, due }
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case days, hours, minutes, weeks, months

        var component: Calendar.Component {
            switch self {
            case .minutes: .minute
            case .hours: .hour
            case .days: .day
            case .weeks: .weekOfYear
            case .months: .month
            }
        }

        public func label(for value: Int) -> String {
            "\(value) \(value == 1 ? String(rawValue.dropLast()) : rawValue) before"
        }
    }

    public var id: String
    public var kind: Kind
    public var at: String?
    // Keep legacy fields unchanged when decoding: queued retry bodies are immutable.
    public var offsetMinutes: Int?
    public var offsetUnit: Unit?
    public var offsetValue: Int?
    public var urgent: Bool

    public static let amounts = 1...999
    public static let offsets = [5, 15, 30, 60, 120, 1_440, 2_880, 10_080]

    public var relativeOffset: (unit: Unit, value: Int)? {
        if let unit = offsetUnit, let value = offsetValue, offsetMinutes == nil, Self.amounts.contains(value) {
            return (unit, value)
        }
        guard offsetUnit == nil, offsetValue == nil,
              let minutes = offsetMinutes, Self.offsets.contains(minutes) else { return nil }
        if minutes % 10_080 == 0 { return (.weeks, minutes / 10_080) }
        if minutes % 1_440 == 0 { return (.days, minutes / 1_440) }
        if minutes % 60 == 0 { return (.hours, minutes / 60) }
        return (.minutes, minutes)
    }

    public mutating func setOffset(unit: Unit, value: Int) {
        offsetUnit = unit
        offsetValue = value
        offsetMinutes = nil
    }

    public init(kind: Kind = .custom, at: String? = nil, offsetMinutes: Int? = nil,
                offsetUnit: Unit? = nil, offsetValue: Int? = nil, urgent: Bool = false) {
        id = UUID().uuidString.lowercased()
        self.kind = kind
        self.at = at
        self.offsetMinutes = offsetMinutes
        self.offsetUnit = offsetUnit
        self.offsetValue = offsetValue
        self.urgent = urgent
    }

    public func date(for task: TaskItem, calendar: Calendar = .current) -> Date? {
        if kind == .custom { return at.flatMap { LocalDateTime.date(from: $0, calendar: calendar) } }
        guard let value = kind == .planned ? task.plannedFor : task.dueOn,
              let base = LocalDateTime.date(from: value, calendar: calendar),
              let offset = relativeOffset else { return nil }
        // Calendar units preserve wall-clock time over DST and clamp month ends.
        return calendar.date(byAdding: offset.unit.component, value: -offset.value, to: base)
    }
}

public struct TaskReminder: Identifiable, Equatable, Sendable {
    public let id: String
    public let taskId: String
    public let title: String
    public let kind: String
    public let wallClock: String
    public let date: Date
    public var urgent = false
}

public enum TaskReminders {
    public static let prefix = "adhocly.task."
    public static let limit = 64

    public static func validate(_ reminders: [CustomReminder]) throws {
        guard reminders.count <= limit, Set(reminders.map(\.id)).count == reminders.count else {
            throw AppFailure("Use unique reminder IDs and at most 64 custom reminders per task.")
        }
        for reminder in reminders {
            guard !reminder.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reminder.id.utf8.count <= 128 else { throw AppFailure("Invalid reminder ID.") }
            if reminder.kind == .custom {
                guard reminder.offsetMinutes == nil, reminder.offsetUnit == nil, reminder.offsetValue == nil, let at = reminder.at,
                      let date = LocalDateTime.date(from: at), LocalDateTime.string(from: date) == at else {
                    throw AppFailure("Choose a valid reminder date and time.")
                }
            } else if reminder.at != nil || reminder.relativeOffset == nil {
                throw AppFailure("Choose a reminder unit and an amount from 1 to 999.")
            }
        }
    }

    public static func upcoming(tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current) -> [TaskReminder] {
        tasks.filter { !$0.completed }.flatMap { task -> [TaskReminder] in
            let defaults = [("planned", task.plannedFor), ("due", task.dueOn)].compactMap { kind, value -> TaskReminder? in
                guard let value, let date = LocalDateTime.date(from: value, calendar: calendar), date > now else { return nil }
                return TaskReminder(id: "\(prefix)\(task.id).\(kind)", taskId: task.id, title: task.title,
                                    kind: kind, wallClock: value, date: date)
            }
            let custom = task.reminders.compactMap { reminder -> TaskReminder? in
                guard let date = reminder.date(for: task, calendar: calendar), date > now else { return nil }
                return TaskReminder(id: "\(prefix)\(task.id).custom.\(reminder.id)", taskId: task.id, title: task.title,
                                    kind: "custom", wallClock: LocalDateTime.string(from: date, calendar: calendar),
                                    date: date, urgent: reminder.urgent)
            }
            return defaults + custom
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}
