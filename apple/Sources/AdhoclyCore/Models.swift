import Foundation

public struct TaskItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var details: String
    public var projectId: String
    public var project: String
    // The API uses local wall-clock strings, not UTC instants, for these two fields.
    public var plannedFor: String?
    public var dueOn: String?
    public var repeatWeekday: Int?
    public var createdAt: String
    public var updatedAt: String
    public var completed: Bool
    public var statusId: String
    public var properties: [String: String]
    public var reminders: [CustomReminder]

    public init(title: String = "", projectId: String = "inbox", project: String = "Inbox") {
        id = UUID().uuidString.lowercased()
        self.title = title
        details = ""
        self.projectId = projectId
        self.project = project
        createdAt = Date().ISO8601Format()
        updatedAt = createdAt
        completed = false
        statusId = "todo"
        properties = [:]
        reminders = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, details, projectId, project, plannedFor, dueOn, repeatWeekday, createdAt, updatedAt, completed, statusId, properties, reminders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        projectId = try c.decode(String.self, forKey: .projectId)
        project = try c.decode(String.self, forKey: .project)
        plannedFor = try c.decodeIfPresent(String.self, forKey: .plannedFor)
        dueOn = try c.decodeIfPresent(String.self, forKey: .dueOn)
        repeatWeekday = try c.decodeIfPresent(Int.self, forKey: .repeatWeekday)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        completed = try c.decode(Bool.self, forKey: .completed)
        statusId = try c.decodeIfPresent(String.self, forKey: .statusId) ?? (completed ? "complete" : "todo")
        properties = try c.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        reminders = try c.decodeIfPresent([CustomReminder].self, forKey: .reminders) ?? []
    }
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

struct Snapshot: Codable, Sendable {
    var protocolVersion = 5
    var tasks: [TaskItem] = []
    var projects: [Project] = [Project(id: "inbox", name: "Inbox")]
    var versions: [String: Int64] = [:]
    var taskFields: [TaskField] = [.status]
    var boards: [KanbanBoard] = [.status]

    init() {}
    private enum CodingKeys: String, CodingKey { case tasks, projects, versions, taskFields, boards, protocolVersion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        tasks = try c.decode([TaskItem].self, forKey: .tasks)
        projects = try c.decode([Project].self, forKey: .projects)
        versions = try c.decode([String: Int64].self, forKey: .versions)
        taskFields = try c.decodeIfPresent([TaskField].self, forKey: .taskFields) ?? [.status]
        boards = try c.decodeIfPresent([KanbanBoard].self, forKey: .boards) ?? [.status]
    }
}

// Optional fields are omitted. Rust treats missing optional task fields like JSON null.
struct MutationBody: Codable, Equatable, Sendable {
    var id: String?
    var title: String?
    var details: String?
    var projectId: String?
    var plannedFor: String?
    var dueOn: String?
    var repeatWeekday: Int?
    var completed: Bool?
    var statusId: String?
    var properties: [String: String]?
    var reminders: [CustomReminder]?
    var name: String?
    var kind: TaskField.Kind?
    var options: [FieldOption]?
    var fieldId: String?
    var sortMode: KanbanSort?
    var manualOrder: [String]?

    init() {}

    init(task: TaskItem) {
        id = task.id
        title = task.title
        details = task.details
        projectId = task.projectId
        plannedFor = task.plannedFor
        dueOn = task.dueOn
        repeatWeekday = task.repeatWeekday
        completed = task.completed
        statusId = task.statusId
        properties = task.properties
        reminders = task.reminders
    }
}

struct SyncOperation: Codable, Equatable, Sendable {
    var id = UUID().uuidString.lowercased()
    var url: String
    var method: String
    var body: MutationBody
    var expectedVersion: Int64
}

struct SyncReply: Decodable, Sendable {
    var snapshot: Snapshot
    var changes: [String: Int64]
}

struct PendingMutation: Codable, Sendable {
    var taskId: String
    var operation: SyncOperation
    // An optimistic projection is separate from the immutable retry request.
    var localTask: TaskItem?
    // Keep the v1 taskId key so existing durable requests migrate without changing their body.
    var entityKind: String?
    var localField: TaskField?
    var localBoard: KanbanBoard?
    var key: String { "\(entityKind ?? "tasks")/\(taskId)" }
}

public struct SyncIssue: Codable, Sendable {
    public let taskId: String
    public let message: String
    public var entityKind: String?
    public var isTask: Bool { entityKind == nil || entityKind == "tasks" }
    var key: String { "\(entityKind ?? "tasks")/\(taskId)" }
}

struct SavedState: Codable, Sendable {
    var formatVersion = 5
    var serverURL = ""
    var snapshot = Snapshot()
    var pending: [PendingMutation] = []
    var issue: SyncIssue?
    var lastSyncedAt: Date?
}

public enum LocalDateTime {
    private static func formatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.isLenient = false
        return formatter
    }

    public static func dueLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        if days < 0 { return "\(-days) \(days == -1 ? "day" : "days") overdue" }
        if days == 0 { return date < now ? "Overdue today" : "Due today" }
        return "Due in \(days) \(days == 1 ? "day" : "days")"
    }

    public static func string(from date: Date) -> String { string(from: date, calendar: .current) }
    public static func date(from string: String) -> Date? { date(from: string, calendar: .current) }
    public static func string(from date: Date, calendar: Calendar) -> String { formatter(calendar: calendar).string(from: date) }
    public static func date(from string: String, calendar: Calendar) -> Date? { formatter(calendar: calendar).date(from: string) }
}
