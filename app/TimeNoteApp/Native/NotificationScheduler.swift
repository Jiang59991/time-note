import Foundation
import UserNotifications

@MainActor
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var generation = 0
    private var previousRevision: Int?
    private var latestDesired = Set<String>()
    private let isTest = !(ProcessInfo.processInfo.environment["TIME_NOTE_DATA_DIR"] ?? "").isEmpty
    var onOpen: (() -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestPermission() async throws -> String {
        if isTest { return "测试模式不会请求或发送系统通知。" }
        let allowed = try await center.requestAuthorization(options: [.alert, .sound])
        previousRevision = nil
        return allowed ? "已允许通知" : "通知未获允许，计时仍正常运行。可在系统设置 → 通知中开启。"
    }

    func sync(_ snapshot: [String: Any], force: Bool = false) async {
        if isTest { return }
        let revision = snapshot["revision"] as? Int ?? 0
        if !force && previousRevision == revision { return }
        previousRevision = revision
        generation += 1
        let mine = generation
        let settings = await center.notificationSettings()
        guard mine == generation else { return }
        let desired = Dictionary(uniqueKeysWithValues: NotificationPlanner.desired(snapshot).map { ($0.identifier, $0) })
        latestDesired = Set(desired.keys)
        let pending = await center.pendingNotificationRequests()
        guard mine == generation else { return }
        let stale = pending.map(\.identifier).filter { $0.hasPrefix("time-note.") && desired[$0] == nil }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let existing = Set(pending.map(\.identifier))
        for (identifier, record) in desired where !existing.contains(identifier) {
            guard mine == generation else { return }
            let deadline = record.deadline
            let delay = deadline / 1000 - Date().timeIntervalSince1970
            guard delay > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "番茄已完成"
            content.body = record.title
            content.sound = .default
            content.userInfo = ["recordID": record.recordID]
            let request = UNNotificationRequest(identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false))
            do {
                try await center.add(request)
                if !latestDesired.contains(identifier) { center.removePendingNotificationRequests(withIdentifiers: [identifier]) }
            }
            catch { previousRevision = nil; NSLog("Time Note notification: %@", error.localizedDescription) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.onOpen?(); completionHandler() }
    }
}
