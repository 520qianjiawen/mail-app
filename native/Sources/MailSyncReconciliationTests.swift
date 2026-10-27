import Foundation

@MainActor private final class MailSyncTestGate {
    private var entered = false
    private var released = false
    private var entrants: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        let waiting = entrants; entrants.removeAll()
        for waiter in waiting { waiter.resume() }
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entrants.append($0) } }
    }
    func release() {
        released = true
        releaseWaiter?.resume(); releaseWaiter = nil
    }
}

@MainActor private final class MailSyncFixtureServer {
    var calls: [String] = []
    var counters: [String: Int] = [:]
    var omittedCounters: Set<String> = []
    var messages: [String: [MailMessage]] = [:]
    var failures: [String: MailFailure] = [:]
    var gates: [String: [MailSyncTestGate]] = [:]
    var actionCalls: [MailAction] = []
    var actionFailure = false
    var actionGate: MailSyncTestGate?

    func message(_ account: MailAccount, id: String = "900", unread: Bool = true) -> MailMessage {
        MailMessage(accountID: account.id, remoteID: "100", folderID: "500", id: id,
                    origin: URL(string: "https://mail.zoho.com")!, subject: "fixture", sender: "fixture@example.test",
                    preview: "", date: Date(timeIntervalSince1970: Double(id) ?? 0), attachment: false, unread: unread)
    }
    func snapshot(_ account: MailAccount) -> MailSyncSnapshot {
        var folder = MailFolder(id: "500", name: "Inbox", path: "/Inbox", type: "Inbox")
        folder.unread = omittedCounters.contains(account.id) ? nil : counters[account.id, default: 0]
        let context = MailboxSession(accountID: account.id, remoteID: "100", email: "fixture@example.test",
                                    origin: URL(string: "https://mail.zoho.com")!, folders: [folder], addresses: ["fixture@example.test"])
        return MailSyncSnapshot(context: context, head: InboxPage(messages: messages[account.id] ?? [], remoteID: "100",
                                  folderID: "500", next: 101, more: true, mailbox: context))
    }
    func fetch(_ account: MailAccount) async throws -> MailSyncSnapshot {
        calls.append(account.id)
        let captured = snapshot(account)
        let failure = failures[account.id]
        if var queue = gates[account.id], !queue.isEmpty {
            let gate = queue.removeFirst(); gates[account.id] = queue
            await gate.pause()
        }
        if let failure { throw failure }
        return captured
    }
    func perform(_ action: MailAction, messages: [MailMessage]) async throws {
        actionCalls.append(action)
        if let gate = actionGate { actionGate = nil; await gate.pause() }
        if actionFailure { throw MailFailure.rejected }
    }
    func state() -> AppState {
        AppState(fixture: true, syncHooks: MailSyncHooks(fetchInbox: { [self] in try await fetch($0) },
                                                      performAction: { [self] in try await perform($0, messages: $1) }))
    }
}

/// Actual AppState and production MailSyncScheduler, with only remote fetch /
/// acknowledgement boundaries replaced. All storage is fixture-temp storage.
@MainActor func runMailSyncReconciliationTests(_ require: (Bool, String) -> Void) async {
    // Every view/account selection is independent of the synchronization target.
    do {
        let server = MailSyncFixtureServer(), state = server.state()
        let a = state.accounts[0], b = state.accounts[1]
        server.counters[a.id] = 123; server.counters[b.id] = 7
        server.messages[a.id] = [server.message(a)]; server.messages[b.id] = [server.message(b)]
        state.start()
        await state.syncScheduler.waitUntilIdle()
        require(server.calls == [a.id, b.id], "startup reconciles every account in order")
        require(state.unreadTotal == 130 && !state.unreadCountsStale, "Dock uses known server Inbox counts above one page")
        for scope in [Scope(kind: .all, accountID: a.id), Scope(kind: .folder, accountID: a.id, folderID: "700"),
                      Scope(kind: .search, query: "fixture"), Scope(kind: .offline), Scope(kind: .outbox)] {
            state.scope = scope
            server.calls = []
            state.handleSyncEvent(.periodic, isActive: true)
            await state.syncScheduler.waitUntilIdle()
            require(server.calls == [a.id, b.id], "periodic sync covers all accounts while viewing \(scope.kind.rawValue)")
        }
        server.calls = []
        state.preferences.value.notificationsEnabled = false
        state.handleSyncEvent(.periodic, isActive: false)
        await state.syncScheduler.waitUntilIdle()
        require(server.calls.isEmpty, "inactive periodic policy honors notifications-disabled preference")
        for event in [MailSyncEvent.activation, .wake] {
            state.handleSyncEvent(event, isActive: false)
            await state.syncScheduler.waitUntilIdle()
            require(server.calls == [a.id, b.id], "activation/wake reconciles despite inactive notification policy")
            server.calls = []
        }
        state.preferences.value.notificationsEnabled = true
        state.handleSyncEvent(.periodic, isActive: false)
        await state.syncScheduler.waitUntilIdle()
        require(server.calls == [a.id, b.id], "notifications-enabled inactive periodic policy reconciles")
        require(state.accountSessions.isEmpty, "all integration fixtures avoid AccountSession construction")
        _ = state.shutdown()
    }

    // Fresh server zero wins over ten stale cached unread rows. Head merge is
    // non-destructive in both memory and SQLite, including offline-saved keys.
    do {
        let server = MailSyncFixtureServer(), state = server.state(), a = state.accounts[0]
        let old = (1...10).map { server.message(a, id: String($0)) }
        for message in old { state.messageStore[message.key] = message }
        state.cache.store(old, account: a.id, replace: false)
        state.preferences.value.offlineSaved = [old[0].key]
        state.scope = Scope(kind: .offline)
        server.counters[a.id] = 5
        state.start(); await state.syncScheduler.waitUntilIdle()
        require(state.folderUnread(a.id, state.sessions[a.id]!.inbox!) == 5, "server5 wins over cached10 rather than max floor")
        server.counters[a.id] = 0
        server.messages[a.id] = [server.message(a, id: "999", unread: false)]
        state.handleSyncEvent(.manual, isActive: true); await state.syncScheduler.waitUntilIdle()
        require(state.unreadTotal == 0 && state.folderUnread(a.id, state.sessions[a.id]!.inbox!) == 0, "server counter falls5 to0 despite stale unread10")
        require(old.allSatisfy { state.messageStore[$0.key] != nil }, "global head upsert preserves older canonical metadata")
        let cached = Set(state.cache.messages(accounts: [a.id]).map { $0.key })
        require(old.allSatisfy { cached.contains($0.key) } && cached.contains(server.messages[a.id]![0].key), "global head upsert preserves and extends SQLite metadata")
        require(state.rows.contains { $0.key == old[0].key }, "offline-saved metadata remains visible after global head refresh")
        let observed = state.counterSyncedAt[a.id]
        server.omittedCounters.insert(a.id)
        state.handleSyncEvent(.manual, isActive: true); await state.syncScheduler.waitUntilIdle()
        require(state.sessions[a.id]?.inbox?.unread == 0 && state.counterSyncedAt[a.id] == observed, "missing new counter preserves last-known zero without refreshing its age")
        server.failures[a.id] = .network
        state.handleSyncEvent(.manual, isActive: true); await state.syncScheduler.waitUntilIdle()
        require(state.sessions[a.id]?.inbox?.unread == 0 && state.counterSyncedAt[a.id] == observed && state.unreadCountsStale,
                "network failure preserves last-known count and observation age, marks stale")
        require(state.messageStore[old[0].key] != nil && state.accountErrors[a.id] != nil, "failed cycle preserves metadata and records account error")
        _ = state.shutdown()
    }

    // Tick pressure does not cancel account A or starve B. All requests received
    // while the first cycle is running result in just one following full cycle.
    do {
        let server = MailSyncFixtureServer(), state = server.state(), gate = MailSyncTestGate()
        let a = state.accounts[0], b = state.accounts[1]
        server.gates[a.id] = [gate]
        state.start(); await gate.waitUntilEntered()
        for _ in 0..<20 { state.handleSyncEvent(.periodic, isActive: true) }
        require(server.calls == [a.id], "running cycle is not restarted by periodic ticks")
        gate.release(); await state.syncScheduler.waitUntilIdle()
        require(server.calls == [a.id, b.id, a.id, b.id], "requests coalesce into one follow-up and both cycles finish later account")
        _ = state.shutdown()
    }

    // Both actual production view-merge and background merge reject pre-ack
    // snapshots; hold the follow-up fetch to inspect state before it can mask a
    // stale intermediate overwrite.
    do {
        let server = MailSyncFixtureServer(), state = server.state(), a = state.accounts[0]
        let unread = server.message(a)
        server.counters[a.id] = 5; server.messages[a.id] = [unread]
        state.start(); await state.syncScheduler.waitUntilIdle()
        let staleView = server.snapshot(a).head, viewFence = state.captureViewReplyFence(accountID: a.id)
        let oldFetch = MailSyncTestGate(), afterAckFetch = MailSyncTestGate()
        server.gates[a.id] = [oldFetch, afterAckFetch]
        state.handleSyncEvent(.manual, isActive: true); await oldFetch.waitUntilEntered()
        var read = unread; read.unread = false
        server.counters[a.id] = 0; server.messages[a.id] = [read]
        await state.performAndWait(.read, on: [unread])
        require(state.messageStore[unread.key]?.unread == false && state.unreadCountsStale, "acknowledged read applies locally and marks server count pending without blind decrement")
        require(!state.mergeViewPage(staleView, account: a, replacing: true, fence: viewFence) && state.messageStore[unread.key]?.unread == false,
                "pre-ack view page cannot restore unread after acknowledgement")
        oldFetch.release(); await afterAckFetch.waitUntilEntered()
        require(state.messageStore[unread.key]?.unread == false && state.sessions[a.id]?.inbox?.unread == 5,
                "pre-ack global snapshot is rejected before following fresh fetch completes")
        afterAckFetch.release(); await state.syncScheduler.waitUntilIdle()
        require(state.sessions[a.id]?.inbox?.unread == 0 && state.unreadTotal == 0 && !state.unreadCountsStale, "acknowledgement triggers fresh server0 reconciliation")
        // A later ordinary page's cached catalog cannot resurrect its old5.
        let currentFence = state.captureViewReplyFence(accountID: a.id)
        require(state.mergeViewPage(staleView, account: a, replacing: false, fence: currentFence) && state.sessions[a.id]?.inbox?.unread == 0,
                "ordinary view page never re-adopts its stale cached catalog")
        _ = state.shutdown()
    }

    // Removal is fenced before WebKit cleanup; stopped work cannot resurrect
    // accounts or metadata even when the injected transport ignores cancellation.
    do {
        let server = MailSyncFixtureServer(), state = server.state(), gate = MailSyncTestGate()
        let a = state.accounts[0], b = state.accounts[1], ghost = server.message(state.accounts[0])
        server.messages[a.id] = [ghost]; server.gates[a.id] = [gate]
        state.start(); await gate.waitUntilEntered()
        let fence = state.captureViewReplyFence(accountID: a.id), page = server.snapshot(a).head
        await state.removeAccountAndWait(a)
        gate.release(); await state.syncScheduler.waitUntilIdle()
        require(state.sessions[a.id] == nil && state.messageStore[ghost.key] == nil && state.cache.contexts(accounts: [a.id]).isEmpty,
                "removed account is not resurrected by late global reply")
        require(!state.mergeViewPage(page, account: a, replacing: true, fence: fence), "removed account rejects late view reply")
        require(server.calls.contains(b.id) && !state.accounts.contains { $0.id == a.id }, "removal does not starve remaining account")
        _ = state.shutdown()
    }
    do {
        let server = MailSyncFixtureServer(), state = server.state(), gate = MailSyncTestGate()
        let a = state.accounts[0]
        server.messages[a.id] = [server.message(a)]; server.gates[a.id] = [gate]
        state.start(); await gate.waitUntilEntered()
        let fence = state.captureViewReplyFence(accountID: a.id), page = server.snapshot(a).head
        require(state.shutdown(), "fixture shutdown succeeds")
        gate.release(); await state.syncScheduler.waitUntilIdle()
        state.handleSyncEvent(.activation, isActive: true)
        require(state.sessions.isEmpty && state.messageStore.isEmpty && server.calls == [a.id], "shutdown fences late response and prevents further account cycles")
        require(!state.mergeViewPage(page, account: a, replacing: true, fence: fence), "shutdown fences late view page")
    }

    // Every successful message mutation routes through the same production
    // completion path, requests fresh counters, and never decrements blindly.
    do {
        let server = MailSyncFixtureServer(), state = server.state(), a = state.accounts[0], b = state.accounts[1]
        let message = server.message(a)
        server.counters[a.id] = 123
        state.start(); await state.syncScheduler.waitUntilIdle()
        let actions: [MailAction] = [.read, .unread, .archive, .unarchive, .move("700"), .trash, .spam, .notSpam,
                                     .flag("important"), .pin(true), .label("77", true), .snooze(nil)]
        for action in actions {
            state.messageStore[message.key] = message
            server.calls = []
            // The queued awaitable action may yield to the fresh-counter job
            // before returning. Hold that actual observation to test the
            // pre-observation state deterministically, not task scheduling.
            let counterGate = MailSyncTestGate()
            server.gates[a.id] = [counterGate]
            await state.performAndWait(action, on: [message])
            require(state.unreadTotal == 123 && state.unreadCountsStale, "acknowledged \(action.mode) preserves snapshot count until fresh observation")
            counterGate.release()
            await state.syncScheduler.waitUntilIdle()
            require(server.calls == [a.id, b.id] && !state.unreadCountsStale, "acknowledged \(action.mode) initiates independent fresh counters")
        }
        require(server.actionCalls.count == actions.count && state.accountSessions.isEmpty, "all action fixtures use hook rather than account sessions")
        server.actionFailure = true; server.calls = []
        state.messageStore[message.key] = message
        await state.performAndWait(.read, on: [message]); await state.syncScheduler.waitUntilIdle()
        require(server.calls.isEmpty && state.messageStore[message.key]?.unread == true, "rejected action neither changes unread nor requests acknowledged reconciliation")
        let gate = MailSyncTestGate(); server.actionFailure = false; server.actionGate = gate
        let actionTask = Task { @MainActor in await state.performAndWait(.read, on: [message]) }
        await gate.waitUntilEntered(); _ = state.shutdown()
        gate.release(); await actionTask.value
        require(state.messageStore[message.key]?.unread == true && server.calls.isEmpty, "late action acknowledgement after shutdown is ignored")
    }

    // No remote observation means cache-only estimates, explicitly stale.
    do {
        let server = MailSyncFixtureServer(), state = server.state(), a = state.accounts[0]
        server.omittedCounters.insert(a.id)
        state.messageStore[server.message(a).key] = server.message(a)
        state.start(); await state.syncScheduler.waitUntilIdle()
        require(state.unreadTotal == 1 && state.unreadCountsStale && state.counterSyncedAt[a.id] == nil,
                "unknown remote count falls back to cached estimate without claiming freshness")
        _ = state.shutdown()
    }
}
