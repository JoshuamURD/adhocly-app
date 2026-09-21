import AdhoclyCore
import SwiftUI

struct StatusEditorView: View {
    let model: AppModel
    let store: TaskStore
    @State var draft: TaskField
    let original: TaskField
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Status heading") {
                    TextField("Name", text: $draft.name)
                }
                Section("Statuses / columns") {
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
                            if ["todo", "complete"].contains(option.id) {
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
                    Button("Add status", systemImage: "plus") {
                        draft.options.append(FieldOption())
                    }
                }
                Section {
                    Text("The board uses this order. The default and Complete statuses can be renamed, but not removed. Moving to Complete finishes the task and creates recurring successors on sync.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppStyle.canvas)
            .navigationTitle("Task statuses")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) { EditButton() }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.saveStatuses(draft, replacing: original)
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
    @State private var showStatuses = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Board") {
                    TextField("Name", text: $draft.name)
                    Text("Boards group tasks by status. Moving a card changes its status everywhere.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Edit statuses") { showStatuses = true }
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
        .sheet(isPresented: $showStatuses) { StatusEditorView(model: model, store: store, draft: store.statusField, original: store.statusField) }
        #if os(macOS)
        .frame(width: 520, height: 480)
        #endif
    }
}
