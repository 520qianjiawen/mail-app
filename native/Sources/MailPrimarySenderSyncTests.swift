import Foundation

@MainActor private final class PrimarySyncTestGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    func pause() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation; started = true
            startContinuation?.resume(); startContinuation = nil
        }
    }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

@MainActor private final class PrimarySyncTestTransport: PrimarySenderSyncTransport {
    var updates: [(String, String)] = []
    var queries: [String] = []
    var names: [String: String] = [:]
    var updateError: MailFailure?
    var queryError: MailFailure?
    var readbackOverride: String?
    var wrongPrimary = false
    var gate: PrimarySyncTestGate?
    func updatePrimary(context: MailboxSession, name: String) async throws {
        updates.append((context.accountID, name))
        if let gate { await gate.pause() }
        if let updateError { throw updateError }
        names[context.accountID] = name
    }
    func queryPrimary(context: MailboxSession) async throws -> PrimaryAccountSenderInfo {
        queries.append(context.accountID)
        if let queryError { throw queryError }
        return .init(accountID: context.remoteID, primaryAddress: wrongPrimary ? "alias@example.test" : context.email,
                     displayName: readbackOverride ?? names[context.accountID] ?? "Original")
    }
}

@MainActor func runMailPrimarySenderSyncTests(_ require: (Bool, String) -> Void) async {
    func mailbox(_ accountID: String, remote: String = "100", email: String = "owner@example.test") -> MailboxSession {
        .init(accountID: accountID, remoteID: remote, email: email, origin: URL(string: "https://mail.zoho.com")!, folders: [], addresses: [email, "alias@example.test"], senderIdentities: [.init(address: "alias@example.test", displayName: "Alias")])
    }
    func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); require(false, label) } catch { require(true, label) }
    }
    let context = mailbox("fixture")
    do {
        require(try PrimarySenderSyncPolicy.url(context: context).absoluteString == "https://mail.zoho.com/api/accounts/100", "primary API uses account endpoint without alias/query")
        require(PrimarySenderSyncPolicy.updateMethod == "PUT", "primary API uses PUT")
        let name = "研发 · A, \"B\""
        require(try PrimarySenderSyncPolicy.updateBody(name: name) == ["mode": "updateDisplayName", "displayName": name], "primary PUT body has exactly two documented fields")
        let row: [String: Any] = ["accountId": "100", "primaryEmailAddress": "OWNER@example.test", "displayName": name, "sendMailDetails": [["displayName": "Not the account name"]]]
        require(try PrimarySenderSyncPolicy.parse(row, context: context).displayName == name, "canonical dictionary reads top-level displayName")
        require(try PrimarySenderSyncPolicy.parse([row], context: context).displayName == name, "canonical array reads matched account")
        rejects("duplicate account rows rejected") { _ = try PrimarySenderSyncPolicy.parse([row, row], context: context) }
        rejects("wrong remote account rejected") { _ = try PrimarySenderSyncPolicy.parse(["accountId": "200", "primaryEmailAddress": context.email, "displayName": name], context: context) }
        rejects("alias is never primary") { try PrimarySenderSyncPolicy.validate(context: context, accountID: "fixture", primaryAddress: "alias@example.test") }
        rejects("invalid numeric ID rejected") { _ = try PrimarySenderSyncPolicy.url(context: mailbox("fixture", remote: "100/evil")) }
        rejects("empty cloud account name rejected") { _ = try PrimarySenderSyncPolicy.updateBody(name: "") }
        rejects("whitespace-only cloud account name rejected") { _ = try PrimarySenderSyncPolicy.updateBody(name: "  ") }
        require(try PrimarySenderSyncPolicy.updateBody(name: " A ")["displayName"] == " A ", "valid authored surrounding spaces are preserved")
        rejects("header control in name rejected") { _ = try PrimarySenderSyncPolicy.updateBody(name: "a\nb") }
        rejects("oversized account array rejected") { _ = try PrimarySenderSyncPolicy.parse(Array(repeating: row, count: 101), context: context) }
    } catch { require(false, "primary pure setup: \(error)") }

    let state = AppState(fixture: true)
    defer { _ = state.shutdown() }
    let a = state.accounts[0].id, b = state.accounts[1].id
    state.sessions[a] = mailbox(a); state.sessions[b] = mailbox(b, remote: "200")
    let originalLabels = state.accounts.map(\.name)
    let originalOverrides = state.preferences.value.senderDisplayNames
    let originalMetadata = state.sessions[a]?.senderIdentities
    let fake = PrimarySyncTestTransport()
    let store = PrimarySenderSyncStore(state: state, transport: fake)
    await store.syncPrimaryDisplayName(accountID: a, primaryAddress: "OWNER@example.test", name: "Exact, A")
    require(store.states[a]?.phase == .confirmed && store.states[a]?.serverName == "Exact, A", "write success published only after exact readback")
    require(fake.updates.count == 1 && fake.queries.count == 1, "one PUT and one GET without retry")
    require(state.accounts.map(\.name) == originalLabels && state.preferences.value.senderDisplayNames == originalOverrides && state.sessions[a]?.senderIdentities == originalMetadata, "sync leaves labels overrides and alias metadata untouched")
    await store.syncPrimaryDisplayName(accountID: a, primaryAddress: "alias@example.test", name: "Alias attack")
    require(fake.updates.count == 1, "alias rejected before PUT")
    fake.readbackOverride = "exact, a"
    await store.syncPrimaryDisplayName(accountID: a, primaryAddress: context.email, name: "Exact, A")
    require(store.states[a]?.phase == .pendingConfirmation, "case-different readback remains unconfirmed")
    fake.readbackOverride = nil; fake.queryError = .network
    await store.syncPrimaryDisplayName(accountID: a, primaryAddress: context.email, name: "Updated")
    require(store.states[a]?.message == "服务器可能已更新，尚未确认，请刷新", "GET failure after ACK never claims rollback")
    fake.queryError = nil; fake.updateError = .auth
    let beforeAuthQueries = fake.queries.count
    await store.syncPrimaryDisplayName(accountID: a, primaryAddress: context.email, name: "Rejected")
    require(store.states[a]?.phase == .failed && fake.queries.count == beforeAuthQueries, "PUT auth rejection does not GET or report success")
    fake.updateError = .network
    await store.syncPrimaryDisplayName(accountID: a, primaryAddress: context.email, name: "Unknown")
    require(store.states[a]?.phase == .pendingConfirmation, "ambiguous PUT network error reports unknown")
    fake.updateError = nil; fake.wrongPrimary = true
    await store.syncPrimaryDisplayName(accountID: a, primaryAddress: context.email, name: "Wrong response")
    require(store.states[a]?.phase == .pendingConfirmation, "readback primary must match")
    fake.wrongPrimary = false
    await store.refreshPrimaryDisplayName(accountID: a, primaryAddress: context.email)
    require(store.states[a]?.phase == .confirmed, "explicit refresh confirms server value")

    // Controlled await gates exercise stale callbacks without WebKit or clocks.
    let gate = PrimarySyncTestGate(); fake.gate = gate
    let first = Task { await store.syncPrimaryDisplayName(accountID: a, primaryAddress: context.email, name: "Late") }
    await gate.waitStarted()
    let count = fake.updates.count
    await store.syncPrimaryDisplayName(accountID: a, primaryAddress: context.email, name: "Duplicate")
    require(fake.updates.count == count && store.busySet.contains(a), "same-account busy lock rejects duplicate")
    fake.gate = nil
    await store.syncPrimaryDisplayName(accountID: b, primaryAddress: context.email, name: "Independent")
    require(store.states[b]?.phase == .confirmed && store.busySet.contains(a), "different accounts progress independently")
    let queriesBeforeSwap = fake.queries.count
    state.sessions[a] = mailbox(a, email: "replacement@example.test")
    gate.release(); await first.value
    require(fake.queries.count == queriesBeforeSwap && store.states[a]?.phase != .confirmed, "primary swap fences late ACK and suppresses GET")
    require(store.states[a] == nil && !store.busySet.contains(a), "identity swap clears stale updating status when its original operation resolves")
    state.sessions[a] = mailbox(a)

    let removeGate = PrimarySyncTestGate(); fake.gate = removeGate
    let removed = Task { await store.syncPrimaryDisplayName(accountID: a, primaryAddress: context.email, name: "Removed") }
    await removeGate.waitStarted()
    store.invalidate(accountID: a)
    let beforeRemoveQueries = fake.queries.count
    let beforeRemoveUpdates = fake.updates.count
    await store.syncPrimaryDisplayName(accountID: a, primaryAddress: context.email, name: "Readded early")
    require(fake.updates.count == beforeRemoveUpdates && store.busySet.contains(a), "invalidation does not release unresolved remote write")
    state.sessions.removeValue(forKey: a)
    removeGate.release(); await removed.value
    require(store.states[a] == nil && fake.queries.count == beforeRemoveQueries && !store.busySet.contains(a), "removed account late callback never GETs or revives state")
    state.sessions[a] = mailbox(a)

    let stopGate = PrimarySyncTestGate(); fake.gate = stopGate
    let stopped = Task { await store.syncPrimaryDisplayName(accountID: a, primaryAddress: context.email, name: "Shutdown") }
    await stopGate.waitStarted(); store.stop()
    let beforeStop = fake.queries.count
    stopGate.release(); await stopped.value
    await store.syncPrimaryDisplayName(accountID: b, primaryAddress: context.email, name: "After shutdown")
    require(store.states.isEmpty && fake.queries.count == beforeStop && store.busySet.isEmpty, "shutdown fences callbacks and future operations")
    require(state.accountSessions.isEmpty, "primary sync tests never construct browser sessions")
    let fixtureDefault = PrimarySenderSyncStore(state: state)
    await fixtureDefault.refreshPrimaryDisplayName(accountID: a, primaryAddress: context.email)
    require(state.accountSessions.isEmpty && fixtureDefault.states[a]?.phase == .failed, "fixture default transport performs no network or WebKit construction")
    let retiringState = AppState(fixture: true)
    let retiringAccount = retiringState.accounts[0]
    retiringState.sessions[retiringAccount.id] = mailbox(retiringAccount.id)
    let retiringTransport = PrimarySyncTestTransport()
    let retiringStore = PrimarySenderSyncStore(state: retiringState, transport: retiringTransport)
    retiringState.removeAccount(retiringAccount)
    await retiringStore.syncPrimaryDisplayName(accountID: retiringAccount.id, primaryAddress: context.email, name: "Too late")
    require(retiringTransport.updates.isEmpty && retiringTransport.queries.isEmpty,
            "account removal's immediate application fence blocks a new sync before async cleanup finishes")
    await Task.yield()
    _ = retiringState.shutdown()
}
