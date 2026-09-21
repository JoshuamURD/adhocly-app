import AdhoclyCore
import SwiftUI

struct ContextRequest: Identifiable {
    let id: String
    let title: String
}

struct ContextLibraryView: View {
    let model: AppModel
    let store: TaskStore
    let openProject: (String) -> Void
    let editTask: (TaskItem) -> Void
    @State private var context: WorkContext?
    @State private var search = ""

    var body: some View {
        List {
            Section("Contexts") {
                ForEach(store.contexts.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { value in
                    NavigationLink {
                        ContextDetailView(model: model, store: store, contextId: value.id,
                                          openProject: openProject, editTask: editTask)
                    } label: {
                        Label(value.name, systemImage: "square.stack.3d.up")
                    }
                    .accessibilityLabel(value.name)
                    .accessibilityIdentifier("context-\(value.id)")
                }
                if store.contexts.isEmpty {
                    Text("Create a context to keep shared information and related work together.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Contacts") {
                ForEach(store.contacts.filter {
                    search.isEmpty || $0.name.localizedStandardContains(search) || $0.email.localizedStandardContains(search)
                }) { value in
                    NavigationLink {
                        ContactDetailView(model: model, store: store, contactId: value.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(value.name)
                            if !value.email.isEmpty { Text(value.email).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if store.contacts.isEmpty {
                    Text("Shared contacts can be referenced by any context.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Contexts & contacts")
        .searchable(text: $search, prompt: "Find contexts and contacts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("New context", systemImage: "plus") {
                    Button("Blank context") { context = WorkContext() }
                    Button("Legal matter") {
                        var value = WorkContext(name: "New matter")
                        value.fields = [ContextField(name: "Matter number", kind: .identifier), ContextField(name: "Client", kind: .contact), ContextField(name: "Instructions & history", kind: .note)]
                        context = value
                    }
                    Button("Software project") {
                        var value = WorkContext(name: "New software project")
                        value.fields = [ContextField(name: "Client", kind: .contact), ContextField(name: "Repository", kind: .link), ContextField(name: "Deployment platform", kind: .text), ContextField(name: "Production website", kind: .link), ContextField(name: "Instructions", kind: .note)]
                        context = value
                    }
                }
                .accessibilityLabel("New context")
                .accessibilityIdentifier("new-context")
                .help("New context")
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    ContactEditorView(model: model, store: store, draft: Contact(), original: nil)
                } label: { Label("New contact", systemImage: "person.badge.plus") }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { context != nil }, set: { if !$0 { context = nil } }
        )) {
            if let context { ContextEditorView(model: model, store: store, draft: context, original: nil) }
        }
        .refreshable { await model.sync() }
    }
}

private struct ContextDetailView: View {
    let model: AppModel
    let store: TaskStore
    let contextId: String
    let openProject: (String) -> Void
    let editTask: (TaskItem) -> Void
    @State private var filter = ContextTaskFilter.all
    @State private var completion = "all"
    @State private var search = ""
    @State private var attachment: ContextRequest?

    var body: some View {
        Group {
            if let context = store.contexts.first(where: { $0.id == contextId }) {
                content(context)
                    .navigationTitle(context.name)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            NavigationLink {
                                ContextEditorView(model: model, store: store, draft: context, original: context)
                            } label: { Label("Edit context", systemImage: "pencil") }
                        }
                    }
            } else {
                ContentUnavailableView("Context unavailable", systemImage: "square.stack.3d.up",
                                       description: Text("It may have been deleted on another device."))
            }
        }
        .sheet(item: $attachment) { request in
            ContextAttachmentsView(model: model, store: store, owner: request.id, title: request.title)
        }
    }

    private func content(_ context: WorkContext) -> some View {
        let usage = store.contextTaskUsage(for: contextId)
        let visible = usage.filter {
            $0.matches(filter)
                && (completion == "all" || $0.task.completed == (completion == "completed"))
                && (search.isEmpty || $0.task.title.localizedStandardContains(search)
                    || $0.task.details.localizedStandardContains(search) || $0.task.project.localizedStandardContains(search))
        }
        let projects = store.projects.filter { project in
            store.resolvedContexts(for: "projects:\(project.id)").contains { $0.id == contextId }
                || store.contextLinks(for: "projects:\(project.id)").overrides[contextId] != nil
                || usage.contains { $0.task.projectId == project.id }
        }
        let folders = store.folders.filter { folder in
            let links = store.contextLinks(for: "folders:\(folder.id)")
            return links.contextIds.contains(contextId) || links.overrides[contextId] != nil
        }
        return List {
            Section("Shared information") {
                DisclosureGroup("\(context.fields.count) fields") {
                    ForEach(context.fields) { field in
                        ContextValueDisplay(store: store, field: ResolvedContextField(
                            field: field, value: field.value, source: "Shared · \(context.name)"))
                    }
                    if context.fields.isEmpty { Text("Add fields with Edit context.").foregroundStyle(.secondary) }
                }
            }
            Section("Tasks (\(visible.count))") {
                Picker("Relationship", selection: $filter) {
                    ForEach(ContextTaskFilter.allCases, id: \.self) { value in
                        Text("\(value.rawValue) (\(usage.filter { $0.matches(value) }.count))").tag(value)
                    }
                }
                .accessibilityIdentifier("context-task-filter")
                Picker("Status", selection: $completion) {
                    Text("All statuses").tag("all")
                    Text("To do").tag("active")
                    Text("Completed").tag("completed")
                }
                TextField("Filter tasks in this context", text: $search)
                    .accessibilityLabel("Filter tasks in this context")
                if filter == .inactive {
                    Text("These tasks retain local overrides but no longer use this context. Reattach it or remove the overrides from the task.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(visible) { item in taskRow(item) }
                if visible.isEmpty {
                    Text("No tasks match these filters.").foregroundStyle(.secondary)
                }
            }
            Section("Projects (\(projects.count))") {
                ForEach(projects) { project in
                    let owner = "projects:\(project.id)"
                    let resolved = store.resolvedContexts(for: owner).first { $0.id == contextId }
                    HStack {
                        Button { openProject(project.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(project.name, systemImage: "folder")
                                Text(resolved?.attachedAt ?? "Referenced by tasks or inactive overrides")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(usage.filter { $0.task.projectId == project.id && $0.resolved != nil }.count) tasks using this context")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open project \(project.name)")
                        Button { attachment = ContextRequest(id: owner, title: project.name) } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Manage contexts for \(project.name)")
                    }
                }
                if projects.isEmpty { Text("No projects use this context.").foregroundStyle(.secondary) }
            }
            if !folders.isEmpty {
                Section("Folder attachments & overrides") {
                    ForEach(folders) { folder in
                        Button { attachment = ContextRequest(id: "folders:\(folder.id)", title: store.folderPath(folder.id)) } label: {
                            Label(store.folderPath(folder.id), systemImage: "folder")
                        }
                    }
                }
            }
        }
        .refreshable { await model.sync() }
    }

    private func taskRow(_ usage: ContextTaskUsage) -> some View {
        let task = usage.task
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Button { model.perform { try store.toggle(task.id) } } label: {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                        .frame(width: AppStyle.controlSide, height: AppStyle.controlSide)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.completed ? "Mark \(task.title) incomplete" : "Complete \(task.title)")
                TaskQuickEdit(model: model, store: store, task: task, editDetails: editTask) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title).strikethrough(task.completed)
                        Text("\(task.project) · \(store.statusName(task.statusId))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            if let resolved = usage.resolved {
                Text(usage.isInherited ? "Inherited · \(resolved.attachedAt)\(usage.isDirect ? " · Also attached to task" : "")" : "Attached to task")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Effective context values") {
                    ForEach(resolved.fields) { field in ContextValueDisplay(store: store, field: field) }
                }
                .font(.callout)
            }
            if !usage.overriddenFields.isEmpty {
                Text("\(usage.resolved == nil ? "Inactive overrides" : "Task overrides"): \(usage.overriddenFields.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Manage task overrides") { attachment = ContextRequest(id: "tasks:\(task.id)", title: task.title) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ContactDetailView: View {
    let model: AppModel
    let store: TaskStore
    let contactId: String

    var body: some View {
        if let contact = store.contacts.first(where: { $0.id == contactId }) {
            Form {
                LabeledContent("Email", value: contact.email.isEmpty ? "Not set" : contact.email)
                LabeledContent("Phone", value: contact.phone.isEmpty ? "Not set" : contact.phone)
                Section("Notes") { Text(contact.notes.isEmpty ? "No notes" : contact.notes) }
            }
            .textSelection(.enabled)
            .formStyle(.grouped)
            .navigationTitle(contact.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ContactEditorView(model: model, store: store, draft: contact, original: contact)
                    } label: { Label("Edit contact", systemImage: "pencil") }
                }
            }
        } else {
            ContentUnavailableView("Contact unavailable", systemImage: "person.crop.circle.badge.questionmark")
        }
    }
}

private struct ContactEditorView: View {
    let model: AppModel
    let store: TaskStore
    @State var draft: Contact
    // Freeze the editing baseline even when sync refreshes the library.
    @State var original: Contact?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var deleting = false

    var body: some View {
        Form {
            TextField("Name", text: $draft.name).accessibilityLabel("Name")
            TextField("Email", text: $draft.email).accessibilityLabel("Email")
            TextField("Phone", text: $draft.phone).accessibilityLabel("Phone")
            TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...10).accessibilityLabel("Notes")
            Text("Editing this contact updates its details everywhere it is used.").font(.caption).foregroundStyle(.secondary)
            if original != nil { Button("Delete contact", role: .destructive) { deleting = true } }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle(original == nil ? "New contact" : "Edit shared contact")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { perform { try store.saveContact(draft, replacing: original) } }
            }
        }
        .confirmationDialog("Delete this contact?", isPresented: $deleting) {
            Button("Delete contact", role: .destructive) { perform { try store.deleteContact(draft.id) } }
        } message: { Text("Contacts still used by contexts cannot be deleted.") }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); model.didSave(); dismiss() } catch { self.error = error.localizedDescription }
    }
}

private struct ContextEditorView: View {
    let model: AppModel
    let store: TaskStore
    @State var draft: WorkContext
    @State var original: WorkContext?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var newContact: Contact?
    @State private var deleting = false

    var body: some View {
        Form {
            Section {
                TextField("Context name", text: $draft.name).accessibilityLabel("Context name")
                Text("Shared values apply everywhere this context is attached, unless a folder, project or task overrides them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($draft.fields) { $field in
                Section {
                    TextField("Field name", text: $field.name).accessibilityLabel("Field name")
                    Text(field.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    if field.kind == .choice {
                        TextField("Options (one per line)", text: Binding(
                            get: { field.options.joined(separator: "\n") },
                            set: { field.options = $0.components(separatedBy: "\n") }
                        ), axis: .vertical).lineLimit(2...8).accessibilityLabel("Options (one per line)")
                    }
                    ContextValueInput(field: field, value: $field.value, contacts: store.contacts)
                    Button("Remove field", role: .destructive) {
                        let id = field.id
                        draft.fields.removeAll { $0.id == id }
                    }
                }
            }
            Section {
                Menu("Add field", systemImage: "plus") {
                    ForEach(ContextField.Kind.allCases, id: \.self) { kind in
                        Button(kind.rawValue.capitalized) { draft.fields.append(ContextField(kind: kind)) }
                    }
                }
                .disabled(draft.fields.count >= 64)
                Button("New shared contact", systemImage: "person.badge.plus") { newContact = Contact() }
                if original != nil { Button("Delete context", role: .destructive) { deleting = true } }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .formStyle(.grouped)
        .navigationTitle(original == nil ? "New context" : "Edit shared context")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { perform { try store.saveContext(draft, replacing: original) } }
            }
        }
        .sheet(item: $newContact) { value in
            NavigationStack { ContactEditorView(model: model, store: store, draft: value, original: nil) }
                #if os(macOS)
                .frame(width: 560, height: 480)
                #endif
        }
        .confirmationDialog("Delete this context?", isPresented: $deleting) {
            Button("Delete context", role: .destructive) { perform { try store.deleteContext(draft.id) } }
        } message: { Text("Detach it and remove its local overrides first. Tasks and projects are kept.") }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); model.didSave(); dismiss() } catch { self.error = error.localizedDescription }
    }
}

private struct ContextValueInput: View {
    let field: ContextField
    @Binding var value: String
    let contacts: [Contact]

    var body: some View {
        switch field.kind {
        case .contact:
            Picker(field.name.isEmpty ? "Contact" : field.name, selection: $value) {
                Text("None").tag("")
                ForEach(contacts) { Text($0.name).tag($0.id) }
                if !value.isEmpty && !contacts.contains(where: { $0.id == value }) { Text("Unavailable contact").tag(value) }
            }
        case .choice:
            Picker(field.name.isEmpty ? "Value" : field.name, selection: $value) {
                Text("None").tag("")
                ForEach(Array(Set(field.options.filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) }
                if !value.isEmpty && !field.options.contains(value) { Text("Unavailable: \(value)").tag(value) }
            }
        case .date:
            Toggle(field.name.isEmpty ? "Date" : field.name, isOn: Binding(
                get: { !value.isEmpty }, set: { value = $0 ? String(LocalDateTime.string(from: Date()).prefix(10)) : "" }
            ))
            if !value.isEmpty {
                DatePicker("Date", selection: Binding(
                    get: { LocalDateTime.date(from: value + "T12:00") ?? Date() },
                    set: { value = String(LocalDateTime.string(from: $0).prefix(10)) }
                ), displayedComponents: .date)
            }
        case .note:
            TextField(field.name.isEmpty ? "Notes" : field.name, text: $value, axis: .vertical).lineLimit(4...16).accessibilityLabel(field.name.isEmpty ? "Notes" : field.name)
        default:
            TextField(field.name.isEmpty ? "Value" : field.name, text: $value, axis: .vertical).lineLimit(1...4).accessibilityLabel(field.name.isEmpty ? "Value" : field.name)
        }
    }
}

struct AttachContextMenu: View {
    let model: AppModel
    let store: TaskStore
    let owner: String

    var body: some View {
        let links = store.contextLinks(for: owner)
        Menu("Attach context", systemImage: "square.stack.3d.up") {
            ForEach(store.contexts) { context in
                let attached = links.contextIds.contains(context.id)
                Button {
                    model.perform {
                        let original = store.contextLinks(for: owner)
                        guard !original.contextIds.contains(context.id) else { return }
                        var updated = original
                        updated.contextIds.append(context.id)
                        try store.saveContextLinks(updated, replacing: original)
                    }
                } label: {
                    if attached { Label(context.name, systemImage: "checkmark") }
                    else { Text(context.name) }
                }
                .disabled(attached || links.contextIds.count >= 64)
            }
            if store.contexts.isEmpty {
                Text("Create a context in Contexts & contacts first.")
            }
        }
    }
}

struct ContextAttachmentsView: View {
    let model: AppModel
    let store: TaskStore
    let owner: String
    let title: String
    @State private var draft: ContextLinks
    // Keep the original revision's values while the observed store refreshes.
    @State private var original: ContextLinks
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    init(model: AppModel, store: TaskStore, owner: String, title: String) {
        self.model = model; self.store = store; self.owner = owner; self.title = title
        let links = store.contextLinks(for: owner)
        _original = State(initialValue: links)
        _draft = State(initialValue: links)
    }

    private var resolved: [ResolvedContext] { store.resolvedContexts(for: owner, draft: draft) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.headline)
                    Text("Overrides apply only here and to descendants. Clear a value to hide the inherited value, or turn off Override to inherit again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu("Attach context", systemImage: "plus") {
                        ForEach(store.contexts.filter { !draft.contextIds.contains($0.id) }) { context in
                            Button(context.name) { draft.contextIds.append(context.id) }
                        }
                    }
                    .disabled(draft.contextIds.count >= 64)
                    Text("Create and manage shared contexts in the Contexts & contacts workspace.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(resolved) { context in
                    Section(context.context.name) {
                        Text("Attached at \(context.attachedAt)").font(.caption).foregroundStyle(.secondary)
                        ForEach(context.fields) { field in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Override \(field.field.name)", isOn: Binding(
                                    get: { draft.overrides[context.id]?[field.id] != nil },
                                    set: { enabled in
                                        if enabled { draft.overrides[context.id, default: [:]][field.id] = field.value }
                                        else { reset(context.id, field.id) }
                                    }
                                ))
                                if draft.overrides[context.id]?[field.id] != nil {
                                    ContextValueInput(field: field.field, value: Binding(
                                        get: { draft.overrides[context.id]?[field.id] ?? "" },
                                        set: { draft.overrides[context.id, default: [:]][field.id] = $0 }
                                    ), contacts: store.contacts)
                                } else {
                                    ContextValueDisplay(store: store, field: field)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        if draft.contextIds.contains(context.id) {
                            Button("Detach here", role: .destructive) {
                                draft.contextIds.removeAll { $0 == context.id }
                            }
                            Text("An ancestor's attachment will still be inherited.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                let dormant = draft.overrides.keys.filter { id in !resolved.contains { $0.id == id } }.sorted()
                if !dormant.isEmpty {
                    Section("Inactive overrides") {
                        Text("Kept after moving or detaching. They apply again if this context is inherited or attached.").font(.caption)
                        ForEach(dormant, id: \.self) { id in
                            Button("Remove overrides: \(store.contexts.first { $0.id == id }?.name ?? id)", role: .destructive) {
                                draft.overrides[id] = nil
                            }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Contexts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try store.saveContextLinks(draft, replacing: original); model.didSave(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .accessibilityIdentifier("save-context-attachments")
                }
            }
        }
        #if os(macOS)
        .frame(width: 620, height: 700)
        #endif
    }

    private func reset(_ context: String, _ field: String) {
        draft.overrides[context]?[field] = nil
        if draft.overrides[context]?.isEmpty == true { draft.overrides[context] = nil }
    }
}

struct TaskContextSection: View {
    let store: TaskStore
    let task: TaskItem

    var body: some View {
        let contexts = store.resolvedContexts(for: "tasks:\(task.id)", projectId: task.projectId)
        ForEach(contexts) { context in
            DisclosureGroup {
                ForEach(context.fields) { field in ContextValueDisplay(store: store, field: field) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.context.name).font(.headline)
                    Text(context.attachedAt).font(.caption).foregroundStyle(.secondary)
                    let key = context.fields.filter { [.identifier, .contact].contains($0.field.kind) && !$0.value.isEmpty }
                    ForEach(key) { field in
                        Text("\(field.field.name): \(store.contextValue(field.field, value: field.value))")
                            .font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
        if contexts.isEmpty { Text("No context attached or inherited.").foregroundStyle(.secondary) }
    }
}

private struct ContextValueDisplay: View {
    let store: TaskStore
    let field: ResolvedContextField

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.field.name).font(.caption.weight(.semibold))
            if field.field.kind == .link, let url = URL(string: field.value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                Link(field.value, destination: url)
            } else {
                Text(field.value.isEmpty ? "Not set" : store.contextValue(field.field, value: field.value)).textSelection(.enabled)
            }
            if field.field.kind == .contact, let contact = store.contacts.first(where: { $0.id == field.value }) {
                if !contact.email.isEmpty { Text(contact.email).textSelection(.enabled) }
                if !contact.phone.isEmpty { Text(contact.phone).textSelection(.enabled) }
                if !contact.notes.isEmpty { Text(contact.notes).textSelection(.enabled) }
            }
            Text(field.source).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct TaskContextLabel: View {
    let store: TaskStore
    let task: TaskItem
    var body: some View {
        let summary = store.contextSummary(for: task)
        if !summary.isEmpty {
            Label(summary, systemImage: "square.stack.3d.up")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .accessibilityLabel("Context: \(summary)")
                .help(summary)
        }
    }
}
