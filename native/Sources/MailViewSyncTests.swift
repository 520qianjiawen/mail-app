import Foundation

@MainActor private final class MailViewTestGate {
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

@MainActor private final class MailViewTestServer {
    var inboxRows: [String: [MailMessage]] = [:]
    var viewRows: [String: [MailMessage]] = [:]
    var next = 101
    var more = true
    var moreByAccount: [String: Bool] = [:]
    var calls: [(String, ScopeKind, Int)] = []
    var filters: [ListFilter] = []
    var inboxGate: MailViewTestGate?
    var viewGate: MailViewTestGate?
    func message(_ account: MailAccount, id: String, folder: String = "500", unread: Bool = true, attachment: Bool = false) -> MailMessage {
        MailMessage(accountID: account.id, remoteID: "100", folderID: folder, id: id,
                    origin: URL(string: "https://mail.zoho.com")!, subject: "view fixture", sender: "sender@example.test",
                    preview: "", date: Date(timeIntervalSince1970: Double(id) ?? 0), attachment: attachment, unread: unread)
    }
    func context(_ account: MailAccount) -> MailboxSession {
        MailboxSession(accountID: account.id, remoteID: "100", email: "fixture@example.test",
                       origin: URL(string: "https://mail.zoho.com")!,
                       folders: [MailFolder(id: "500", name: "Inbox", path: "/Inbox", type: "Inbox", unread: 0),
                                 MailFolder(id: "700", name: "Sent", path: "/Sent", type: "Sent", unread: 0)], addresses: [])
    }
    func page(_ account: MailAccount, rows: [MailMessage], folder: String = "500") -> InboxPage {
        InboxPage(messages: rows, remoteID: "100", folderID: folder, next: next, more: moreByAccount[account.id] ?? more)
    }
    func state() -> AppState {
        AppState(fixture: true, syncHooks: MailSyncHooks(fetchInbox: { [self] account in
            let result = MailSyncSnapshot(context: context(account), head: page(account, rows: inboxRows[account.id] ?? []))
            if let gate = inboxGate { inboxGate = nil; await gate.pause() }
            return result
        }, fetchView: { [self] account, scope, filter, start in
            calls.append((account.id, scope.kind, start))
            filters.append(filter)
            let result = page(account, rows: viewRows[account.id] ?? [], folder: scope.folderID ?? "500")
            if let gate = viewGate { viewGate = nil; await gate.pause() }
            return result
        }))
    }
    func settle(_ state: AppState) async {
        await state.syncScheduler.waitUntilIdle()
        await state.refreshTask?.value
        await state.viewSyncScheduler.waitUntilIdle()
    }
}

@MainActor func runMailViewSyncTests(_ require: (Bool, String) -> Void) async {
    // Query replacement is not canonical/offline deletion, and global unfiltered
    // heads do not alter a successful empty filtered membership.
    do {
        let server = MailViewTestServer(), state = server.state(), a = state.accounts[0]
        let old = server.message(a, id: "1"), unread = server.message(a, id: "2"), read = server.message(a, id: "3", unread: false)
        state.messageStore[old.key] = old; state.cache.store([old], account: a.id, replace: false)
        state.preferences.value.offlineSaved = [old.key]
        server.inboxRows[a.id] = [unread, read]
        state.start(); await server.settle(state)
        state.scope = Scope(kind: .unread, accountID: a.id); state.filter = .unread
        server.viewRows[a.id] = []; state.refresh(); await server.settle(state)
        require(state.rows.isEmpty, "successful empty unread query hides stale canonical unread rows")
        require(state.messageStore[old.key] != nil && state.cache.messages(accounts: [a.id]).contains { $0.key == old.key }, "empty filtered page preserves canonical and SQLite offline metadata")
        state.handleSyncEvent(.mutation, isActive: true); await server.settle(state)
        require(state.rows.isEmpty, "unfiltered background head does not contaminate filtered membership")
        state.scope = Scope(kind: .offline); state.filter = .all; state.rebuildRows()
        require(state.rows.contains { $0.key == old.key }, "offline view retains saved metadata after empty filtered refresh")
        state.scope = Scope(kind: .all, accountID: a.id); state.rebuildRows()
        require(!state.rows.contains { $0.key == old.key } && state.rows.count == 2, "successful Inbox head excludes absent ghost membership without deleting canonical old mail")
        server.inboxRows[a.id] = [read]; state.handleSyncEvent(.mutation); await server.settle(state)
        require(state.rows.map(\.key) == [read.key] && state.messageStore[unread.key] != nil, "remote head deletion removes live row but preserves cached metadata")
        _ = state.shutdown()
    }
    // Pagination uses remote offsets, not canonical counts, and deduplicates IDs.
    do {
        let server = MailViewTestServer(), state = server.state(), a = state.accounts[0]
        state.start(); await server.settle(state)
        for n in 1...220 { let m = server.message(a, id: String(n)); state.messageStore[m.key] = m }
        let first = server.message(a, id: "300"), second = server.message(a, id: "301")
        state.scope = Scope(kind: .folder, accountID: a.id, folderID: "700")
        let sentFirst = server.message(a, id: first.id, folder: "700"), sentSecond = server.message(a, id: second.id, folder: "700")
        server.viewRows[a.id] = [sentFirst]; server.next = 101
        state.refresh(); await server.settle(state)
        server.viewRows[a.id] = [sentFirst, sentSecond]; server.next = 201
        state.loadMore(); await server.settle(state)
        require(server.calls.last?.2 == 101, "pagination sends actual response next101 despite canonical220")
        require(state.rows.count == 2 && Set(state.rows.map(\.key)).count == 2, "appended query page deduplicates repeated identities")
        let query = MailViewQuery.make(accountID: a.id, scope: state.scope, filter: .all, inboxID: "500")!
        require(state.viewWindows[query]?.next == 201, "query stores returned next201 rather than deduplicated member count")
        _ = state.shutdown()
    }
    // Toolbar filters immediately request the corresponding network query,
    // and sparse/grouped result pagination follows server window.more.
    do {
        let server = MailViewTestServer(), state = server.state(), a = state.accounts[0]
        state.start(); await server.settle(state)
        state.scope = Scope(kind: .folder, accountID: a.id, folderID: "700")
        let read = server.message(a, id: "40", folder: "700", unread: false)
        let unread = server.message(a, id: "41", folder: "700")
        server.viewRows[a.id] = [read]; state.refresh(); await server.settle(state)
        server.viewRows[a.id] = [unread]
        let before = server.calls.count
        state.setFilter(.unread); await server.settle(state)
        require(server.calls.count == before + 1 && server.filters.last == .unread,
                "selecting unread in Sent immediately fetches the unread network query")
        require(state.rows.map(\.key) == [unread.key], "Sent unread filter displays newly returned query membership immediately")
        require(state.rows.count < state.visibleLimit && state.canLoadMoreResults,
                "sparse or grouped query exposes pagination when server more is true")
        server.more = false; state.refresh(); await server.settle(state)
        for n in 1000...1220 { let m = server.message(a, id: String(n), folder: "700"); state.messageStore[m.key] = m }
        state.rebuildRows()
        require(!state.canLoadMoreResults, "successful more=false hides pagination despite large canonical cache")
        state.scope = Scope(kind: .search, query: "mixed account")
        server.moreByAccount[state.accounts[1].id] = true
        state.filter = .all; state.refresh(); await server.settle(state)
        require(state.canLoadMoreResults, "multi-account query exposes pagination if any successful account window has more")
        state.scope = Scope(kind: .offline); state.rebuildRows()
        require(!state.canLoadMoreResults, "offline view never exposes remote pagination")
        _ = state.shutdown()
    }
    // Search membership is per-account, rendered through canonical IDs; label
    // server membership does not depend on an optional labels response field.
    do {
        let server = MailViewTestServer(), state = server.state(), a = state.accounts[0], b = state.accounts[1]
        let ma = server.message(a, id: "10"), mb = server.message(b, id: "11")
        state.start(); await server.settle(state)
        server.viewRows[a.id] = [ma]; server.viewRows[b.id] = [mb]
        state.scope = Scope(kind: .search, query: "entire:fixture"); state.refresh(); await server.settle(state)
        require(Set(state.rows.map(\.key)) == Set([ma.key, mb.key]), "two-account replacing search retains both result memberships")
        var changed = ma; changed.unread = false
        state.messageStore[ma.key] = changed; state.rebuildRows()
        require(state.rows.first { $0.key == ma.key }?.unread == false, "search projection reads updated canonical status rather than stale copies")
        state.scope = Scope(kind: .label, accountID: a.id, label: MailLabel(id: "77", name: "fixture", color: ""))
        state.refresh(); await server.settle(state)
        require(state.rows.map(\.key) == [ma.key], "label query displays server hits even when optional labels metadata is absent")
        _ = state.shutdown()
    }
    // The real selected-view scheduler updates non-Inbox content while the
    // independent Inbox cycle is still blocked. Scope changes fence old replies.
    do {
        let server = MailViewTestServer(), state = server.state(), a = state.accounts[0]
        state.start(); await server.settle(state)
        let sent = server.message(a, id: "80", folder: "700")
        state.scope = Scope(kind: .folder, accountID: a.id, folderID: "700")
        server.viewRows[a.id] = [sent]; state.refresh(); await server.settle(state)
        let globalGate = MailViewTestGate(); server.inboxGate = globalGate
        server.viewRows[a.id] = []
        state.handleSyncEvent(.periodic, isActive: true); await globalGate.wait()
        await state.viewSyncScheduler.waitUntilIdle()
        require(state.rows.isEmpty && state.messageStore[sent.key] != nil, "periodic refresh removes remote Sent row while unrelated global Inbox fetch remains pending")
        globalGate.release(); await server.settle(state)
        let gate = MailViewTestGate(); server.viewGate = gate; server.viewRows[a.id] = [sent]
        state.refresh(); await gate.wait()
        state.select(Scope(kind: .search, accountID: a.id, query: "new query"))
        gate.release(); await server.settle(state)
        require(state.scope.kind == .search && state.viewWindows.keys.filter { $0.kind == "folder" && $0.identifier == "700" }.allSatisfy { state.viewWindows[$0]?.keys.isEmpty == true }, "scope generation change ignores late old-folder reply")
        _ = state.shutdown()
    }
    // A valid query token does not permit cross-account/remote/origin data.
    do {
        let server = MailViewTestServer(), state = server.state(), a = state.accounts[0], b = state.accounts[1]
        state.start(); await server.settle(state)
        state.scope = Scope(kind: .search, accountID: a.id, query: "fixture")
        let original = server.message(a, id: "850"), foreign = server.message(b, id: "851")
        state.messageStore[foreign.key] = foreign
        func attempt(_ page: InboxPage) -> Bool {
            state.mergeViewPage(page, account: a, replacing: true, fence: state.captureViewReplyFence(accountID: a.id))
        }
        require(!attempt(server.page(a, rows: [foreign])), "cross-account query result is rejected even when foreign key already exists canonically")
        let wrongRemote = InboxPage(messages: [original], remoteID: "999", folderID: "500", next: 101, more: true)
        require(!attempt(wrongRemote), "query result with wrong remote account is rejected")
        let wrongOrigin = MailMessage(accountID: a.id, remoteID: "100", folderID: "500", id: "852", origin: URL(string: "https://mail.zoho.eu")!, subject: "wrong origin", sender: "", preview: "", date: Date(), attachment: false, unread: true)
        require(!attempt(server.page(a, rows: [wrongOrigin])) && state.messageStore[wrongOrigin.key] == nil, "wrong authenticated origin neither creates membership nor writes canonical data")
        require(!attempt(InboxPage(messages: [original], remoteID: "100", folderID: "500", next: 0, more: true)), "invalid pagination offset rejects entire query result")
        state.rebuildRows()
        require(state.rows.isEmpty, "invalid search pages cannot expose another account's cached row")
        state.scope = Scope(kind: .folder, accountID: a.id, folderID: "700")
        require(!attempt(server.page(a, rows: [original])), "folder query rejects page and message folder mismatch")
        _ = state.shutdown()
    }
    // Capture the ORIGINAL request token before a newer global observation.
    do {
        let server = MailViewTestServer(), state = server.state(), a = state.accounts[0]
        let unread = server.message(a, id: "900"), stalePage = server.page(a, rows: [server.message(a, id: "900")])
        server.inboxRows[a.id] = [unread]; state.start(); await server.settle(state)
        state.scope = Scope(kind: .unread, accountID: a.id); state.filter = .unread
        let original = state.captureViewReplyFence(accountID: a.id)
        var read = unread; read.unread = false; server.inboxRows[a.id] = [read]
        state.handleSyncEvent(.mutation); await server.settle(state)
        _ = state.mergeViewPage(stalePage, account: a, replacing: true, fence: original)
        require(state.messageStore[unread.key]?.unread == false, "older original view token cannot revert newer global canonical read state across different queries")
        let sameQueryOld = state.captureViewReplyFence(accountID: a.id)
        state.scope = Scope(kind: .all, accountID: a.id); state.filter = .all
        state.handleSyncEvent(.mutation); await server.settle(state)
        require(!state.mergeViewPage(stalePage, account: a, replacing: true, fence: sameQueryOld), "older same-query reply cannot replace newer global membership")
        let stoppedToken = state.captureViewReplyFence(accountID: a.id)
        _ = state.shutdown()
        require(!state.mergeViewPage(stalePage, account: a, replacing: true, fence: stoppedToken), "lifetime shutdown fence also protects query membership")
    }
    // All Sent scope queries the sent folder and displays sent rows
    do {
        let server = MailViewTestServer(), state = server.state(), a = state.accounts[0]
        let sentMessage = server.message(a, id: "901", folder: "700", unread: false)
        server.viewRows[a.id] = [sentMessage]
        state.start(); await server.settle(state)
        state.showAllSent()
        await server.settle(state)
        require(state.scope.kind == .sent, "showAllSent selects sent scope")
        require(server.calls.contains { $0.0 == a.id && $0.1 == .sent }, "sent query dispatched to account")
        _ = state.shutdown()
    }
}
