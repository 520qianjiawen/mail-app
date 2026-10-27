import Foundation

@MainActor private final class MailReadingGate {
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

@MainActor private func readingFixture(_ gate: MailReadingGate) -> AppState {
    var first = true
    let state = AppState(fixture: true, syncHooks: MailSyncHooks(fetchInbox: { _ in throw MailFailure.rejected }, performAction: { _, _ in }, fetchDetail: { message in
        if first { first = false; await gate.pause() }
        return MailDetail(message: message, from: "fixture@example.test", to: "reader@example.test", cc: "", replyTo: "", html: "<p>body-\(message.id)</p>", attachments: [], inline: [])
    }))
    state.preferences.value.markReadOnOpen = false
    return state
}

@MainActor private func readingMessage(_ state: AppState, id: String = "1") -> MailMessage {
    MailMessage(accountID: state.accounts[0].id, remoteID: "100", folderID: "500", id: id, origin: URL(string: "https://mail.zoho.com")!, subject: "Reading", sender: "fixture@example.test", preview: "", date: Date(), attachment: false, unread: true)
}

@MainActor func runMailReadingLifecycleTests(_ require: (Bool, String) -> Void) async {
    do {
        let gate = MailReadingGate(), state = readingFixture(gate)
        let message = readingMessage(state)
        state.messageStore[message.key] = message
        state.open(message)
        await gate.wait()
        await state.performAndWait(.read, on: [message])
        require(state.messageStore[message.key]?.unread == false, "read acknowledgement arrives while body is still downloading")
        gate.release(); await state.detailTask?.value
        require(state.detail?.html == "<p>body-1</p>" && !state.detailLoading, "read acknowledgement does not discard a valid body or leave spinner running")
        require(state.messageStore[message.key]?.unread == false, "rendering body with old message metadata cannot revert acknowledged read status")
        require(state.threadDetails[message.key] != nil && state.accountSessions.isEmpty, "injected body traverses production acceptance without account sessions")
        _ = state.shutdown()
    }
    do {
        let gate = MailReadingGate(), state = readingFixture(gate)
        let first = readingMessage(state), second = readingMessage(state, id: "2")
        state.messageStore[first.key] = first; state.messageStore[second.key] = second
        state.open(first); let oldTask = state.detailTask
        await gate.wait()
        state.open(second); await state.detailTask?.value
        require(state.detail?.message.key == second.key, "new reader body completes while old request is paused")
        gate.release(); await oldTask?.value
        require(state.activeKey == second.key && state.detail?.message.key == second.key, "late cancelled body cannot replace a newer active reader")
        require(state.cache.detail(first) == nil && state.threadDetails[first.key] == nil, "cancelled old body is not committed to caches")
        _ = state.shutdown()
    }
    do {
        let gate = MailReadingGate(), state = readingFixture(gate)
        let message = readingMessage(state), account = state.accounts[0]
        let pending = Task { @MainActor in await state.loadDetail(message) }
        await gate.wait()
        await state.removeAccountAndWait(account)
        gate.release()
        let loaded = await pending.value
        require(loaded == nil && state.cache.detail(message) == nil && state.threadDetails[message.key] == nil, "late member-body reply cannot recreate removed-account caches")
        _ = state.shutdown()
    }
    do {
        let gate = MailReadingGate(), state = readingFixture(gate)
        let message = readingMessage(state)
        state.messageStore[message.key] = message
        state.open(message); let pending = state.detailTask
        await gate.wait(); _ = state.shutdown()
        gate.release(); await pending?.value
        require(state.detail == nil && state.cache.detail(message) == nil && state.threadDetails[message.key] == nil, "late body after shutdown neither renders nor persists")
    }
}
