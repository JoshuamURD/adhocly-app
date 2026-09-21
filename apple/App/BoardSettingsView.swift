import AdhoclyCore
import SwiftUI

private struct FieldRequest: Identifiable {
    var id: String { draft.id }
    let draft: TaskField
    let original: TaskField?
}

struct PropertiesView: View {
    let model: AppModel
    let store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var editor: FieldRequest?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.taskFields) { field in
                        Button {
                            editor = FieldRequest(draft: field, original: field)
                        } label: {
                            HStack {
                                Label(field.name, systemImage: field.id == "status" ? "checklist" : "tag")
                                Spacer()
                                Text(field.kind.rawValue.capitalized).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Status columns are shared by all tasks. Other boards can group tasks by a choice, text, or number property. Renaming an option keeps its tasks assigned.")
                }
            }
            .navigationTitle("Task properties")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add property", systemImage: "plus") { editor = FieldRequest(draft: TaskField(), original: nil) }
                }
            }
        }
        .sheet(item: $editor) { request in
            FieldEditorView(model: model, store: store, draft: request.draft, original: request.original)
        }
        #if os(macOS)
        .frame(width: 540, height: 520)
        #endif
    }
}

struct FieldEditorView: View {
    let model: AppModel
    let store: TaskStore
    @State var draft: TaskField
    let original: TaskField?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Property") {
                    TextField("Name", text: $draft.name)
                    if original == nil {
                        Picker("Type", selection: $draft.kind) {
                            ForEach(TaskField.Kind.allCases, id: \.self) { kind in Text(kind.rawValue.capitalized).tag(kind) }
                        }
                    } else { LabeledContent("Type", value: draft.kind.rawValue.capitalized) }
                }
                if draft.kind == .choice {
                    Section(draft.id == "status" ? "Statuses / columns" : "Options / columns") {
                        ForEach($draft.options) { $option in
                            HStack {
                                TextField("Option name", text: $option.name)
                                let index = draft.options.firstIndex { $0.id == option.id }!
                                Button("Move \(option.name) up", systemImage: "chevron.up") {
                                    moveOption(option.id, by: -1)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .disabled(index == draft.options.startIndex)
                                Button("Move \(option.name) down", systemImage: "chevron.down") {
                                    moveOption(option.id, by: 1)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .disabled(index == draft.options.index(before: draft.options.endIndex))
                                if draft.id == "status", ["todo", "complete"].contains(option.id) {
                                    Image(systemName: "lock").foregroundStyle(.secondary)
                                        .accessibilityLabel(option.id == "complete" ? "Special completion status" : "Default status")
                                } else {
                                    Button("Remove \(option.name)", systemImage: "minus.circle", role: .destructive) {
                                        let id = option.id
                                        draft.options.removeAll { $0.id == id }
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .onMove { draft.options.move(fromOffsets: $0, toOffset: $1) }
                        Button("Add \(draft.id == "status" ? "status" : "option")", systemImage: "plus") {
                            draft.options.append(FieldOption())
                        }
                    }
                    Section {
                        Text(draft.id == "status" ? "The board uses this order. The default and Complete statuses can be renamed, but not removed. Moving to Complete finishes the task and creates recurring successors on sync." : "Options have stable identities. Renaming an option updates its column without moving tasks. Move tasks before removing an option.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Kanban columns come from the distinct values assigned to tasks. Edit a task’s property to introduce a new column.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppStyle.canvas)
            .navigationTitle(original == nil ? "New property" : "Edit \(original!.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) { EditButton() }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.saveField(draft, replacing: original)
                            dismiss()
                            model.didSave()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 600)
        #endif
    }

    private func moveOption(_ id: String, by offset: Int) {
        guard let index = draft.options.firstIndex(where: { $0.id == id }),
              draft.options.indices.contains(index + offset) else { return }
        withAnimation { draft.options.swapAt(index, index + offset) }
    }
}

struct BoardEditorView: View {
    let model: AppModel
    let store: TaskStore
    @State var draft: KanbanBoard
    let original: KanbanBoard?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var showProperties = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Board") {
                    TextField("Name", text: $draft.name)
                    Picker("Columns from", selection: $draft.fieldId) {
                        ForEach(store.taskFields) { field in Text(field.name).tag(field.id) }
                    }
                    Text(draft.fieldId == "status" ? "Define your own columns by editing statuses. Moving a card changes its status everywhere." : "Moving a card changes this task property. Complete remains a separate, special column.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Manage statuses and properties") { showProperties = true }
                }
                Section("Card sorting") {
                    Picker("Sort all columns", selection: $draft.sortMode) {
                        ForEach(KanbanSort.allCases, id: \.self) { mode in Text(mode.name).tag(mode) }
                    }
                    Text(draft.sortMode == .manual
                         ? "Drop on the upper or lower half of a card to place it before or after. Sorting and order sync with this board."
                         : "Tasks without a date appear last. Sorting applies to every column and syncs with this board.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppStyle.canvas)
            .navigationTitle(original == nil ? "New board" : "Edit board")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.saveBoard(draft, replacing: original)
                            dismiss()
                            model.didSave()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
        .sheet(isPresented: $showProperties) { PropertiesView(model: model, store: store) }
        #if os(macOS)
        .frame(width: 520, height: 480)
        #endif
    }
}
