import AdhoclyCore
import SwiftUI

struct TaskEditorView: View {
    let model: AppModel
    let store: TaskStore
    @State var draft: TaskItem
    let original: TaskItem?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs doing?", text: $draft.title, axis: .vertical)
                        .font(.system(.title2, design: .serif, weight: .medium))
                        .lineLimit(2...6)
                        .accessibilityLabel("Task title")
                }
                Section("Details") {
                    TextField("Add a longer description, notes, or context…", text: $draft.details, axis: .vertical)
                        .lineLimit(3...10)
                        .accessibilityLabel("Task details")
                }
                Section("Organize") {
                    Picker("Project", selection: $draft.projectId) {
                        ForEach(store.projects) { project in Text(project.name).tag(project.id) }
                    }
                    Picker(store.statusField.name, selection: $draft.statusId) {
                        ForEach(store.statusField.options) { option in Text(option.name).tag(option.id) }
                    }
                }
                if store.taskFields.contains(where: { $0.id != "status" }) {
                    Section("Properties") {
                        ForEach(store.taskFields.filter { $0.id != "status" }) { field in
                            if field.kind == .choice {
                                Picker(field.name, selection: property(field.id)) {
                                    Text("Unassigned").tag("")
                                    ForEach(field.options) { option in Text(option.name).tag(option.id) }
                                }
                            } else {
                                TextField(field.name, text: property(field.id))
                            }
                        }
                    }
                }
                let unknown = draft.properties.keys.filter { id in !store.taskFields.contains { $0.id == id } }.sorted()
                if !unknown.isEmpty {
                    Section("Unavailable properties") {
                        ForEach(unknown, id: \.self) { id in
                            LabeledContent(id, value: draft.properties[id] ?? "")
                            Button("Remove unavailable property", role: .destructive) { draft.properties[id] = nil }
                        }
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
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(AppStyle.canvas)
            .navigationTitle(original == nil ? "New task" : "Edit task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
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
        }
        #if os(macOS)
        .frame(width: 560, height: 660)
        #endif
    }
    private func property(_ id: String) -> Binding<String> {
        Binding(get: { draft.properties[id] ?? "" }, set: { draft.properties[id] = $0.isEmpty ? nil : $0 })
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
