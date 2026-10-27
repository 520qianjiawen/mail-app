import Foundation
import Combine

struct PrimaryAccountSenderInfo: Equatable {
    let accountID: String
    let primaryAddress: String
    let displayName: String
}

@MainActor protocol PrimarySenderSyncTransport {
    func queryPrimary(context: MailboxSession) async throws -> PrimaryAccountSenderInfo
    func updatePrimary(context: MailboxSession, name: String) async throws
}

enum PrimarySenderSyncPolicy {
    static func validate(context: MailboxSession, accountID: String, primaryAddress: String) throws {
        guard context.accountID == accountID, Trust.numericID(context.remoteID) == context.remoteID,
              Trust.mail(context.origin), context.origin.path.isEmpty || context.origin.path == "/",
              context.origin.query == nil, context.origin.fragment == nil,
              let primary = SenderIdentityPolicy.normalizedAddress(primaryAddress),
              SenderIdentityPolicy.normalizedAddress(context.email) == primary,
              context.addresses.contains(where: { SenderIdentityPolicy.normalizedAddress($0) == primary }) else { throw SenderIdentityError.identity }
    }
    static func url(context: MailboxSession) throws -> URL {
        try validate(context: context, accountID: context.accountID, primaryAddress: context.email)
        return context.origin.appendingPathComponent("api/accounts/\(context.remoteID)")
    }
    static let updateMethod = "PUT"
    static func updateBody(name: String) throws -> [String: String] {
        try SenderIdentityPolicy.validateName(name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SenderIdentityError.name }
        return ["mode": "updateDisplayName", "displayName": name]
    }
    /// The public account detail API returns data as an account dictionary or array.
    /// Only the account's top-level displayName is authoritative; aliases are ignored.
    static func parse(_ data: Any, context: MailboxSession) throws -> PrimaryAccountSenderInfo {
        let rows: [[String: Any]]
        if let row = data as? [String: Any] { rows = [row] }
        else if let array = data as? [[String: Any]], array.count <= 100 { rows = array }
        else { throw MailFailure.response }
        let matches = rows.filter { Trust.numericID($0["accountId"]) == context.remoteID }
        guard matches.count == 1, let row = matches.first,
              let primary = row["primaryEmailAddress"] as? String,
              SenderIdentityPolicy.normalizedAddress(primary) == SenderIdentityPolicy.normalizedAddress(context.email),
              let name = row["displayName"] as? String else { throw MailFailure.response }
        try validate(context: context, accountID: context.accountID, primaryAddress: primary)
        try SenderIdentityPolicy.validateName(name)
        return .init(accountID: context.remoteID, primaryAddress: primary, displayName: name)
    }
    static func matches(_ info: PrimaryAccountSenderInfo, context: MailboxSession) -> Bool {
        info.accountID == context.remoteID && SenderIdentityPolicy.normalizedAddress(info.primaryAddress) == SenderIdentityPolicy.normalizedAddress(context.email)
    }
}

struct PrimarySenderSyncState: Equatable {
    enum Phase: Equatable { case idle, refreshing, updating, confirmed, pendingConfirmation, failed }
    var phase: Phase = .idle
    var serverName: String? = nil
    var message: String = "尚未读取服务器名称"
}

/// No networking at initialization. Fixture states require an explicitly injected transport.
@MainActor final class PrimarySenderSyncStore: ObservableObject {
    @Published private(set) var states: [String: PrimarySenderSyncState] = [:]
    @Published private(set) var busySet: Set<String> = []
    private weak var state: AppState?
    private let injectedTransport: (any PrimarySenderSyncTransport)?
    private var tokens: [String: UUID] = [:]
    private var stopped = false
    init(state: AppState, transport: (any PrimarySenderSyncTransport)? = nil) {
        self.state = state; self.injectedTransport = transport
    }
    func invalidate(accountID: String) {
        tokens.removeValue(forKey: accountID)
        states.removeValue(forKey: accountID)
        // Do not release a remote write's serialization lock until its await resolves.
    }
    func stop() {
        stopped = true; tokens.removeAll(); states.removeAll()
    }
    private func context(accountID: String, primaryAddress: String) throws -> MailboxSession {
        guard !stopped, let state, state.accounts.contains(where: { $0.id == accountID }),
              state.acceptsContextAction(accountID: accountID, lifetime: state.contextActionLifetime()),
              let context = state.sessions[accountID] else { throw SenderIdentityError.account }
        try PrimarySenderSyncPolicy.validate(context: context, accountID: accountID, primaryAddress: primaryAddress)
        return context
    }
    private func current(_ original: MailboxSession, token: UUID) -> Bool {
        guard tokens[original.accountID] == token,
              let latest = try? context(accountID: original.accountID, primaryAddress: original.email) else { return false }
        return latest.remoteID == original.remoteID && latest.origin == original.origin &&
            SenderIdentityPolicy.normalizedAddress(latest.email) == SenderIdentityPolicy.normalizedAddress(original.email)
    }
    func syncPrimaryDisplayName(accountID: String, primaryAddress: String, name: String) async {
        await perform(accountID: accountID, primaryAddress: primaryAddress, requestedName: name)
    }
    func refreshPrimaryDisplayName(accountID: String, primaryAddress: String) async {
        await perform(accountID: accountID, primaryAddress: primaryAddress, requestedName: nil)
    }
    private func perform(accountID: String, primaryAddress: String, requestedName: String?) async {
        guard !stopped, !busySet.contains(accountID) else { return }
        let original: MailboxSession
        do {
            original = try context(accountID: accountID, primaryAddress: primaryAddress)
            if let requestedName { _ = try PrimarySenderSyncPolicy.updateBody(name: requestedName) }
        } catch {
            states[accountID] = .init(phase: .failed, message: error.localizedDescription); return
        }
        let token = UUID(); tokens[accountID] = token; busySet.insert(accountID)
        defer {
            busySet.remove(accountID)
            if tokens[accountID] == token {
                if !current(original, token: token) { states.removeValue(forKey: accountID) }
                tokens.removeValue(forKey: accountID)
            }
        }
        let oldName = states[accountID]?.serverName
        states[accountID] = .init(phase: requestedName == nil ? .refreshing : .updating, serverName: oldName, message: requestedName == nil ? "正在读取服务器名称…" : "正在同步到 Zoho…")
        var acknowledged = false
        var attemptedWrite = false
        do {
            guard let state else { throw SenderIdentityError.account }
            let transport: any PrimarySenderSyncTransport
            if let injectedTransport { transport = injectedTransport }
            else {
                guard !state.fixture else { throw MailFailure.auth }
                transport = LivePrimarySenderSyncTransport(state: state, fence: { [weak self] in self?.current(original, token: token) == true })
            }
            if let requestedName {
                guard current(original, token: token) else { return }
                attemptedWrite = true
                try await transport.updatePrimary(context: original, name: requestedName)
                guard current(original, token: token) else { return }
                acknowledged = true
            }
            let info = try await transport.queryPrimary(context: original)
            guard current(original, token: token) else { return }
            guard PrimarySenderSyncPolicy.matches(info, context: original) else { throw MailFailure.response }
            try SenderIdentityPolicy.validateName(info.displayName)
            if let requestedName, info.displayName != requestedName {
                states[accountID] = .init(phase: .pendingConfirmation, serverName: info.displayName, message: "服务器可能已更新，尚未确认，请刷新")
            } else {
                states[accountID] = .init(phase: .confirmed, serverName: info.displayName, message: requestedName == nil ? "已读取 Zoho 主邮箱账户名称" : "已确认 Zoho 主邮箱账户名称同步成功")
            }
        } catch {
            guard current(original, token: token) else { return }
            let definiteRejection = (error as? MailFailure).map { $0 == .auth || $0 == .rate || $0 == .rejected } ?? false
            let unknown = acknowledged || (attemptedWrite && !definiteRejection)
            states[accountID] = .init(phase: unknown ? .pendingConfirmation : .failed, serverName: oldName,
                message: unknown ? "服务器可能已更新，尚未确认，请刷新" : ((error as? MailFailure)?.label ?? error.localizedDescription))
        }
    }
}

@MainActor private final class LivePrimarySenderSyncTransport: PrimarySenderSyncTransport {
    private weak var state: AppState?
    private let fence: () -> Bool
    init(state: AppState, fence: @escaping () -> Bool) { self.state = state; self.fence = fence }
    private func request(context: MailboxSession, name: String?) async throws -> Any {
        guard fence(), let state, !state.fixture,
              let account = state.accounts.first(where: { $0.id == context.accountID }) else { throw SenderIdentityError.account }
        let url = try PrimarySenderSyncPolicy.url(context: context)
        let session = state.webSession(account)
        // Explicit user settings action only; never open/login/load a web page here.
        let csrf = try await state.api.csrf(session.store, origin: context.origin)
        guard fence() else { throw SenderIdentityError.account }
        let result = try await state.api.browserRequest(url, csrf: csrf, browser: session.webView,
            method: name == nil ? "GET" : PrimarySenderSyncPolicy.updateMethod,
            body: try name.map { try PrimarySenderSyncPolicy.updateBody(name: $0) })
        guard fence() else { throw SenderIdentityError.account }
        return result
    }
    func queryPrimary(context: MailboxSession) async throws -> PrimaryAccountSenderInfo {
        try PrimarySenderSyncPolicy.parse(try await request(context: context, name: nil), context: context)
    }
    func updatePrimary(context: MailboxSession, name: String) async throws {
        _ = try await request(context: context, name: name)
    }
}
