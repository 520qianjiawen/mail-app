import AppKit
import UserNotifications

@MainActor protocol MailReminderTransport: AnyObject {
    func permission(request: Bool) async throws -> Bool
    func schedule(_ reminder: MailReminderRecord, sound: Bool) async throws
    func cancel(_ identifiers: [String])
    func pendingIDs() async -> Set<String>
}

@MainActor final class NativeMailReminderTransport: MailReminderTransport {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    func permission(request: Bool) async throws -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined where request: return try await center.requestAuthorization(options: [.alert, .sound])
        default: return false
        }
    }
    func schedule(_ reminder: MailReminderRecord, sound: Bool) async throws {
        let content = UNMutableNotificationContent()
        content.title = "邮件提醒"
        content.body = "你设置的邮件提醒时间已到。"
        // No sender, subject, preview, body, account or URL travels in the payload.
        content.userInfo = [MailReminderPolicy.userInfoKey: reminder.key]
        if sound { content.sound = .default }
        // Absolute UTC calendar components survive app termination and timezone changes.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let triggerDate = Date(timeIntervalSince1970: ceil(reminder.dueDate.timeIntervalSince1970))
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: triggerDate)
        components.calendar = calendar; components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: reminder.requestID, content: content, trigger: trigger))
    }
    func cancel(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func pendingIDs() async -> Set<String> { Set(await center.pendingNotificationRequests().map(\.identifier)) }
}

@MainActor final class MailReminderStore {
    private weak var state: AppState?
    private let transport: (any MailReminderTransport)?
    private var tokens: [String: UUID] = [:]
    private var inFlight: [String: MailReminderRecord] = [:]
    private func cancelInFlight(where matches: (MailReminderRecord) -> Bool) {
        let ids = inFlight.values.filter(matches).map(\.requestID)
        transport?.cancel(ids)
        for id in ids { inFlight.removeValue(forKey: id) }
    }
    private var epochs: [String: UInt64] = [:]
    private var lifetime: UInt64 = 0
    private var stopped = false
    private var restoreTask: Task<Void, Never>?
    // Injectable persistence permits deterministic I/O failure tests without real profiles.
    var saveHook: (() -> Bool)?

    init(state: AppState, transport: (any MailReminderTransport)? = nil) {
        self.state = state
        self.transport = transport ?? ((!state.fixture && Bundle.main.bundleURL.pathExtension == "app") ? NativeMailReminderTransport() : nil)
    }
    private func persist() -> Bool { saveHook?() ?? state?.preferences.save() ?? false }
    func accountContext(_ accountID: String) -> () -> Bool {
        let epoch = epochs[accountID, default: 0], life = lifetime
        return { [weak self] in
            guard let self else { return false }
            return !self.stopped && self.lifetime == life && self.epochs[accountID, default: 0] == epoch &&
                self.state?.accounts.contains(where: { $0.id == accountID }) == true
        }
    }
    func date(for key: String) -> Date? { state?.preferences.value.mailReminders[key]?.dueDate }
    func message(for key: String) -> MailMessage? {
        guard let state, let record = state.preferences.value.mailReminders[key],
              state.accounts.contains(where: { $0.id == record.accountID }), record.snapshot.key == key else { return nil }
        return state.messageStore[key] ?? record.snapshot
    }
    private func valid(_ key: String, account: String, token: UUID, epoch: UInt64, life: UInt64) -> Bool {
        !stopped && lifetime == life && tokens[key] == token && epochs[account, default: 0] == epoch &&
        state?.accounts.contains(where: { $0.id == account }) == true
    }
    @discardableResult func set(_ message: MailMessage, dueDate: Date, requestPermission: Bool = true) async throws -> MailReminderRecord {
        guard let state, !stopped, state.accounts.contains(where: { $0.id == message.accountID }) else { throw MailReminderError.account }
        guard MailReminderPolicy.isFuture(dueDate) else { throw MailReminderError.date }
        guard state.preferences.value.notificationsEnabled else { throw MailReminderError.disabled }
        guard let transport else { throw MailReminderError.unavailable }
        guard state.preferences.value.mailReminders[message.key] != nil || state.preferences.value.mailReminders.count < MailReminderPolicy.maximumRecords else { throw MailReminderError.limit }
        let key = message.key, token = UUID(), epoch = epochs[message.accountID, default: 0], life = lifetime
        try Task.checkCancellation()
        tokens[key] = token
        cancelInFlight { $0.key == key }
        let allowed = try await transport.permission(request: requestPermission)
        try Task.checkCancellation()
        guard valid(key, account: message.accountID, token: token, epoch: epoch, life: life) else { throw MailReminderError.superseded }
        guard state.preferences.value.notificationsEnabled else { throw MailReminderError.disabled }
        guard allowed else { throw MailReminderError.permission }
        guard MailReminderPolicy.isFuture(dueDate) else { throw MailReminderError.date }
        let record = MailReminderRecord(key: key, accountID: message.accountID, dueDate: dueDate,
            requestID: MailReminderPolicy.requestPrefix + UUID().uuidString, snapshot: MailReminderPolicy.snapshot(message))
        // Track before native add can suspend: shutdown must enqueue removal even
        // when the OS accepted the request but its completion has not returned.
        inFlight[record.requestID] = record
        defer { inFlight.removeValue(forKey: record.requestID) }
        do {
            try await transport.schedule(record, sound: state.preferences.value.playSound)
            try Task.checkCancellation()
        } catch { transport.cancel([record.requestID]); throw error }
        guard valid(key, account: message.accountID, token: token, epoch: epoch, life: life), state.preferences.value.notificationsEnabled else {
            transport.cancel([record.requestID]); throw MailReminderError.superseded
        }
        // Re-read after suspension: unrelated reminder commits must never be rolled back.
        let previous = state.preferences.value.mailReminders[key]
        guard previous != nil || state.preferences.value.mailReminders.count < MailReminderPolicy.maximumRecords else {
            transport.cancel([record.requestID]); throw MailReminderError.limit
        }
        state.preferences.value.mailReminders[key] = record
        guard persist() else {
            state.preferences.value.mailReminders[key] = previous
            transport.cancel([record.requestID]); throw MailReminderError.persistence
        }
        if let previous { transport.cancel([previous.requestID]) }
        state.mailRemindersVersion += 1
        return record
    }
    func cancel(key: String) throws {
        tokens[key] = UUID() // Invalidate even an operation awaiting permission/add.
        cancelInFlight { $0.key == key }
        guard let state, let previous = state.preferences.value.mailReminders[key] else { return }
        state.preferences.value.mailReminders.removeValue(forKey: key)
        guard persist() else { state.preferences.value.mailReminders[key] = previous; throw MailReminderError.persistence }
        transport?.cancel([previous.requestID]); state.mailRemindersVersion += 1
    }
    @discardableResult func removeAccount(accountID: String) -> Bool {
        guard let state else { return false }
        let records = state.preferences.value.mailReminders.filter { $0.value.accountID == accountID }
        for key in records.keys { state.preferences.value.mailReminders.removeValue(forKey: key) }
        guard records.isEmpty || persist() else {
            state.preferences.value.mailReminders.merge(records) { _, old in old }
            state.status = MailReminderError.persistence.localizedDescription; return false
        }
        // No suspension occurs before this fence; a failed save leaves the account live.
        epochs[accountID, default: 0] &+= 1
        cancelInFlight { $0.accountID == accountID }
        for key in records.keys { tokens[key] = UUID() }
        transport?.cancel(records.values.map(\.requestID)); state.mailRemindersVersion += 1
        return true
    }
    func stop() {
        stopped = true; lifetime &+= 1; restoreTask?.cancel(); restoreTask = nil
        cancelInFlight { _ in true }
        // Committed requests deliberately remain registered with macOS after quit.
    }
    func restore() {
        guard let state, !state.fixture, Bundle.main.bundleURL.pathExtension == "app", let transport, !stopped, restoreTask == nil else { return }
        let life = lifetime
        restoreTask = Task { [weak self] in
            guard let self else { return }
            defer { self.restoreTask = nil }
            let ids = await transport.pendingIDs()
            guard !self.stopped, self.lifetime == life else { return }
            let records = Array(state.preferences.value.mailReminders.values)
            for record in records {
                guard !Task.isCancelled, !self.stopped, self.lifetime == life else { return }
                guard state.accounts.contains(where: { $0.id == record.accountID }) else { _ = self.removeAccount(accountID: record.accountID); continue }
                guard MailReminderPolicy.isFuture(record.dueDate), !ids.contains(record.requestID),
                      state.preferences.value.mailReminders[record.key]?.requestID == record.requestID else { continue }
                do { try await self.set(record.snapshot, dueDate: record.dueDate, requestPermission: false) }
                catch { if !(error is CancellationError) { state.status = error.localizedDescription } }
            }
        }
    }
}

@MainActor extension AppState {
    func messageReminderDate(_ message: MailMessage) -> Date? {
        _ = mailRemindersVersion
        return mailReminderStore.date(for: message.key)
    }
    func messageForReminderKey(_ key: String) -> MailMessage? { mailReminderStore.message(for: key) }
    func cancelMessageReminder(_ message: MailMessage) {
        do { try mailReminderStore.cancel(key: message.key); status = "已取消邮件提醒" }
        catch { status = error.localizedDescription }
    }
    func presentMessageReminder(_ message: MailMessage) {
        guard accounts.contains(where: { $0.id == message.accountID }) else { status = MailReminderError.account.localizedDescription; return }
        let contextIsCurrent = mailReminderStore.accountContext(message.accountID)
        let alert = NSAlert()
        alert.messageText = messageReminderDate(message) == nil ? "设置提醒" : "编辑提醒"
        alert.informativeText = "在指定时间发送本地通知；邮件仍保留在原位置。"
        alert.addButton(withTitle: "保存提醒"); alert.addButton(withTitle: "取消")
        if messageReminderDate(message) != nil { alert.addButton(withTitle: "取消此提醒") }
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = messageReminderDate(message) ?? Date().addingTimeInterval(3600)
        alert.accessoryView = picker
        let response = alert.runModal()
        guard contextIsCurrent() else { return }
        if response == .alertThirdButtonReturn { cancelMessageReminder(message); return }
        guard response == .alertFirstButtonReturn else { return }
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: picker.dateValue)
        guard let date = MailReminderPolicy.date(components: components, calendar: calendar) else { status = MailReminderError.date.localizedDescription; return }
        Task { @MainActor in
            guard contextIsCurrent() else { return }
            do { try await mailReminderStore.set(message, dueDate: date); status = "已设置邮件提醒" }
            catch MailReminderError.superseded { /* A newer user action owns the UI. */ }
            catch { status = error.localizedDescription }
        }
    }
}
