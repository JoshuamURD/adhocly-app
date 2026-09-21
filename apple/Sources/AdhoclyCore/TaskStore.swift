import Foundation
import Observation

@MainActor @Observable
public final class TaskStore {
    private var state: SavedState
    public private(set) var isSyncing = false
    public private(set) var syncError: String?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let session: URLSession

    public init(fileURL: URL, session: URLSession = .shared) throws {
        self.fileURL = fileURL
        self.session = session
        if FileManager.default.fileExists(atPath: fileURL.path) {
            state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: fileURL))
            guard [1, 2, 3, 4, 5].contains(state.formatVersion) else { throw AppFailure("Unsupported local data version. Update the app before opening this data.") }
        } else {
            state = SavedState()
        }
    }

    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Adhocly/state.json")
    }

    public var serverURL: String { state.serverURL }
    public var projects: [Project] { state.snapshot.projects }
    public var pendingCount: Int { state.pending.count }
    public var issue: SyncIssue? { state.issue }
    public var lastSyncedAt: Date? { state.lastSyncedAt }

    public var tasks: [TaskItem] {
        var tasks = state.snapshot.tasks
        for pending in state.pending where pending.entityKind == nil || pending.entityKind == "tasks" {
            tasks.removeAll { $0.id == pending.taskId }
            if let task = pending.localTask { tasks.append(task) }
        }
        return tasks.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt > $1.createdAt
        }
    }

    public func isPending(_ id: String) -> Bool { state.pending.contains { $0.key == "tasks/\(id)" } }
    public func serverTask(_ id: String) -> TaskItem? { state.snapshot.tasks.first { $0.id == id } }

    public var taskFields: [TaskField] {
        var fields = state.snapshot.taskFields
        for pending in state.pending where pending.entityKind == "task-fields" {
            fields.removeAll { $0.id == pending.taskId }
            if let field = pending.localField { fields.append(field) }
        }
        return fields.sorted { $0.id == "status" ? $1.id != "status" : $1.id != "status" && $0.name < $1.name }
    }

    public var boards: [KanbanBoard] {
        var boards = state.snapshot.boards
        for pending in state.pending where pending.entityKind == "boards" {
            boards.removeAll { $0.id == pending.taskId }
            if let board = pending.localBoard { boards.append(board) }
        }
        return boards.sorted { $0.name < $1.name }
    }

    public var statusField: TaskField { taskFields.first { $0.id == "status" } ?? .status }
    public var completeName: String { statusField.options.first { $0.id == "complete" }?.name ?? "Complete" }
    public func statusName(_ id: String) -> String { statusField.options.first { $0.id == id }?.name ?? id }

    private func version(for key: String) -> Int64 {
        state.snapshot.versions[key] ?? (["task-fields/status", "boards/status"].contains(key) ? 1 : 0)
    }

    private func validateProperties(of task: TaskItem) throws {
        guard statusField.options.contains(where: { $0.id == task.statusId }) else { throw AppFailure("Choose an available status.") }
        for (id, value) in task.properties {
            guard id != "status", let field = taskFields.first(where: { $0.id == id }) else {
                throw AppFailure("An unknown task property must be removed before saving.")
            }
            if field.kind == .choice && !field.options.contains(where: { $0.id == value }) {
                throw AppFailure("Choose an available option for \(field.name).")
            }
            if field.kind == .number && Double(value)?.isFinite != true {
                throw AppFailure("\(field.name) must be a finite number.")
            }
        }
    }

    public func move(_ taskId: String, to lane: KanbanLane, on board: KanbanBoard,
                     relativeTo targetId: String? = nil, after: Bool = false) throws {
        guard let original = tasks.first(where: { $0.id == taskId }),
              boards.contains(board), let field = taskFields.first(where: { $0.id == board.fieldId }),
              Kanban.lanes(field: field, tasks: tasks, completeName: completeName).contains(lane) else {
            throw AppFailure("The task or board changed. Refresh it before moving this card.")
        }
        var task = original
        if lane.isComplete {
            task.statusId = "complete"
        } else if board.fieldId == "status" {
            task.statusId = lane.value!
        } else {
            task.properties[board.fieldId] = lane.value
            if task.completed { task.statusId = "todo" }
        }
        task.completed = task.statusId == "complete"
        var next = state
        if let targetId {
            guard board.sortMode == .manual,
                  tasks.contains(where: { $0.id == targetId && Kanban.laneID(task: $0, fieldId: field.id) == lane.id }) else {
                throw AppFailure("The drop target changed. Try moving the card again.")
            }
            if targetId == taskId { return }
        }
        if task != original { next.pending.append(try taskMutation(task, replacing: original)) }
        if board.sortMode == .manual {
            var reordered = board
            // One board-wide order also orders each column; include cards hidden by search.
            reordered.manualOrder = Kanban.sorted(tasks, on: board).map(\.id).filter { $0 != taskId }
            let index = targetId.flatMap { reordered.manualOrder.firstIndex(of: $0) }
            reordered.manualOrder.insert(taskId, at: index.map { $0 + (after ? 1 : 0) } ?? reordered.manualOrder.count)
            if reordered != board { next.pending.append(boardMutation(reordered, create: false)) }
        }
        // Persist the lane change and its order together, or leave both unchanged on disk failure.
        if next.pending.count != state.pending.count { try commit(next) }
    }

    public func saveField(_ draft: TaskField, replacing original: TaskField? = nil) throws {
        var field = draft
        field.name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
        field.options = field.kind == .choice ? field.options.map { FieldOption(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines)) } : []
        guard !field.name.isEmpty, !taskFields.contains(where: { $0.id != field.id && $0.name.lowercased() == field.name.lowercased() }) else {
            throw AppFailure("Use a nonempty, unique property name.")
        }
        guard field.kind != .choice || (!field.options.isEmpty && field.options.allSatisfy { !$0.name.isEmpty }),
              Set(field.options.map(\.id)).count == field.options.count,
              Set(field.options.map { $0.name.lowercased() }).count == field.options.count else {
            throw AppFailure("Options need unique ids and nonempty, unique names.")
        }
        if field.id == "status" && (field.kind != .choice || !["todo", "complete"].allSatisfy({ id in field.options.contains { $0.id == id } })) {
            throw AppFailure("Keep the default and Complete statuses. You can rename them.")
        }
        if let original {
            guard original.id == field.id, taskFields.first(where: { $0.id == field.id }) == original,
                  field.kind == original.kind else { throw AppFailure("This property changed. Reopen it before editing.") }
        } else if taskFields.contains(where: { $0.id == field.id }) { throw AppFailure("Property already exists.") }
        let used = tasks.compactMap { field.id == "status" ? $0.statusId : $0.properties[field.id] }
        if field.kind == .choice && used.contains(where: { value in !field.options.contains { $0.id == value } }) {
            throw AppFailure("Move tasks out of an option before removing it.")
        }
        var body = MutationBody()
        body.id = field.id; body.name = field.name; body.kind = field.kind; body.options = field.options
        try enqueueConfiguration(kind: "task-fields", id: field.id, body: body, create: original == nil, field: field)
    }

    public func saveBoard(_ draft: KanbanBoard, replacing original: KanbanBoard? = nil) throws {
        var board = draft
        board.name = board.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !board.name.isEmpty, taskFields.contains(where: { $0.id == board.fieldId }) else { throw AppFailure("Choose a board name and an available property.") }
        if let original {
            guard original.id == board.id, boards.first(where: { $0.id == board.id }) == original else { throw AppFailure("This board changed. Reopen it before editing.") }
        } else if boards.contains(where: { $0.id == board.id }) { throw AppFailure("Board already exists.") }
        guard Set(board.manualOrder).count == board.manualOrder.count,
              board.manualOrder.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AppFailure("Manual order must contain unique, nonempty task ids.")
        }
        if board.sortMode == .manual, board.manualOrder.isEmpty {
            board.manualOrder = Kanban.sorted(tasks, on: original ?? board).map(\.id)
        }
        var next = state
        next.pending.append(boardMutation(board, create: original == nil))
        try commit(next)
    }

    private func boardMutation(_ board: KanbanBoard, create: Bool) -> PendingMutation {
        var body = MutationBody()
        body.id = board.id; body.name = board.name; body.fieldId = board.fieldId
        body.sortMode = board.sortMode; body.manualOrder = board.manualOrder
        return PendingMutation(taskId: board.id,
            operation: SyncOperation(url: "/api/boards" + (create ? "" : "/\(board.id)"),
                                     method: create ? "POST" : "PUT", body: body,
                                     expectedVersion: version(for: "boards/\(board.id)")),
            entityKind: "boards", localBoard: board)
    }

    public func deleteBoard(_ id: String) throws {
        guard boards.contains(where: { $0.id == id }) else { throw AppFailure("Board no longer exists.") }
        var next = state
        next.pending.append(PendingMutation(taskId: id, operation: SyncOperation(url: "/api/boards/\(id)", method: "DELETE", body: MutationBody(), expectedVersion: version(for: "boards/\(id)")), entityKind: "boards"))
        try commit(next)
    }

    private func enqueueConfiguration(kind: String, id: String, body: MutationBody, create: Bool, field: TaskField? = nil, board: KanbanBoard? = nil) throws {
        var next = state
        let path = "/api/\(kind)" + (create ? "" : "/\(id)")
        next.pending.append(PendingMutation(taskId: id, operation: SyncOperation(url: path, method: create ? "POST" : "PUT", body: body, expectedVersion: version(for: "\(kind)/\(id)")), entityKind: kind, localField: field, localBoard: board))
        try commit(next)
    }

    public func configurationDescription(local: Bool) -> String {
        guard let issue, !issue.isTask else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data?
        if issue.entityKind == "task-fields" {
            let value = (local ? taskFields : state.snapshot.taskFields).first { $0.id == issue.taskId }
            data = try? encoder.encode(value)
        } else {
            let value = (local ? boards : state.snapshot.boards).first { $0.id == issue.taskId }
            data = try? encoder.encode(value)
        }
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "Deleted"
    }

    public func resolveConfigurationIssue(keepLocal: Bool) throws {
        guard !isSyncing, let issue, !issue.isTask,
              var replacement = state.pending.last(where: { $0.key == issue.key }) else { throw AppFailure("Wait for sync before reviewing configuration.") }
        var next = state
        next.pending.removeAll { $0.key == issue.key }
        next.issue = nil
        if keepLocal {
            replacement.operation.id = UUID().uuidString.lowercased()
            replacement.operation.expectedVersion = version(for: issue.key)
            let exists = issue.entityKind == "task-fields" ? state.snapshot.taskFields.contains { $0.id == issue.taskId } : state.snapshot.boards.contains { $0.id == issue.taskId }
            if replacement.operation.method != "DELETE" {
                replacement.operation.method = exists ? "PUT" : "POST"
                replacement.operation.url = "/api/\(issue.entityKind!)" + (exists ? "/\(issue.taskId)" : "")
            }
            // Keep configuration ahead of tasks that reference its new fields/options.
            next.pending.insert(replacement, at: 0)
        }
        try commit(next)
    }

    public func configure(serverURL: String) throws {
        guard !isSyncing else { throw AppFailure("Wait for the current sync to finish before changing the connection.") }
        let url = try SyncAPI.validatedURL(serverURL).absoluteString
        guard url != state.serverURL else { return }
        var next = state
        if !state.serverURL.isEmpty {
            guard state.pending.isEmpty else { throw AppFailure("Sync or resolve pending changes before switching servers. They belong to the current server.") }
            next = SavedState()
        }
        next.serverURL = url
        try commit(next)
        syncError = nil
    }

    public func save(_ draft: TaskItem, replacing original: TaskItem? = nil) throws {
        var next = state
        next.pending.append(try taskMutation(draft, replacing: original))
        try commit(next)
    }

    private func taskMutation(_ draft: TaskItem, replacing original: TaskItem?) throws -> PendingMutation {
        var task = draft
        task.properties = task.properties.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        task.completed = task.statusId == "complete"
        try validateProperties(of: task)
        try TaskReminders.validate(task.reminders)
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.title.isEmpty else { throw AppFailure("A task needs a title.") }
        guard projects.contains(where: { $0.id == task.projectId }) else { throw AppFailure("That project is no longer available. Choose another project.") }
        guard task.repeatWeekday == nil || (0...6).contains(task.repeatWeekday!) else { throw AppFailure("Invalid repeat weekday.") }
        for date in [task.plannedFor, task.dueOn].compactMap({ $0 }) {
            guard LocalDateTime.date(from: date).map({ LocalDateTime.string(from: $0) == date }) == true else {
                throw AppFailure("Dates must use YYYY-MM-DDTHH:MM local time.")
            }
        }
        if let original {
            guard task.id == original.id, let current = tasks.first(where: { $0.id == task.id }),
                  MutationBody(task: current) == MutationBody(task: original) else {
                throw AppFailure("This task changed while the editor was open. Close and reopen it to review the latest version; your draft has not been sent.")
            }
            // Acknowledgements can refresh timestamps/project names without changing editable data.
            task.createdAt = current.createdAt
            // Rust now handles recurrence for both status edits and checkbox toggles.
        } else {
            guard !task.id.hasPrefix("next:"), !isPending(task.id),
                  state.snapshot.versions["tasks/\(task.id)"] == nil else {
                throw AppFailure("This task ID already exists. Create a new task instead.")
            }
        }
        task.updatedAt = Date().ISO8601Format()
        task.project = projects.first { $0.id == task.projectId }!.name
        let url = original == nil ? "/api/tasks" : Self.taskPath(task.id)
        return PendingMutation(taskId: task.id,
            operation: SyncOperation(url: url, method: original == nil ? "POST" : "PUT",
                                     body: MutationBody(task: task), expectedVersion: version(for: "tasks/\(task.id)")),
            localTask: task)
    }

    public func toggle(_ id: String) throws {
        guard var task = tasks.first(where: { $0.id == id }) else { throw AppFailure("Task no longer exists.") }
        task.completed.toggle()
        task.statusId = task.completed ? "complete" : "todo"
        task.updatedAt = Date().ISO8601Format()
        var body = MutationBody()
        body.completed = task.completed
        try enqueue(taskId: id, url: Self.taskPath(id) + "/toggle", method: "POST", body: body, localTask: task)
    }

    public func delete(_ id: String) throws {
        guard tasks.contains(where: { $0.id == id }) else { throw AppFailure("Task no longer exists.") }
        try enqueue(taskId: id, url: Self.taskPath(id), method: "DELETE", body: MutationBody(), localTask: nil)
    }

    private static func taskPath(_ id: String) -> String {
        let segment = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return "/api/tasks/\(segment)"
    }

    private func enqueue(taskId: String, url: String, method: String, body: MutationBody, localTask: TaskItem?) throws {
        var next = state
        next.pending.append(PendingMutation(taskId: taskId,
            operation: SyncOperation(url: url, method: method, body: body,
                                     expectedVersion: version(for: "tasks/\(taskId)")),
            localTask: localTask))
        try commit(next)
    }

    // Snapshot, outbox, and receipt acknowledgement always commit together. A failed disk write
    // leaves the old queue intact; a committed server mutation can safely replay after a crash.
    private func commit(_ newState: SavedState) throws {
        var next = newState
        next.formatVersion = 5
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
        state = next
    }

    public func sync(token: String) async {
        guard !isSyncing, !state.serverURL.isEmpty else { return }
        isSyncing = true
        // Keep the offline status visible during retries; only a successful sync clears it.
        defer { isSyncing = false }
        do {
            let api = SyncAPI(baseURL: try SyncAPI.validatedURL(state.serverURL), token: token, session: session)
            let initialSnapshot = try await api.snapshot()
            guard initialSnapshot.protocolVersion >= 5 else {
                throw AppFailure("Update the Rust server to the task details and reminder units version before syncing. Your local changes are safe; older servers cannot save these fields.")
            }
            var refreshed = state
            refreshed.snapshot = initialSnapshot
            refreshed.lastSyncedAt = Date()
            try commit(refreshed)
            var attemptedWrite = false
            // ponytail: one FIFO and full snapshots fit a personal task list. Use per-entity queues
            // and a server change cursor if volume makes this expensive. Review blocks the queue.
            while let pending = state.pending.first, state.issue == nil {
                try Task.checkCancellation()
                let reply: SyncReply
                attemptedWrite = true
                do {
                    reply = try await api.apply(pending.operation)
                } catch let error as HTTPFailure where error.needsReview {
                    var next = state
                    next.issue = SyncIssue(taskId: pending.taskId, message: error.localizedDescription, entityKind: pending.entityKind)
                    try commit(next)
                    break
                }
                var next = state
                next.snapshot = reply.snapshot
                next.pending.removeFirst()
                // Only rebase the next *unsent* edit to this entity against our own receipt.
                // The snapshot may already contain a different device's later edit; using that
                // version here would silently overwrite it. Sent requests never change identity.
                if let index = next.pending.firstIndex(where: { $0.key == pending.key }),
                   let version = reply.changes[pending.key] {
                    next.pending[index].operation.expectedVersion = version
                }
                try commit(next)
            }
            if attemptedWrite {
                let snapshot = try await api.snapshot()
                var next = state
                next.snapshot = snapshot
                next.lastSyncedAt = Date()
                try commit(next)
            }
            syncError = nil
        } catch is CancellationError {
            // An interrupted request stays queued with its original id and body.
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            syncError = error.localizedDescription
        }
    }

    // Only definitive server rejections can be discarded. A timeout might have committed, so it
    // must be retried, not replaced with a new mutation id. Copying preserves both users' versions.
    public func resolveIssue(saveLocalCopy: Bool) throws {
        guard !isSyncing, let issue = state.issue, issue.isTask else { throw AppFailure("Wait for sync to finish before resolving this change.") }
        let local = tasks.first { $0.id == issue.taskId }
        var next = state
        next.pending.removeAll { $0.key == issue.key }
        next.issue = nil
        if saveLocalCopy {
            guard var copy = local else { throw AppFailure("This change deletes a task; there is no local task to copy.") }
            copy.id = UUID().uuidString.lowercased()
            copy.createdAt = Date().ISO8601Format()
            copy.updatedAt = copy.createdAt
            if !projects.contains(where: { $0.id == copy.projectId }) {
                copy.projectId = "inbox"
                copy.project = "Inbox"
            }
            next.pending.append(PendingMutation(taskId: copy.id,
                operation: SyncOperation(url: "/api/tasks", method: "POST", body: MutationBody(task: copy), expectedVersion: 0),
                localTask: copy))
        }
        try commit(next)
        syncError = nil
    }
}
