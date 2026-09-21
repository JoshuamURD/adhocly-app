import Foundation
import XCTest
@testable import AdhoclyCore

@MainActor final class ContextsTests: XCTestCase {
    private func file() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appending(path: "state.json")
    }

    func testCompositionInheritanceOverridesMovesAndPersistence() throws {
        let file = file(), store = try TaskStore(fileURL: file)
        let client = Contact(name: "Example client")
        try store.saveContact(client)
        var matter = WorkContext(name: "Matter")
        var number = ContextField(name: "Matter number", kind: .identifier)
        number.value = "M-123"
        var contact = ContextField(name: "Client", kind: .contact)
        contact.value = client.id
        matter.fields = [number, contact]
        try store.saveContext(matter)
        var software = WorkContext(name: "Website")
        var repo = ContextField(name: "Repository", kind: .link)
        repo.value = "https://example.com/repo"
        software.fields = [repo]
        try store.saveContext(software)
        let root = ProjectFolder(name: "Work"), child = ProjectFolder(name: "Clients", parentId: root.id)
        try store.saveFolder(root); try store.saveFolder(child)
        let project = try store.createProject(named: "Project")
        try store.moveProject(project.id, to: child.id)
        let task = TaskItem(title: "Review", projectId: project.id)
        try store.save(task)
        let rootOwner = "folders:\(root.id)", childOwner = "folders:\(child.id)", projectOwner = "projects:\(project.id)", taskOwner = "tasks:\(task.id)"
        var rootLinks = store.contextLinks(for: rootOwner)
        rootLinks.contextIds = [matter.id]
        try store.saveContextLinks(rootLinks, replacing: store.contextLinks(for: rootOwner))
        var childLinks = store.contextLinks(for: childOwner)
        childLinks.overrides = [matter.id: [number.id: "M-456"]]
        try store.saveContextLinks(childLinks, replacing: store.contextLinks(for: childOwner))
        var projectLinks = store.contextLinks(for: projectOwner)
        projectLinks.contextIds = [matter.id, software.id] // repeated attachment must not reset inherited overrides
        try store.saveContextLinks(projectLinks, replacing: store.contextLinks(for: projectOwner))
        XCTAssertEqual(store.resolvedContexts(for: taskOwner).map(\.id), [matter.id, software.id])
        XCTAssertEqual(store.resolvedContexts(for: taskOwner)[0].fields[0].value, "M-456")
        XCTAssertEqual(store.resolvedContexts(for: taskOwner)[0].fields[0].source, "Folder · Clients")
        XCTAssertTrue(store.contextSummary(for: task).contains("Example client"))
        XCTAssertEqual(store.search("M-456").tasks.map(\.id), [task.id])

        var local = store.contextLinks(for: taskOwner)
        local.overrides = [matter.id: [number.id: ""]]
        try store.saveContextLinks(local, replacing: store.contextLinks(for: taskOwner))
        XCTAssertEqual(store.resolvedContexts(for: taskOwner)[0].fields[0].value, "")
        XCTAssertEqual(store.resolvedContexts(for: taskOwner)[0].fields[0].source, "This task")
        XCTAssertEqual(store.contexts.first { $0.id == matter.id }?.fields[0].value, "M-123")
        let reopened = try TaskStore(fileURL: file)
        XCTAssertEqual(reopened.contextLinks, store.contextLinks)
        XCTAssertEqual(reopened.contexts, store.contexts)
        XCTAssertEqual(reopened.contacts, [client])
        XCTAssertThrowsError(try reopened.saveContextLinks(rootLinks, replacing: ContextLinks(id: rootOwner)))
        XCTAssertThrowsError(try reopened.deleteContext(matter.id))
        XCTAssertThrowsError(try reopened.deleteContact(client.id))
        var removing = matter
        removing.fields.removeFirst()
        XCTAssertThrowsError(try reopened.saveContext(removing, replacing: matter))
        var renamed = client
        renamed.name = "Renamed client"
        try reopened.saveContact(renamed, replacing: client)
        XCTAssertTrue(reopened.contextSummary(for: task).contains("Renamed client"))

        var reset = local
        reset.overrides = [:]
        try reopened.saveContextLinks(reset, replacing: local)
        XCTAssertEqual(reopened.resolvedContexts(for: taskOwner)[0].fields[0].value, "M-456")
        try reopened.moveProject(project.id, to: nil)
        XCTAssertEqual(reopened.resolvedContexts(for: taskOwner)[0].fields[0].value, "M-123")
        var detached = projectLinks
        detached.contextIds = []
        try reopened.saveContextLinks(detached, replacing: projectLinks)
        XCTAssertTrue(reopened.resolvedContexts(for: taskOwner).isEmpty)
        XCTAssertFalse(reopened.contextLinks(for: childOwner).overrides.isEmpty)
    }

    func testContextTaskListsTrackInheritanceLocalOverridesAndMoves() throws {
        let url = file(), store = try TaskStore(fileURL: url)
        var context = WorkContext(name: "Work")
        var field = ContextField(name: "Reference", kind: .identifier)
        field.value = "SHARED"
        context.fields = [field]
        try store.saveContext(context)
        let folder = ProjectFolder(name: "Clients")
        try store.saveFolder(folder)
        let project = try store.createProject(named: "Website")
        try store.moveProject(project.id, to: folder.id)
        let inherited = TaskItem(title: "Inherited", projectId: project.id)
        let overridden = TaskItem(title: "Overridden", projectId: project.id)
        let direct = TaskItem(title: "Direct")
        let repeated = TaskItem(title: "Repeated attachment", projectId: project.id)
        let inactive = TaskItem(title: "Inactive")
        let unrelated = TaskItem(title: "Unrelated")
        for task in [inherited, overridden, direct, repeated, inactive, unrelated] { try store.save(task) }
        func link(_ owner: String, attach: Bool = false, value: String? = nil) throws {
            let original = store.contextLinks(for: owner)
            var links = original
            if attach { links.contextIds = [context.id] }
            if let value { links.overrides = [context.id: [field.id: value]] }
            try store.saveContextLinks(links, replacing: original)
        }
        try link("folders:\(folder.id)", attach: true, value: "FOLDER")
        try link("tasks:\(overridden.id)", value: "") // Explicit clear is still an override.
        try link("tasks:\(direct.id)", attach: true, value: "SHARED") // So is an equal value.
        try link("tasks:\(repeated.id)", attach: true)
        try link("tasks:\(inactive.id)", value: "DORMANT")
        try store.toggle(inherited.id) // Completed tasks remain part of context membership.
        func ids(_ filter: ContextTaskFilter) -> Set<String> {
            Set(store.contextTaskUsage(for: context.id).filter { $0.matches(filter) }.map(\.id))
        }
        XCTAssertEqual(ids(.all), [inherited.id, overridden.id, direct.id, repeated.id])
        XCTAssertEqual(ids(.inherited), [inherited.id, overridden.id, repeated.id])
        XCTAssertEqual(ids(.direct), [direct.id, repeated.id])
        XCTAssertEqual(ids(.overridden), [overridden.id, direct.id])
        XCTAssertEqual(ids(.inactive), [inactive.id])
        let usage = store.contextTaskUsage(for: context.id)
        XCTAssertEqual(usage.first { $0.id == inherited.id }?.resolved?.fields[0].value, "FOLDER")
        XCTAssertEqual(usage.first { $0.id == overridden.id }?.resolved?.fields[0].value, "")
        XCTAssertEqual(usage.first { $0.id == overridden.id }?.overriddenFields.map(\.id), [field.id])
        XCTAssertTrue(store.contextTaskUsage(for: "missing").isEmpty)

        try store.moveProject(project.id, to: nil)
        XCTAssertEqual(ids(.all), [direct.id, repeated.id])
        XCTAssertTrue(ids(.inherited).isEmpty)
        XCTAssertEqual(ids(.inactive), [overridden.id, inactive.id])
        try link("projects:\(project.id)", attach: true)
        XCTAssertEqual(ids(.inherited), [inherited.id, overridden.id, repeated.id])
        try store.delete(direct.id)
        XCTAssertEqual(ids(.direct), [repeated.id])
        let reopened = try TaskStore(fileURL: url)
        XCTAssertEqual(reopened.contextTaskUsage(for: context.id).filter { $0.matches(.all) }.count, 3)
    }

    func testPropertyFiltersUseEffectiveValuesAndCombineOnTheSameContext() throws {
        let store = try TaskStore(fileURL: file())
        let client = Contact(name: "Client"), namesake = Contact(name: "Client")
        try store.saveContact(client); try store.saveContact(namesake)
        var context = WorkContext(name: "Software")
        var platform = ContextField(name: "Platform", kind: .choice)
        platform.options = ["Cloudflare", "Local"]
        platform.value = "Cloudflare"
        var contact = ContextField(name: "Client", kind: .contact)
        contact.value = client.id
        context.fields = [platform, contact]
        try store.saveContext(context)
        let project = try store.createProject(named: "Website")
        let task = TaskItem(title: "Deploy", projectId: project.id)
        try store.save(task)
        let owner = "projects:\(project.id)"
        let original = store.contextLinks(for: owner)
        var links = original
        links.contextIds = [context.id]
        links.overrides = [context.id: [platform.id: "Local"]]
        try store.saveContextLinks(links, replacing: original)
        let projectContext = try XCTUnwrap(store.resolvedContexts(for: owner).first)
        XCTAssertTrue(projectContext.matches(propertyValues: [:]))
        XCTAssertTrue(projectContext.matches(propertyValues: [platform.id: "Local", contact.id: client.id]))
        XCTAssertFalse(projectContext.matches(propertyValues: [platform.id: "Cloudflare"]))
        XCTAssertFalse(projectContext.matches(propertyValues: [platform.id: "Local", contact.id: namesake.id]))
        XCTAssertFalse(projectContext.matches(propertyValues: ["deleted-field": ""]))
        let inherited = try XCTUnwrap(store.contextTaskUsage(for: context.id).first?.resolved)
        XCTAssertTrue(inherited.matches(propertyValues: [platform.id: "Local"]))
        let taskOwner = "tasks:\(task.id)"
        let taskOriginal = store.contextLinks(for: taskOwner)
        var taskLinks = taskOriginal
        taskLinks.overrides = [context.id: [platform.id: "", contact.id: namesake.id]]
        try store.saveContextLinks(taskLinks, replacing: taskOriginal)
        let overridden = try XCTUnwrap(store.contextTaskUsage(for: context.id).first?.resolved)
        XCTAssertTrue(overridden.matches(propertyValues: [platform.id: "", contact.id: namesake.id]))
        XCTAssertFalse(overridden.matches(propertyValues: [platform.id: "Local"]))
        XCTAssertFalse(overridden.matches(propertyValues: [platform.id: "", contact.id: client.id]))
        XCTAssertFalse(projectContext.matches(propertyValues: [platform.id: ""]))
    }

    func testTypedValuesRejectInvalidInputsAndAllowExplicitClears() throws {
        let date = ContextField(name: "Date", kind: .date)
        for invalid in ["2026-02-29", "2026-04-31", "2026-1-01", "2026-01-01T00:00"] {
            XCTAssertThrowsError(try date.validate(invalid, contacts: []))
        }
        for valid in ["", "2028-02-29", "2026-01-01"] { XCTAssertNoThrow(try date.validate(valid, contacts: [])) }
        let link = ContextField(name: "Link", kind: .link)
        for invalid in ["javascript:alert(1)", "file:///etc/passwd", "https://", "not a link"] {
            XCTAssertThrowsError(try link.validate(invalid, contacts: []))
        }
        XCTAssertNoThrow(try link.validate("https://example.com/repo", contacts: []))
        var choice = ContextField(name: "Platform", kind: .choice)
        choice.options = ["Cloudflare", "Local"]
        XCTAssertThrowsError(try choice.validate("Unknown", contacts: []))
        XCTAssertNoThrow(try choice.validate("Cloudflare", contacts: []))
        XCTAssertNoThrow(try choice.validate("", contacts: []))
        XCTAssertThrowsError(try ContextField(name: "Client", kind: .contact).validate("missing", contacts: []))
    }

    func testRustContextsSyncConflictsRecurrenceAndContactReferences() async throws {
        guard let url = ProcessInfo.processInfo.environment["ADHOCLY_TEST_URL"] else {
            throw XCTSkip("Run scripts/test-integration.sh to exercise contexts sync")
        }
        let token = ProcessInfo.processInfo.environment["ADHOCLY_TEST_TOKEN"] ?? ""
        let aFile = file(), a = try TaskStore(fileURL: aFile), b = try TaskStore(fileURL: file())
        try a.configure(serverURL: url); try b.configure(serverURL: url)
        let client = Contact(name: "Sync client")
        try a.saveContact(client)
        var context = WorkContext(name: "Sync matter")
        var field = ContextField(name: "Client", kind: .contact)
        field.value = client.id
        var identifier = ContextField(name: "Matter number", kind: .identifier)
        identifier.value = "SYNC-123"
        context.fields = [field, identifier]
        try a.saveContext(context)
        let project = try a.createProject(named: "Contexts \(UUID().uuidString)")
        var task = TaskItem(title: "Context recurrence", projectId: project.id)
        task.repeatWeekday = 3
        try a.save(task)
        let projectOwner = "projects:\(project.id)", taskOwner = "tasks:\(task.id)"
        var links = a.contextLinks(for: projectOwner)
        links.contextIds = [context.id]
        try a.saveContextLinks(links, replacing: a.contextLinks(for: projectOwner))
        var local = a.contextLinks(for: taskOwner)
        local.overrides = [context.id: [identifier.id: "LOCAL-456"]]
        try a.saveContextLinks(local, replacing: a.contextLinks(for: taskOwner))
        let restored = try TaskStore(fileURL: aFile)
        await restored.sync(token: token)
        XCTAssertNil(restored.syncError); XCTAssertNil(restored.issue); XCTAssertEqual(restored.pendingCount, 0)
        await b.sync(token: token)
        XCTAssertEqual(b.contexts.first { $0.id == context.id }, context)
        XCTAssertEqual(b.contacts.first { $0.id == client.id }, client)
        XCTAssertEqual(b.resolvedContexts(for: taskOwner)[0].fields[1].value, "LOCAL-456")
        try restored.toggle(task.id)
        await restored.sync(token: token)
        XCTAssertNil(restored.issue)
        XCTAssertEqual(restored.resolvedContexts(for: "tasks:next:\(task.id)")[0].fields[1].value, "LOCAL-456")
        var renamed = client
        renamed.name = "Updated contact"
        try restored.saveContact(renamed, replacing: client)
        await restored.sync(token: token)
        var stale = client
        stale.name = "Offline contact"
        try b.saveContact(stale, replacing: client)
        await b.sync(token: token)
        XCTAssertEqual(b.issue?.entityKind, "contacts")
        XCTAssertTrue(b.configurationDescription(local: false).contains("Updated contact"))
        try b.resolveConfigurationIssue(keepLocal: true)
        await b.sync(token: token)
        XCTAssertNil(b.issue); XCTAssertEqual(b.pendingCount, 0)
        XCTAssertTrue(b.contextSummary(for: task).contains("Offline contact"))

        var aLinks = local
        aLinks.overrides[context.id]?[identifier.id] = "A"
        try restored.saveContextLinks(aLinks, replacing: local)
        await restored.sync(token: token)
        var bLinks = local
        bLinks.overrides[context.id]?[identifier.id] = "B"
        try b.saveContextLinks(bLinks, replacing: local)
        await b.sync(token: token)
        XCTAssertEqual(b.issue?.entityKind, "context-links")
        try b.resolveConfigurationIssue(keepLocal: true)
        await b.sync(token: token)
        XCTAssertNil(b.issue); XCTAssertEqual(b.resolvedContexts(for: taskOwner)[0].fields[1].value, "B")
        for id in [task.id, "next:\(task.id)"] { try b.delete(id) }
        try b.deleteProject(project.id)
        try b.deleteContext(context.id)
        try b.deleteContact(client.id)
        await b.sync(token: token)
        XCTAssertNil(b.syncError); XCTAssertNil(b.issue); XCTAssertEqual(b.pendingCount, 0)
        XCTAssertFalse(b.contextLinks.contains { [projectOwner, taskOwner, "tasks:next:\(task.id)"].contains($0.id) })
    }
}
