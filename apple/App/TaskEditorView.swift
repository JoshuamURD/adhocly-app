import AdhoclyCore
import SwiftUI

struct EditorRequest: Identifiable {
    var id: String { draft.id }
    let draft: TaskItem
    let original: TaskItem?
}

extension View {
    func taskEditor(model: AppModel, store: TaskStore, request: Binding<EditorRequest?>) -> some View {
        modifier(TaskEditorPresentation(model: model, store: store, request: request))
    }
}

private struct TaskEditorPresentation: ViewModifier {
    let model: AppModel
    let store: TaskStore
    @Binding var request: EditorRequest?
    @State private var activeRequest: EditorRequest?
    @State private var isDirty = false
    @State private var confirmDiscard = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content.inspector(isPresented: Binding(
            get: { activeRequest != nil }, set: { if !$0 { request = nil } }
        )) {
            if let activeRequest {
                editor(activeRequest)
                    .id(activeRequest.id)
                    .inspectorColumnWidth(min: 360, ideal: 440, max: 600)
                    .interactiveDismissDisabled(isDirty)
            }
        }
        .onChange(of: request?.id, initial: true) { _, id in
            guard id != activeRequest?.id else { return }
            if isDirty { confirmDiscard = true }
            else { activeRequest = request }
        }
        .confirmationDialog("Discard unsaved task changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) {
                isDirty = false
                activeRequest = request
            }
            Button("Keep editing", role: .cancel) { request = activeRequest }
        }
        #else
        content.sheet(item: $request) { editor($0) }
        #endif
    }

    private func editor(_ request: EditorRequest) -> some View {
        TaskEditorView(model: model, store: store, draft: request.draft, original: request.original,
                       onEdit: { isDirty = $0 != request.draft }) {
            isDirty = false
            activeRequest = nil
            self.request = nil
        }
    }
}

struct TaskEditorView: View {
    let model: AppModel
    let store: TaskStore
    @State var draft: TaskItem
    let original: TaskItem?
    let onEdit: (TaskItem) -> Void
    let dismiss: () -> Void
    @State private var error: String?
    @State private var showNewProject = false
    @State private var showContexts = false

    var body: some View {
        Group {
            #if os(macOS)
            desktopEditor
            #else
            NavigationStack {
                taskForm
                    .navigationTitle(original == nil ? "New task" : "Edit task")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) { saveButton }
                    }
            }
            #endif
        }
        .onChange(of: draft) { _, draft in onEdit(draft) }
        .sheet(isPresented: $showContexts) {
            ContextAttachmentsView(model: model, store: store, owner: "tasks:\(draft.id)", title: draft.title)
        }
        .sheet(isPresented: $showNewProject) {
            ProjectEditorView { name in
                let project = try store.createProject(named: name)
                draft.projectId = project.id
                draft.project = project.name
                model.didSave()
            }
        }
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    #if os(macOS)
    private var desktopEditor: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text(original == nil ? "New task" : "Edit task")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                TextField("Task title", text: $draft.title, prompt: Text("What needs doing?"), axis: .vertical)
                    .font(AppStyle.editorFont)
                    .lineLimit(1...3)
                    .accessibilityLabel("Task title")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextEditor(text: $draft.details)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 100)
                        .accessibilityLabel("Task details")
                        .overlay(alignment: .topLeading) {
                            if draft.details.isEmpty {
                                Text("Add a longer description, notes, or context…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(12)
                        .background(AppStyle.canvas, in: RoundedRectangle(cornerRadius: AppStyle.cardRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: AppStyle.cardRadius)
                                .strokeBorder(AppStyle.border)
                                .allowsHitTesting(false)
                        }
                }
            }
            // macOS Form treats a TextField title as a persistent, leading label.
            // Keep free-form writing outside that label/value layout and use real prompts.
            .textFieldStyle(.plain)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .background(AppStyle.surface)
            Divider()
            taskForm
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    saveButton.buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(AppStyle.surface)
        }
    }
    #endif

    private var taskForm: some View {
        Form {
            #if os(iOS)
            Section {
                TextField("Task title", text: $draft.title, prompt: Text("What needs doing?"), axis: .vertical)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .font(AppStyle.editorFont)
                    .lineLimit(2...6)
                    .accessibilityLabel("Task title")
            }
            Section("Details") {
                TextField("Task details", text: $draft.details, prompt: Text("Add a longer description, notes, or context…"), axis: .vertical)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .lineLimit(3...10)
                    .accessibilityLabel("Task details")
            }
            #endif
            Section("Organize") {
                Picker("Project", selection: $draft.projectId) {
                    ForEach(store.projects) { project in Text(project.name).tag(project.id) }
                }
                Button("New project", systemImage: "folder.badge.plus") { showNewProject = true }
                Picker(store.statusField.name, selection: $draft.statusId) {
                    ForEach(store.statusField.options) { option in Text(option.name).tag(option.id) }
                }
            }
            Section("Contexts") {
                TaskContextSection(store: store, task: draft)
                if original != nil && draft.projectId == original?.projectId {
                    Button("Attach or override contexts…") { showContexts = true }
                } else {
                    Text("Save the task and its project before attaching or overriding contexts.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                OptionalDatePicker(title: "Planned", value: $draft.plannedFor)
                OptionalDatePicker(title: "Due", value: $draft.dueOn)
                Picker("Repeat weekly", selection: Binding(
                    get: { draft.repeatWeekday ?? -1 },
                    set: { draft.repeatWeekday = $0 == -1 ? nil : $0 }
                )) {
                    Text("Never").tag(-1)
                    // Rust/SQLite use Sunday = 0, matching Gregorian weekdaySymbols.
                    ForEach(Array(Calendar(identifier: .gregorian).weekdaySymbols.enumerated()), id: \.offset) { day in
                        Text(day.element).tag(day.offset)
                    }
                }
            } header: {
                Label("Make time for it", systemImage: "calendar")
            } footer: {
                Text("Plan when to work on it; set a due date for the deadline. Repeating tasks renew after completion and sync.")
            }
            Section {
                ForEach($draft.reminders) { $reminder in
                    VStack(alignment: .leading, spacing: 12) {
                        CustomReminderEditor(reminder: $reminder, task: draft)
                        Button("Remove reminder", systemImage: "trash", role: .destructive) {
                            let id = reminder.id
                            draft.reminders.removeAll { $0.id == id }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Button("Add reminder", systemImage: "bell.badge") {
                    if draft.dueOn != nil || draft.plannedFor != nil {
                        draft.reminders.append(CustomReminder(kind: draft.dueOn != nil ? .due : .planned,
                                                              offsetUnit: .days, offsetValue: 1))
                    } else {
                        draft.reminders.append(CustomReminder(at: LocalDateTime.string(from: Date().addingTimeInterval(3_600))))
                    }
                }
                .disabled(draft.reminders.count >= TaskReminders.limit)
            } header: {
                Label("Extra reminders", systemImage: "bell")
            } footer: {
                Text("Planned and due dates already include an alert. Add an earlier nudge or a separate reminder. Urgent alerts follow your system’s Time Sensitive settings. Past reminders won’t send an alert.")
            }
            #if os(iOS)
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            #endif
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(AppStyle.canvas)
    }

    private var saveButton: some View {
        Button("Save") {
            do {
                try store.save(draft, replacing: original)
                dismiss()
                model.didSave()
            } catch { self.error = error.localizedDescription }
        }
        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.defaultAction)
    }
}

private struct OptionalDatePicker: View {
    let title: String
    @Binding var value: String?

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { value != nil },
            set: { value = $0 ? LocalDateTime.string(from: Date()) : nil }
        ))
        if value != nil {
            DatePicker("\(title) date", selection: Binding(
                get: { value.flatMap(LocalDateTime.date(from:)) ?? Date() },
                set: { value = LocalDateTime.string(from: $0) }
            ), displayedComponents: [.date, .hourAndMinute])
        }
    }
}

private struct CustomReminderEditor: View {
    @Binding var reminder: CustomReminder
    let task: TaskItem

    var body: some View {
        Picker("Remind me", selection: Binding(
            get: { reminder.kind },
            set: { kind in
                guard reminder.kind != kind else { return }
                reminder.kind = kind
                reminder.at = kind == .custom ? LocalDateTime.string(from: Date().addingTimeInterval(3_600)) : nil
                if kind == .custom {
                    reminder.offsetMinutes = nil
                    reminder.offsetUnit = nil
                    reminder.offsetValue = nil
                } else if reminder.relativeOffset == nil {
                    reminder.setOffset(unit: .days, value: 1)
                }
            }
        )) {
            Text("On a date and time").tag(CustomReminder.Kind.custom)
            Text("Before planned date").tag(CustomReminder.Kind.planned)
            Text("Before due date").tag(CustomReminder.Kind.due)
        }
        if reminder.kind == .custom {
            DatePicker("Reminder date", selection: Binding(
                get: { reminder.at.flatMap(LocalDateTime.date(from:)) ?? Date() },
                set: { reminder.at = LocalDateTime.string(from: $0) }
            ), displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.compact)
        } else {
            Picker("Unit", selection: Binding(
                get: { reminder.relativeOffset?.unit ?? .days },
                set: { reminder.setOffset(unit: $0, value: reminder.relativeOffset?.value ?? 1) }
            )) {
                ForEach(CustomReminder.Unit.allCases, id: \.self) { unit in
                    Text(unit.rawValue.capitalized).tag(unit)
                }
            }
            .accessibilityIdentifier("reminder-unit")
            let offset = reminder.relativeOffset ?? (unit: .days, value: 1)
            Stepper(offset.unit.label(for: offset.value), value: Binding(
                get: { reminder.relativeOffset?.value ?? 1 },
                set: { reminder.setOffset(unit: offset.unit, value: $0) }
            ), in: CustomReminder.amounts)
            .accessibilityIdentifier("reminder-amount")
            .accessibilityLabel("Reminder amount")
            .accessibilityValue(offset.unit.label(for: offset.value))
        }
        if let date = reminder.date(for: task) {
            Text(date, format: .dateTime.year().month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Set the \(reminder.kind == .planned ? "planned" : "due") date to activate this reminder.")
                .font(.caption).foregroundStyle(.orange)
        }
        Toggle("Urgent", isOn: $reminder.urgent)
    }
}
