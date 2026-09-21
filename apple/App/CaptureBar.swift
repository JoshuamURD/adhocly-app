import AdhoclyCore
import SwiftUI

struct CaptureBar: View {
    let model: AppModel
    let store: TaskStore
    let projectId: String
    @AppStorage("captureDefaultTime") private var defaultTime = 9 * 60
    @State private var text = ""
    @State private var preview: CaptureResult?
    @State private var error: String?
    @State private var showHelp = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                TextField("What needs doing?", text: $text)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isFocused)
                    .frame(minHeight: 44)
                    .onSubmit(save)
                    .accessibilityLabel("Quick capture. Exclamation mark for due date, at sign for planned date, slash for project.")
                    #if os(iOS)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    #endif
                Button(action: save) { Text("Add").fontWeight(.semibold).frame(minHeight: 28) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(preview == nil)
            }
            .padding(8)
            .padding(.leading, 6)
            .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isFocused ? Color.accentColor : AppStyle.border, lineWidth: isFocused ? 1.5 : 1)
            }
            HStack {
                Text("Quick capture").fontWeight(.medium)
                Spacer()
                Button { showHelp = true } label: {
                    Label("Date & project shortcuts", systemImage: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showHelp) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("A task, in a sentence.").font(.system(.title2, design: .serif))
                        Text("Start with a title. Add a date or project if you need one.")
                        Label("!tomorrow — due date", systemImage: "flag")
                        Label("@Monday 9am — planned time", systemImage: "calendar")
                        Label("/Inbox — project", systemImage: "folder")
                        Text("Send the report !tomorrow /Inbox")
                            .font(.callout.monospaced()).padding(12)
                            .background(AppStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                        Text("You’ll see the dates before you add the task. For reminders and more options, use New task.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Got it") { showHelp = false }.buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .frame(idealWidth: 340)
                    .presentationCompactAdaptation(.popover)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let preview {
                if preview.hasDueDate || preview.hasPlannedDate || preview.hasProject {
                    Text(preview.task.title).font(.callout)
                }
                if let value = preview.task.dueOn { dateLabel(value, prefix: "Due", symbol: "flag") }
                if let value = preview.task.plannedFor { dateLabel(value, prefix: "Planned", symbol: "calendar") }
                if preview.hasProject { Label(preview.task.project, systemImage: "folder").font(.caption) }
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .onChange(of: text) { _, _ in parse() }
        .onChange(of: defaultTime) { _, _ in parse() }
        .onChange(of: projectId) { _, _ in parse() }
        .onChange(of: store.projects) { _, _ in parse() }
    }

    private func dateLabel(_ value: String, prefix: String, symbol: String) -> some View {
        let date = LocalDateTime.date(from: value)
        let isPast = date.map { $0 <= Date() } ?? false
        return Label("\(prefix): \(date?.formatted(date: .complete, time: .shortened) ?? value)\(isPast ? " (past; no alert)" : "")", systemImage: symbol)
            .font(.caption).foregroundStyle(isPast ? Color.orange : Color.secondary)
    }

    private func parse() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { preview = nil; error = nil; return }
        do {
            let minutes = min(max(defaultTime, 0), 1439)
            preview = try Capture.parse(text, projects: store.projects, defaultProjectId: projectId,
                                        defaultHour: minutes / 60, defaultMinute: minutes % 60)
            error = nil
        } catch { preview = nil; self.error = error.localizedDescription }
    }

    private func save() {
        guard let preview else { return }
        model.perform {
            // Save exactly the dates shown in the preview, not a newly interpreted relative date.
            try store.save(preview.task)
            text = ""
            self.preview = nil
            isFocused = false
        }
    }
}
