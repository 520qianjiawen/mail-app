import Foundation

@MainActor private final class MailContextGate {
    private var entered = false
    private var released = false
    private var entry: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        let callbacks = entry; entry.removeAll(); callbacks.forEach { $0.resume() }
        if !released { await withCheckedContinuation { releaseContinuation = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entry.append($0) } } }
    func release() { released = true; releaseContinuation?.resume(); releaseContinuation = nil }
}

@MainActor private func contextMessage(_ state: AppState, id: String = "1", subject: String = "Subject", origin: String = "https://mail.zoho.com", sender: String = "Sender <sender@example.test>") -> MailMessage {
    MailMessage(accountID: state.accounts[0].id, remoteID: "100", folderID: "500", id: id,
                origin: URL(string: origin)!, subject: subject, sender: sender,
                preview: "", date: Date(timeIntervalSince1970: 1), attachment: false, unread: true)
}

private func contextDetail(_ message: MailMessage) -> MailDetail {
    var value = MailDetail(message: message, from: "sender@example.test", to: "recipient@example.test",
                           cc: "copy@example.test", replyTo: "reply@example.test", html: "<p>body-\(message.id)</p>", attachments: [], inline: [])
    value.replyHeadersChecked = true
    return value
}

@MainActor private func contextState(fetch: @escaping (MailMessage) async throws -> MailDetail) -> AppState {
    let state = AppState(fixture: true, syncHooks: MailSyncHooks(fetchInbox: { _ in throw MailFailure.rejected }, performAction: { _, _ in }, fetchDetail: fetch))
    state.preferences.value.markReadOnOpen = false
    return state
}

@MainActor func runMailContextMenuTests(_ require: (Bool, String) -> Void) async {
    require(MailContextCommand.allCases.map(\.rawValue) == ["sender", "subject", "reply", "replyAll", "forward", "spam", "delete", "reminder", "pin"],
            "message-list command definition contains only the nine requested commands; no tabs, windows, read, flag, folder, label, archive, offline or snooze")
    require(MailContextCommand.replyAll.title() == "回复所有人" && MailContextCommand.pin.title() == "固定邮件" && MailContextCommand.pin.title(pinned: true) == "取消固定", "menu uses requested reply-all and fixed-mail wording")
    require(MailContextCommand.reminder.title() == "设置提醒…" && MailContextCommand.reminder.title(reminded: true) == "修改提醒…", "reminder label reflects existing reminder")

    // Every compose mode captures clicked A while selected B is active, then C is
    // selected during the fetch. No polling, timeout or current-detail handoff.
    for mode in [ComposeMode.reply, .replyAll, .forward] {
        let gate = MailContextGate()
        var fetches = 0
        let state = contextState { message in fetches += 1; await gate.pause(); return contextDetail(message) }
        let a = contextMessage(state), b = contextMessage(state, id: "2"), c = contextMessage(state, id: "3")
        state.messageStore[a.key] = a; state.messageStore[b.key] = b; state.messageStore[c.key] = c
        state.activeKey = b.key; state.detail = contextDetail(b); state.selectedKeys = [b.key]
        var drafts: [(MailDetail, ComposeMode)] = []
        state.contextComposeHook = { drafts.append(($0, $1)) }
        let pending = Task { @MainActor in await state.composeContextMessage(a, mode: mode) }
        await gate.wait()
        require(drafts.isEmpty, "\(mode.rawValue) does not create a draft from previously selected B while A loads")
        state.activeKey = c.key; state.detail = contextDetail(c); state.selectedKeys = [c.key]
        let duplicate = await state.composeContextMessage(a, mode: mode)
        require(!duplicate && fetches == 1, "\(mode.rawValue) repeated pending command neither fetches twice nor opens duplicate drafts")
        gate.release(); let opened = await pending.value
        require(opened && drafts.count == 1 && drafts.first?.0.message.key == a.key && drafts.first?.0.message.origin == a.origin && drafts.first?.1 == mode,
                "\(mode.rawValue) uses exact clicked A and requested compose mode despite later C selection")
        require(state.activeKey == c.key && state.detail?.message.key == c.key && state.selectedKeys == [c.key], "context compose preserves independent reader selection")
        require(state.messageStore[a.key]?.unread == true, "context compose adds no unrequested mark-read mutation")
        require(state.contextComposePending.isEmpty, "completed context compose releases pending guard")
        _ = state.shutdown()
    }
    do {
        let gate = MailContextGate()
        let state = contextState { message in await gate.pause(); return contextDetail(message) }
        let a = contextMessage(state), account = state.accounts[0]
        var count = 0; state.contextComposeHook = { _, _ in count += 1 }
        let pending = Task { @MainActor in await state.composeContextMessage(a, mode: .replyAll) }
        await gate.wait(); await state.removeAccountAndWait(account); gate.release()
        let opened = await pending.value
        require(!opened && count == 0 && state.cache.detail(a) == nil && state.threadDetails[a.key] == nil, "account removal during context fetch prevents draft and cache resurrection")
        require(!state.status.isEmpty, "account removal produces visible context-action status")
        _ = state.shutdown()
    }
    do {
        let gate = MailContextGate()
        let state = contextState { message in await gate.pause(); return contextDetail(message) }
        let a = contextMessage(state)
        var count = 0; state.contextComposeHook = { _, _ in count += 1 }
        let pending = Task { @MainActor in await state.composeContextMessage(a, mode: .forward) }
        await gate.wait(); _ = state.shutdown(); gate.release()
        let opened = await pending.value
        require(!opened && count == 0 && state.cache.detail(a) == nil, "shutdown lifetime fences late forward body and draft")
    }
    do {
        let gate = MailContextGate()
        let state = contextState { message in await gate.pause(); return contextDetail(message) }
        let a = contextMessage(state)
        var count = 0; state.contextComposeHook = { _, _ in count += 1 }
        let pending = Task { @MainActor in await state.composeContextMessage(a, mode: .reply) }
        await gate.wait(); state.accounts[0].name = "replacement@example.test"; gate.release()
        let opened = await pending.value
        require(!opened && count == 0, "changed account identity with same account ID fences delayed draft")
        _ = state.shutdown()
    }
    do {
        let gate = MailContextGate()
        let state = contextState { message in await gate.pause(); return contextDetail(message) }
        let a = contextMessage(state)
        var count = 0; state.contextComposeHook = { _, _ in count += 1 }
        let pending = Task { @MainActor in await state.composeContextMessage(a, mode: .forward) }
        await gate.wait(); state.messageStore[a.key] = contextMessage(state, origin: "https://mail.zoho.eu"); gate.release()
        let opened = await pending.value
        require(!opened && count == 0, "same message key with changed origin is rejected after fetch")
        _ = state.shutdown()
    }
    do {
        let gate = MailContextGate()
        let state = contextState { message in await gate.pause(); return contextDetail(message) }
        let a = contextMessage(state)
        state.sessions[a.accountID] = MailboxSession(accountID: a.accountID, remoteID: a.remoteID, email: "first@example.test", origin: a.origin, folders: [], addresses: [])
        var count = 0; state.contextComposeHook = { _, _ in count += 1 }
        let pending = Task { @MainActor in await state.composeContextMessage(a, mode: .replyAll) }
        await gate.wait()
        state.sessions[a.accountID] = MailboxSession(accountID: a.accountID, remoteID: a.remoteID, email: "replacement@example.test", origin: a.origin, folders: [], addresses: [])
        gate.release(); let opened = await pending.value
        require(!opened && count == 0, "replaced mailbox identity during fetch fences delayed reply-all")
        _ = state.shutdown()
    }
    for wrongOrigin in [false, true] {
        let state = contextState { message in
            let wrong = MailMessage(accountID: message.accountID, remoteID: message.remoteID, folderID: message.folderID,
                                    id: wrongOrigin ? message.id : "999", origin: wrongOrigin ? URL(string: "https://mail.zoho.eu")! : message.origin,
                                    subject: "Wrong", sender: "wrong@example.test", preview: "", date: message.date, attachment: false, unread: false)
            return contextDetail(wrong)
        }
        let a = contextMessage(state)
        var count = 0; state.contextComposeHook = { _, _ in count += 1 }
        let opened = await state.composeContextMessage(a, mode: .replyAll)
        require(!opened && count == 0 && state.cache.detail(a) == nil && !state.status.isEmpty, "wrong fetched \(wrongOrigin ? "origin" : "key") never creates draft and shows status")
        _ = state.shutdown()
    }
    do {
        let state = contextState { _ in throw MailFailure.rejected }
        let a = contextMessage(state)
        var count = 0; state.contextComposeHook = { _, _ in count += 1 }
        let opened = await state.composeContextMessage(a, mode: .forward)
        require(!opened && count == 0 && !state.status.isEmpty && state.contextComposePending.isEmpty, "fetch failure is visible and releases duplicate guard without draft")
        _ = state.shutdown()
    }
    do {
        let gate = MailContextGate()
        let state = contextState { message in await gate.pause(); return contextDetail(message) }
        let a = contextMessage(state)
        var count = 0; state.contextComposeHook = { _, _ in count += 1 }
        let pending = Task { @MainActor in await state.composeContextMessage(a, mode: .reply) }
        await gate.wait(); pending.cancel(); gate.release()
        let opened = await pending.value
        require(!opened && count == 0 && state.cache.detail(a) == nil, "cancelled exact-target compose creates neither draft nor cache")
        _ = state.shutdown()
    }

    do {
        var fetches = 0
        let state = contextState { message in fetches += 1; return contextDetail(message) }
        let a = contextMessage(state)
        let oldFolder = MailMessage(accountID: a.accountID, remoteID: a.remoteID, folderID: "999", id: a.id, origin: a.origin,
                                    subject: a.subject, sender: a.sender, preview: "", date: a.date, attachment: false, unread: false)
        state.threadDetails[a.key] = contextDetail(oldFolder)
        var drafts: [MailDetail] = []; state.contextComposeHook = { source, _ in drafts.append(source) }
        let opened = await state.composeContextMessage(a, mode: .reply)
        require(opened && fetches == 1 && drafts.first?.message.folderID == a.folderID, "old-folder cached source is refetched and never used for draft")
        _ = state.shutdown()
    }
    for wrongRemote in [true, false] {
        let state = contextState { message in
            let wrong = MailMessage(accountID: message.accountID, remoteID: wrongRemote ? "999" : message.remoteID,
                                    folderID: wrongRemote ? message.folderID : "999", id: message.id, origin: message.origin,
                                    subject: message.subject, sender: message.sender, preview: "", date: message.date, attachment: false, unread: false)
            return contextDetail(wrong)
        }
        let a = contextMessage(state)
        var count = 0; state.contextComposeHook = { _, _ in count += 1 }
        let opened = await state.composeContextMessage(a, mode: .replyAll)
        require(!opened && count == 0 && state.cache.detail(a) == nil, "wrong fetched \(wrongRemote ? "remote account" : "folder") identity never creates draft")
        _ = state.shutdown()
    }
    do {
        var fetches = 0
        let state = contextState { message in fetches += 1; return contextDetail(message) }
        let a = contextMessage(state)
        var count = 0; state.contextComposeHook = { _, _ in count += 1 }
        for mode in [ComposeMode.new, .edit] {
            let opened = await state.composeContextMessage(a, mode: mode)
            require(!opened && count == 0 && fetches == 0, "context compose rejects unsupported \(mode.rawValue) before loading")
        }
        _ = state.shutdown()
    }

    let literals = ["Normal subject", "a \"quoted\" subject", "back\\slash\\", "OR from:other@example.test", "a\" OR subject:\"b", "主题 AND has:attachment", "(x):y + - !"]
    let searchState = AppState(fixture: true)
    for literal in literals {
        guard let query = MailContextSearch.subject.query(literal), let parsed = MailContextSearch.parse(query) else {
            require(false, "literal query must build and roundtrip"); continue
        }
        require(parsed.field == .subject && parsed.literal == literal, "quoted subject roundtrips quotes, backslashes and operator words: \(literal)")
        let exact = contextMessage(searchState, subject: literal)
        let broad = contextMessage(searchState, subject: literal + " extra")
        require(MailContextSearch.matches(exact, query: query) && !MailContextSearch.matches(broad, query: query), "subject field postfilter requires exact literal, not substring")
    }
    require(MailContextSearch.subject.query("line\nbreak") == nil && MailContextSearch.subject.query("") == nil && MailContextSearch.subject.query(String(repeating: "x", count: 1000)) == nil, "invalid/oversize literal search is rejected rather than changed or truncated")
    let senderQuery = MailContextSearch.sender.query("sender@example.test")!
    require(MailContextSearch.matches(contextMessage(searchState), query: senderQuery), "sender exact search compares extracted address rather than display name")
    require(MailContextSearch.parse("subject:\"a\" OR from:b") == nil && MailContextSearch.matches(contextMessage(searchState), query: "has:attachment"), "general user search remains untouched by literal-only parser")
    let disguised = contextMessage(searchState, sender: "\"billing@fake.test\" <actual@example.test>")
    require(MailContextSearch.senderLiteral(disguised.sender) == "actual@example.test", "canonical bracket mailbox wins over email-looking quoted display name")
    let actualQuery = MailContextSearch.sender.query("actual@example.test")!
    let fakeQuery = MailContextSearch.sender.query("billing@fake.test")!
    require(MailContextSearch.matches(disguised, query: actualQuery) && !MailContextSearch.matches(disguised, query: fakeQuery), "sender exact filter never matches display-only fake mailbox")
    searchState.searchContextMessage(disguised, field: .sender)
    require(searchState.scope.query == actualQuery, "sender menu search uses canonical mailbox rather than first extracted display-name email")
    require(MailContextSearch.senderLiteral("Simple Name<real@example.test>") == "real@example.test" && MailContextSearch.senderLiteral("REAL@example.test") == "REAL@example.test", "simple angle and bare mailbox senders remain supported")
    require(MailContextSearch.matches(contextMessage(searchState, sender: "REAL@example.test"), query: MailContextSearch.sender.query("real@example.test")!), "bare sender exact matching remains case insensitive")
    for malformed in ["", "a@example.test, b@example.test", "a@example.test a@example.test", "<a@example.test", "a@example.test>", "<a@example.test><b@example.test>", "A <a@example.test>, B <b@example.test>", "\"unclosed <a@example.test>", "A <a@example.test b@example.test>"] {
        require(MailContextSearch.senderLiteral(malformed) == nil, "ambiguous or malformed sender is rejected: \(malformed)")
        let oldQuery = searchState.scope.query
        searchState.searchContextMessage(contextMessage(searchState, sender: malformed), field: .sender)
        require(searchState.scope.query == oldQuery && !searchState.status.isEmpty, "malformed sender search surfaces error and does not guess first mailbox")
    }
    var explicit = contextMessage(searchState, sender: "billing@fake.test")
    explicit.fromAddress = "actual@example.test"
    require(MailContextSearch.senderLiteral(explicit) == "actual@example.test" && MailContextSearch.matches(explicit, query: actualQuery) && !MailContextSearch.matches(explicit, query: fakeQuery), "explicit API From mailbox wins over display-only email in both query and filter")
    searchState.searchContextMessage(explicit, field: .sender)
    require(searchState.scope.query == actualQuery && searchState.contextSearchTask == nil, "known explicit address searches synchronously without detail request")
    let apiRow: [String: Any] = ["messageId": "44", "subject": "Invoice", "sender": "Acme Billing", "fromAddress": "actual@example.test", "receivedTime": "1000"]
    let apiMessage = MailMessage.parse(apiRow, accountID: explicit.accountID, remoteID: explicit.remoteID, folderID: explicit.folderID, origin: explicit.origin)
    require(apiMessage?.sender == "Acme Billing" && apiMessage?.fromAddress == "actual@example.test", "API row preserves display sender separately from real From mailbox")
    if let apiMessage { require(MailContextSearch.matches(apiMessage, query: actualQuery), "display-name-only API row matches real From query") }
    explicit.fromAddress = "bad mailbox"
    searchState.searchContextMessage(explicit, field: .sender)
    require(searchState.contextSearchTask == nil && !searchState.status.isEmpty, "malformed explicit From is not replaced by display-name email")
    _ = searchState.shutdown()

    do {
        let gate = MailContextGate()
        var fetched: [String] = []
        let state = contextState { message in fetched.append(message.key); await gate.pause(); return contextDetail(message) }
        let a = contextMessage(state, sender: "Legacy Name"), b = contextMessage(state, id: "2")
        state.activeKey = b.key; state.detail = contextDetail(b)
        state.searchContextMessage(a, field: .sender)
        let pending = state.contextSearchTask
        await gate.wait(); gate.release(); await pending?.value
        require(fetched == [a.key] && state.scope.query == senderQuery, "legacy display-name cache resolves exact clicked message From asynchronously")
        require(state.activeKey == b.key && state.detail?.message.key == b.key, "legacy sender lookup does not redirect reader or use selected detail")
        _ = state.shutdown()
    }
    do {
        let gate = MailContextGate()
        let state = contextState { message in await gate.pause(); return contextDetail(message) }
        state.searchContextMessage(contextMessage(state, sender: "Legacy Name"), field: .sender)
        let pending = state.contextSearchTask
        await gate.wait(); state.search("subject:manual"); gate.release(); await pending?.value
        require(state.scope.query == "subject:manual", "manual newer query invalidates pending legacy sender lookup")
        _ = state.shutdown()
    }
    do {
        let gate = MailContextGate()
        let state = contextState { message in await gate.pause(); return contextDetail(message) }
        state.searchContextMessage(contextMessage(state, sender: "Legacy Name"), field: .sender)
        let pending = state.contextSearchTask
        await gate.wait()
        let b = contextMessage(state, id: "2", sender: "second@example.test")
        state.searchContextMessage(b, field: .sender)
        gate.release(); await pending?.value
        require(state.scope.query == MailContextSearch.sender.query("second@example.test"), "second clicked sender invalidates first pending lookup token")
        _ = state.shutdown()
    }
    do {
        let gate = MailContextGate()
        let state = contextState { message in await gate.pause(); return contextDetail(message) }
        let a = contextMessage(state, sender: "Legacy Name"), account = state.accounts[0]
        state.searchContextMessage(a, field: .sender)
        let pending = state.contextSearchTask
        await gate.wait(); await state.removeAccountAndWait(account); gate.release(); await pending?.value
        require(state.scope.kind != .search && !state.status.isEmpty, "removed-account legacy From lookup never launches stale search")
        _ = state.shutdown()
    }
    do {
        let state = contextState { message in
            let wrong = MailMessage(accountID: message.accountID, remoteID: "999", folderID: message.folderID, id: message.id, origin: message.origin,
                                    subject: message.subject, sender: message.sender, preview: "", date: message.date, attachment: false, unread: false)
            return contextDetail(wrong)
        }
        state.searchContextMessage(contextMessage(state, sender: "Legacy Name"), field: .sender)
        await state.contextSearchTask?.value
        require(state.scope.kind != .search && !state.status.isEmpty, "legacy sender fetch rejects wrong source remote identity")
        _ = state.shutdown()
    }
    do {
        let state = contextState { _ in throw MailFailure.rejected }
        state.searchContextMessage(contextMessage(state, sender: "Legacy Name"), field: .sender)
        await state.contextSearchTask?.value
        require(state.scope.kind != .search && !state.status.isEmpty, "legacy From lookup failure surfaces error without guessed sender query")
        _ = state.shutdown()
    }

    // Pin travels through the existing per-account server mutation queue, not
    // a second preference bit. A gate proves acknowledgement-only behavior.
    do {
        let gate = MailContextGate()
        var calls: [MailAction] = []
        let state = AppState(fixture: true, syncHooks: MailSyncHooks(fetchInbox: { _ in throw MailFailure.rejected }, performAction: { action, _ in calls.append(action); await gate.pause() }))
        let a = contextMessage(state); state.messageStore[a.key] = a
        state.togglePin(a)
        await gate.wait()
        require(calls == [.pin(true)] && state.messageStore[a.key]?.pinned != true, "pin uses existing server queue without optimistic preferences mutation")
        gate.release(); await state.mutationQueue.waitUntilIdle()
        require(state.messageStore[a.key]?.pinned == true, "pin acknowledgement updates existing message metadata")
        if let pinned = state.messageStore[a.key] { state.togglePin(pinned) }
        await state.mutationQueue.waitUntilIdle()
        require(calls == [.pin(true), .pin(false)] && state.messageStore[a.key]?.pinned == false, "unpin uses same queue and persistence path")
        _ = state.shutdown()
    }
}
