import Foundation

public enum TodayTaskOrder: String, CaseIterable, Sendable {
    case project, due, planned, alphabetical, status

    public var name: String {
        switch self {
        case .project: "Project"
        case .due: "Due date"
        case .planned: "Planned date"
        case .alphabetical: "Alphabetical"
        case .status: "Status"
        }
    }
}

public struct TodayTaskGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let tasks: [TaskItem]
}

public enum TodayTasks {
    public static func matching(_ tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current) -> [TaskItem] {
        let day = LocalDateTime.string(from: now, calendar: calendar).prefix(10)
        // These are local wall-clock strings: do not shift their dates through UTC.
        return tasks.filter { $0.plannedFor?.prefix(10) == day || $0.dueOn?.prefix(10) == day }
    }

    public static func sorted(_ tasks: [TaskItem], by order: TodayTaskOrder,
                              statuses: [FieldOption]) -> [TaskItem] {
        switch order {
        case .due, .planned, .alphabetical:
            let mode: KanbanSort = order == .due ? .due : order == .planned ? .planned : .alphabetical
            return Kanban.sorted(tasks, on: KanbanBoard(sortMode: mode))
        case .project, .status:
            return tasks.sorted { lhs, rhs in
                if order == .project {
                    let comparison = lhs.project.localizedStandardCompare(rhs.project)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                    if lhs.projectId != rhs.projectId { return lhs.projectId < rhs.projectId }
                } else {
                    let a = statuses.firstIndex { $0.id == lhs.statusId } ?? Int.max
                    let b = statuses.firstIndex { $0.id == rhs.statusId } ?? Int.max
                    if a != b { return a < b }
                    if lhs.statusId != rhs.statusId { return lhs.statusId < rhs.statusId }
                }
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
            }
        }
    }

    public static func groups(_ tasks: [TaskItem], by grouping: TodayTaskOrder,
                              sort: TodayTaskOrder, statuses: [FieldOption]) -> [TodayTaskGroup] {
        let ordered = sorted(tasks, by: sort, statuses: statuses)
        let buckets = Dictionary(grouping: ordered) { key(for: $0, by: grouping) }
        var seen = Set<String>()
        return sorted(tasks, by: grouping, statuses: statuses).compactMap { task in
            let id = key(for: task, by: grouping)
            guard seen.insert(id).inserted else { return nil }
            let name: String
            switch grouping {
            case .project: name = task.project
            case .status: name = statuses.first { $0.id == task.statusId }?.name ?? task.statusId
            case .alphabetical: name = id
            case .due, .planned:
                if id.isEmpty {
                    name = grouping == .due ? "No due date" : "No planned date"
                } else {
                    name = LocalDateTime.date(from: id + "T12:00")?
                        .formatted(date: .abbreviated, time: .omitted) ?? id
                }
            }
            return TodayTaskGroup(id: id, name: name, tasks: buckets[id] ?? [])
        }
    }

    private static func key(for task: TaskItem, by grouping: TodayTaskOrder) -> String {
        switch grouping {
        case .project: task.projectId
        case .status: task.statusId
        case .due: task.dueOn.map { String($0.prefix(10)) } ?? ""
        case .planned: task.plannedFor.map { String($0.prefix(10)) } ?? ""
        case .alphabetical: String(task.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
        }
    }
}
