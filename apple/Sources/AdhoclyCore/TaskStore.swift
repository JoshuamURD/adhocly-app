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
            guard [1, 2, 3, 4, 5, 6, 7, 8].contains(state.formatVersion) else { throw AppFailure("Unsupported local data version. Update the app before opening this data.") }
        } else {
            state = SavedState()
        }
    }

    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Adhocly/state.json")
    }

    public var serverURL: String { state.serverURL }
    public var projects: [Project] {
        var projects = state.snapshot.projects
        for pending in state.pending where pending.entityKind == "projects" {
            projects.removeAll { $0.id == pending.taskId }
            if let project = pending.localProject { projects.append(project) }
        }
        return projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public var folders: [ProjectFolder] {
        var folders = state.snapshot.folders
        for pending in state.pending where pending.entityKind == "folders" {
            folders.removeAll { $0.id == pending.taskId }
            if let folder = pending.localFolder { folders.append(folder) }
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func folderPath(_ id: String) -> String {
        let folders = folders
        var names: [String] = [], visited = Set<String>(), current: String? = id
        while let id = current, visited.insert(id).inserted,
              let folder = folders.first(where: { $0.id == id }) {
            names.append(folder.name)
            current = folder.parentId
        }
        return names.reversed().joined(separator: " / ")
    }

    public func canMoveFolder(_ id: String, to parentId: String?) -> Bool {
        let folders = folders
        var visited: Set<String> = [id], current = parentId
        while let parent = current {
            guard visited.insert(parent).inserted,
                  let folder = folders.first(where: { $0.id == parent }) else { return false }
            current = folder.parentId
        }
        return true
    }

    public var contexts: [WorkContext] {
        var values = state.snapshot.contexts
        for pending in state.pending where pending.entityKind == "contexts" {
            values.removeAll { $0.id == pending.taskId }
            if let value = pending.localContext { values.append(value) }
        }
        return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var contacts: [Contact] {
        var values = state.snapshot.contacts
        for pending in state.pending where pending.entityKind == "contacts" {
            values.removeAll { $0.id == pending.taskId }
            if let value = pending.localContact { values.append(value) }
        }
        return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var contextLinks: [ContextLinks] {
        var values = state.snapshot.contextLinks
        for pending in state.pending {
            if pending.entityKind == "context-links" {
                values.removeAll { $0.id == pending.taskId }
                if let value = pending.localContextLinks { values.append(value) }
            } else if pending.operation.method == "DELETE" {
                values.removeAll { $0.id == "\(pending.entityKind ?? "tasks"):\(pending.taskId)" }
            }
        }
        return values
    }

    private func validateContextID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw AppFailure("Context, field and contact IDs must use letters, numbers, hyphens or underscores.")
        }
    }

    private func validateContextName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256 else {
            throw AppFailure("Use a nonempty name of at most 256 bytes.")
        }
    }

    public func saveContext(_ draft: WorkContext, replacing original: WorkContext? = nil) throws {
        var value = draft
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateContextID(value.id)
        try validateContextName(value.name)
        guard contexts.first(where: { $0.id == value.id }) == original,
              original == nil || original?.id == value.id else { throw AppFailure("This context changed. Reopen it before editing.") }
        guard value.fields.count <= 64 else { throw AppFailure("At most 64 fields per context.") }
        for index in value.fields.indices { value.fields[index].name = value.fields[index].name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(value.fields.map(\.id)).count == value.fields.count,
              Set(value.fields.map { $0.name.lowercased() }).count == value.fields.count else { throw AppFailure("Fields need unique IDs and names.") }
        for field in value.fields {
            try validateContextID(field.id)
            try validateContextName(field.name)
            if let old = original?.fields.first(where: { $0.id == field.id }), old.kind != field.kind {
                throw AppFailure("A field's type cannot change. Add a new field instead.")
            }
            if field.kind == .choice {
                guard !field.options.isEmpty, field.options.count <= 128,
                      field.options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 }),
                      Set(field.options.map { $0.lowercased() }).count == field.options.count else { throw AppFailure("Choice fields need 1–128 nonempty, unique options.") }
            } else if !field.options.isEmpty { throw AppFailure("Only choice fields can have options.") }
            try field.validate(field.value, contacts: contacts)
        }
        for link in contextLinks {
            for (id, override) in link.overrides[value.id] ?? [:] {
                guard let field = value.fields.first(where: { $0.id == id }) else { throw AppFailure("Remove local overrides before deleting their field.") }
                try field.validate(override, contacts: contacts)
            }
        }
        var body = MutationBody()
        body.id = value.id; body.name = value.name; body.fields = value.fields
        try enqueueContextEntity(kind: "contexts", id: value.id, body: body, context: value)
    }

    public func saveContact(_ draft: Contact, replacing original: Contact? = nil) throws {
        var value = draft
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateContextID(value.id)
        try validateContextName(value.name)
        guard contacts.first(where: { $0.id == value.id }) == original,
              original == nil || original?.id == value.id else { throw AppFailure("This contact changed. Reopen it before editing.") }
        guard value.email.utf8.count <= 320, value.phone.utf8.count <= 128, value.notes.utf8.count <= 65_536 else { throw AppFailure("Contact details are too long.") }
        var body = MutationBody()
        body.id = value.id; body.name = value.name; body.email = value.email; body.phone = value.phone; body.notes = value.notes
        try enqueueContextEntity(kind: "contacts", id: value.id, body: body, contact: value)
    }

    public func saveContextLinks(_ draft: ContextLinks, replacing original: ContextLinks) throws {
        guard draft.id == original.id, contextLinks(for: draft.id) == original else { throw AppFailure("These attachments changed. Reopen them before editing.") }
        let exists: Bool
        if draft.id.hasPrefix("tasks:") { exists = tasks.contains { "tasks:\($0.id)" == draft.id } }
        else if draft.id.hasPrefix("projects:") { exists = projects.contains { "projects:\($0.id)" == draft.id } }
        else { exists = folders.contains { "folders:\($0.id)" == draft.id } }
        guard exists else { throw AppFailure("Save this task, project or folder before attaching contexts.") }
        guard draft.contextIds.count <= 64, draft.overrides.count <= 64,
              Set(draft.contextIds).count == draft.contextIds.count,
              draft.contextIds.allSatisfy({ id in contexts.contains { $0.id == id } }) else { throw AppFailure("Choose up to 64 unique, existing contexts.") }
        for (id, values) in draft.overrides {
            guard let context = contexts.first(where: { $0.id == id }) else { throw AppFailure("An override references an unavailable context.") }
            for (fieldId, value) in values {
                guard let field = context.fields.first(where: { $0.id == fieldId }) else { throw AppFailure("An override references an unavailable field.") }
                try field.validate(value, contacts: contacts)
            }
        }
        if draft == original { return }
        var body = MutationBody()
        body.id = draft.id; body.contextIds = draft.contextIds; body.overrides = draft.overrides
        try enqueueContextEntity(kind: "context-links", id: draft.id, body: body, links: draft)
    }

    public func deleteContext(_ id: String) throws {
        guard contexts.contains(where: { $0.id == id }) else { throw AppFailure("Context no longer exists.") }
        guard !contextLinks.contains(where: { $0.contextIds.contains(id) || $0.overrides[id] != nil }) else {
            throw AppFailure("Detach this context and remove its overrides before deleting it.")
        }
        try enqueueContextEntity(kind: "contexts", id: id, body: MutationBody(), delete: true)
    }

    public func deleteContact(_ id: String) throws {
        guard contacts.contains(where: { $0.id == id }) else { throw AppFailure("Contact no longer exists.") }
        for context in contexts {
            for field in context.fields where field.kind == .contact {
                guard field.value != id, !contextLinks.contains(where: { $0.overrides[context.id]?[field.id] == id }) else {
                    throw AppFailure("Remove this contact from contexts and overrides before deleting it.")
                }
            }
        }
        try enqueueContextEntity(kind: "contacts", id: id, body: MutationBody(), delete: true)
    }

    private func enqueueContextEntity(kind: String, id: String, body: MutationBody, context: WorkContext? = nil,
                                      contact: Contact? = nil, links: ContextLinks? = nil, delete: Bool = false) throws {
        var next = state
        next.pending.append(PendingMutation(taskId: id,
            operation: SyncOperation(url: Self.entityPath(kind, id), method: delete ? "DELETE" : "PUT", body: body,
                                     expectedVersion: version(for: "\(kind)/\(id)")),
            entityKind: kind, localContext: context, localContact: contact, localContextLinks: links))
        try commit(next)
    }

    public var pendingCount: Int { state.pending.count }
    public var issue: SyncIssue? { state.issue }
    public var lastSyncedAt: Date? { state.lastSyncedAt }

    public var tasks: [TaskItem] {
        var tasks = state.snapshot.tasks
        for pending in state.pending {
            if pending.entityKind == nil || pending.entityKind == "tasks" {
                tasks.removeAll { $0.id == pending.taskId }
                if let task = pending.localTask { tasks.append(task) }
            } else if pending.entityKind == "projects", pending.operation.method == "DELETE" {
                // Match the server's cascade without changing immutable retry requests.
                for index in tasks.indices where tasks[index].projectId == pending.taskId {
                    tasks[index].projectId = "inbox"
                    tasks[index].project = projects.first { $0.id == "inbox" }?.name ?? "Inbox"
                }
            }
        }
        return tasks.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt > $1.createdAt
        }
    }

    public func search(_ text: String) -> (projects: [Project], tasks: [TaskItem]) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ([], []) }
        let projects = projects
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        return (
            projects.filter { $0.name.localizedStandardContains(query) },
            tasks.filter {
                $0.title.localizedStandardContains(query)
                    || $0.details.localizedStandardContains(query)
                    || contextSummary(for: $0).localizedStandardContains(query)
                    || (names[$0.projectId] ?? $0.project).localizedStandardContains(query)
            }
        )
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

    @discardableResult
    public func createProject(named name: String) throws -> Project {
        let mutation = try projectMutation(Project(id: UUID().uuidString.lowercased(), name: name))
        var next = state
        next.pending.append(mutation)
        try commit(next)
        return mutation.localProject!
    }

    private func projectMutation(_ draft: Project) throws -> PendingMutation {
        let project = Project(id: draft.id, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !project.name.isEmpty, !projects.contains(where: {
            $0.name.compare(project.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { throw AppFailure("Use a nonempty, unique project name.") }
        guard UUID(uuidString: project.id) != nil, !projects.contains(where: { $0.id == project.id }),
              state.snapshot.versions["projects/\(project.id)"] == nil else { throw AppFailure("This project ID is not available.") }
        var body = MutationBody()
        body.id = project.id; body.name = project.name
        return PendingMutation(taskId: project.id,
            operation: SyncOperation(url: "/api/projects", method: "POST", body: body, expectedVersion: 0),
            entityKind: "projects", localProject: project)
    }

    public func deleteProject(_ id: String) throws {
        guard id != "inbox" else { throw AppFailure("Inbox cannot be deleted.") }
        guard projects.contains(where: { $0.id == id }) else { throw AppFailure("Project no longer exists.") }
        var next = state
        next.pending.append(PendingMutation(taskId: id,
            operation: SyncOperation(url: Self.entityPath("projects", id), method: "DELETE",
                                     body: MutationBody(), expectedVersion: version(for: "projects/\(id)")),
            entityKind: "projects"))
        try commit(next)
    }

    public func moveProject(_ id: String, to folderId: String?) throws {
        guard id != "inbox" else { throw AppFailure("Inbox cannot be moved into a folder.") }
        guard var project = projects.first(where: { $0.id == id }) else { throw AppFailure("Project no longer exists.") }
        guard folderId == nil || folders.contains(where: { $0.id == folderId }) else { throw AppFailure("Folder no longer exists.") }
        guard project.folderId != folderId else { return }
        project.folderId = folderId
        var body = MutationBody()
        body.folderId = folderId
        var next = state
        next.pending.append(PendingMutation(taskId: id,
            operation: SyncOperation(url: Self.entityPath("projects", id) + "/folder", method: "PUT",
                                     body: body, expectedVersion: version(for: "projects/\(id)")),
            entityKind: "projects", localProject: project))
        try commit(next)
    }

    public func saveFolder(_ draft: ProjectFolder, replacing original: ProjectFolder? = nil) throws {
        var folder = draft
        folder.name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.name.isEmpty, !folders.contains(where: {
            $0.id != folder.id && $0.parentId == folder.parentId &&
            $0.name.compare(folder.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { throw AppFailure("Use a nonempty folder name that is unique within its parent.") }
        if let original {
            guard folder.id == original.id, folders.first(where: { $0.id == folder.id }) == original else {
                throw AppFailure("This folder changed. Reopen it before editing.")
            }
        } else {
            guard UUID(uuidString: folder.id) != nil, !folders.contains(where: { $0.id == folder.id }),
                  state.snapshot.versions["folders/\(folder.id)"] == nil else { throw AppFailure("This folder ID is not available.") }
        }
        guard canMoveFolder(folder.id, to: folder.parentId) else {
            throw AppFailure("Choose an existing parent outside this folder’s own subtree.")
        }
        var body = MutationBody()
        body.id = folder.id; body.name = folder.name; body.parentId = folder.parentId
        var next = state
        next.pending.append(PendingMutation(taskId: folder.id,
            operation: SyncOperation(url: original == nil ? "/api/folders" : Self.entityPath("folders", folder.id),
                                     method: original == nil ? "POST" : "PUT", body: body,
                                     expectedVersion: version(for: "folders/\(folder.id)")),
            entityKind: "folders", localFolder: folder))
        try commit(next)
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
        if issue.entityKind == "contexts" {
            data = try? encoder.encode((local ? contexts : state.snapshot.contexts).first { $0.id == issue.taskId })
        } else if issue.entityKind == "contacts" {
            data = try? encoder.encode((local ? contacts : state.snapshot.contacts).first { $0.id == issue.taskId })
        } else if issue.entityKind == "context-links" {
            data = try? encoder.encode((local ? contextLinks : state.snapshot.contextLinks).first { $0.id == issue.taskId })
        } else if issue.entityKind == "projects" {
            let value = (local ? projects : state.snapshot.projects).first { $0.id == issue.taskId }
            data = try? encoder.encode(value)
        } else if issue.entityKind == "folders" {
            let value = (local ? folders : state.snapshot.folders).first { $0.id == issue.taskId }
            data = try? encoder.encode(value)
        } else if issue.entityKind == "task-fields" {
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
            let exists: Bool
            switch issue.entityKind {
            case "contexts": exists = state.snapshot.contexts.contains { $0.id == issue.taskId }
            case "contacts": exists = state.snapshot.contacts.contains { $0.id == issue.taskId }
            case "context-links": exists = state.snapshot.contextLinks.contains { $0.id == issue.taskId }
            case "projects": exists = state.snapshot.projects.contains { $0.id == issue.taskId }
            case "folders": exists = state.snapshot.folders.contains { $0.id == issue.taskId }
            case "task-fields": exists = state.snapshot.taskFields.contains { $0.id == issue.taskId }
            default: exists = state.snapshot.boards.contains { $0.id == issue.taskId }
            }
            if issue.entityKind == "projects", replacement.operation.url.hasSuffix("/folder") {
                guard exists else { throw AppFailure("This project was deleted on the server. Discard its local move before continuing.") }
                // A move updates only folderId, not the project's name or metadata.
            } else if ["contexts", "contacts", "context-links"].contains(issue.entityKind ?? "") {
                // These use PUT upserts on a stable, independently revisioned URL.
            } else if replacement.operation.method != "DELETE" {
                replacement.operation.method = exists ? "PUT" : "POST"
                replacement.operation.url = exists ? Self.entityPath(issue.entityKind!, issue.taskId) : "/api/\(issue.entityKind!)"
            }
            // Keep configuration ahead of tasks that reference its new fields/options.
            if exists || replacement.operation.method != "DELETE" { next.pending.insert(replacement, at: 0) }
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

    public func save(_ draft: TaskItem, replacing original: TaskItem? = nil, creatingProject: Project? = nil) throws {
        var next = state
        var availableProjects = projects
        if let creatingProject {
            guard original == nil, draft.projectId == creatingProject.id else { throw AppFailure("The task must belong to the new project.") }
            let mutation = try projectMutation(creatingProject)
            next.pending.append(mutation)
            availableProjects.append(mutation.localProject!)
        }
        next.pending.append(try taskMutation(draft, replacing: original, availableProjects: availableProjects))
        // A new project and its first task reach disk together, with the project uploaded first.
        try commit(next)
    }

    private func taskMutation(_ draft: TaskItem, replacing original: TaskItem?, availableProjects: [Project]? = nil) throws -> PendingMutation {
        let projects = availableProjects ?? self.projects
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
        entityPath("tasks", id)
    }

    private static func entityPath(_ kind: String, _ id: String) -> String {
        let segment = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return "/api/\(kind)/\(segment)"
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
        next.formatVersion = 8
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
            guard initialSnapshot.protocolVersion >= 6 else {
                throw AppFailure("Update the Rust server to the contexts version before syncing. Your local changes are safe; older servers cannot save contexts.")
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
                // Project deletion also moves tasks to Inbox and advances their revisions.
                for (key, version) in reply.changes {
                    if let index = next.pending.firstIndex(where: { $0.key == key }),
                       key == pending.key || version == next.pending[index].operation.expectedVersion + 1 {
                        // A cascade may follow someone else's task edit. Do not rebase over it.
                        next.pending[index].operation.expectedVersion = version
                    }
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
            var links = contextLinks(for: "tasks:\(issue.taskId)")
            if !links.contextIds.isEmpty || !links.overrides.isEmpty {
                links.id = "tasks:\(copy.id)"
                var body = MutationBody()
                body.id = links.id; body.contextIds = links.contextIds; body.overrides = links.overrides
                next.pending.append(PendingMutation(taskId: links.id,
                    operation: SyncOperation(url: Self.entityPath("context-links", links.id), method: "PUT", body: body, expectedVersion: 0),
                    entityKind: "context-links", localContextLinks: links))
            }
        }
        try commit(next)
        syncError = nil
    }
}
