import AdhoclyCore
import SwiftUI

struct ProjectEditorView: View {
    @State var name = ""
    var taskTitle: String? = nil
    let save: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name)
                        .focused($isFocused)
                        .accessibilityLabel("Project name")
                        .onSubmit(create)
                    if let taskTitle {
                        Text("Create this project and add “\(taskTitle)” to it.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Group related tasks here. Projects save on this device and sync when connected.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppStyle.canvas)
            .navigationTitle("New project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(taskTitle == nil ? "Create project" : "Create & add task", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { isFocused = true }
        #if os(macOS)
        .frame(width: 460, height: 300)
        #endif
    }

    private func create() {
        do {
            try save(name)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct FolderEditorView: View {
    let model: AppModel
    let store: TaskStore
    @State var draft: ProjectFolder
    let original: ProjectFolder?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $draft.name)
                    .focused($isFocused)
                    .accessibilityLabel("Folder name")
                    .onSubmit(save)
                Picker("Parent folder", selection: $draft.parentId) {
                    Text("Top level").tag(String?.none)
                    ForEach(store.folders.filter { store.canMoveFolder(draft.id, to: $0.id) }) { folder in
                        Text(store.folderPath(folder.id)).tag(Optional(folder.id))
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppStyle.canvas)
            .navigationTitle(original == nil ? "New folder" : "Edit folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(original == nil ? "Create folder" : "Save", action: save)
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { isFocused = true }
        #if os(macOS)
        .frame(width: 460, height: 300)
        #endif
    }

    private func save() {
        do {
            try store.saveFolder(draft, replacing: original)
            model.didSave()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
