import Foundation

@MainActor private final class MailMutationTestGate {
    private var entered = false
    private var released = false
    private var entrants: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        let callbacks = entrants; entrants.removeAll()
        callbacks.forEach { $0.resume() }
        if !released { await withCheckedContinuation { releaseContinuation = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entrants.append($0) } } }
    func release() { released = true; releaseContinuation?.resume(); releaseContinuation = nil }
}

@MainActor private final class MailMutationTestServer {
    var calls: [(String, MailAction)] = []
    var unread: [String: Bool] = [:]
    var gateAccount: String?
    var gate: MailMutationTestGate?
    var failingAccount: String?
    var completedAccounts: Set<String> = []
    private var completionWaiters: [(String, CheckedContinuation<Void, Never>)] = []

    func message(_ account: MailAccount) -> MailMessage {
        MailMessage(accountID: account.id, remoteID: "100", folderID: "500", id: "900",
                    origin: URL(string: "https://mail.zoho.com")!, subject: "mutation fixture", sender: "sender@example.test",
                    preview: "", date: Date(timeIntervalSince1970: 900), attachment: false, unread: unread[account.id] ?? true)
    }
    func snapshot(_ account: MailAccount) -> MailSyncSnapshot {
        let m = message(account)
        let context = MailboxSession(accountID: account.id, remoteID: "100", email: "fixture@example.test", origin: m.origin,
                                     folders: [MailFolder(id: "500", name: "Inbox", path: "/Inbox", type: "Inbox", unread: m.unread ? 1 : 0)], addresses: [])
        return MailSyncSnapshot(context: context, head: InboxPage(messages: [m], remoteID: "100", folderID: "500", next: 2, more: false))
    }
    func state() -> AppState {
        AppState(fixture: true, syncHooks: MailSyncHooks(fetchInbox: { [self] in snapshot($0) }, performAction: { [self] action, messages in
            guard let first = messages.first else { throw MailFailure.rejected }
            let accountID = first.accountID
            calls.append((accountID, action))
            if accountID == gateAccount, let waiting = gate {
                gate = nil
                await waiting.pause()
            }
            if failingAccount == accountID { failingAccount = nil; throw MailFailure.rejected }
            if action == .read { unread[accountID] = false }
            if action == .unread { unread[accountID] = true }
            completedAccounts.insert(accountID)
            let callbacks = completionWaiters.filter { $0.0 == accountID }
            completionWaiters.removeAll { $0.0 == accountID }
            callbacks.forEach { $0.1.resume() }
        }))
    }
    func waitForCompletion(_ accountID: String) async {
        if !completedAccounts.contains(accountID) {
            await withCheckedContinuation { completionWaiters.append((accountID, $0)) }
        }
    }
}

@MainActor func runMailMutationOrderTests(_ require: (Bool, String) -> Void) async {
    // UI intent ordering is established synchronously, but acknowledgements
    // remain server-first; the queue never applies an optimistic local read.
    do {
        let server = MailMutationTestServer(), state = server.state(), a = state.accounts[0], b = state.accounts[1]
        state.start(); await state.syncScheduler.waitUntilIdle()
        let message = server.message(a), other = server.message(b), first = MailMutationTestGate()
        server.gateAccount = a.id; server.gate = first
        let staleFence = state.captureViewReplyFence(accountID: a.id)
        let stale = InboxPage(messages: [message], remoteID: "100", folderID: "500", next: 2, more: false)
        state.perform(.read, on: [message])
        state.perform(.unread, on: [message])
        await first.wait()
        require(server.calls.filter { $0.0 == a.id }.map { $0.1 } == [.read], "second same-account UI request does not reach transport until first ack")
        require(state.messageStore[message.key]?.unread == true, "blocked read remains acknowledgement-only rather than optimistic")
        state.perform(.read, on: [other])
        await server.waitForCompletion(b.id)
        require(server.calls.contains { $0.0 == b.id } && server.calls.filter { $0.0 == a.id }.count == 1,
                "account B proceeds independently while account A transport is blocked")
        first.release(); await state.mutationQueue.waitUntilIdle(); await state.syncScheduler.waitUntilIdle()
        require(server.calls.filter { $0.0 == a.id }.map { $0.1 } == [.read, .unread], "same-account transport receives intents FIFO")
        require(server.unread[a.id] == true && state.messageStore[message.key]?.unread == true,
                "latest read then unread intent wins both remote fixture and local state")
        require(!state.mergeViewPage(stale, account: a, replacing: true, fence: staleFence), "pre-ack view reply is fenced after serialized mutations")
        // The awaitable entry joins the same queue after already-enqueued UI work.
        state.perform(.read, on: [message])
        await state.performAndWait(.unread, on: [message])
        await state.syncScheduler.waitUntilIdle()
        require(Array(server.calls.filter { $0.0 == a.id }.suffix(2)).map { $0.1 } == [.read, .unread] && state.messageStore[message.key]?.unread == true,
                "awaitable mutation entry shares UI queue and waits through its own acknowledgement")
        _ = state.shutdown()
    }
    do {
        let server = MailMutationTestServer(), state = server.state(), a = state.accounts[0]
        state.start(); await state.syncScheduler.waitUntilIdle()
        let message = server.message(a), gate = MailMutationTestGate()
        server.gateAccount = a.id; server.gate = gate; server.failingAccount = a.id
        state.perform(.read, on: [message]); state.perform(.unread, on: [message])
        await gate.wait()
        require(server.calls.count == 1, "failed-first queue still waits for its transport result")
        gate.release(); await state.mutationQueue.waitUntilIdle(); await state.syncScheduler.waitUntilIdle()
        require(server.calls.map { $0.1 } == [.read, .unread] && server.completedAccounts.contains(a.id), "first request failure releases next queued intent")
        require(state.messageStore[message.key]?.unread == true && server.unread[a.id] == true, "failure does not apply the rejected read locally")
        _ = state.shutdown()
    }
    do {
        let server = MailMutationTestServer(), state = server.state(), a = state.accounts[0]
        state.start(); await state.syncScheduler.waitUntilIdle()
        let message = server.message(a), gate = MailMutationTestGate()
        server.gateAccount = a.id; server.gate = gate
        state.perform(.read, on: [message]); state.perform(.unread, on: [message])
        await gate.wait(); _ = state.shutdown()
        state.perform(.read, on: [message])
        gate.release()
        // Includes fenced cancelled tails and their original in-flight request.
        await state.mutationQueue.waitUntilIdle()
        require(server.calls.map { $0.1 } == [.read], "shutdown drops queued and newly requested intents before transport")
        require(state.messageStore[message.key]?.unread == true, "late in-flight acknowledgement after shutdown cannot write local state")
    }
    do {
        let server = MailMutationTestServer(), state = server.state(), a = state.accounts[0]
        state.start(); await state.syncScheduler.waitUntilIdle()
        let message = server.message(a), gate = MailMutationTestGate()
        server.gateAccount = a.id; server.gate = gate
        state.perform(.read, on: [message]); state.perform(.unread, on: [message])
        await gate.wait(); await state.removeAccountAndWait(a)
        state.perform(.read, on: [message]); gate.release()
        await state.mutationQueue.waitUntilIdle()
        require(server.calls.map { $0.1 } == [.read], "removed account's queued and new intents never reach transport")
        require(state.messageStore[message.key] == nil && !state.accounts.contains { $0.id == a.id }, "removed account is not recreated by late acknowledgement")
        _ = state.shutdown()
    }
}
