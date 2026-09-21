import Foundation
import XCTest
@testable import AdhoclyCore

// A tiny in-process HTTP peer. Each session gets its own host so parallel tests cannot share data.
private final class MockServer: @unchecked Sendable {
    let lock = NSLock()
    private var snapshot = Snapshot()
    private var receipts: [String: (SyncOperation, [String: Int64])] = [:]
    private var requests: [SyncOperation] = []
    private var loseReply = false
    private var status: Int?
    private var responseHook: (@Sendable () -> Void)?

    func beforeResponse(_ hook: (@Sendable () -> Void)?) { lock.withLock { responseHook = hook } }
    func protocolVersion(_ version: Int) { lock.withLock { snapshot.protocolVersion = version } }
    func loseNextReply() { lock.withLock { loseReply = true } }
    func reject(with status: Int?) { lock.withLock { self.status = status } }
    var sent: [SyncOperation] { lock.withLock { requests } }

    func editOnAnotherDevice(id: String, title: String) {
        lock.withLock {
            snapshot.tasks[snapshot.tasks.firstIndex { $0.id == id }!].title = title
            snapshot.versions["tasks/\(id)", default: 0] += 1
        }
    }

    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.withLock { responseHook }?()
        return try lock.withLock {
            if let status { return (status, Data("rejected".utf8)) }
            if request.httpMethod != "POST" { return (200, try JSONEncoder().encode(snapshot)) }
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let operation = try JSONDecoder().decode(SyncOperation.self, from: data)
            requests.append(operation)
            if let receipt = receipts[operation.id] {
                guard receipt.0 == operation else { return (409, Data("changed retry".utf8)) }
                return (200, try reply(changes: receipt.1))
            }
            let parts = operation.url.split(separator: "/").map { String($0).removingPercentEncoding! }
            let id = parts.count == 2 ? operation.body.id! : parts[2]
            let key = "\(parts[1])/\(id)"
            guard snapshot.versions[key, default: 0] == operation.expectedVersion else {
                return (409, Data("changed on another device".utf8))
            }
            if parts[1] == "projects" {
                snapshot.projects.removeAll { $0.id == id }
                snapshot.projects.append(Project(id: id, name: operation.body.name!))
            } else if operation.method == "DELETE" {
                snapshot.tasks.removeAll { $0.id == id }
            } else if parts.last == "toggle" {
                guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return (404, Data()) }
                snapshot.tasks[index].completed = operation.body.completed!
                snapshot.tasks[index].statusId = operation.body.completed! ? "complete" : "todo"
            } else {
                guard let project = snapshot.projects.first(where: { $0.id == operation.body.projectId }) else { return (400, Data("unknown project".utf8)) }
                var task = TaskItem(title: operation.body.title!, projectId: project.id, project: project.name)
                task.id = id
                task.details = operation.body.details ?? ""
                task.createdAt = "2026-04-01T00:00:00.000Z"
                task.updatedAt = task.createdAt
                task.completed = operation.body.completed!
                task.statusId = operation.body.statusId ?? (task.completed ? "complete" : "todo")
                task.properties = operation.body.properties ?? [:]
                task.reminders = operation.body.reminders ?? []
                task.plannedFor = operation.body.plannedFor
                task.dueOn = operation.body.dueOn
                task.repeatWeekday = operation.body.repeatWeekday
                snapshot.tasks.removeAll { $0.id == id }
                snapshot.tasks.append(task)
            }
            snapshot.versions[key, default: 0] += 1
            let changes = [key: snapshot.versions[key]!]
            receipts[operation.id] = (operation, changes)
            if loseReply {
                loseReply = false
                throw URLError(.networkConnectionLost)
            }
            return (200, try reply(changes: changes))
        }
    }

    private func reply(changes: [String: Int64]) throws -> Data {
        struct Reply: Encodable { let snapshot: Snapshot; let changes: [String: Int64] }
        return try JSONEncoder().encode(Reply(snapshot: snapshot, changes: changes))
    }
}

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var servers: [String: MockServer] = [:]
    }
    private static let registry = Registry()
    static func register(_ server: MockServer, host: String) {
        registry.lock.withLock { registry.servers[host] = server }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let server = Self.registry.lock.withLock { Self.registry.servers[request.url!.host!]! }
            let (status, data) = try server.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class TaskStoreTests: XCTestCase {
    private func file() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appending(path: "state.json")
    }

    private func connectedStore(server: MockServer, file: URL) throws -> (TaskStore, URLSession) {
        let host = UUID().uuidString.lowercased() + ".test"
        MockProtocol.register(server, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        let store = try TaskStore(fileURL: file, session: session)
        if store.serverURL.isEmpty { try store.configure(serverURL: "https://\(host)") }
        return (store, session)
    }

    func testProjectAndCapturePersistAtomicallyAndSyncInOrderAfterLostReply() async throws {
        let server = MockServer()
        let file = file()
        let (store, session) = try connectedStore(server: server, file: file)
        let project = try store.createProject(named: "  Café  ")
        XCTAssertEqual(project.name, "Café")
        for name in ["", "  ", "cafe", "INBOX"] { XCTAssertThrowsError(try store.createProject(named: name)) }
        let capture = try Capture.parse("First task /New project !tomorrow", projects: store.projects, allowNewProject: true)
        let newProject = try XCTUnwrap(capture.projectToCreate)
        var invalid = capture.task
        invalid.title = ""
        XCTAssertThrowsError(try store.save(invalid, creatingProject: newProject))
        XCTAssertFalse(store.projects.contains(newProject))
        XCTAssertEqual(store.pendingCount, 1)
        try store.save(capture.task, creatingProject: newProject)
        let queued = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
        XCTAssertEqual(queued.pending.map(\.operation.url), ["/api/projects", "/api/projects", "/api/tasks"])
        XCTAssertEqual(queued.pending.map(\.operation.expectedVersion), [0, 0, 0])
        XCTAssertThrowsError(try store.save(capture.task, creatingProject: newProject))
        server.loseNextReply()
        await store.sync(token: "")
        let restored = try TaskStore(fileURL: file, session: session)
        XCTAssertTrue(restored.projects.contains(project))
        XCTAssertTrue(restored.projects.contains(newProject))
        XCTAssertEqual(restored.tasks.first?.projectId, newProject.id)
        await restored.sync(token: "")
        XCTAssertNil(restored.syncError)
        XCTAssertNil(restored.issue)
        XCTAssertEqual(restored.pendingCount, 0)
        XCTAssertEqual(server.sent[0], server.sent[1])
        XCTAssertEqual(restored.tasks.first?.project, newProject.name)
        XCTAssertEqual(restored.tasks.first?.dueOn, capture.task.dueOn)

        // Disk failure must not leave a project without its task (or vice versa).
        let blocked = try TaskStore(fileURL: file.appending(path: "state.json"))
        XCTAssertThrowsError(try blocked.save(capture.task, creatingProject: newProject))
        XCTAssertEqual(blocked.projects.map(\.id), ["inbox"])
        XCTAssertTrue(blocked.tasks.isEmpty)
        XCTAssertEqual(blocked.pendingCount, 0)
    }

    func testProjectConfigurationReviewUsesProjectsNotBoards() throws {
        let file = file()
        let project = Project(id: UUID().uuidString.lowercased(), name: "Local project")
        let store = try TaskStore(fileURL: file)
        let task = TaskItem(title: "Keep this draft", projectId: project.id, project: project.name)
        try store.save(task, creatingProject: project)
        var state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
        state.snapshot.projects.append(Project(id: project.id, name: "Server project"))
        state.snapshot.versions["projects/\(project.id)"] = 1
        state.issue = SyncIssue(taskId: project.id, message: "Conflict", entityKind: "projects")
        try JSONEncoder().encode(state).write(to: file)
        let restored = try TaskStore(fileURL: file)
        XCTAssertTrue(restored.configurationDescription(local: true).contains("Local project"))
        XCTAssertTrue(restored.configurationDescription(local: false).contains("Server project"))
        try restored.resolveConfigurationIssue(keepLocal: true)
        let resolved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
        XCTAssertEqual(resolved.pending[0].operation.url, "/api/projects/\(project.id)")
        XCTAssertEqual(resolved.pending[0].operation.method, "PUT")
        XCTAssertEqual(resolved.pending[0].operation.expectedVersion, 1)
        XCTAssertEqual(restored.tasks.first?.id, task.id)
        XCTAssertNil(restored.issue)

        try JSONEncoder().encode(state).write(to: file)
        let discarded = try TaskStore(fileURL: file)
        try discarded.resolveConfigurationIssue(keepLocal: false)
        XCTAssertEqual(discarded.projects.first { $0.id == project.id }?.name, "Server project")
        XCTAssertEqual(discarded.tasks.first?.id, task.id)
        XCTAssertEqual(discarded.pendingCount, 1)
    }

    func testOfflineEditsAndDeletesSurviveRelaunch() throws {
        let file = file()
        let store = try TaskStore(fileURL: file)
        let task = TaskItem(title: "Offline")
        try store.save(task)
        let original = store.tasks[0]
        var edited = original
        edited.title = "Edited offline"
        try store.save(edited, replacing: original)
        try store.toggle(task.id)
        let relaunched = try TaskStore(fileURL: file)
        XCTAssertEqual(relaunched.tasks[0].title, "Edited offline")
        XCTAssertTrue(relaunched.tasks[0].completed)
        XCTAssertEqual(relaunched.pendingCount, 3)
        try relaunched.delete(task.id)
        let reloaded = try TaskStore(fileURL: file)
        XCTAssertTrue(reloaded.tasks.isEmpty)
        XCTAssertEqual(reloaded.pendingCount, 4)
    }

    func testDetailsAndRemindersSurviveOfflineRestartLostReplyAndRemoval() async throws {
        let server = MockServer()
        let file = file()
        let (store, session) = try connectedStore(server: server, file: file)
        var task = TaskItem(title: "Custom reminders")
        task.details = "First line of context\n" + String(repeating: "More detail. ", count: 500)
        task.dueOn = "2027-04-01T09:00"
        task.reminders = [CustomReminder(at: "2027-03-31T10:00", urgent: true),
                          CustomReminder(kind: .due, offsetUnit: .months, offsetValue: 2)]
        try store.save(task)
        server.loseNextReply()
        await store.sync(token: "")
        let restored = try TaskStore(fileURL: file, session: session)
        XCTAssertEqual(restored.tasks[0].details, task.details)
        XCTAssertEqual(restored.tasks[0].reminders, task.reminders)
        await restored.sync(token: "")
        XCTAssertNil(restored.syncError)
        XCTAssertEqual(server.sent[0], server.sent[1])
        XCTAssertEqual(restored.tasks[0].details, task.details)
        XCTAssertEqual(restored.tasks[0].reminders, task.reminders)
        let original = restored.tasks[0]
        var edited = original
        edited.details = ""
        edited.reminders.removeAll()
        try restored.save(edited, replacing: original)
        await restored.sync(token: "")
        XCTAssertNil(restored.syncError)
        XCTAssertEqual(restored.tasks[0].details, "")
        XCTAssertTrue(restored.tasks[0].reminders.isEmpty)
        XCTAssertEqual(restored.tasks[0].dueOn, task.dueOn)
    }

    func testQueuedCreateEditAndToggleUseReceiptRevisions() async throws {
        let server = MockServer()
        let (store, _) = try connectedStore(server: server, file: file())
        let task = TaskItem(title: "First")
        try store.save(task)
        let original = store.tasks[0]
        var edited = original
        edited.title = "Second"
        try store.save(edited, replacing: original)
        try store.toggle(task.id)
        await store.sync(token: "secret")
        XCTAssertNil(store.syncError)
        XCTAssertNil(store.issue)
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.tasks[0].title, "Second")
        XCTAssertTrue(store.tasks[0].completed)
        XCTAssertEqual(server.sent.map(\.expectedVersion), [0, 1, 2])
        try store.delete(task.id)
        await store.sync(token: "secret")
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testAcknowledgementTimestampsDoNotInvalidateOpenEditor() async throws {
        let server = MockServer()
        let (store, _) = try connectedStore(server: server, file: file())
        try store.save(TaskItem(title: "Pending create"))
        let original = store.tasks[0]
        await store.sync(token: "")
        XCTAssertNotEqual(store.tasks[0].createdAt, original.createdAt)
        var draft = original
        draft.title = "Edited while syncing"
        try store.save(draft, replacing: original)
        await store.sync(token: "")
        XCTAssertNil(store.issue)
        XCTAssertEqual(store.tasks[0].title, draft.title)
    }

    func testLostReplyRelaunchAndRemoteEditDoNotLoseEitherVersion() async throws {
        let server = MockServer()
        let file = file()
        let (store, session) = try connectedStore(server: server, file: file)
        let task = TaskItem(title: "Initial")
        try store.save(task)
        let original = store.tasks[0]
        var edited = original
        edited.title = "My offline edit"
        try store.save(edited, replacing: original)
        server.loseNextReply()
        await store.sync(token: "")
        XCTAssertEqual(store.pendingCount, 2)
        XCTAssertNotNil(store.syncError)
        server.editOnAnotherDevice(id: task.id, title: "Browser edit")

        let relaunched = try TaskStore(fileURL: file, session: session)
        await relaunched.sync(token: "")
        XCTAssertEqual(server.sent[0], server.sent[1], "A retry must preserve every operation field")
        XCTAssertEqual(server.sent.last?.expectedVersion, 1, "Use receipt revision, NOT the newer snapshot revision")
        XCTAssertEqual(relaunched.pendingCount, 1)
        XCTAssertNotNil(relaunched.issue)
        XCTAssertEqual(relaunched.tasks[0].title, "My offline edit")
        XCTAssertEqual(relaunched.serverTask(task.id)?.title, "Browser edit")

        try relaunched.resolveIssue(saveLocalCopy: true)
        await relaunched.sync(token: "")
        XCTAssertEqual(Set(relaunched.tasks.map(\.title)), ["Browser edit", "My offline edit"])
        XCTAssertEqual(relaunched.pendingCount, 0)
        XCTAssertNil(relaunched.issue)
    }

    func testOlderServerCannotSilentlyDiscardReminders() async throws {
        let server = MockServer()
        server.protocolVersion(4)
        let (store, _) = try connectedStore(server: server, file: file())
        var task = TaskItem(title: "Keep my status")
        task.statusId = "doing"
        task.reminders = [CustomReminder(at: "2027-04-01T08:00", urgent: true)]
        try store.save(task)
        await store.sync(token: "")
        XCTAssertTrue(server.sent.isEmpty)
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertTrue(store.syncError?.contains("Update the Rust server") == true)
        server.protocolVersion(5)
        await store.sync(token: "")
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.tasks[0].statusId, "doing")
        XCTAssertEqual(store.tasks[0].reminders, task.reminders)
    }

    func testAuthFailureDoesNotDiscardOrMakeUncertainOperationResolvable() async throws {
        let server = MockServer()
        let (store, _) = try connectedStore(server: server, file: file())
        try store.save(TaskItem(title: "Keep me"))
        server.reject(with: 401)
        await store.sync(token: "wrong")
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertNil(store.issue)
        XCTAssertTrue(store.syncError?.contains("token") == true)
        XCTAssertThrowsError(try store.resolveIssue(saveLocalCopy: false))
        server.reject(with: nil)
        await store.sync(token: "right")
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testSyncErrorStaysVisibleDuringRetryUntilRecovery() async throws {
        let server = MockServer()
        let (store, _) = try connectedStore(server: server, file: file())
        server.reject(with: 503)
        await store.sync(token: "")
        let offlineError = try XCTUnwrap(store.syncError)
        let requestStarted = expectation(description: "Retry in flight")
        let releaseResponse = DispatchSemaphore(value: 0)
        server.beforeResponse {
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 5)
        }

        let retry = Task { await store.sync(token: "") }
        await fulfillment(of: [requestStarted], timeout: 2)
        XCTAssertTrue(store.isSyncing)
        XCTAssertEqual(store.syncError, offlineError, "Retry must not collapse the offline status row")
        releaseResponse.signal()
        await retry.value
        XCTAssertEqual(store.syncError, offlineError)
        XCTAssertFalse(store.isSyncing)

        server.beforeResponse(nil)
        server.reject(with: nil)
        await store.sync(token: "")
        XCTAssertNil(store.syncError)
        XCTAssertFalse(store.isSyncing)
    }

    func testSyncWithoutServerLeavesLocalBoardUntouched() async throws {
        let store = try TaskStore(fileURL: file())
        try store.save(TaskItem(title: "Local card"))
        let tasks = store.tasks
        let boards = store.boards
        await store.sync(token: "")
        XCTAssertEqual(store.tasks, tasks)
        XCTAssertEqual(store.boards, boards)
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertFalse(store.isSyncing)
        XCTAssertNil(store.syncError)
        XCTAssertNil(store.lastSyncedAt)
    }

    func testUseServerDiscardsOnlyConflictingEntity() async throws {
        let server = MockServer()
        let (store, _) = try connectedStore(server: server, file: file())
        let task = TaskItem(title: "Initial")
        try store.save(task)
        await store.sync(token: "")
        let original = store.tasks[0]
        var edit = original
        edit.title = "Offline edit"
        try store.save(edit, replacing: original)
        try store.toggle(task.id)
        try store.save(TaskItem(title: "Unrelated"))
        server.editOnAnotherDevice(id: task.id, title: "Remote edit")
        await store.sync(token: "")
        try store.resolveIssue(saveLocalCopy: false)
        XCTAssertEqual(store.pendingCount, 1)
        await store.sync(token: "")
        XCTAssertEqual(Set(store.tasks.map(\.title)), ["Remote edit", "Unrelated"])
    }

    func testCorruptionAndDiskErrorsNeverSilentlyReplaceData() throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("not JSON".utf8)
        try invalid.write(to: file)
        XCTAssertThrowsError(try TaskStore(fileURL: file))
        XCTAssertEqual(try Data(contentsOf: file), invalid)
        // A regular file as parent guarantees persistence fails, including for privileged users.
        let store = try TaskStore(fileURL: file.appending(path: "state.json"))
        XCTAssertThrowsError(try store.save(TaskItem(title: "Cannot save")))
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testConnectionIsolationStaleDraftAndInputValidation() throws {
        let store = try TaskStore(fileURL: file())
        XCTAssertThrowsError(try store.configure(serverURL: "http://public.example.com"))
        XCTAssertThrowsError(try store.configure(serverURL: "https://user:password@example.com"))
        XCTAssertThrowsError(try store.configure(serverURL: "https://example.com?token=secret"))
        try store.configure(serverURL: "http://localhost:3000/")
        XCTAssertEqual(store.serverURL, "http://localhost:3000")
        XCTAssertThrowsError(try store.save(TaskItem(title: "  ")))
        var task = TaskItem(title: "Valid")
        task.dueOn = "not a date"
        XCTAssertThrowsError(try store.save(task))
        task.dueOn = "2026-04-01T09:30"
        try store.save(task)
        let original = store.tasks[0]
        try store.toggle(task.id)
        XCTAssertThrowsError(try store.save(original, replacing: original))
        XCTAssertThrowsError(try store.configure(serverURL: "https://another.example.com"))
        XCTAssertEqual(store.serverURL, "http://localhost:3000")
    }

    func testRustKanbanCaptureAndConfigurationConflicts() async throws {
        guard let url = ProcessInfo.processInfo.environment["ADHOCLY_TEST_URL"] else {
            throw XCTSkip("Run scripts/test-integration.sh with a disposable Rust database")
        }
        let token = ProcessInfo.processInfo.environment["ADHOCLY_TEST_TOKEN"] ?? ""
        let file = file()
        let a = try TaskStore(fileURL: file)
        let b = try TaskStore(fileURL: self.file())
        try a.configure(serverURL: url)
        try b.configure(serverURL: url)
        await a.sync(token: token)
        let originalStatus = a.statusField
        var status = originalStatus
        let reviewId = "review-" + UUID().uuidString.lowercased()
        status.options.append(FieldOption(id: reviewId, name: reviewId))
        status.options[status.options.firstIndex { $0.id == "complete" }!].name = "Shipped"
        try a.saveField(status, replacing: originalStatus)
        let priority = TaskField(name: "Priority \(UUID().uuidString)", options: [FieldOption(id: "high", name: "High"), FieldOption(id: "low", name: "Low")])
        try a.saveField(priority)
        let board = KanbanBoard(name: "Priority board", fieldId: priority.id)
        try a.saveBoard(board)
        var captured = try Capture.parse("Send report !Monday 9am @two weeks from now /Inbox", projects: a.projects).task
        captured.statusId = reviewId
        captured.properties[priority.id] = "high"
        captured.repeatWeekday = 1
        try a.save(captured)

        let relaunched = try TaskStore(fileURL: file)
        await relaunched.sync(token: token)
        XCTAssertNil(relaunched.syncError)
        XCTAssertNil(relaunched.issue)
        XCTAssertEqual(relaunched.pendingCount, 0)
        await b.sync(token: token)
        let original = try XCTUnwrap(b.tasks.first { $0.id == captured.id })
        XCTAssertEqual(original.properties[priority.id], "high")
        XCTAssertEqual(original.statusId, reviewId)
        XCTAssertEqual(original.plannedFor, captured.plannedFor)
        XCTAssertEqual(original.dueOn, captured.dueOn)
        XCTAssertTrue(b.boards.contains(board))
        XCTAssertEqual(b.completeName, "Shipped")

        let lanes = Kanban.lanes(field: priority, tasks: relaunched.tasks, completeName: relaunched.completeName)
        try relaunched.move(captured.id, to: lanes.first { $0.value == "low" }!, on: board)
        await relaunched.sync(token: token)
        var offlineEdit = original
        offlineEdit.title = "Saved from a second device"
        try b.save(offlineEdit, replacing: original)
        await b.sync(token: token)
        XCTAssertNotNil(b.issue)
        try b.resolveIssue(saveLocalCopy: true)
        await b.sync(token: token)
        XCTAssertNil(b.issue)
        let copy = try XCTUnwrap(b.tasks.first { $0.title == offlineEdit.title })
        XCTAssertEqual(copy.properties[priority.id], "high")

        // A stale property editor cannot silently overwrite another device's configuration.
        var serverField = priority
        serverField.name = "Server priority \(priority.id)"
        try relaunched.saveField(serverField, replacing: priority)
        await relaunched.sync(token: token)
        var localField = priority
        localField.name = "Local priority \(priority.id)"
        try b.saveField(localField, replacing: priority)
        await b.sync(token: token)
        XCTAssertEqual(b.issue?.entityKind, "task-fields")
        XCTAssertEqual(b.tasks.count, 2, "Configuration outbox entries must not erase task projections")
        try b.resolveConfigurationIssue(keepLocal: true)
        await b.sync(token: token)
        XCTAssertNil(b.issue)
        await relaunched.sync(token: token)
        XCTAssertTrue(relaunched.taskFields.contains { $0.name == localField.name })

        try relaunched.move(captured.id, to: lanes.last!, on: board)
        await relaunched.sync(token: token)
        XCTAssertNil(relaunched.issue)
        let successor = try XCTUnwrap(relaunched.tasks.first { $0.id == "next:\(captured.id)" })
        XCTAssertEqual(successor.statusId, "todo")
        XCTAssertEqual(successor.properties[priority.id], "low")
        await b.sync(token: token)
        for id in [captured.id, successor.id, copy.id] { try b.delete(id) }
        try b.deleteBoard(board.id)
        await b.sync(token: token)
        XCTAssertNil(b.issue)
        XCTAssertEqual(b.pendingCount, 0)
        try b.saveField(originalStatus, replacing: b.statusField)
        await b.sync(token: token)
        XCTAssertNil(b.issue)
    }

    func testRustServerRoundTrip() async throws {
        guard let url = ProcessInfo.processInfo.environment["ADHOCLY_TEST_URL"] else {
            throw XCTSkip("Run scripts/test-integration.sh to exercise the actual Rust API")
        }
        let token = ProcessInfo.processInfo.environment["ADHOCLY_TEST_TOKEN"] ?? ""
        let aFile = file()
        let a = try TaskStore(fileURL: aFile)
        let b = try TaskStore(fileURL: file())
        try a.configure(serverURL: url)
        try b.configure(serverURL: url)
        let project = try a.createProject(named: "Swift project \(UUID().uuidString)")
        var task = TaskItem(title: "Swift integration \(UUID().uuidString)", projectId: project.id, project: project.name)
        task.details = "Longer task description\nWith a second line."
        task.plannedFor = "2026-04-01T09:00"
        task.repeatWeekday = 3
        task.reminders = [CustomReminder(kind: .planned, offsetUnit: .months, offsetValue: 2, urgent: true),
                          CustomReminder(at: "2026-03-30T09:00")]
        try a.save(task)
        let relaunched = try TaskStore(fileURL: aFile)
        await relaunched.sync(token: token)
        XCTAssertNil(relaunched.syncError)
        XCTAssertNil(relaunched.issue)
        XCTAssertEqual(relaunched.pendingCount, 0)
        await b.sync(token: token)
        let original = try XCTUnwrap(b.tasks.first { $0.id == task.id })
        XCTAssertEqual(original.plannedFor, task.plannedFor)
        XCTAssertEqual(original.details, task.details)
        XCTAssertEqual(original.reminders, task.reminders)
        XCTAssertTrue(b.projects.contains(project))
        XCTAssertEqual(original.projectId, project.id)
        XCTAssertEqual(original.project, project.name)

        try relaunched.toggle(task.id)
        await relaunched.sync(token: token)
        XCTAssertEqual(relaunched.tasks.first { $0.id == "next:\(task.id)" }?.details, task.details)
        XCTAssertTrue(relaunched.tasks.contains { $0.id == "next:\(task.id)" })
        XCTAssertEqual(relaunched.tasks.first { $0.id == "next:\(task.id)" }?.reminders, [task.reminders[0]])
        var staleEdit = original
        staleEdit.title = "Kept from a second device"
        try b.save(staleEdit, replacing: original)
        await b.sync(token: token)
        XCTAssertNotNil(b.issue)
        try b.resolveIssue(saveLocalCopy: true)
        await b.sync(token: token)
        XCTAssertNil(b.syncError)
        XCTAssertNil(b.issue)
        let copy = try XCTUnwrap(b.tasks.first { $0.title == staleEdit.title })
        XCTAssertEqual(copy.details, task.details)
        for id in [task.id, "next:\(task.id)", copy.id] { try b.delete(id) }
        await b.sync(token: token)
        XCTAssertEqual(b.pendingCount, 0)
        await relaunched.sync(token: token)
        XCTAssertFalse(relaunched.tasks.contains { [task.id, "next:\(task.id)", copy.id].contains($0.id) })
    }
}

extension TaskStoreTests {
    func testRustBoardSortingSyncsAcrossDevicesAndConflictsSafely() async throws {
        guard let url = ProcessInfo.processInfo.environment["ADHOCLY_TEST_URL"] else {
            throw XCTSkip("Run scripts/test-integration.sh to exercise board sorting sync")
        }
        let token = ProcessInfo.processInfo.environment["ADHOCLY_TEST_TOKEN"] ?? ""
        let file = file()
        let a = try TaskStore(fileURL: file), b = try TaskStore(fileURL: self.file())
        try a.configure(serverURL: url)
        try b.configure(serverURL: url)
        let first = TaskItem(title: "Sorting Alpha"), second = TaskItem(title: "Sorting Bravo")
        try a.save(first)
        try a.save(second)
        var board = KanbanBoard(name: "Sorting integration", sortMode: .alphabetical)
        try a.saveBoard(board)
        await a.sync(token: token)
        XCTAssertNil(a.syncError)
        for mode in KanbanSort.allCases {
            var updated = board
            updated.sortMode = mode
            try a.saveBoard(updated, replacing: board)
            await a.sync(token: token)
            XCTAssertNil(a.syncError)
            XCTAssertNil(a.issue)
            await b.sync(token: token)
            board = try XCTUnwrap(a.boards.first { $0.id == board.id })
            XCTAssertEqual(b.boards.first { $0.id == board.id }, board)
            XCTAssertEqual(board.sortMode, mode)
        }
        let todo = Kanban.lanes(field: a.statusField, tasks: a.tasks, completeName: a.completeName)[0]
        try a.move(second.id, to: todo, on: board, relativeTo: first.id)
        let relaunched = try TaskStore(fileURL: file)
        await relaunched.sync(token: token)
        XCTAssertEqual(relaunched.pendingCount, 0)
        let serverOrder = try XCTUnwrap(relaunched.boards.first { $0.id == board.id })
        XCTAssertEqual(Kanban.sorted(relaunched.tasks, on: serverOrder).map(\.id), [second.id, first.id])
        // A second device still has the earlier board revision; never silently overwrite order.
        try b.move(first.id, to: todo, on: board, relativeTo: second.id, after: true)
        await b.sync(token: token)
        XCTAssertEqual(b.issue?.entityKind, "boards")
        try b.resolveConfigurationIssue(keepLocal: false)
        XCTAssertEqual(b.boards.first { $0.id == board.id }, serverOrder)
        for id in [first.id, second.id] { try b.delete(id) }
        try b.deleteBoard(board.id)
        await b.sync(token: token)
        XCTAssertNil(b.syncError)
        XCTAssertNil(b.issue)
        XCTAssertEqual(b.pendingCount, 0)
    }
}
