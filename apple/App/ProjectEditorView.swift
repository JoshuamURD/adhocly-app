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
