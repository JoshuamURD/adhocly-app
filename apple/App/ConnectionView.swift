import AdhoclyCore
import SwiftUI

struct ConnectionView: View {
    let model: AppModel
    let store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = ""
    @State private var token = ""
    @State private var error: String?
    @State private var showStatusEditor = false
    @AppStorage("captureDefaultTime") private var defaultTime = 9 * 60

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        WorkspaceIcon(symbol: "arrow.triangle.2.circlepath")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Your tasks, wherever you are.")
                                .font(.system(.title3, design: .serif, weight: .medium))
                            Text("Work offline anytime. Connect a server to keep your devices together.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }
                Section("Sync connection") {
                    TextField("Server URL", text: $serverURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    SecureField("API token (if required)", text: $token)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Text("Enter your server address, for example https://tasks.example.com (without /api).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Workflow") {
                    Button("Task statuses", systemImage: "checklist") { showStatusEditor = true }
                    Text("Add, rename, remove, or reorder the columns used by the status Kanban.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Capture and reminders") {
                    DatePicker("Default capture time", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: min(max(defaultTime, 0), 1439) / 60, minute: min(max(defaultTime, 0), 1439) % 60, second: 0, of: Date())! },
                        set: { defaultTime = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) }
                    ), displayedComponents: .hourAndMinute)
                    Text("! sets the due date; @ sets the planned date; / selects a project. Both dates schedule local notifications when alerts are enabled. Explicit times override this device’s default.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Enable notifications") { Task { await model.reminders.enable() } }
                    if let message = model.reminders.message { Text(message).font(.caption).foregroundStyle(.orange) }
                }
                Section {
                    Text("For local development, use http://localhost:3000 on Mac or Simulator, or http://your-mac.local:3000 on a phone.")
                    Text("Your token stays in this device’s Keychain. Tasks sync through the Rust server, not iCloud. This server currently shares one workspace per API token configuration; it does not provide individual user accounts.")
                    Text("Switching servers replaces the downloaded cache. Pending changes must sync first. HTTP is for trusted local development only; use HTTPS outside it.")
                }
                .font(.caption).foregroundStyle(.secondary)
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppStyle.canvas)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.configure(serverURL: serverURL)
                            try Credentials.save(token.trimmingCharacters(in: .whitespacesAndNewlines), server: store.serverURL)
                            dismiss()
                            Task { await model.sync() }
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(store.isSyncing || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            serverURL = store.serverURL.isEmpty ? "http://localhost:3000" : store.serverURL
            do { token = try Credentials.read(server: store.serverURL) }
            catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $showStatusEditor) {
            FieldEditorView(model: model, store: store, draft: store.statusField, original: store.statusField)
        }
        #if os(macOS)
        .frame(width: 540, height: 660)
        #endif
    }
}

struct SyncReviewView: View {
    let model: AppModel
    let store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var confirmKeep = false
    @State private var editingTask: EditorRequest?

    var body: some View {
        NavigationStack {
            Form {
                if let issue = store.issue {
                    Section("Sync paused") {
                        Text(issue.message).textSelection(.enabled)
                        Text(issue.isTask ? "Your changes are still saved locally. Keep them as a separate task, or discard them and use the server’s version. Neither choice overwrites someone else’s work." : "Review both configurations. Keeping yours replaces this server configuration, guarded by its latest downloaded revision. Discarding keeps the server version; tasks referencing discarded options may need review next.")
                    }
                    Section("Your local version") {
                        if issue.isTask {
                            let task = store.tasks.first { $0.id == issue.taskId }
                            summary(task)
                            if let task { Button("Edit local task") { editingTask = EditorRequest(draft: task, original: task) } }
                        } else { Text(store.configurationDescription(local: true)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                    Section("Last downloaded server version") {
                        if issue.isTask { summary(store.serverTask(issue.taskId)) }
                        else { Text(store.configurationDescription(local: false)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        Button("Refresh server version") { Task { await model.sync() } }
                            .disabled(store.isSyncing)
                        if let syncError = store.syncError { Text(syncError).foregroundStyle(.orange) }
                    }
                    Section {
                        if !issue.isTask {
                            Button("Keep my configuration") { confirmKeep = true }
                        } else if store.tasks.contains(where: { $0.id == issue.taskId }) {
                            Button("Save mine as a new task") { resolve(copy: true) }
                        }
                        Button("Discard local changes", role: .destructive) { confirmDiscard = true }
                    }
                    .disabled(store.isSyncing)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppStyle.canvas)
            .navigationTitle("Review change")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .confirmationDialog("Discard all pending changes to this item?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard local changes", role: .destructive) { resolve(copy: false) }
            }
            .confirmationDialog("Replace the server configuration with your local version?", isPresented: $confirmKeep, titleVisibility: .visible) {
                Button("Keep my configuration", role: .destructive) { resolve(copy: true) }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 640)
        #endif
        .taskEditor(model: model, store: store, request: $editingTask)
    }

    @ViewBuilder private func summary(_ task: TaskItem?) -> some View {
        if let task {
            Text(task.title).font(.headline)
            if !task.details.isEmpty { Text(task.details).textSelection(.enabled) }
            Text("\(task.project) · \(store.statusName(task.statusId))")
            ForEach(task.properties.keys.sorted(), id: \.self) { id in
                let field = store.taskFields.first { $0.id == id }
                LabeledContent(field?.name ?? id, value: field?.options.first { $0.id == task.properties[id] }?.name ?? task.properties[id] ?? "")
            }
            if let planned = task.plannedFor { Text("Planned: \(planned)") }
            if let due = task.dueOn { Text("Due: \(due)") }
            if let day = task.repeatWeekday, (0...6).contains(day) {
                Text("Repeats: \(Calendar(identifier: .gregorian).weekdaySymbols[day])")
            }
        } else {
            Text("Task absent or deleted").foregroundStyle(.secondary)
        }
    }

    private func resolve(copy: Bool) {
        do {
            if store.issue?.isTask == true { try store.resolveIssue(saveLocalCopy: copy) }
            else { try store.resolveConfigurationIssue(keepLocal: copy) }
            dismiss()
            Task { await model.sync() }
        } catch { self.error = error.localizedDescription }
    }
}
