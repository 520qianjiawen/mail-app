import Foundation

@MainActor func runMailForwardMarkerTests(_ require: (Bool, String) -> Void) async {
    let state = AppState(fixture: true)
    defer { _ = state.shutdown(); try? FileManager.default.removeItem(at: state.preferences.directory) }
    let account = state.accounts[0], other = state.accounts[1]
    let origin = URL(string: "https://mail.zoho.com")!
    let inbox = MailFolder(id: "500", name: "Inbox", path: "/Inbox", type: "Inbox")
    state.sessions[account.id] = MailboxSession(accountID: account.id, remoteID: "100", email: "owner@example.test", origin: origin, folders: [inbox], addresses: ["owner@example.test"])
    func message(_ id: String, accountID: String? = nil, folder: String = "500", status: String? = nil) -> MailMessage {
        MailMessage(accountID: accountID ?? account.id, remoteID: "100", folderID: folder, id: id, origin: origin,
            subject: "forward marker fixture", sender: "sender@example.test", preview: "", date: Date(), attachment: false,
            unread: false, threadID: "800", status2: status)
    }
    let source = message("700")
    let foreign = message("700", accountID: other.id)
    state.messageStore[source.key] = source; state.messageStore[foreign.key] = foreign
    state.rebuildRows()
    let detail = MailDetail(message: source, from: "sender@example.test", to: "owner@example.test", cc: "", replyTo: "",
        html: "<p>controlled fixture</p>", attachments: [], inline: [])
    var draft = MailDraft(accountID: account.id, from: "owner@example.test", mode: "forward", source: detail,
        to: "recipient@example.test", subject: "Fwd: fixture", body: "fixture")
    draft.htmlBody = "<p>controlled forward</p>"
    let model = ComposeModel(state: state, draft: draft)
    defer { model.stopBackgroundWork() }
    state.outboxSendHook = { _ in throw MailFailure.rejected }
    model.scheduledAt = Date().addingTimeInterval(3600)
    model.send(schedule: true)
    await model.sendTask?.value
    guard let queued = state.outboxStore.all().first(where: { $0.draftID == draft.id }) else {
        require(false, "forward composer creates a durable fixture job"); return
    }
    require(queued.forwardOf?.key == source.key && queued.replyToMessageID == nil, "forward captures its source without pretending to be a reply")
    require(OutboxStore(directory: state.outboxStore.directory).all().first?.forwardOf?.key == source.key,
            "forward association survives queue restart")
    await state.sendOutbox(queued.id)
    require(state.outboxStore.all().first(where: { $0.id == queued.id })?.state == "failed" && state.messageStore[source.key]?.forwarded == false,
            "failed forward never marks the source")
    state.outboxSendHook = { _ in }
    _ = state.outboxStore.update(queued.id) { $0.state = "queued" }
    await state.sendOutbox(queued.id)
    require(state.messageStore[source.key]?.forwarded == true && state.messageStore[source.key]?.replied == false,
            "acknowledged forward marks only forwarded")
    require(state.messageStore[foreign.key]?.forwarded == false, "same numeric message ID in a different account is isolated")
    require(state.rows.first(where: { $0.accountID == account.id })?.forwarded == true, "visible conversation reflects acknowledged forward immediately")
    require(state.cache.messages(accounts: [account.id]).first(where: { $0.id == source.id })?.forwarded == true,
            "forward marker is written to the message cache")
    let reopened = RepliedMessageStore(directory: state.preferences.directory)
    var moved = message("700", folder: "900")
    reopened.applyStatus(to: &moved)
    require(moved.forwarded, "forward marker survives application restart and folder moves")
    var serverReplied = message("700", status: "1")
    reopened.applyStatus(to: &serverReplied)
    require(serverReplied.replied && serverReplied.forwarded, "local forwarded and server replied states merge")
    state.markMessageReplied(source.key, id: source.id, threadID: source.threadID)
    require(state.messageStore[source.key]?.status2 == "3", "later reply preserves the previous forward marker")
    var serverForwarded = message("701", status: "2")
    state.repliedStore.markReplied(key: serverForwarded.key, id: serverForwarded.id)
    state.repliedStore.applyStatus(to: &serverForwarded)
    require(serverForwarded.status2 == "3", "local replied and server forwarded states merge")
    var newest = message("702", status: "0"); newest = MailMessage(accountID: newest.accountID, remoteID: newest.remoteID,
        folderID: newest.folderID, id: newest.id, origin: newest.origin, subject: newest.subject, sender: newest.sender,
        preview: "", date: Date().addingTimeInterval(100), attachment: false, unread: false, threadID: "800", status2: "0")
    let group = MailMessage.conversations([newest, message("700", status: "2"), message("701", status: "1")])
    require(group.count == 1 && group[0].replied && group[0].forwarded, "conversation aggregation retains both markers even when newest row reports zero")
    let seedDirectory = state.preferences.directory.appendingPathComponent("seed-forward")
    try? FileManager.default.createDirectory(at: seedDirectory, withIntermediateDirectories: true)
    let seed = RepliedMessageStore(directory: seedDirectory)
    var sent = queued; sent.state = "sent"
    seed.seedFromOutbox([sent])
    require(seed.isForwarded(key: source.key, id: source.id), "sent outbox receipts rebuild forward status at startup")
    let failedDirectory = state.preferences.directory.appendingPathComponent("seed-failed")
    try? FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
    let unconfirmed = RepliedMessageStore(directory: failedDirectory)
    var uncertain = queued; uncertain.state = "uncertain"
    unconfirmed.seedFromOutbox([queued, uncertain])
    require(!unconfirmed.isForwarded(key: source.key, id: source.id), "queued and uncertain delivery never seed a forward marker")
}
