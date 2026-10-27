import Foundation

@MainActor extension AppState {
    /// Notification clicks must also move selection, not leave toolbar commands
    /// pointing at a different previously selected message.
    @discardableResult func openMessageReminder(_ key: String) -> Bool {
        guard let message = messageForReminderKey(key) else {
            status = "提醒对应的邮件或账户已移除"
            return false
        }
        selectedKeys = [message.key]
        open(message)
        return true
    }
}

@MainActor func runMailReminderRoutingTests(_ require: (Bool, String) -> Void) async {
    let state = AppState(fixture: true)
    defer { _ = state.shutdown() }
    let account = state.accounts[0].id
    let target = MailMessage(accountID: account, remoteID: "100", folderID: "200", id: "301", origin: URL(string: "https://mail.zoho.com")!, subject: "Reminder target", sender: "target@example.test", preview: "", date: Date(), attachment: false, unread: false)
    let other = MailMessage(accountID: account, remoteID: "100", folderID: "200", id: "302", origin: target.origin, subject: "Previously selected", sender: "other@example.test", preview: "", date: Date(), attachment: false, unread: false)
    let record = MailReminderRecord(key: target.key, accountID: account, dueDate: Date().addingTimeInterval(3600), requestID: "fixture-routing", snapshot: target)
    state.preferences.value.mailReminders[target.key] = record
    state.messageStore[other.key] = other
    state.rows = [other]
    state.activeKey = other.key
    state.selectedKeys = [other.key]
    require(state.openMessageReminder(target.key), "notification routes a persisted reminder even when its mail is outside current rows")
    await state.detailTask?.value
    require(state.activeKey == target.key && state.detail?.message.key == target.key, "notification reads the reminder target rather than the previously active message")
    require(state.selectedKeys == [target.key] && state.selectedMessages().map(\.key) == [target.key], "toolbar actions after notification click target the reminded mail, not stale selection")
    require(!state.openMessageReminder("missing") && state.activeKey == target.key, "unknown reminder does not redirect selection")
    state.accounts.removeAll { $0.id == account }
    require(!state.openMessageReminder(target.key), "notification for removed account does not open stale mail")
}
