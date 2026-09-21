import Foundation

public struct Contact: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString.lowercased()
    public var name = ""
    public var email = ""
    public var phone = ""
    public var notes = ""
    public init(name: String = "") { self.name = name }
}

public struct ContextField: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case identifier, contact, choice, text, date, link, note
    }
    public var id = UUID().uuidString.lowercased()
    public var name: String
    public var kind: Kind
    public var options: [String] = []
    public var value = ""
    public init(name: String = "", kind: Kind = .text) { self.name = name; self.kind = kind }

    public func validate(_ value: String, contacts: [Contact]) throws {
        guard value.utf8.count <= 65_536 else { throw AppFailure("\(name) cannot exceed 64 KB.") }
        if value.isEmpty { return }
        switch kind {
        case .contact:
            guard contacts.contains(where: { $0.id == value }) else { throw AppFailure("Choose an available contact for \(name).") }
        case .choice:
            guard options.contains(value) else { throw AppFailure("Choose an available option for \(name).") }
        case .date:
            guard value.count == 10, let date = LocalDateTime.date(from: value + "T12:00"),
                  String(LocalDateTime.string(from: date).prefix(10)) == value else { throw AppFailure("\(name) must be a valid YYYY-MM-DD date.") }
        case .link:
            guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else { throw AppFailure("\(name) must be an absolute HTTP or HTTPS link.") }
        default: break
        }
    }
}

public struct WorkContext: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString.lowercased()
    public var name = ""
    public var fields: [ContextField] = []
    public init(name: String = "") { self.name = name }
}

public struct ContextLinks: Codable, Equatable, Identifiable, Sendable {
    /// One record per owner, e.g. projects:<id> or tasks:<id> (including recurring task ids).
    public var id: String
    public var contextIds: [String] = []
    /// Missing = inherit. Empty string = explicitly clear, without changing the shared context.
    public var overrides: [String: [String: String]] = [:]
    public init(id: String) { self.id = id }
}

public struct ResolvedContext: Identifiable, Sendable {
    public var id: String { context.id }
    public var context: WorkContext
    public var attachedAt: String
    public var fields: [ResolvedContextField]

    /// Match effective values, including explicit clears, rather than shared defaults.
    public func matches(propertyValues: [String: String]) -> Bool {
        propertyValues.allSatisfy { id, value in
            fields.contains { $0.id == id && $0.value == value }
        }
    }
}

public struct ResolvedContextField: Identifiable, Sendable {
    public var id: String { field.id }
    public var field: ContextField
    public var value: String
    public var source: String

    public init(field: ContextField, value: String, source: String) {
        self.field = field; self.value = value; self.source = source
    }
}

/// A live context relationship, independent of any screen or saved-view configuration.
public struct ContextTaskUsage: Identifiable, Sendable {
    public var id: String { task.id }
    public let task: TaskItem
    public let resolved: ResolvedContext?
    public let isDirect: Bool
    public let isInherited: Bool
    public let overriddenFields: [ContextField]

    public func matches(_ filter: ContextTaskFilter) -> Bool {
        switch filter {
        case .all: resolved != nil
        case .inherited: resolved != nil && isInherited
        case .direct: resolved != nil && isDirect
        case .overridden: resolved != nil && !overriddenFields.isEmpty
        case .inactive: resolved == nil && !overriddenFields.isEmpty
        }
    }
}

public enum ContextTaskFilter: String, CaseIterable, Sendable {
    case all = "All using context"
    case inherited = "Inherited"
    case direct = "Direct attachments"
    case overridden = "Task overrides"
    case inactive = "Inactive overrides"
}

public enum ContextInheritance {
    /// Root first, task last. A repeated attachment does not reset an ancestor's overrides.
    public static func resolve(contexts: [WorkContext], layers: [(name: String, links: ContextLinks)]) -> [ResolvedContext] {
        var result: [ResolvedContext] = []
        for layer in layers {
            for id in layer.links.contextIds where !result.contains(where: { $0.id == id }) {
                guard let context = contexts.first(where: { $0.id == id }) else { continue }
                result.append(ResolvedContext(context: context, attachedAt: layer.name, fields: context.fields.map {
                    ResolvedContextField(field: $0, value: $0.value, source: "Shared · \(context.name)")
                }))
            }
            for index in result.indices {
                for field in result[index].fields.indices {
                    if let value = layer.links.overrides[result[index].id]?[result[index].fields[field].id] {
                        result[index].fields[field].value = value
                        result[index].fields[field].source = layer.name
                    }
                }
            }
        }
        return result
    }
}

extension TaskStore {
    public func contextLinks(for owner: String) -> ContextLinks {
        contextLinks.first { $0.id == owner } ?? ContextLinks(id: owner)
    }

    // ponytail: scan the small local snapshot per item; cache ancestry if large workspaces need it.
    public func resolvedContexts(for owner: String, projectId: String? = nil, draft: ContextLinks? = nil) -> [ResolvedContext] {
        let projects = projects, folders = folders, links = contextLinks
        var layers: [(name: String, links: ContextLinks)] = []
        var visited = Set<String>()
        func append(_ key: String, _ name: String) {
            layers.append((name, key == draft?.id ? draft! : links.first { $0.id == key } ?? ContextLinks(id: key)))
        }
        func folder(_ id: String?) {
            guard let id, visited.insert(id).inserted, let item = folders.first(where: { $0.id == id }) else { return }
            folder(item.parentId)
            append("folders:\(id)", "Folder · \(item.name)")
        }
        func project(_ id: String?) {
            guard let item = projects.first(where: { $0.id == id }) else { return }
            folder(item.folderId)
            append("projects:\(item.id)", "Project · \(item.name)")
        }
        if owner.hasPrefix("tasks:") {
            let id = String(owner.dropFirst(6))
            project(projectId ?? tasks.first { $0.id == id }?.projectId)
            append(owner, "This task")
        } else if owner.hasPrefix("projects:") {
            project(String(owner.dropFirst(9)))
        } else if owner.hasPrefix("folders:") {
            folder(String(owner.dropFirst(8)))
        }
        return ContextInheritance.resolve(contexts: contexts, layers: layers)
    }

    public func contextTaskUsage(for contextId: String) -> [ContextTaskUsage] {
        guard let context = contexts.first(where: { $0.id == contextId }) else { return [] }
        let links = Dictionary(uniqueKeysWithValues: contextLinks.map { ($0.id, $0) })
        let inheritedProjects = Set(projects.filter {
            resolvedContexts(for: "projects:\($0.id)").contains { $0.id == contextId }
        }.map(\.id))
        return tasks.compactMap { task in
            let local = links["tasks:\(task.id)"]
            let resolved = resolvedContexts(for: "tasks:\(task.id)", projectId: task.projectId).first { $0.id == contextId }
            let overridden = context.fields.filter { local?.overrides[contextId]?[$0.id] != nil }
            guard resolved != nil || !overridden.isEmpty else { return nil }
            return ContextTaskUsage(task: task, resolved: resolved,
                                    isDirect: local?.contextIds.contains(contextId) == true,
                                    isInherited: inheritedProjects.contains(task.projectId), overriddenFields: overridden)
        }
    }

    public func contextValue(_ field: ContextField, value: String) -> String {
        field.kind == .contact ? contacts.first { $0.id == value }?.name ?? value : value
    }

    public func contextSummary(for task: TaskItem) -> String {
        resolvedContexts(for: "tasks:\(task.id)", projectId: task.projectId).map { context in
            let details = context.fields.filter { [.identifier, .contact].contains($0.field.kind) && !$0.value.isEmpty }
                .map { contextValue($0.field, value: $0.value) }
            return ([context.context.name] + details).joined(separator: " · ")
        }.joined(separator: " / ")
    }
}
