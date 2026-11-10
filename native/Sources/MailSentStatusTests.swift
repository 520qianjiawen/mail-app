import Foundation

@MainActor func runMailSentStatusTests(_ require: (Bool, String) -> Void) async {
    let state = AppState(fixture: true)
    defer { _ = state.shutdown(); try? FileManager.default.removeItem(at: state.preferences.directory) }
    let account = state.accounts[0], origin = URL(string: "https://mail.zoho.com")!
    let sent = MailFolder(id: "600", name: "Sent", path: "/Sent", type: "Sent")
    let session = MailboxSession(accountID: account.id, remoteID: "100", email: "owner@example.test",
        origin: origin, folders: [sent], addresses: ["owner@example.test"])
    state.sessions[account.id] = session
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    func message(folder: String = "600", id: String = "700", accountID: String? = nil,
                 remoteID: String = "100", host: URL? = nil, date: Date? = nil) -> MailMessage {
        MailMessage(accountID: accountID ?? account.id, remoteID: remoteID, folderID: folder, id: id,
            origin: host ?? origin, subject: "same subject", sender: "owner@example.test", preview: "",
            date: date ?? Date(timeIntervalSince1970: 1_790_000_000), attachment: false, unread: false, threadID: "800")
    }
    func status(_ message: MailMessage, _ receipts: [OutboxItem] = []) -> Date? {
        MailSentStatus.date(for: message, session: session, receipts: receipts)
    }
    require(status(message()) == date, "server Sent folder displays its actual message date, including mail sent by other clients")
    require(status(message(folder: "500")) == nil, "self-addressed Inbox mail does not imply successful sending")
    require(status(message(accountID: state.accounts[1].id)) == nil, "Sent folder IDs cannot cross accounts")
    require(status(message(remoteID: "101")) == nil, "Sent folder IDs cannot cross remote mailboxes")
    require(status(message(host: URL(string: "https://mail.zoho.eu")!)) == nil, "Sent folder IDs cannot cross data centers")
    require(status(message(date: Date(timeIntervalSince1970: 0))) == nil, "missing server date is not fabricated")
    var receipt = OutboxItem(accountID: account.id, from: "owner@example.test", to: "recipient@example.test")
    receipt.state = "sent"; receipt.sentMessageID = "700"; receipt.sentAt = date
    receipt.sentRemoteID = "100"; receipt.sentOrigin = origin
    require(status(message(folder: "900"), [receipt]) == date, "exact durable receipt remains valid after moving a sent message")
    require(status(message(folder: "500", id: "701"), [receipt]) == nil, "same subject and conversation never transfer success to another message")
    require(status(message(folder: "900", accountID: state.accounts[1].id), [receipt]) == nil, "receipt message IDs cannot cross accounts")
    require(status(message(folder: "900", remoteID: "101"), [receipt]) == nil, "receipt IDs cannot cross remote mailboxes")
    require(status(message(folder: "900", host: URL(string: "https://mail.zoho.eu")!), [receipt]) == nil, "receipt IDs cannot cross origins")
    for pending in ["queued", "sending", "failed", "uncertain", "cancelled"] {
        var item = receipt; item.state = pending
        require(status(message(folder: "900"), [item]) == nil, "\(pending) item never displays successful sending")
    }
    var legacy = receipt; legacy.sentAt = nil
    require(status(message(folder: "900"), [legacy]) == nil, "manual or legacy reconciliation never uses queue creation as send time")
    require(state.outboxStore.enqueue(receipt), "send receipt persists")
    let reopened = OutboxStore(directory: state.outboxStore.directory)
    require(status(message(folder: "900"), reopened.all()) == date, "send date and exact context survive restart")
    let queued = OutboxItem(accountID: account.id, from: "owner@example.test", to: "recipient@example.test")
    require(state.outboxStore.enqueue(queued), "controlled send job persists")
    state.outboxSendHook = { _ in throw MailFailure.rejected }
    await state.sendOutbox(queued.id)
    require(state.outboxStore.all().first { $0.id == queued.id }?.sentAt == nil, "rejected transport never records a send timestamp")
    _ = state.outboxStore.update(queued.id) { $0.state = "queued" }
    state.outboxSendHook = { _ in }
    await state.sendOutbox(queued.id)
    let acknowledged = state.outboxStore.all().first { $0.id == queued.id }
    require(acknowledged?.state == "sent" && acknowledged?.sentAt != nil && acknowledged?.sentRemoteID == "100" && acknowledged?.sentOrigin == origin,
        "successful transport persists acknowledgement time and mailbox context")
    // Optional fields remain compatible with receipts written before this release.
    let encoded = try! JSONEncoder().encode(queued)
    var json = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    for key in ["sentAt", "sentRemoteID", "sentOrigin"] { json.removeValue(forKey: key) }
    let decoded = try? JSONDecoder().decode(OutboxItem.self, from: JSONSerialization.data(withJSONObject: json))
    require(decoded != nil && decoded?.sentAt == nil, "legacy outbox loads without migration or invented send time")
}
