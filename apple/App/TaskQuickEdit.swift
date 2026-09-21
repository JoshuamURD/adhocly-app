import AdhoclyCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct TaskTitleEditingKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The same title editing and quick actions in lists, boards, and the schedule.
struct TaskQuickEdit<Content: View>: View {
    let model: AppModel
    let store: TaskStore
    let task: TaskItem
    let editDetails: (TaskItem) -> Void
    @ViewBuilder let content: () -> Content
    @AppStorage("captureDefaultTime") private var defaultTime = 9 * 60
    @State private var original: TaskItem?
    @State private var text = ""
    @State private var preview: CaptureResult?
    @State private var error: String?
    @State private var dateRequest: TaskDateRequest?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if original != nil {
                inlineEditor
            } else {
                Button(action: beginEditing) {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit title: \(task.title)")
                .help("Edit title · @ planned · ! due · / project")
            }
            #if os(macOS)
            if original == nil { detailsButton }
            #else
            detailsButton
            #endif
        }
        .contextMenu {
            Button("Edit title", systemImage: "pencil", action: beginEditing)
                .disabled(original != nil)
            Button("Task details…", systemImage: "slider.horizontal.3", action: openDetails)
            Divider()
            dateMenu(isDue: false)
            dateMenu(isDue: true)
            Menu("Move to project", systemImage: "folder") {
                ForEach(store.projects) { project in
                    Button {
                        update { $0.projectId = project.id }
                    } label: {
                        if project.id == task.projectId { Label(project.name, systemImage: "checkmark") }
                        else { Text(project.name) }
                    }
                    .disabled(project.id == task.projectId)
                }
            }
            .disabled(original != nil)
            Divider()
            Button(task.completed ? "Mark incomplete" : "Complete", systemImage: "checkmark.circle") {
                model.perform { try store.toggle(task.id) }
            }
            .disabled(original != nil)
            Button("Delete task", systemImage: "trash", role: .destructive) {
                model.perform { try store.delete(task.id) }
            }
            .disabled(original != nil)
        }
        .preference(key: TaskTitleEditingKey.self, value: original != nil)
        .sheet(item: $dateRequest) { request in
            TaskQuickDateEditor(model: model, store: store, request: request)
        }
        .onChange(of: text) { _, _ in parse() }
        .onChange(of: defaultTime) { _, _ in parse() }
        .onChange(of: store.projects) { _, _ in parse() }
    }

    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Task title", text: $text)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .focused($isFocused)
                .frame(minHeight: AppStyle.controlSide)
                .multilineTextAlignment(.leading)
                .help("Return to save · Escape to cancel\n@ planned · ! due · / project")
                .onSubmit { _ = save() }
                .onKeyPress(.escape) { cancel(); return .handled }
                .accessibilityLabel("Inline task title")
                #if os(iOS)
                .submitLabel(.done)
                .autocorrectionDisabled()
                #endif
            #if os(iOS)
            Text("@ planned · ! due · / project")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            let suggestions = Capture.projectSuggestions(in: text, projects: store.projects)
            if !suggestions.isEmpty && preview?.hasProject != true {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions) { project in
                            Button {
                                text = Capture.completingProject(in: text, with: project)
                                parse()
                                isFocused = true
                            } label: {
                                Label(project.name, systemImage: "folder")
                                    .frame(maxWidth: .infinity, minHeight: AppStyle.controlSide, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use project \(project.name)")
                        }
                    }
                }
                .frame(height: CGFloat(min(suggestions.count, 3)) * AppStyle.controlSide)
                #if os(macOS)
                .padding(.horizontal, 8)
                .background(AppStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
                #endif
            }
            if let preview {
                if preview.hasPlannedDate, let value = preview.task.plannedFor { TaskDateLabel(value: value) }
                if preview.hasDueDate, let value = preview.task.dueOn { TaskDateLabel(value: value, isDue: true) }
                if preview.hasProject { Label(preview.task.project, systemImage: "folder").font(.caption) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            #if os(macOS)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("@ planned · ! due · / project")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    desktopActions.labelStyle(.titleOnly)
                }
                HStack {
                    Spacer(minLength: 0)
                    desktopActions.labelStyle(.iconOnly)
                }
            }
            #else
            HStack {
                Button("Save title") { _ = save() }
                    .disabled(preview == nil)
                Button("Cancel", action: cancel)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: 44)
            #endif
        }
        .fixedSize(horizontal: false, vertical: true)
        #if os(macOS)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: AppStyle.cardRadius))
        .background(InlineEditBoundary(commit: save))
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.cardRadius)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.5) : AppStyle.border)
                .allowsHitTesting(false)
        }
        #else
        .padding(8)
        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.4)).allowsHitTesting(false) }
        #endif
    }

    private var detailsButton: some View {
        Button(action: openDetails) {
            Image(systemName: "slider.horizontal.3")
                .frame(width: AppStyle.controlSide, height: AppStyle.controlSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Details for \(task.title)")
        .help(original == nil ? "Open full task details" : "Save title and open full task details")
    }

    #if os(macOS)
    private var desktopActions: some View {
        HStack(spacing: 6) {
            detailsButton
            Button(action: cancel) {
                Label("Cancel", systemImage: "xmark")
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
            .help("Cancel editing (Escape)")
            Button { _ = save() } label: {
                Label("Save", systemImage: "checkmark")
                    .frame(minWidth: 28, minHeight: 28)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(preview == nil ? Color.secondary : Color.accentColor)
            .background(AppStyle.canvas, in: RoundedRectangle(cornerRadius: 5))
            .disabled(preview == nil)
            .accessibilityLabel("Save title")
            .help("Save title (Return)")
        }
        .font(.caption.weight(.medium))
        .buttonStyle(.plain)
    }
    #endif

    private func beginEditing() {
        guard original == nil else { isFocused = true; return }
        original = task
        text = Capture.editingText(for: task.title)
        parse()
        isFocused = true
    }

    private func parse() {
        guard let original else { return }
        do {
            let minutes = min(max(defaultTime, 0), 1439)
            preview = try Capture.parse(text, projects: store.projects, defaultProjectId: original.projectId,
                                        defaultHour: minutes / 60, defaultMinute: minutes % 60)
            error = nil
        } catch { preview = nil; self.error = error.localizedDescription }
    }

    private func save() -> Bool {
        guard let original else { return true }
        guard let preview else { return false }
        do {
            let updated = preview.applying(to: original)
            if updated != original {
                try store.save(updated, replacing: original)
                model.didSave()
            }
            cancel()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private func cancel() {
        original = nil
        preview = nil
        error = nil
        isFocused = false
    }

    private func openDetails() {
        guard save(), let current = store.tasks.first(where: { $0.id == task.id }) else { return }
        editDetails(current)
    }

    private func dateMenu(isDue: Bool) -> some View {
        Menu(isDue ? "Due date" : "Planned date", systemImage: isDue ? "flag" : "calendar") {
            if let value = isDue ? task.dueOn : task.plannedFor {
                Text(LocalDateTime.date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value)
                Divider()
            }
            Button("Today") { setDate("today", isDue: isDue) }
            Button("Tomorrow") { setDate("tomorrow", isDue: isDue) }
            Button("In one week") { setDate("in one week", isDue: isDue) }
            Button("Choose date & time…") {
                dateRequest = TaskDateRequest(task: task, isDue: isDue)
            }
            Divider()
            Button(isDue ? "Remove due date" : "Remove planned date") {
                update { if isDue { $0.dueOn = nil } else { $0.plannedFor = nil } }
            }
            .disabled((isDue ? task.dueOn : task.plannedFor) == nil)
        }
        .disabled(original != nil)
    }

    private func setDate(_ phrase: String, isDue: Bool) {
        model.perform {
            let minutes = min(max(defaultTime, 0), 1439)
            let date = try NaturalDate.parse(phrase, defaultHour: minutes / 60, defaultMinute: minutes % 60)
            var updated = task
            if isDue { updated.dueOn = LocalDateTime.string(from: date) }
            else { updated.plannedFor = LocalDateTime.string(from: date) }
            try store.save(updated, replacing: task)
        }
    }

    private func update(_ change: (inout TaskItem) -> Void) {
        var updated = task
        change(&updated)
        model.perform { try store.save(updated, replacing: task) }
    }
}

#if os(macOS)
/// Watch the whole editor, not just text-field focus: suggestion and action clicks stay inside.
private struct InlineEditBoundary: NSViewRepresentable {
    let commit: () -> Bool

    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }
    func updateNSView(_ view: BoundaryView, context: Context) { view.commit = commit }
    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.stopMonitoring() }

    final class BoundaryView: NSView {
        var commit: () -> Bool = { true }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    // Save before navigation or completion can remove this row. Invalid edits
                    // consume the outside click so the draft and its error remain visible.
                    return self.commit() ? event : nil
                }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif

private struct TaskDateRequest: Identifiable {
    var id: String { task.id }
    let task: TaskItem
    let isDue: Bool
}

private struct TaskQuickDateEditor: View {
    let model: AppModel
    let store: TaskStore
    let request: TaskDateRequest
    @State private var date = Date()
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("captureDefaultTime") private var defaultTime = 9 * 60

    var body: some View {
        NavigationStack {
            Form {
                Text(request.task.title).font(.headline)
                DatePicker(request.isDue ? "Due" : "Planned", selection: $date, displayedComponents: [.date, .hourAndMinute])
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(request.isDue ? "Due date" : "Planned date")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            var task = request.task
                            if request.isDue { task.dueOn = LocalDateTime.string(from: date) }
                            else { task.plannedFor = LocalDateTime.string(from: date) }
                            try store.save(task, replacing: request.task)
                            model.didSave()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear {
            let value = request.isDue ? request.task.dueOn : request.task.plannedFor
            let minutes = min(max(defaultTime, 0), 1439)
            date = value.flatMap(LocalDateTime.date(from:))
                ?? Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }
        #if os(macOS)
        .frame(width: 420, height: 240)
        #endif
    }
}
