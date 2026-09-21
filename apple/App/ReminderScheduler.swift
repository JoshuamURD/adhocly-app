import AdhoclyCore
import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    private(set) var message: String?
    private(set) var needsPermission = false
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var requested: [TaskItem]?
    @ObservationIgnored private var latestTasks: [TaskItem] = []
    @ObservationIgnored private var running = false

    override init() {
        super.init()
        center.delegate = self
    }

    func enableIfNeeded() async {
        if await center.notificationSettings().authorizationStatus == .notDetermined,
           !TaskReminders.upcoming(tasks: latestTasks).isEmpty { await enable() }
    }

    func enable() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            await update(tasks: latestTasks)
        } catch { message = "Couldn’t enable reminders: \(error.localizedDescription)" }
    }

    // Serialize reconciliations, coalescing changes made during an await. An old sync snapshot
    // must not reinstall notifications after a newer local completion or date edit.
    func update(tasks: [TaskItem]) async {
        latestTasks = tasks
        requested = tasks
        guard !running else { return }
        running = true
        defer { running = false }
        while let tasks = requested {
            requested = nil
            await reconcile(tasks: tasks)
        }
    }

    private func reconcile(tasks: [TaskItem]) async {
        let upcoming = TaskReminders.upcoming(tasks: tasks)
        // iOS limits pending local notifications. Schedule the nearest 64 and tell the user
        // when more remain; server push is needed for unlimited reminders without reopening.
        let plan = Array(upcoming.prefix(TaskReminders.limit))
        let existing = await center.pendingNotificationRequests()
        func matches(_ request: UNNotificationRequest, _ reminder: TaskReminder) -> Bool {
            request.identifier == reminder.id && request.content.title == reminder.title &&
            request.content.userInfo["wallClock"] as? String == reminder.wallClock &&
            request.content.interruptionLevel == (reminder.urgent ? .timeSensitive : .active)
        }
        // Cancel changed alerts even when permission is currently denied: re-enabling alerts
        // later must not resurrect an old time while the app is suspended.
        center.removePendingNotificationRequests(withIdentifiers: existing.filter { request in
            request.identifier.hasPrefix(TaskReminders.prefix) && !plan.contains { matches(request, $0) }
        }.map(\.identifier))
        let active = Set(tasks.filter { !$0.completed }.map(\.id))
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            $0.request.identifier.hasPrefix(TaskReminders.prefix) && !active.contains($0.request.content.userInfo["taskId"] as? String ?? "")
        }.map { $0.request.identifier })
        let settings = await center.notificationSettings()
        needsPermission = settings.authorizationStatus == .notDetermined
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
            message = upcoming.isEmpty ? nil : needsPermission ? "Enable notifications for task reminders." : "Notifications are off. Enable Adhocly alerts in system settings."
            return
        }
        do {
            for reminder in plan {
                let body = reminder.kind == "custom" ? (reminder.urgent ? "Urgent task reminder." : "Task reminder.") :
                    reminder.kind == "due" ? "This task is due." : "Time planned for this task."
                if existing.contains(where: { matches($0, reminder) }) { continue }
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                content.body = body
                content.sound = .default
                content.interruptionLevel = reminder.urgent ? .timeSensitive : .active
                content.userInfo = ["taskId": reminder.taskId, "wallClock": reminder.wallClock]
                let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
            }
            message = upcoming.count > TaskReminders.limit ? "The next 64 alerts are scheduled. Reopen the app to schedule later reminders." : nil
        } catch { message = "A reminder couldn’t be scheduled: \(error.localizedDescription)" }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
