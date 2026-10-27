import Foundation

/// A local reminder never changes the server message or its snooze state.
struct MailReminderRecord: Codable, Sendable {
    let key: String
    let accountID: String
    let dueDate: Date
    let requestID: String
    let snapshot: MailMessage
}

enum MailReminderPolicy {
    static let userInfoKey = "mailReminderKey"
    static let requestPrefix = "MailLite.reminder."
    static let maximumRecords = 500
    static func isFuture(_ date: Date, now: Date = Date()) -> Bool {
        date.timeIntervalSince1970.isFinite && date > now && date.timeIntervalSince(now) < 10 * 366 * 86400
    }
    /// Exact round trip rejects nonexistent wall-clock dates (e.g. the DST gap).
    static func date(components: DateComponents, calendar: Calendar, now: Date = Date()) -> Date? {
        guard let date = calendar.date(from: components), isFuture(date, now: now) else { return nil }
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let result = calendar.dateComponents(units, from: date)
        for unit in units where components.value(for: unit) != nil {
            guard components.value(for: unit) == result.value(for: unit) else { return nil }
        }
        return date
    }
    static func snapshot(_ message: MailMessage) -> MailMessage {
        var result = MailMessage(accountID: String(message.accountID.prefix(64)), remoteID: String(message.remoteID.prefix(64)),
            folderID: String(message.folderID.prefix(64)), id: String(message.id.prefix(64)), origin: message.origin,
            subject: String(message.subject.prefix(240)), sender: String(message.sender.prefix(160)), preview: "",
            date: message.date, attachment: message.attachment, unread: message.unread)
        result.fromAddress = message.fromAddress.map { String($0.prefix(320)) }
        result.threadID = message.threadID.map { String($0.prefix(64)) }
        return result
    }
}

enum MailReminderError: LocalizedError {
    case date, account, disabled, permission, unavailable, persistence, limit, superseded
    var errorDescription: String? {
        switch self {
        case .date: return "请选择未来十年内的有效提醒时间。"
        case .account: return "此邮件的账户已移除。"
        case .disabled: return "请先在设置中启用通知，再设置提醒。"
        case .permission: return "提醒未保存：请在系统设置中允许 Mail Lite 通知。"
        case .unavailable: return "当前运行环境未启用系统提醒。"
        case .persistence: return "提醒保存失败，请检查本地存储后重试。"
        case .limit: return "本地提醒已达 500 条，请先取消部分提醒。"
        case .superseded: return "提醒操作已取消或被后续操作替代。"
        }
    }
}
