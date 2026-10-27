import Foundation

@MainActor private final class ConversationOpeningGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        let waiters = entryWaiters; entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entryWaiters.append($0) } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

private func openingBody(_ message: MailMessage) -> MailDetail {
    MailDetail(message: message, from: message.sender, to: "reader@example.test", cc: "", replyTo: "reply-\(message.id)@example.test", html: "<p>body-\(message.id)</p>", attachments: [], inline: [], replyHeadersChecked: true)
}

@MainActor private func openingFixture(
    thread: @escaping (MailMessage) async throws -> [MailMessage],
    body: @escaping (MailMessage) async throws -> MailDetail = { openingBody($0) }
) -> AppState {
    let state = AppState(fixture: true, syncHooks: MailSyncHooks(
        fetchInbox: { _ in throw MailFailure.rejected }, performAction: { _, _ in },
        fetchDetail: body, fetchThread: thread))
    state.preferences.value.markReadOnOpen = false
    return state
}

@MainActor private func openingMessage(_ state: AppState, id: String, seconds: Double,
                                         sent: Bool = false, thread: String? = "700",
                                         account: String? = nil, remote: String = "100",
                                         origin: String = "https://mail.zoho.com") -> MailMessage {
    MailMessage(accountID: account ?? state.accounts[0].id, remoteID: remote,
                folderID: sent ? "502" : "500", id: id, origin: URL(string: origin)!,
                subject: "Conversation", sender: sent ? "Cavon <cavon@example.test>" : "Customer <customer@example.test>",
                preview: "", date: Date(timeIntervalSince1970: seconds), attachment: false,
                unread: !sent, threadID: thread)
}

/// Only local hooks and temporary fixture stores; no accounts/login/WebKit/network.
@MainActor func runMailConversationOpeningTests(_ require: (Bool, String) -> Void) async {
    do {
        var members: [MailMessage] = []
        let state = openingFixture(thread: { _ in members })
        let old = openingMessage(state, id: "1", seconds: 28)
        let sent = openingMessage(state, id: "2", seconds: 58, sent: true)
        // Screenshot case: the newer Sent message is not initially in Inbox cache.
        members = [sent]
        state.messageStore[old.key] = old; state.rebuildRows()
        state.open(old, preferLatest: true); await state.detailTask?.value
        require(state.activeKey == sent.key && state.detail?.message.key == sent.key && state.detail?.html == "<p>body-2</p>", "list open adopts actual latest Sent body, not only reordered cards")
        require(state.detail?.from == sent.sender && state.detail?.replyAddress == "reply-2@example.test", "latest opening loads its own sender and reply headers")
        require(state.threadRows.map(\.key) == [sent.key, old.key], "latest-first thread retains source omitted by server response")
        require(state.selectedKeys == [sent.key] && state.selectedMessages().map(\.key) == [sent.key], "toolbar selection targets latest message outside Inbox rows")
        require(state.isActiveConversation(old) && state.activeConversationIndex() == 0, "Inbox representative stays highlighted and navigable after Sent adoption")
        require(state.messageStore[old.key]?.unread == true && state.accountSessions.isEmpty, "latest opening neither marks whole conversation read nor constructs sessions")
        state.open(old); await state.detailTask?.value
        state.rebuildRows()
        require(state.activeKey == old.key && state.detail?.html == "<p>body-1</p>" && state.selectedKeys == [old.key], "explicit old card remains old through thread fetch and row refresh")
        _ = state.shutdown()
    }
    do {
        let gate = ConversationOpeningGate()
        var members: [MailMessage] = []
        let state = openingFixture(thread: { _ in members }, body: { message in
            if message.id == "2" { await gate.pause() }
            return openingBody(message)
        })
        let old = openingMessage(state, id: "1", seconds: 28)
        let sent = openingMessage(state, id: "2", seconds: 58, sent: true)
        let other = openingMessage(state, id: "3", seconds: 80, thread: "701")
        members = [old, sent]; state.messageStore[old.key] = old; state.messageStore[other.key] = other
        state.open(old, preferLatest: true); let pending = state.detailTask
        await gate.wait()
        members = [other]; state.open(other, preferLatest: true); await state.detailTask?.value
        gate.release(); await pending?.value
        require(state.activeKey == other.key && state.detail?.message.key == other.key && state.selectedKeys == [other.key], "late latest body from A cannot overwrite new B reader or selection")
        require(state.cache.detail(sent) == nil && state.threadDetails[sent.key] == nil, "cancelled latest body is not committed to caches")
        _ = state.shutdown()
    }
    for remove in [false, true] {
        let gate = ConversationOpeningGate()
        var members: [MailMessage] = []
        let state = openingFixture(thread: { _ in members }, body: { message in
            if message.id == "2" { await gate.pause() }
            return openingBody(message)
        })
        let old = openingMessage(state, id: "1", seconds: 28)
        let sent = openingMessage(state, id: "2", seconds: 58, sent: true)
        members = [old, sent]; state.messageStore[old.key] = old
        state.open(old, preferLatest: true); let pending = state.detailTask
        await gate.wait()
        if remove { await state.removeAccountAndWait(state.accounts[0]) } else { _ = state.shutdown() }
        gate.release(); await pending?.value
        require(state.cache.detail(sent) == nil && state.threadDetails[sent.key] == nil && state.detail?.message.key != sent.key,
                remove ? "account removal fences latest body and caches" : "shutdown fences latest body and caches")
        _ = state.shutdown()
    }
    do {
        let gate = ConversationOpeningGate()
        var members: [MailMessage] = []
        let state = openingFixture(thread: { _ in await gate.pause(); return members })
        let old = openingMessage(state, id: "1", seconds: 28)
        let sent = openingMessage(state, id: "2", seconds: 58, sent: true)
        members = [old, sent]; state.messageStore[old.key] = old
        state.open(old, preferLatest: true)
        await gate.wait(); await state.performAndWait(.read, on: [old])
        gate.release(); await state.detailTask?.value
        require(state.activeKey == sent.key && state.detail?.message.key == sent.key, "mark-read acknowledgement does not invalidate latest thread adoption")
        require(state.messageStore[old.key]?.unread == false, "thread reply cannot revert acknowledged canonical unread status")
        _ = state.shutdown()
    }
    for sourceRemoval in [false, true] {
        let gate = ConversationOpeningGate()
        var members: [MailMessage] = []
        let state = openingFixture(thread: { _ in await gate.pause(); return members })
        let old = openingMessage(state, id: "1", seconds: 28)
        let sent = openingMessage(state, id: "2", seconds: 58, sent: true)
        members = [old, sent]; state.messageStore[old.key] = old; state.messageStore[sent.key] = sent
        state.open(old, preferLatest: true); let pending = state.detailTask
        await gate.wait(); await state.performAndWait(.trash, on: [sourceRemoval ? old : sent])
        gate.release(); await pending?.value
        require(state.messageStore[sourceRemoval ? old.key : sent.key] == nil,
                sourceRemoval ? "removed source is not resurrected by late thread reply" : "removed latest member is not resurrected by late thread reply")
        require(state.activeKey != sent.key && state.detail?.message.key != sent.key, "destructive membership change prevents stale latest body adoption")
        _ = state.shutdown()
    }
    for mismatch in ["account", "origin", "remote", "thread"] {
        var members: [MailMessage] = []
        let state = openingFixture(thread: { _ in members })
        let old = openingMessage(state, id: "1", seconds: 28)
        let foreign = openingMessage(state, id: "2", seconds: 58, sent: true,
            thread: mismatch == "thread" ? "999" : "700",
            account: mismatch == "account" ? state.accounts[1].id : nil,
            remote: mismatch == "remote" ? "200" : "100",
            origin: mismatch == "origin" ? "https://mail.zoho.eu" : "https://mail.zoho.com")
        members = [foreign]; state.messageStore[old.key] = old
        state.open(old, preferLatest: true); await state.detailTask?.value
        require(state.activeKey == old.key && state.messageStore[foreign.key] == nil && state.readingError != nil,
                "thread \(mismatch) contamination is rejected visibly")
        _ = state.shutdown()
    }
    do {
        var members: [MailMessage] = []
        var fail = true
        let state = openingFixture(thread: { _ in members }, body: { message in
            if message.id == "2" && fail { throw MailFailure.network }
            return openingBody(message)
        })
        let old = openingMessage(state, id: "1", seconds: 28)
        // Header metadata may omit echoed threadId within the scoped thread endpoint.
        let sent = openingMessage(state, id: "2", seconds: 58, sent: true, thread: nil)
        members = [sent]; state.messageStore[old.key] = old
        state.open(old, preferLatest: true); await state.detailTask?.value
        require(state.activeKey == sent.key && state.detail == nil && state.readingError != nil && !state.detailLoading, "latest body failure is visible and never presents older body under latest header")
        require(state.threadRows.count == 2 && state.messageStore[sent.key]?.threadID == old.threadID, "scoped member missing echoed threadId still participates with original source")
        fail = false; state.retryReading(); await state.detailTask?.value
        require(state.detail?.message.key == sent.key && state.readingError == nil, "retry retains preferLatest intent and loads latest actual body")
        _ = state.shutdown()
    }
    do {
        var members: [MailMessage] = []
        let state = openingFixture(thread: { _ in members })
        let old = openingMessage(state, id: "1", seconds: 58)
        let tie = openingMessage(state, id: "2", seconds: 58, sent: true)
        members = [tie, old, tie]; state.messageStore[old.key] = old
        state.open(old, preferLatest: true); await state.detailTask?.value
        let ordered = state.threadRows.map(\.key)
        members = [old, tie]; state.open(old, preferLatest: true); await state.detailTask?.value
        require(state.threadRows.map(\.key) == ordered && ordered.count == 2 && ordered == ordered.sorted(), "equal-date ordering is stable by canonical key and deduplicated")
        _ = state.shutdown()
    }
    do {
        var members: [MailMessage] = []
        let state = openingFixture(thread: { _ in members })
        let old = openingMessage(state, id: "1", seconds: 28)
        let sent = openingMessage(state, id: "2", seconds: 58, sent: true)
        let other = openingMessage(state, id: "3", seconds: 80, thread: "701")
        members = [old]; state.messageStore[old.key] = old; state.messageStore[other.key] = other
        state.open(old); await state.detailTask?.value
        let fence = state.captureVisibleConversationSend(accountID: old.accountID, replyToMessageID: old.id)
        members = [old, sent] // Fresh server membership after successful send ACK.
        state.refreshVisibleConversationAfterSend(fence); await state.detailTask?.value
        state.rebuildRows()
        require(state.activeKey == sent.key && state.detail?.html == "<p>body-2</p>" && state.selectedKeys == [sent.key], "successful reply refresh adopts newly available sent member without reopening list")
        let switched = state.captureVisibleConversationSend(accountID: old.accountID, replyToMessageID: old.id)
        members = [other]; state.open(other); await state.detailTask?.value
        state.refreshVisibleConversationAfterSend(switched); await state.detailTask?.value
        require(state.activeKey == other.key && state.detail?.message.key == other.key, "send acknowledgement cannot jump from a different active conversation")
        require(state.captureVisibleConversationSend(accountID: old.accountID, replyToMessageID: old.id) == nil, "unrelated outgoing reply cannot capture current conversation")
        members = [old, sent]; state.open(old); await state.detailTask?.value
        let explicit = state.captureVisibleConversationSend(accountID: old.accountID, replyToMessageID: old.id)
        state.open(old); await state.detailTask?.value
        state.refreshVisibleConversationAfterSend(explicit); await state.detailTask?.value
        require(state.activeKey == old.key && state.detail?.message.key == old.key, "explicit card selection made during send wins over late post-send default")
        _ = state.shutdown()
    }
}
