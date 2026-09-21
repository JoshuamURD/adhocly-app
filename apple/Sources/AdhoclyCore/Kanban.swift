import Foundation

public struct FieldOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public init(id: String = UUID().uuidString.lowercased(), name: String = "") {
        self.id = id
        self.name = name
    }
}

// The status configuration retains its historical wire shape for queued sync requests.
public struct TaskField: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case text, number, choice }
    public var id: String
    public var name: String
    public var kind: Kind
    public var options: [FieldOption]

    public init(id: String = UUID().uuidString.lowercased(), name: String = "", kind: Kind = .choice, options: [FieldOption] = []) {
        self.id = id; self.name = name; self.kind = kind; self.options = options
    }

    public static let status = TaskField(id: "status", name: "Status", options: [
        FieldOption(id: "todo", name: "To do"), FieldOption(id: "doing", name: "In progress"),
        FieldOption(id: "complete", name: "Complete")
    ])
}

public enum KanbanSort: String, Codable, CaseIterable, Sendable {
    case due, planned, created, alphabetical, manual

    public var name: String {
        switch self {
        case .due: "Due date (earliest first)"
        case .planned: "Planned date (earliest first)"
        case .created: "Created date (newest first)"
        case .alphabetical: "Alphabetical (A–Z)"
        case .manual: "Manual"
        }
    }
}

public struct KanbanBoard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var fieldId: String
    public var sortMode: KanbanSort
    public var manualOrder: [String]
    public init(id: String = UUID().uuidString.lowercased(), name: String = "", fieldId: String = "status",
                sortMode: KanbanSort = .created, manualOrder: [String] = []) {
        self.id = id; self.name = name; self.fieldId = fieldId
        self.sortMode = sortMode; self.manualOrder = manualOrder
    }

    private enum CodingKeys: String, CodingKey { case id, name, fieldId, sortMode, manualOrder }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fieldId = try c.decode(String.self, forKey: .fieldId)
        sortMode = try c.decodeIfPresent(KanbanSort.self, forKey: .sortMode) ?? .created
        manualOrder = try c.decodeIfPresent([String].self, forKey: .manualOrder) ?? []
    }

    public static let status = KanbanBoard(id: "status", name: "By status")
}

public struct KanbanLane: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let value: String?
    public let isComplete: Bool
}

public enum Kanban {
    public static func sorted(_ tasks: [TaskItem], on board: KanbanBoard) -> [TaskItem] {
        let ranks = board.manualOrder.enumerated().reduce(into: [String: Int]()) { $0[$1.element] = $1.offset }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        let created = tasks.reduce(into: [String: Date]()) {
            $0[$1.id] = fractional.date(from: $1.createdAt) ?? whole.date(from: $1.createdAt)
        }
        return tasks.sorted { lhs, rhs in
            switch board.sortMode {
            case .manual:
                let a = ranks[lhs.id] ?? Int.max, b = ranks[rhs.id] ?? Int.max
                if a != b { return a < b }
            case .alphabetical:
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id < rhs.id
            case .due, .planned:
                let a = board.sortMode == .due ? lhs.dueOn : lhs.plannedFor
                let b = board.sortMode == .due ? rhs.dueOn : rhs.plannedFor
                if a != b {
                    guard let a else { return false }
                    guard let b else { return true }
                    return a < b
                }
                return lhs.id < rhs.id
            case .created: break
            }
            let a = created[lhs.id] ?? .distantPast, b = created[rhs.id] ?? .distantPast
            return a == b ? lhs.id < rhs.id : a > b
        }
    }

    public static func lanes(status: TaskField) -> [KanbanLane] {
        status.options.map { option in
            option.id == "complete"
                ? KanbanLane(id: "complete", name: option.name, value: nil, isComplete: true)
                : KanbanLane(id: "value:\(option.id)", name: option.name, value: option.id, isComplete: false)
        }
    }

    public static func laneID(task: TaskItem) -> String {
        task.completed ? "complete" : "value:\(task.statusId)"
    }
}
