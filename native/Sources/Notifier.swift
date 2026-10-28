import AppKit
import UserNotifications

/// macOS notifications and Dock badge. Nothing is scheduled while the user has
/// notifications disabled, and no message body ever leaves the process.
@MainActor final class Notifier {
    private var available: Bool { Bundle.main.bundleIdentifier != nil }
    private var authorized = false

    func requestAuthorization() async -> Bool {
        guard available else { return false }
        do {
            authorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            return authorized
        } catch { return false }
    }

    func notifyNewMessages(_ messages: [MailMessage], accounts: [MailAccount], sound: Bool) {
        guard available, authorized, !messages.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        for message in messages.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = message.sender.isEmpty ? (names[message.accountID] ?? "新邮件") : message.sender
            content.subtitle = message.subject
            content.body = message.preview.isEmpty ? (names[message.accountID] ?? "") : message.preview
            if sound { content.sound = .default }
            let request = UNNotificationRequest(identifier: "mail-\(message.key)", content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
        if messages.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = "还有 \(messages.count - 3) 封新邮件"
            content.body = "打开 Mail Lite 查看所有收件箱"
            center.add(UNNotificationRequest(identifier: "mail-more-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    func setBadge(_ count: Int, enabled: Bool) {
        guard let app = NSApp else { return }
        app.dockTile.badgeLabel = enabled && count > 0 ? (count > 999 ? "999+" : "\(count)") : nil
    }
}
