import AdhoclyCore
import SwiftUI

@MainActor @Observable
final class AppModel {
    let store: TaskStore?
    let loadError: String?
    var actionError: String?
    var credentialError: String?
    let reminders = ReminderScheduler()

    init() {
        do {
            store = try TaskStore(fileURL: TaskStore.defaultFileURL)
            loadError = nil
        } catch {
            // Never replace unreadable local data with an empty database.
            store = nil
            loadError = error.localizedDescription
        }
    }

    func perform(_ action: () throws -> Void) {
        do {
            try action()
            didSave()
        } catch { actionError = error.localizedDescription }
    }

    func didSave() {
        Task {
            guard let store else { return }
            await reminders.update(tasks: store.tasks)
            await reminders.enableIfNeeded()
            await sync()
        }
    }

    func sync() async {
        guard let store else { return }
        do {
            let token = try Credentials.read(server: store.serverURL)
            credentialError = nil
            await store.sync(token: token)
        } catch { credentialError = error.localizedDescription }
        await reminders.update(tasks: store.tasks)
    }
}

@main
struct AdhoclyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let store = model.store {
                    TaskListView(model: model, store: store)
                        .onChange(of: store.tasks, initial: true) { _, tasks in
                            Task { await model.reminders.update(tasks: tasks) }
                        }
                } else {
                    ContentUnavailableView {
                        Label("Local data could not be opened", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("\(model.loadError ?? "Unknown error")\n\nYour file has not been replaced. Back it up before attempting recovery:\n\(TaskStore.defaultFileURL.path)")
                            .textSelection(.enabled)
                    }
                    .padding()
                }
            }
            .tint(.accentColor)
            #if os(macOS)
            .frame(minWidth: 760, minHeight: 560)
            #else
            .frame(minWidth: 320, minHeight: 400)
            #endif
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                // iOS suspends normal apps in the background. Persist immediately, then resume
                // sync on activation; polling also catches reconnects and non-Apple edits.
                while !Task.isCancelled {
                    await model.sync()
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
            .alert("Couldn’t save change", isPresented: Binding(
                get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }
            )) {
                Button("OK") { model.actionError = nil }
            } message: { Text(model.actionError ?? "") }
        }
        .defaultSize(width: 1120, height: 780)
    }
}
