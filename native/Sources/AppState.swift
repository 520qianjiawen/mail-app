import AppKit
import SwiftUI
import WebKit

enum ScopeKind: String, Codable { case all, sent, unread, flagged, attachments, folder, label, search, outbox, offline }

struct Scope: Equatable {
    var kind: ScopeKind = .all
    var accountID: String? = nil
    var folderID: String? = nil
    var label: MailLabel? = nil
    var query: String = ""

    var isSmart: Bool { [.all, .sent, .unread, .flagged, .attachments, .outbox, .offline].contains(kind) }
    var isInboxLike: Bool { [.all, .unread, .flagged, .attachments].contains(kind) }
}

enum ListFilter: Int, CaseIterable, Identifiable {
    case all = 0, unread = 1, attachments = 2, flagged = 3
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .unread: return "未读"
        case .attachments: return "附件"
        case .flagged: return "标记"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .unread: return "circle.inset.filled"
        case .attachments: return "paperclip"
        case .flagged: return "flag"
        }
    }
}

/// Central application state. Views observe `@Published` fields; all mailbox
/// work happens on the main actor and every network call is bound to the
/// account's own WebKit session.
@MainActor final class AppState: ObservableObject {
    let fixture: Bool
    // Only consulted in isolated fixtures, never in normal account operation.
    var inlineImageDataHook: ((MailAttachment, MailMessage) async throws -> Data)?
    var sessionImageDataHook: ((String) async throws -> Data)?
    let preferences: PreferenceFile
    let cache: MailCache
    let draftStore: DraftStore
    let outboxStore: OutboxStore
    let api = MailAPI()
    let notifier = Notifier()

    @Published var accounts: [MailAccount]
    @Published var scope = Scope()
    @Published var filter: ListFilter = .all
    @Published var rows: [MailMessage] = []
    @Published var threadRows: [MailMessage] = []
    @Published var selectedKeys: Set<String> = []
    @Published var activeKey: String?
    @Published var detail: MailDetail?
    @Published var threadDetails: [String: MailDetail] = [:]
    @Published var detailLoading = false
    @Published var readingError: String?
    private var openingToken = UUID()
    private var readingRetry: (message: MailMessage, preferLatest: Bool)?
    // Destructive changes fence only the affected messages, not mark-read acks.
    private var readingRemovalRevisions: [String: UInt64] = [:]
    @Published var loading = false
    @Published var loadingMore = false
    @Published var accountErrors: [String: String] = [:]
    @Published var status = ""
    @Published var labelsByAccount: [String: [MailLabel]] = [:]
    @Published var labelsLoading = false
    @Published var outbox: [OutboxItem] = []
    @Published var uploadProgress: [String: MailUploadProgress] = [:]
    @Published var searchText = ""
    @Published var unreadTotal = 0
    @Published var visibleLimit = 100
    @Published var foldersVersion = 0
    @Published var draftsVersion = 0
    @Published var composeCount = 0
    @Published var showingSettings = false
    @Published var showingDrafts = false
    @Published var loginAccountID: String?
    @Published var readyAccounts = 0
    @Published var totalAccounts = 0
    @Published var listWidth: Double
    @Published var sidebarWidth: Double
    @Published var expandedAccounts: Set<String> = []
    @Published var searchFocusToken = 0
    @Published var selectedLabelFilter: MailLabel?

    var sessions: [String: MailboxSession] = [:]
    var foldersByAccount: [String: [MailFolder]] = [:]
    var messageStore: [String: MailMessage] = [:]
    var moreByFolder: [String: Bool] = [:]
    var searchResults: [MailMessage] = []
    var accountSessions: [String: AccountSession] = [:]
    var refreshTask: Task<Void, Never>?
    var detailTask: Task<Void, Never>?
    var generation = 0
    var refreshTimer: Timer?
    var outboxTimer: Timer?
    var cloudDraftSaveHook: ((MailDraft, [String: Any]) async throws -> String)?
    var cloudDraftRemoveHook: ((String) async throws -> Void)?
    var outboxSendHook: ((OutboxItem) async throws -> Void)?
    var knownUnread: Set<String> = []
    var composeControllers: [ComposeController] = []
    @Published var inlineReplyModel: ComposeModel? = nil
    var contextComposePending: Set<String> = []
    @Published var composeSourcePending: Set<String> = []
    @Published var composePreparationFailure: String?
    var composePreparationRetry: (() -> Void)?
    var offlineSavePending: Set<String> = []
    var contextSearchToken = UUID()
    var contextSearchTask: Task<Void, Never>?
    var contextComposeHook: ((MailDetail, ComposeMode) -> Void)?
    @Published var mailRemindersVersion = 0
    lazy var mailReminderStore = MailReminderStore(state: self)
    lazy var primarySenderSync = PrimarySenderSyncStore(state: self)
    var settingsController: SettingsWindowController?
    var draftsController: DraftsWindowController?
    @Published var signaturesVersion = 0
    var signatureFetchHook: ((MailAccount, String) async throws -> [MailSignature])?
    var remoteSignatureCache: [String: [MailSignature]] = [:]
    var signatureAccountEpoch: [String: UInt64] = [:]
    var signatureFetchLifetime: UInt64 = 0
    var signatureFetchingAllowed: Bool { !stopped }
    var started = false
    let syncHooks: MailSyncHooks?
    let mutationQueue = MailMutationQueue()
    @Published private(set) var unreadCountsStale = true
    private(set) var counterSyncedAt: [String: Date] = [:]
    private var counterRefreshPending: Set<String> = []
    private var syncLifetime: UInt64 = 0
    private var stopped = false
    private var invalidatedAccounts: Set<String> = []
    private var mutationRevisions: [String: UInt64] = [:]
    private var catalogSerial: UInt64 = 0
    private var adoptedCatalogSerial: [String: UInt64] = [:]
    private var syncObservers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private(set) var viewWindows: [MailViewQuery: MailViewWindow] = [:]
    private var messageObservationSerial: [String: UInt64] = [:]
    lazy var viewSyncScheduler = MailSyncScheduler { [weak self] in
        guard let self else { return }
        await self.refreshTask?.value
        guard self.started, !self.stopped else { return }
        self.beginViewLoad(silent: true, more: false)
        await self.refreshTask?.value
    }
    lazy var syncScheduler = MailSyncScheduler { [weak self] in
        await self?.reconcileAllAccounts()
    }

    init(fixture: Bool = false, syncHooks: MailSyncHooks? = nil) {
        self.fixture = fixture
        self.syncHooks = syncHooks
        let prefs: PreferenceFile
        if fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-lite-fixture-\(UUID().uuidString)")
            prefs = PreferenceFile(directory: directory)
            prefs.value.accounts = [
                .init(id: "fixture-work", name: "design@northwind.studio", region: "global"),
                .init(id: "fixture-personal", name: "mira@aurora.mail", region: "global")
            ]
        } else {
            prefs = PreferenceFile()
        }
        let previousSignatures = prefs.value.accountSignatures
        SignaturePolicy.migrate(&prefs.value)
        if previousSignatures != prefs.value.accountSignatures { prefs.save() }
        preferences = prefs
        let loaded = prefs.value.accounts
        accounts = loaded
        totalAccounts = loaded.count
        listWidth = prefs.value.listWidth
        sidebarWidth = prefs.value.sidebarWidth
        let mailboxCache = MailCache(directory: prefs.directory)
        let localDrafts = DraftStore(directory: prefs.directory)
        let queue = OutboxStore(directory: prefs.directory.appendingPathComponent("outbox"))
        mailboxCache.restorePins(prefs.value.offlineSaved)
        cache = mailboxCache
        draftStore = localDrafts
        outboxStore = queue
        outbox = queue.all().filter { !["sent", "cancelled"].contains($0.state) }
        let identifiers = Set(loaded.map { $0.id })
        for item in mailboxCache.contexts(accounts: identifiers) {
            sessions[item.accountID] = item
            foldersByAccount[item.accountID] = item.folders
        }
        if !fixture {
            for message in mailboxCache.messages(accounts: identifiers) { messageStore[message.key] = message }
        }
        expandedAccounts = Set(loaded.map { $0.id })
        restoreScope()
        rebuildRows()
    }

    func saveLayout() {
        preferences.value.listWidth = min(Metrics.listMax, max(Metrics.listMin, listWidth))
        preferences.value.sidebarWidth = min(320, max(208, sidebarWidth))
        preferences.save()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        stopped = false
        mailReminderStore.restore()
        if fixture, syncHooks == nil { seedFixture(); refresh(); return }
        knownUnread = Set(messageStore.values.filter { $0.unread }.map { $0.key })
        handleSyncEvent(.startup, isActive: true)
        // Hook-driven fixtures exercise the real scheduler without timers,
        // notification permissions, account sessions or login documents.
        if fixture { rebuildRows(); return }
        refresh()
        syncObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSyncEvent(.activation) }
        })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSyncEvent(.wake) }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleSyncEvent(.periodic) }
        }
        outboxTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processOutbox() }
        }
        processOutbox()
        Task { @MainActor in
            if preferences.value.notificationsEnabled {
                _ = await notifier.requestAuthorization()
            }
        }
    }

    func shutdown() -> Bool {
        if composeControllers.contains(where: { $0.busy }) || (inlineReplyModel?.busy == true) {
            let alert = NSAlert()
            alert.messageText = "有邮件正在发送或同步，请完成后再退出。"
            alert.runModal()
            return false
        }
        if let model = inlineReplyModel {
            _ = model.persistDraft()
            inlineReplyModel = nil
        }
        for composer in composeControllers { composer.persistDraft() }
        contextSearchToken = UUID()
        contextSearchTask?.cancel(); contextSearchTask = nil
        primarySenderSync.stop()
        mailReminderStore.stop()
        for session in accountSessions.values { session.finishLogin(false) }
        started = false
        stopped = true
        signatureFetchLifetime &+= 1
        syncLifetime &+= 1
        generation += 1
        refreshTask?.cancel()
        detailTask?.cancel()
        syncScheduler.stop()
        viewSyncScheduler.stop()
        mutationQueue.stop()
        refreshTimer?.invalidate(); refreshTimer = nil
        outboxTimer?.invalidate(); outboxTimer = nil
        for observer in syncObservers { NotificationCenter.default.removeObserver(observer) }
        syncObservers.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        return true
    }

    // MARK: - Independent mailbox reconciliation

    func handleSyncEvent(_ event: MailSyncEvent, isActive: Bool? = nil) {
        guard started, !stopped, !fixture || syncHooks != nil,
              event.shouldReconcile(isActive: isActive ?? NSApp.isActive,
                                    notificationsEnabled: preferences.value.notificationsEnabled) else { return }
        syncScheduler.request()
        switch event {
        case .periodic, .activation, .wake:
            if !fixture || syncHooks?.fetchView != nil { viewSyncScheduler.request() }
        default: break
        }
    }

    func contextActionLifetime() -> UInt64 { syncLifetime }

    func acceptsContextAction(accountID: String, lifetime: UInt64) -> Bool {
        acceptsLifetimeReply(accountID: accountID, lifetime: lifetime)
    }

    private func acceptsLifetimeReply(accountID: String, lifetime: UInt64) -> Bool {
        !stopped && lifetime == syncLifetime && !invalidatedAccounts.contains(accountID) &&
        accounts.contains(where: { $0.id == accountID })
    }

    private func acceptsReply(accountID: String, lifetime: UInt64, revision: UInt64) -> Bool {
        acceptsLifetimeReply(accountID: accountID, lifetime: lifetime) && mutationRevisions[accountID, default: 0] == revision
    }

    private func nextCatalogSerial() -> UInt64 {
        catalogSerial &+= 1
        return catalogSerial
    }

    private func reconcileAllAccounts() async {
        let lifetime = syncLifetime
        for account in accounts {
            guard started, !stopped, lifetime == syncLifetime, !Task.isCancelled else { return }
            guard !invalidatedAccounts.contains(account.id) else { continue }
            let revision = mutationRevisions[account.id, default: 0]
            let serial = nextCatalogSerial()
            do {
                let snapshot: MailSyncSnapshot
                if let syncHooks {
                    snapshot = try await syncHooks.fetchInbox(account)
                } else {
                    let webSession = session(account)
                    try await webSession.ready()
                    let context = try await api.discover(account: account, store: webSession.store,
                                                         origin: webSession.origin, browser: webSession.webView)
                    guard let inbox = context.inbox else { throw MailFailure.folder }
                    let head = try await api.messages(context: context, folder: inbox, store: webSession.store,
                                                       browser: webSession.webView)
                    snapshot = MailSyncSnapshot(context: context, head: head)
                }
                guard acceptsReply(accountID: account.id, lifetime: lifetime, revision: revision), !Task.isCancelled else { continue }
                let context = snapshot.context, head = snapshot.head
                guard context.accountID == account.id, Trust.mail(context.origin), Trust.numericID(context.remoteID) != nil,
                      let inbox = context.inbox, head.folderID == inbox.id, head.remoteID == context.remoteID,
                      head.messages.allSatisfy({ $0.accountID == account.id && $0.remoteID == context.remoteID &&
                          $0.origin == context.origin && $0.folderID == inbox.id && Trust.numericID($0.id) != nil }) else { throw MailFailure.response }
                adopt(context, account: account, observationSerial: serial)
                // The Inbox head is a partial observation, never deletion
                // authority for older pages or offline-saved metadata.
                let query = MailViewQuery(accountID: account.id, kind: "folder", identifier: inbox.id, filter: ListFilter.all.rawValue)
                mergeObservation(head, account: account, query: query, replacing: true, serial: serial, headOnly: true)
                accountErrors[account.id] = nil
                let newUnread = head.messages.filter { $0.unread && !knownUnread.contains($0.key) }
                knownUnread.formUnion(head.messages.filter { $0.unread }.map { $0.key })
                if preferences.value.notificationsEnabled, !fixture, !NSApp.isActive, !newUnread.isEmpty {
                    notifier.notifyNewMessages(newUnread, accounts: accounts, sound: preferences.value.playSound)
                }
            } catch {
                guard acceptsReply(accountID: account.id, lifetime: lifetime, revision: revision), !Task.isCancelled else { continue }
                // Preserve last-known catalogs and metadata on failure.
                accountErrors[account.id] = (error as? MailFailure)?.label ?? MailFailure.network.label
            }
            rebuildRows()
        }
        guard started, !stopped, lifetime == syncLifetime else { return }
        updateStatus()
        rebuildRows()
    }

    /// Called only after the server acknowledges a mutation. Do not blindly
    /// adjust a cached server count: an overlapping snapshot may include it.
    private func acknowledgedMutation(accountID: String) {
        mutationRevisions[accountID, default: 0] &+= 1
        counterRefreshPending.insert(accountID)
        unreadCountsStale = true
        handleSyncEvent(.mutation, isActive: true)
    }

    // MARK: - Scope

    func restoreScope() {
        let kind = ScopeKind(rawValue: preferences.value.lastScopeKind) ?? .all
        if kind == .folder, let account = preferences.value.lastAccountID,
           let folder = preferences.value.lastFolderID,
           foldersByAccount[account]?.contains(where: { $0.id == folder }) == true {
            scope = Scope(kind: .folder, accountID: account, folderID: folder)
        } else {
            scope = Scope(kind: .all)
        }
    }

    func persistScope() {
        preferences.value.lastScopeKind = scope.kind.rawValue
        preferences.value.lastAccountID = scope.accountID
        preferences.value.lastFolderID = scope.folderID
        preferences.save()
    }

    func select(_ newScope: Scope, filter newFilter: ListFilter? = nil) {
        scope = newScope
        filter = MailSyncPolicy.effectiveFilter(scopeKind: newScope.kind, selected: newFilter ?? filter)
        searchText = newScope.kind == .search ? newScope.query : ""
        if newScope.kind != .search { searchResults = [] }
        selectedKeys = []
        persistScope()
        refresh()
    }

    func showAllInbox() { select(Scope(kind: .all), filter: .all) }

    func showAllSent() { select(Scope(kind: .sent), filter: .all) }

    func showOutbox() { select(Scope(kind: .outbox)) }

    func setFilter(_ value: ListFilter) {
        let nextKind = MailSyncPolicy.scopeKindAfterSelectingFilter(value, in: scope.kind)
        if nextKind != scope.kind {
            // A different toolbar choice exits the intrinsic smart scope, so
            // every selectable toolbar filter has a visible, consistent effect.
            select(Scope(kind: nextKind, accountID: scope.accountID), filter: value)
            return
        }
        guard filter != value else { return }
        filter = value
        if scope.kind == .offline || scope.kind == .outbox { rebuildRows() }
        else { beginViewLoad(silent: false, more: false) }
    }

    // MARK: - Loading

    func refresh(silent: Bool = false, more: Bool = false) {
        guard !stopped else { return }
        if !more { handleSyncEvent(.manual, isActive: true) }
        beginViewLoad(silent: silent, more: more)
    }

    private func beginViewLoad(silent: Bool, more: Bool) {
        guard !stopped else { return }
        if fixture, syncHooks?.fetchView == nil { rebuildRows(); return }
        refreshTask?.cancel()
        generation += 1
        let requestGeneration = generation, requestScope = scope, requestFilter = effectiveFilter
        // Refresh retains the loaded range; new query windows still begin at page one.
        if !silent { loading = true; status = "正在同步…" }
        refreshTask = Task { @MainActor [weak self] in
            await self?.load(generation: requestGeneration, more: more, scope: requestScope, filter: requestFilter)
        }
    }

    private func load(generation: Int, more: Bool, scope requestScope: Scope, filter requestFilter: ListFilter) async {
        defer { if generation == self.generation { loading = false; loadingMore = false } }
        guard requestScope.kind != .offline, requestScope.kind != .outbox else { rebuildRows(); return }
        let targets = accounts.filter { requestScope.accountID == nil || $0.id == requestScope.accountID }
        for account in targets {
            guard !Task.isCancelled, generation == self.generation, scope == requestScope else { return }
            let fence = captureViewReplyFence(accountID: account.id)
            do {
                let context: MailboxSession
                if fixture, syncHooks?.fetchView != nil {
                    guard let saved = sessions[account.id] else { continue }
                    context = saved
                } else { context = try await mailbox(account) }
                guard let query = MailViewQuery.make(accountID: account.id, scope: requestScope, filter: requestFilter, inboxID: context.inbox?.id, sentID: context.sent?.id) else { continue }
                let start = more ? (viewWindows[query]?.next ?? 1) : 1
                let loadedNext = more ? start : (viewWindows[query]?.next ?? 1)
                func fetchPage(_ start: Int) async throws -> InboxPage {
                let page: InboxPage
                if let fetch = syncHooks?.fetchView {
                    page = try await fetch(account, requestScope, requestFilter, start)
                } else {
                    let web = session(account)
                    switch requestScope.kind {
                    case .all, .unread, .flagged, .attachments:
                        guard let inbox = context.inbox else { throw MailFailure.folder }
                        page = try await api.messages(context: context, folder: inbox, store: web.store, browser: web.webView, start: start, filter: requestFilter.rawValue)
                    case .sent:
                        guard let sent = context.sent else { throw MailFailure.folder }
                        page = try await api.messages(context: context, folder: sent, store: web.store, browser: web.webView, start: start, filter: requestFilter.rawValue)
                    case .folder:
                        guard let folder = context.folders.first(where: { $0.id == requestScope.folderID }) else { throw MailFailure.folder }
                        page = try await api.messages(context: context, folder: folder, store: web.store, browser: web.webView, start: start, filter: requestFilter.rawValue)
                    case .label:
                        guard let inbox = context.inbox, let label = requestScope.label else { throw MailFailure.folder }
                        page = try await api.messages(context: context, folder: inbox, labelID: label.id, store: web.store, browser: web.webView, start: start, filter: requestFilter.rawValue)
                    case .search:
                        page = try await api.search(context: context, query: requestScope.query, store: web.store, browser: web.webView, start: start)
                    case .offline, .outbox: throw MailFailure.folder
                    }
                }
                return page
                }
                var page = try await fetchPage(start)
                var combined = page.messages
                var cursor = start
                // Re-fetch the complete previously loaded window, then replace
                // membership once. Failure never truncates a successful old view.
                while !more, page.more, page.next < loadedNext {
                    guard page.next > cursor, !Task.isCancelled, generation == self.generation else { throw MailFailure.response }
                    cursor = page.next
                    page = try await fetchPage(cursor)
                    combined += page.messages
                }
                if !more { page = InboxPage(messages: combined, remoteID: page.remoteID, folderID: page.folderID, next: page.next, more: page.more) }
                guard !Task.isCancelled, generation == self.generation, scope == requestScope,
                      acceptsReply(accountID: account.id, lifetime: fence.lifetime, revision: fence.mutationRevision) else { continue }
                guard mergeObservation(page, account: account, query: query, replacing: !more, serial: fence.observationSerial) else { continue }
                accountErrors[account.id] = nil
                if !fixture, labelsByAccount[account.id] == nil { await loadLabels(account) }
            } catch {
                guard !Task.isCancelled, generation == self.generation,
                      acceptsReply(accountID: account.id, lifetime: fence.lifetime, revision: fence.mutationRevision) else { continue }
                accountErrors[account.id] = (error as? MailFailure)?.label ?? MailFailure.network.label
            }
            rebuildRows()
        }
        guard generation == self.generation else { return }
        updateStatus(); rebuildRows()
    }

    private var effectiveFilter: ListFilter {
        MailSyncPolicy.effectiveFilter(scopeKind: scope.kind, selected: filter)
    }

    private var apiFilter: Int { MailSyncPolicy.apiFilter(effectiveFilter) }

    func webSession(_ account: MailAccount) -> AccountSession { session(account) }

    private func session(_ account: MailAccount) -> AccountSession {
        if let existing = accountSessions[account.id] { return existing }
        let created = AccountSession(account: account, fixture: fixture)
        created.state = self
        accountSessions[account.id] = created
        return created
    }

    func mailbox(_ account: MailAccount) async throws -> MailboxSession {
        if fixture, syncHooks != nil {
            guard !stopped, !invalidatedAccounts.contains(account.id), let saved = sessions[account.id] else { throw MailFailure.folder }
            return saved
        }
        let lifetime = syncLifetime, revision = mutationRevisions[account.id, default: 0]
        let webSession = session(account)
        // A cached catalog is enough for display, but every REST call still
        // needs the account's WebKit document on its mail origin. Loading it
        // here also turns an expired cookie into an immediate auth error
        // instead of a misleading "response" failure on first use.
        if let saved = sessions[account.id] {
            try await webSession.ready()
            guard acceptsReply(accountID: account.id, lifetime: lifetime, revision: revision) else { throw CancellationError() }
            return saved
        }
        if fixture, let fake = fixtureSession(account) { return fake }
        try await webSession.ready()
        let serial = nextCatalogSerial()
        let context = try await api.discover(account: account, store: webSession.store,
                                             origin: webSession.origin, browser: webSession.webView)
        guard acceptsReply(accountID: account.id, lifetime: lifetime, revision: revision) else { throw CancellationError() }
        adopt(context, account: account, observationSerial: serial)
        return sessions[account.id] ?? context
    }

    func adopt(_ context: MailboxSession, account: MailAccount, observationSerial: UInt64? = nil) {
        guard !stopped, context.accountID == account.id, !invalidatedAccounts.contains(account.id),
              accounts.contains(where: { $0.id == account.id }) else { return }
        let serial = observationSerial ?? nextCatalogSerial()
        guard serial >= adoptedCatalogSerial[account.id, default: 0] else { return }
        adoptedCatalogSerial[account.id] = serial
        // A partial catalog must not turn a last-known server total into a
        // synthesized zero or make an inherited counter observation fresh.
        let previous = Dictionary(uniqueKeysWithValues: (sessions[account.id]?.folders ?? []).map { ($0.id, $0) })
        var merged = context
        merged.folders = context.folders.map { folder in
            var value = folder
            if value.unread == nil { value.unread = previous[folder.id]?.unread }
            if value.total == nil { value.total = previous[folder.id]?.total }
            return value
        }
        if context.inbox?.unread != nil {
            counterSyncedAt[account.id] = Date()
            counterRefreshPending.remove(account.id)
        }
        accountErrors[context.accountID] = nil
        sessions[context.accountID] = merged
        foldersByAccount[context.accountID] = merged.folders
        cache.store(merged)
        foldersVersion += 1
        if let index = accounts.firstIndex(where: { $0.id == account.id }), accounts[index].name != context.email,
           preferences.value.accounts.contains(where: { $0.id == account.id && $0.name.hasPrefix("账号") }) {
            accounts[index].name = context.email
            preferences.value.accounts[index].name = context.email
            preferences.save()
        }
    }

    func captureViewReplyFence(accountID: String) -> MailSyncReplyFence {
        MailSyncReplyFence(accountID: accountID, lifetime: syncLifetime,
                           mutationRevision: mutationRevisions[accountID, default: 0], observationSerial: nextCatalogSerial())
    }

    /// View loading and fixture regressions share this exact acceptance fence.
    @discardableResult
    func mergeViewPage(_ page: InboxPage, account: MailAccount, replacing: Bool, fence: MailSyncReplyFence) -> Bool {
        guard fence.accountID == account.id, !Task.isCancelled,
              acceptsReply(accountID: account.id, lifetime: fence.lifetime, revision: fence.mutationRevision) else { return false }
        guard let query = MailViewQuery.make(accountID: account.id, scope: scope, filter: effectiveFilter,
                                            inboxID: sessions[account.id]?.inbox?.id,
                                            sentID: sessions[account.id]?.sent?.id) else { return false }
        return mergeObservation(page, account: account, query: query, replacing: replacing, serial: fence.observationSerial)
    }

    /// A query page replaces membership, never canonical/offline mail. Request
    /// ordering is shared across background and view requests, even different queries.
    @discardableResult
    private func mergeObservation(_ page: InboxPage, account: MailAccount, query: MailViewQuery, replacing: Bool, serial: UInt64, headOnly: Bool = false) -> Bool {
        guard query.accountID == account.id, serial >= viewWindows[query]?.serial ?? 0,
              let context = sessions[account.id], context.accountID == account.id,
              Trust.mail(context.origin), page.remoteID == context.remoteID, page.next >= 1,
              Trust.numericID(page.folderID) != nil,
              query.kind != "folder" || page.folderID == query.identifier,
              page.messages.allSatisfy({ message in
                  message.accountID == account.id && message.remoteID == context.remoteID && message.origin == context.origin &&
                  Trust.numericID(message.id) != nil && Trust.numericID(message.folderID) != nil &&
                  (query.kind != "folder" || message.folderID == query.identifier)
              }) else { return false }
        let accepted = page.messages.filter { message in
            serial >= messageObservationSerial[message.key, default: 0]
        }
        for message in accepted {
            messageStore[message.key] = message
            messageObservationSerial[message.key] = serial
        }
        cache.store(accepted, account: account.id, replace: false)
        if headOnly, let old = viewWindows[query], old.next > page.next {
            // Head polling is not authority to discard an older loaded page.
            // The selected-view refresh separately validates the whole range.
            if MailViewQuery.make(accountID: account.id, scope: scope, filter: effectiveFilter, inboxID: context.inbox?.id, sentID: context.sent?.id) == query {
                viewSyncScheduler.request()
            }
            return true
        }
        var seen = Set<String>()
        let keys = (replacing ? [] : (viewWindows[query]?.keys ?? [])) + page.messages.map(\.key)
        viewWindows[query] = MailViewWindow(keys: keys.filter { seen.insert($0).inserted }, next: page.next, more: page.more, serial: serial)
        let legacyKey = "\(account.id):\(query.kind == "label" ? "label:" + query.identifier : query.identifier)"
        moreByFolder[legacyKey] = page.more
        return true
    }

    var canLoadMoreResults: Bool {
        guard scope.kind != .offline, scope.kind != .outbox else { return false }
        var missingWindow = false
        for account in accounts where scope.accountID == nil || scope.accountID == account.id {
            guard let query = MailViewQuery.make(accountID: account.id, scope: scope, filter: effectiveFilter,
                                                inboxID: sessions[account.id]?.inbox?.id,
                                                sentID: sessions[account.id]?.sent?.id),
                  let window = viewWindows[query] else { missingWindow = true; continue }
            if window.more { return true }
        }
        return missingWindow && rows.count >= visibleLimit
    }

    func loadMore() {
        guard !loading, !loadingMore else { return }
        loadingMore = true
        visibleLimit += 100
        if scope.kind == .offline || scope.kind == .outbox { rebuildRows(); loadingMore = false; return }
        refresh(silent: true, more: true)
    }

    private func hasQueryWindow(accountID: String) -> Bool {
        guard let key = MailViewQuery.make(accountID: accountID, scope: scope, filter: effectiveFilter,
                                          inboxID: sessions[accountID]?.inbox?.id,
                                          sentID: sessions[accountID]?.sent?.id) else { return false }
        return viewWindows[key] != nil
    }

    private func queryMessages(scope: Scope, filter: ListFilter) -> [MailMessage] {
        accounts.filter { scope.accountID == nil || $0.id == scope.accountID }.flatMap { account in
            if let query = MailViewQuery.make(accountID: account.id, scope: scope, filter: filter,
                                             inboxID: sessions[account.id]?.inbox?.id,
                                             sentID: sessions[account.id]?.sent?.id),
               let window = viewWindows[query] {
                return window.keys.compactMap { messageStore[$0] }
            }
            if scope.kind == .search { return [] }
            return messageStore.values.filter { $0.accountID == account.id }
        }
    }

    func rebuildRows() {
        var pool: [MailMessage]
        switch scope.kind {
        case .search: pool = queryMessages(scope: scope, filter: effectiveFilter).filter { MailContextSearch.matches($0, query: scope.query) }
        case .offline: pool = preferences.value.offlineSaved.compactMap { messageStore[$0] }
        case .outbox: pool = []
        default: pool = queryMessages(scope: scope, filter: effectiveFilter)
        }
        let inboxIDs = sessions.mapValues { $0.inbox?.id }
        let sentIDs = sessions.mapValues { $0.sent?.id }
        pool = pool.filter { message in
            switch scope.kind {
            case .all, .unread, .flagged, .attachments:
                guard accounts.contains(where: { $0.id == message.accountID }) else { return false }
                if let wanted = scope.accountID, message.accountID != wanted { return false }
                return message.folderID == (inboxIDs[message.accountID] ?? message.folderID) || inboxIDs[message.accountID] == nil
            case .sent:
                guard accounts.contains(where: { $0.id == message.accountID }) else { return false }
                if let wanted = scope.accountID, message.accountID != wanted { return false }
                return message.folderID == (sentIDs[message.accountID] ?? message.folderID) || sentIDs[message.accountID] == nil
            case .folder:
                return message.accountID == scope.accountID && message.folderID == scope.folderID
            case .label:
                return message.accountID == scope.accountID &&
                    (hasQueryWindow(accountID: message.accountID) || (message.labels ?? []).contains(scope.label?.id ?? ""))
            default:
                return true
            }
        }
        let listFilter = effectiveFilter
        pool = pool.filter { MailSyncPolicy.matches($0, filter: listFilter) }
        var rows = MailMessage.conversations(pool)
        rows.sort { a, b in
            if (a.pinned == true) != (b.pinned == true) { return a.pinned == true }
            return a.date > b.date
        }
        if scope.kind == .offline { rows.sort { $0.date > $1.date } }
        self.rows = Array(rows.prefix(visibleLimit))
        unreadTotal = accounts.filter { !invalidatedAccounts.contains($0.id) }.reduce(0) { total, account in
            guard let inbox = sessions[account.id]?.inbox else { return total }
            return total + folderUnread(account.id, inbox)
        }
        let now = Date()
        unreadCountsStale = accounts.contains { account in
            guard !invalidatedAccounts.contains(account.id), sessions[account.id]?.inbox?.unread != nil,
                  let observed = counterSyncedAt[account.id] else { return true }
            return counterRefreshPending.contains(account.id) || accountErrors[account.id] != nil || now.timeIntervalSince(observed) > 120
        }
        rebuildThread()
        updateBadge()
    }

    private func rebuildThread() {
        guard let key = activeKey, let active = messageStore[key] ?? rows.first(where: { $0.key == key }) ?? threadRows.first(where: { $0.key == key }) else {
            threadRows = []; return
        }
        if let threadID = active.threadID {
            let members = messageStore.values.filter { Self.sameReadingMailbox($0, active) && $0.threadID == threadID }
            if members.count > 1 {
                threadRows = Self.orderedReadingMembers(members)
                return
            }
        }
        if !threadRows.contains(where: { $0.key == active.key }) {
            threadRows = [active]
        }
    }

    func email(for accountID: String) -> String {
        sessions[accountID]?.email ?? accounts.first(where: { $0.id == accountID })?.name ?? ""
    }

    /// In a merged list the mailbox is the missing piece of identity. In a
    /// single-account folder it is already implied, so the badge is hidden.
    var showsAccountBadge: Bool {
        guard accounts.count > 1 else { return false }
        switch scope.kind {
        case .folder, .label, .outbox: return false
        default: return true
        }
    }

    func isDraft(_ message: MailMessage) -> Bool {
        folders(message.accountID).first { $0.id == message.folderID }?.systemName == "Drafts"
    }

    func unreadCount(accountID: String, folderID: String) -> Int {
        messageStore.values.filter { $0.accountID == accountID && $0.folderID == folderID && $0.unread }.count
    }

    func folderUnread(_ accountID: String, _ folder: MailFolder) -> Int {
        // A known server snapshot wins over a partial or stale local cache.
        // With no server counter, this remains a cached estimate, not a total.
        let current = foldersByAccount[accountID]?.first(where: { $0.id == folder.id }) ?? folder
        if counterSyncedAt[accountID] != nil, let remote = current.unread {
            return remote
        }
        return unreadCount(accountID: accountID, folderID: folder.id)
    }

    func customFolders(_ accountID: String) -> [MailFolder] {
        folders(accountID).filter { $0.systemName == nil }
    }

    func systemFolder(_ accountID: String, _ name: String) -> MailFolder? {
        folders(accountID).first { $0.systemName == name }
    }

    func recipientSuggestions(_ prefix: String) -> [String] {
        let value = prefix.lowercased()
        var seen = Set<String>()
        var result: [String] = []
        for account in accounts {
            for address in sessions[account.id]?.addresses ?? [] where seen.insert(address.lowercased()).inserted { result.append(address) }
        }
        for message in messageStore.values {
            if let address = MailAddresses.extract(message.sender).first, seen.insert(address.lowercased()).inserted { result.append(address) }
        }
        if value.isEmpty { return Array(result.prefix(8)) }
        return result.filter { $0.lowercased().contains(value) }.prefix(8).map { $0 }
    }

    func updateStatus() {
        let valid = Set(accounts.map { $0.id })
        if accountErrors.keys.contains(where: { !valid.contains($0) }) {
            accountErrors = accountErrors.filter { valid.contains($0.key) }
        }
        let ready = accounts.filter { sessions[$0.id] != nil && accountErrors[$0.id] == nil }.count
        readyAccounts = ready
        totalAccounts = accounts.count
        if accounts.isEmpty { status = "添加账号后开始同步" }
        else if loading { status = "正在同步 \(accounts.count) 个账号…" }
        else if ready == 0 { status = "账号需要重新登录" }
        else { status = "\(ready)/\(accounts.count) 个账号已连接 · \(rows.count) 个会话" + (ready < accounts.count ? " · 部分账号待验证" : "") }
        updateBadge()
    }

    func updateBadge() {
        notifier.setBadge(unreadTotal, enabled: preferences.value.badgeEnabled)
    }

    // MARK: - Reading

    /// List/navigation opens prefer the newest member. Cards, reminders and
    /// explicit message actions keep their exact target by default.
    func open(_ row: MailMessage, preferLatest: Bool = false) {
        guard acceptsLifetimeReply(accountID: row.accountID, lifetime: syncLifetime) else { return }
        if let model = inlineReplyModel, model.draft.source?.message.key != row.key {
            _ = model.persistDraft()
            inlineReplyModel = nil
        }
        // Conversation unread is aggregate presentation state, never server state.
        let message = messageStore[row.key] ?? row
        if messageStore[message.key] == nil { messageStore[message.key] = message }
        detailTask?.cancel()
        let token = UUID(), lifetime = syncLifetime
        openingToken = token
        let removals = readingRemovalRevisions
        readingError = nil
        readingRetry = (message, preferLatest)
        activeKey = message.key
        selectedKeys = [message.key]
        detail = cache.detail(message).flatMap { Self.sameReadingIdentity($0.message, message) ? $0 : nil }
        detailLoading = detail == nil
        rebuildThread()
        if preferences.value.markReadOnOpen, message.unread {
            perform(.read, on: [message], quiet: true)
        }
        detailTask = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func valid(_ expected: MailMessage) -> Bool {
                !Task.isCancelled && self.openingToken == token &&
                self.acceptsLifetimeReply(accountID: message.accountID, lifetime: lifetime) &&
                self.readingRemovalRevisions[message.key, default: 0] == removals[message.key, default: 0] &&
                self.readingRemovalRevisions[expected.key, default: 0] == removals[expected.key, default: 0] &&
                self.messageStore[message.key].map { Self.sameReadingIdentity($0, message) } == true &&
                self.messageStore[expected.key].map { Self.sameReadingIdentity($0, expected) } == true &&
                self.activeKey == expected.key
            }
            defer {
                if self.openingToken == token, !Task.isCancelled { self.detailLoading = false }
            }
            do {
                // Even if the representative body fails, discovering the newest
                // member can still succeed and show its complete headers/body.
                do {
                    let loaded = try await self.fetchReadingDetail(message)
                    guard valid(message) else { return }
                    guard Self.sameReadingIdentity(loaded.message, message) else { throw MailFailure.response }
                    self.cache.store(loaded)
                    self.threadDetails[message.key] = loaded
                    self.detail = loaded
                } catch {
                    guard valid(message) else { return }
                    self.readingError = "正文读取失败，请重试"
                }
                guard valid(message), message.threadID != nil,
                      !self.fixture || self.syncHooks?.fetchThread != nil else { return }
                let fetched = try await self.fetchReadingThread(message)
                guard valid(message) else { return }
                // The request is scoped to one thread. Missing echoed threadId
                // is accepted only here; conflicting IDs/accounts/origins fail.
                guard fetched.allSatisfy({ member in
                    Self.sameReadingMailbox(member, message) &&
                    Trust.numericID(member.id) != nil && Trust.numericID(member.folderID) != nil &&
                    (member.threadID == nil || member.threadID == message.threadID)
                }) else { throw MailFailure.response }
                var members: [String: MailMessage] = [:]
                for current in self.messageStore.values where Self.sameReadingMailbox(current, message) && current.threadID == message.threadID {
                    members[current.key] = current
                }
                for var member in fetched {
                    guard self.readingRemovalRevisions[member.key, default: 0] == removals[member.key, default: 0] else { continue }
                    if member.threadID == nil { member.threadID = message.threadID }
                    // Do not revert concurrently acknowledged read/flag metadata.
                    if let current = self.messageStore[member.key] {
                        guard Self.sameReadingIdentity(current, member) else { continue }
                        member = current
                    }
                    if member.threadID == nil { member.threadID = message.threadID }
                    members[member.key] = member
                }
                members[message.key] = self.messageStore[message.key] ?? message
                for member in members.values { self.messageStore[member.key] = member }
                self.threadRows = Self.orderedReadingMembers(Array(members.values))
                guard preferLatest, let latest = self.threadRows.first, latest.key != message.key else { return }
                // Adopt within this task, never recursively open/cancel ourselves.
                self.activeKey = latest.key
                self.selectedKeys = [latest.key]
                self.detail = self.cache.detail(latest).flatMap { Self.sameReadingIdentity($0.message, latest) ? $0 : nil }
                self.detailLoading = self.detail == nil
                self.readingError = nil
                if self.preferences.value.markReadOnOpen, latest.unread {
                    self.perform(.read, on: [latest], quiet: true)
                }
                let loaded = try await self.fetchReadingDetail(latest)
                guard valid(latest) else { return }
                guard Self.sameReadingIdentity(loaded.message, latest) else { throw MailFailure.response }
                self.cache.store(loaded)
                self.threadDetails[latest.key] = loaded
                self.detail = loaded
                self.readingError = nil
            } catch {
                guard !Task.isCancelled, self.openingToken == token,
                      self.acceptsLifetimeReply(accountID: message.accountID, lifetime: lifetime) else { return }
                self.readingError = "会话或最新正文读取失败，请重试"
            }
        }
    }

    struct MailConversationSendFence {
        fileprivate let message: MailMessage
        fileprivate let token: UUID
        fileprivate let lifetime: UInt64
    }

    func captureVisibleConversationSend(accountID: String, replyToMessageID: String?) -> MailConversationSendFence? {
        guard let replyID = replyToMessageID, let activeKey, let active = messageStore[activeKey],
              active.accountID == accountID,
              let original = messageStore.values.first(where: {
                  $0.id == replyID && Self.sameReadingMailbox($0, active)
              }), isActiveConversation(original),
              acceptsLifetimeReply(accountID: accountID, lifetime: syncLifetime) else { return nil }
        return MailConversationSendFence(message: active, token: openingToken, lifetime: syncLifetime)
    }

    func refreshVisibleConversationAfterSend(_ fence: MailConversationSendFence?) {
        guard let fence, openingToken == fence.token,
              acceptsLifetimeReply(accountID: fence.message.accountID, lifetime: fence.lifetime),
              messageStore[fence.message.key].map({ Self.sameReadingIdentity($0, fence.message) }) == true,
              isActiveConversation(fence.message) else { return }
        open(fence.message, preferLatest: true)
    }

    func retryReading() {
        guard let retry = readingRetry else { return }
        open(retry.message, preferLatest: retry.preferLatest)
    }

    private static func sameReadingMailbox(_ a: MailMessage, _ b: MailMessage) -> Bool {
        a.accountID == b.accountID && a.remoteID == b.remoteID && a.origin == b.origin
    }

    private static func sameReadingIdentity(_ a: MailMessage, _ b: MailMessage) -> Bool {
        a.key == b.key && sameReadingMailbox(a, b)
    }

    private static func orderedReadingMembers(_ members: [MailMessage]) -> [MailMessage] {
        members.sorted { $0.date == $1.date ? $0.key < $1.key : $0.date > $1.date }
    }

    private func fetchReadingThread(_ message: MailMessage) async throws -> [MailMessage] {
        if let fetch = syncHooks?.fetchThread { return try await fetch(message) }
        guard let account = accounts.first(where: { $0.id == message.accountID }) else { throw MailFailure.auth }
        // A thread request does not require a catalog revision fence: mark-read
        // acknowledgements do not change its mailbox identity or membership.
        let web = session(account)
        try await web.ready()
        guard let context = sessions[account.id], context.accountID == message.accountID,
              context.remoteID == message.remoteID, context.origin == message.origin else { throw MailFailure.response }
        var result: [MailMessage] = [], start = 1
        // Read every page before claiming a latest member, independent of server
        // sort direction. Bounded malformed/repeating pagination is visible error.
        for _ in 0..<20 {
            try Task.checkCancellation()
            let page = try await api.thread(message, context: context, store: web.store, browser: web.webView, start: start)
            result.append(contentsOf: page.messages)
            if !page.more { return result }
            guard page.next > start else { throw MailFailure.response }
            start = page.next
        }
        throw MailFailure.response
    }

    func fetchReadingDetail(_ message: MailMessage) async throws -> MailDetail {
        if let fetch = syncHooks?.fetchDetail { return try await fetch(message) }
        if fixture { return fixtureDetail(message) }
        guard let account = accounts.first(where: { $0.id == message.accountID }) else { throw MailFailure.auth }
        let web = session(account)
        try await web.ready()
        return try await api.detail(message, store: web.store, browser: web.webView)
    }

    func loadDetail(_ message: MailMessage) async -> MailDetail? {
        let lifetime = syncLifetime
        guard acceptsLifetimeReply(accountID: message.accountID, lifetime: lifetime) else { return nil }
        if let existing = threadDetails[message.key] ?? cache.detail(message),
           existing.imageSourceRecovery != nil || !MailOriginalHTML.needsRecovery(existing.html) {
            threadDetails[message.key] = existing
            return existing
        }
        do {
            let loaded = try await fetchReadingDetail(message)
            try Task.checkCancellation()
            guard acceptsLifetimeReply(accountID: message.accountID, lifetime: lifetime),
                  loaded.message.key == message.key, loaded.message.origin == message.origin else { return nil }
            cache.store(loaded)
            threadDetails[message.key] = loaded
            return loaded
        } catch {
            return nil
        }
    }

    func closeReader() {
        if let model = inlineReplyModel {
            _ = model.persistDraft()
            inlineReplyModel = nil
        }
        openingToken = UUID()
        readingError = nil; readingRetry = nil; detailLoading = false
        activeKey = nil; detail = nil; threadRows = []; detailTask?.cancel(); detailTask = nil
    }

    func isActiveConversation(_ row: MailMessage) -> Bool {
        guard let activeKey, let active = messageStore[activeKey] else { return false }
        return active.key == row.key || (Self.sameReadingMailbox(active, row) &&
            active.threadID != nil && active.threadID == row.threadID)
    }

    func activeConversationIndex() -> Int? { rows.firstIndex(where: isActiveConversation) }

    func attachmentData(_ file: MailAttachment, message: MailMessage) async throws -> Data {
        guard let account = accounts.first(where: { $0.id == message.accountID }) else { throw MailFailure.auth }
        if fixture, let hook = inlineImageDataHook { return try await hook(file, message) }
        if fixture, let data = "Mail Lite fixture attachment".data(using: .utf8) { return data }
        _ = try await mailbox(account)
        let session = session(account)
        try await session.ready()
        return try await api.attachment(file, message: message, store: session.store, browser: session.webView)
    }

    /// Session-only provider image bytes. Fixture mode serves the hook so tests
    /// never touch a network; production re-validates trust and raster format.
    func sessionImageData(_ raw: String, message: MailMessage) async throws -> Data {
        guard MailInlineImageReference.sessionImageURL(raw, origin: message.origin) != nil,
              let account = accounts.first(where: { $0.id == message.accountID }) else { throw MailFailure.auth }
        if fixture, let hook = sessionImageDataHook {
            let data = try await hook(raw)
            guard MailRasterImage.mimeType(for: data) != nil else { throw MailFailure.response }
            return data
        }
        _ = try await mailbox(account)
        let session = session(account)
        guard let url = MailInlineImageReference.sessionImageURL(raw, origin: message.origin) else { throw MailFailure.auth }
        let data = try await api.sessionImage(url, origin: message.origin, store: session.store)
        guard MailRasterImage.mimeType(for: data) != nil else { throw MailFailure.response }
        return data
    }

    // MARK: - Actions

    func perform(_ action: MailAction, on targets: [MailMessage], quiet: Bool = false) {
        if fixture, syncHooks == nil { applyLocal(action, targets); return }
        // Establish FIFO synchronously, rather than racing two newly spawned
        // Tasks to reach the enqueue point.
        _ = enqueueMutation(action, targets: targets, quiet: quiet)
    }

    /// UI and tests enter the exact same account FIFO and ack-only pipeline.
    func performAndWait(_ action: MailAction, on targets: [MailMessage], quiet: Bool = false) async {
        if fixture, syncHooks == nil { applyLocal(action, targets); return }
        let tasks = enqueueMutation(action, targets: targets, quiet: quiet)
        for task in tasks { await task.value }
    }

    private func enqueueMutation(_ action: MailAction, targets: [MailMessage], quiet: Bool) -> [Task<Void, Never>] {
        guard !stopped else { return [] }
        let groups = Dictionary(grouping: targets.filter { Trust.numericID($0.id) != nil }, by: { $0.accountID })
        let lifetime = syncLifetime
        return groups.compactMap { accountID, messages in
            guard let account = accounts.first(where: { $0.id == accountID }), !invalidatedAccounts.contains(accountID) else { return nil }
            return mutationQueue.enqueue(accountID: accountID) { [weak self] in
                await self?.executeMutation(action, messages: messages, account: account, lifetime: lifetime, quiet: quiet)
            }
        }
    }

    private func executeMutation(_ action: MailAction, messages: [MailMessage], account: MailAccount, lifetime: UInt64, quiet: Bool) async {
        let accountID = account.id
        func active() -> Bool {
            acceptsReply(accountID: accountID, lifetime: lifetime, revision: mutationRevisions[accountID, default: 0])
        }
        guard active(), !Task.isCancelled else { return }
        do {
            if fixture {
                guard let actionHook = syncHooks?.performAction else { throw MailFailure.rejected }
                try await actionHook(action, messages)
            } else {
                let context = try await mailbox(account)
                let session = self.session(account)
                try await session.ready()
                guard active(), !Task.isCancelled else { return }
                try await api.perform(action, messages: messages, context: context,
                                      store: session.store, browser: session.webView)
            }
            guard active() else { return }
            acknowledgedMutation(accountID: accountID)
            applyLocal(action, messages)
            if !quiet { status = actionLabel(action) }
        } catch {
            guard active() else { return }
            status = "\(actionLabel(action))失败：\((error as? MailFailure)?.label ?? "请稍后重试")"
        }
        guard active() else { return }
        rebuildRows()
    }

    private func actionLabel(_ action: MailAction) -> String {
        switch action {
        case .read: return "已标记为已读"
        case .unread: return "已标记为未读"
        case .archive: return "已归档"
        case .unarchive: return "已取消归档"
        case .trash: return "已移到回收站"
        case .move: return "已移动"
        case .flag: return "已更新标记"
        case .spam: return "已标记为垃圾邮件"
        case .notSpam: return "已标记为非垃圾邮件"
        case .pin(let value): return value ? "已置顶" : "已取消置顶"
        case .snooze(let date): return date == nil ? "已取消延迟" : "已延迟"
        case .label(_, let add): return add ? "已添加标签" : "已移除标签"
        }
    }

    private func applyLocal(_ action: MailAction, _ messages: [MailMessage]) {
        for message in messages {
            switch action {
            case .trash, .move, .spam, .notSpam:
                readingRemovalRevisions[message.key, default: 0] &+= 1
            default: break
            }
            guard var current = messageStore[message.key] else { continue }
            switch action {
            case .read: current.unread = false
            case .unread: current.unread = true
            case .archive: current.archived = true
            case .unarchive: current.archived = false
            case .flag(let flag): current.flag = flag
            case .pin(let value): current.pinned = value
            case .snooze(let date): current.snoozedUntil = date
            case .label(let id, let add):
                var labels = current.labels ?? []
                if add, !labels.contains(id) { labels.append(id) }
                if !add { labels.removeAll { $0 == id } }
                current.labels = labels
            case .trash, .move, .spam, .notSpam:
                messageStore.removeValue(forKey: message.key)
                if !fixture { cache.removeMessage(message.key) }
                continue
            }
            messageStore[current.key] = current
            if !fixture { cache.store([current], account: current.accountID, replace: false) }
        }
        if let activeKey, messageStore[activeKey] == nil { closeReader() }
    }

    func moveTargets(_ targets: [MailMessage], to folder: MailFolder, accountID: String) {
        perform(.move(folder.id), on: targets)
    }

    func toggleFlag(_ message: MailMessage) {
        perform(.flag(message.hasFlag ? "flag_not_set" : "important"), on: [message])
    }

    func togglePin(_ message: MailMessage) {
        perform(.pin(!(message.pinned == true)), on: [message])
    }

    func snooze(_ message: MailMessage, until date: Date) {
        perform(.snooze(date), on: [message])
    }

    func unsnooze(_ message: MailMessage) {
        perform(.snooze(nil), on: [message])
    }

    func toggleLabel(_ message: MailMessage, label: MailLabel) {
        let active = (message.labels ?? []).contains(label.id)
        perform(.label(label.id, !active), on: [message])
    }

    func emptyTrash(_ account: MailAccount) {
        guard let folder = foldersByAccount[account.id]?.first(where: { $0.systemName == "Trash" }) else { return }
        emptyFolder(account, folder)
    }

    func emptyFolder(_ account: MailAccount, _ folder: MailFolder) {
        guard !fixture, !stopped else { return }
        let lifetime = syncLifetime
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = try await self.mailbox(account)
                let session = self.session(account)
                try await session.ready()
                try await self.api.emptyFolder(id: folder.id, context: context, store: session.store, browser: session.webView)
                guard self.acceptsReply(accountID: account.id, lifetime: lifetime,
                                        revision: self.mutationRevisions[account.id, default: 0]) else { return }
                self.acknowledgedMutation(accountID: account.id)
                for (key, message) in self.messageStore where message.accountID == account.id && message.folderID == folder.id {
                    self.readingRemovalRevisions[key, default: 0] &+= 1
                    self.messageStore.removeValue(forKey: key)
                    self.cache.removeMessage(key)
                }
                self.rebuildRows()
                self.status = "已清空\(folder.title)"
            } catch { self.status = "清空失败：\((error as? MailFailure)?.label ?? "请稍后重试")" }
        }
    }

    func blockSender(_ address: String, accountID: String) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        performBlock(address, account: account, block: true)
    }

    func unblockSender(_ address: String, accountID: String) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        performBlock(address, account: account, block: false)
    }

    private func performBlock(_ address: String, account: MailAccount, block: Bool) {
        guard !fixture else { status = "测试模式"; return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = try await self.mailbox(account)
                let session = self.session(account)
                try await session.ready()
                if block {
                    try await self.api.blockSender(address, context: context, store: session.store, browser: session.webView)
                } else {
                    try await self.api.unblockSender(address, context: context, store: session.store, browser: session.webView)
                }
                self.status = block ? "已阻止 \(address)" : "已取消阻止 \(address)"
            } catch {
                self.status = "阻止设置未确认：\((error as? MailFailure)?.label ?? "服务器未接受此请求")"
            }
        }
    }

    func setVacation(_ account: MailAccount, enabled: Bool, message: String) {
        preferences.value.vacationEnabled[account.id] = enabled
        preferences.value.vacationMessage[account.id] = message
        preferences.save()
        guard !fixture else { status = "测试模式"; return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = try await self.mailbox(account)
                let session = self.session(account)
                try await session.ready()
                try await self.api.setVacation(enabled: enabled, message: message, context: context,
                                               store: session.store, browser: session.webView)
                self.status = enabled ? "假期自动回复已开启" : "假期自动回复已关闭"
            } catch {
                self.status = "假期回复设置未确认：\((error as? MailFailure)?.label ?? "服务器未接受此请求")"
            }
        }
    }

    func clearBodyCache() {
        cache.clearDetails()
        status = "已清除本机正文缓存"
        detail = nil
    }

    func reportPhishing(_ message: MailMessage) {
        perform(.spam, on: [message])
        status = "已移入垃圾邮件；如需向 Zoho 报告，请在网页邮箱中使用“报告网络钓鱼”"
    }

    func unsubscribe(_ detail: MailDetail) {
        let account = accounts.first(where: { $0.id == detail.message.accountID })
        guard let account else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.mailbox(account)
                let session = self.session(account)
                try await session.ready()
                let headers = try await self.api.headers(detail.message, store: session.store, browser: session.webView)
                guard let raw = headers["list-unsubscribe"] ?? headers["List-Unsubscribe"] else {
                    self.status = "这封邮件没有提供退订方式"
                    return
                }
                let targets = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>")) }
                if let http = targets.first(where: { $0.lowercased().hasPrefix("http") }), let url = URL(string: http), Trust.outside(url) {
                    var request = URLRequest(url: url)
                    if (headers["list-unsubscribe-post"] ?? "").lowercased().contains("one-click") {
                        request.httpMethod = "POST"
                        request.setValue("List-Unsubscribe=One-Click", forHTTPHeaderField: "Content-Type")
                    }
                    _ = try? await URLSession.shared.data(for: request)
                    self.status = "已发送退订请求"
                } else if let mailto = targets.first(where: { $0.lowercased().hasPrefix("mailto:") }),
                          let address = MailAddresses.extract(mailto).first {
                    self.composeNew(accountID: account.id, to: address, subject: "unsubscribe", body: "")
                    self.status = "已打开退订邮件"
                } else {
                    self.status = "退订链接格式不受支持"
                }
            } catch { self.status = "退订失败：\((error as? MailFailure)?.label ?? "请稍后重试")" }
        }
    }

    func toggleOffline(_ message: MailMessage) {
        if preferences.value.offlineSaved.contains(message.key) {
            guard cache.setPinned(message.key, false) else { status = "离线保存状态写入失败"; return }
            preferences.value.offlineSaved.removeAll { $0 == message.key }
            preferences.save(); status = "已取消离线保存"
            if scope.kind == .offline { rebuildRows() }
            return
        }
        guard offlineSavePending.insert(message.key).inserted else { return }
        // Pin before download so cache trimming cannot race the saved body.
        guard cache.setPinned(message.key, true) else { offlineSavePending.remove(message.key); status = "离线保存失败"; return }
        func complete(_ detail: MailDetail?) {
            offlineSavePending.remove(message.key)
            guard let detail, detail.message.key == message.key, accounts.contains(where: { $0.id == message.accountID }) else {
                _ = cache.setPinned(message.key, false); status = "正文下载失败，未标记为离线保存"; return
            }
            cache.store(detail)
            guard cache.detail(message) != nil else { _ = cache.setPinned(message.key, false); status = "正文保存失败"; return }
            if !preferences.value.offlineSaved.contains(message.key) { preferences.value.offlineSaved.append(message.key) }
            preferences.save(); status = "正文已离线保存"
            if scope.kind == .offline { rebuildRows() }
        }
        if let saved = cache.detail(message) { complete(saved) }
        else {
            status = "正在下载离线正文…"
            Task { @MainActor in complete(await self.loadDetail(message)) }
        }
    }

    func isOfflineSaved(_ message: MailMessage) -> Bool {
        preferences.value.offlineSaved.contains(message.key)
    }

    // MARK: - Search

    func search(_ raw: String) {
        let query = raw.trimmed
        guard !query.isEmpty else { clearSearch(); return }
        var history = preferences.value.searchHistory.filter { $0 != query }
        history.insert(query, at: 0)
        preferences.value.searchHistory = Array(history.prefix(12))
        preferences.save()
        searchText = query
        searchResults = []
        select(Scope(kind: .search, query: query))
    }

    func clearSearch() {
        searchText = ""
        searchResults = []
        showAllInbox()
    }

    func saveSearch(name: String, query: String) {
        preferences.value.savedSearches.append(SavedSearch(name: name, query: query))
        preferences.save()
    }

    func deleteSavedSearch(_ value: SavedSearch) {
        preferences.value.savedSearches.removeAll { $0.id == value.id }
        preferences.save()
    }

    // MARK: - Accounts

    func addAccount(name: String, region: Region) {
        let account = MailAccount(id: UUID().uuidString.lowercased(),
                                  name: name.nonEmpty ?? "账号 \(accounts.count + 1)", region: region.id)
        accounts.append(account)
        preferences.value.accounts.append(account)
        preferences.save()
        totalAccounts = accounts.count
        Task { @MainActor in
            let session = self.session(account)
            let ok = await session.authenticate(presenting: nil)
            if ok {
                self.accountErrors[account.id] = nil
                self.status = "已添加 \(account.name)"
                self.refresh()
                await self.loadLabels(account)
            } else {
                self.accountErrors[account.id] = "登录未完成"
            }
        }
    }

    func relogin(_ account: MailAccount) {
        primarySenderSync.invalidate(accountID: account.id)
        accountErrors[account.id] = nil
        Task { @MainActor in
            let ok = await self.session(account).authenticate(presenting: nil)
            if ok { self.refresh(); await self.loadLabels(account) }
        }
    }

    func renameAccount(_ account: MailAccount, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let clean = Trust.text(name, limit: 80)
        accounts[index].name = clean.isEmpty ? account.name : clean
        if let prefIndex = preferences.value.accounts.firstIndex(where: { $0.id == account.id }) {
            preferences.value.accounts[prefIndex].name = accounts[index].name
            preferences.save()
        }
    }

    func removeAccount(_ account: MailAccount) {
        guard mailReminderStore.removeAccount(accountID: account.id) else { return }
        // Fence replies immediately, before asynchronous WebKit data cleanup.
        invalidateAccount(account.id)
        Task { @MainActor in await self.removeAccountAndWait(account) }
    }

    private func invalidateAccount(_ accountID: String) {
        if invalidatedAccounts.insert(accountID).inserted {
            primarySenderSync.invalidate(accountID: accountID)
            mutationRevisions[accountID, default: 0] &+= 1
            mutationQueue.invalidate(accountID: accountID)
            signatureAccountEpoch[accountID, default: 0] &+= 1
        }
    }

    func removeAccountAndWait(_ account: MailAccount) async {
        guard mailReminderStore.removeAccount(accountID: account.id) else { return }
        invalidateAccount(account.id)
        if let session = accountSessions[account.id] { await session.clearData() }
        accountSessions[account.id] = nil
        sessions[account.id] = nil
        counterSyncedAt[account.id] = nil
        counterRefreshPending.remove(account.id)
        adoptedCatalogSerial[account.id] = nil
        viewWindows = viewWindows.filter { $0.key.accountID != account.id }
        accountErrors[account.id] = nil
        labelsByAccount[account.id] = nil
        foldersByAccount[account.id] = nil
        cache.removeAccount(account.id)
        for (key, message) in messageStore where message.accountID == account.id {
            messageStore.removeValue(forKey: key)
        }
        accounts.removeAll { $0.id == account.id }
        preferences.value.accounts.removeAll { $0.id == account.id }
        preferences.value.accountSignatures.removeValue(forKey: account.id)
        preferences.value.defaultSignatureByAccount.removeValue(forKey: account.id)
        preferences.value.signatures?.removeValue(forKey: account.id)
        preferences.value.senderDisplayNames.removeValue(forKey: account.id)
        signatureAccountEpoch[account.id, default: 0] &+= 1
        remoteSignatureCache = remoteSignatureCache.filter { !$0.key.hasPrefix(account.id + "\u{1f}") }
        signaturesVersion += 1
        preferences.save()
        let affected = composeControllers.filter { $0.draft.accountID == account.id }
        for composer in affected { composer.close(save: false) }
        if scope.accountID == account.id { showAllInbox() } else { refresh() }
        foldersVersion += 1
        totalAccounts = accounts.count
        rebuildRows()
        status = "已移除 \(account.name)"
    }

    // MARK: - Folders and labels

    func folders(_ accountID: String) -> [MailFolder] {
        foldersByAccount[accountID] ?? []
    }

    func createFolder(accountID: String, name: String, parent: String?) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = try await self.mailbox(account)
                let session = self.session(account)
                try await session.ready()
                try await self.api.createFolder(name: name, parent: parent, context: context, store: session.store, browser: session.webView)
                try await self.reloadFolders(account)
                self.status = "已创建文件夹“\(name)”"
            } catch { self.status = "创建文件夹失败：\((error as? MailFailure)?.label ?? "服务器未接受此请求")" }
        }
    }

    func renameFolder(accountID: String, folder: MailFolder, name: String) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = try await self.mailbox(account)
                let session = self.session(account)
                try await session.ready()
                try await self.api.renameFolder(id: folder.id, name: name, context: context, store: session.store, browser: session.webView)
                try await self.reloadFolders(account)
                self.status = "文件夹已重命名"
            } catch { self.status = "重命名失败：\((error as? MailFailure)?.label ?? "服务器未接受此请求")" }
        }
    }

    func deleteFolder(accountID: String, folder: MailFolder) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = try await self.mailbox(account)
                let session = self.session(account)
                try await session.ready()
                try await self.api.deleteFolder(id: folder.id, context: context, store: session.store, browser: session.webView)
                try await self.reloadFolders(account)
                if self.scope.folderID == folder.id { self.showAllInbox() }
                self.status = "文件夹已删除"
            } catch { self.status = "删除文件夹失败：\((error as? MailFailure)?.label ?? "服务器未接受此请求")" }
        }
    }

    private func reloadFolders(_ account: MailAccount) async throws {
        guard !stopped, !invalidatedAccounts.contains(account.id), accounts.contains(where: { $0.id == account.id }) else { throw CancellationError() }
        acknowledgedMutation(accountID: account.id)
        let fence = captureViewReplyFence(accountID: account.id)
        let serial = nextCatalogSerial()
        let session = self.session(account)
        try await session.ready()
        let context = try await api.discover(account: account, store: session.store, origin: session.origin, browser: session.webView)
        guard acceptsReply(accountID: account.id, lifetime: fence.lifetime, revision: fence.mutationRevision) else { throw CancellationError() }
        adopt(context, account: account, observationSerial: serial)
        handleSyncEvent(.manual, isActive: true)
    }

    func loadLabels(_ account: MailAccount) async {
        guard !fixture, let context = sessions[account.id] else { return }
        do {
            let session = session(account)
            try await session.ready()
            let labels = try await api.labels(context: context, store: session.store, browser: session.webView)
            labelsByAccount[account.id] = labels
        } catch {
            labelsByAccount[account.id] = []
        }
    }

    func loadLabelsForAllAccounts() async {
        labelsLoading = true
        for account in accounts { await loadLabels(account) }
        labelsLoading = false
    }

    func createLabel(accountID: String, name: String) {
        guard let account = accounts.first(where: { $0.id == accountID }), !fixture else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = try await self.mailbox(account)
                let session = self.session(account)
                try await session.ready()
                try await self.api.createLabel(name: name, context: context, store: session.store, browser: session.webView)
                await self.loadLabels(account)
                self.status = "已创建标签"
            } catch { self.status = "创建标签失败：\((error as? MailFailure)?.label ?? "服务器未接受此请求")" }
        }
    }

    func deleteLabel(accountID: String, label: MailLabel) {
        guard let account = accounts.first(where: { $0.id == accountID }), !fixture else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = try await self.mailbox(account)
                let session = self.session(account)
                try await session.ready()
                try await self.api.deleteLabel(id: label.id, context: context, store: session.store, browser: session.webView)
                await self.loadLabels(account)
                self.status = "已删除标签"
            } catch { self.status = "删除标签失败：\((error as? MailFailure)?.label ?? "服务器未接受此请求")" }
        }
    }

    // MARK: - Compose

    func composeNew(accountID: String? = nil, to: String = "", subject: String = "", body: String = "") {
        let id = accountID ?? scope.accountID ?? accounts.first?.id
        guard let id, let account = accounts.first(where: { $0.id == id }) else { return }
        let from = sessions[id]?.addresses.first ?? account.name
        let draft = MailDraft(accountID: id, from: from, mode: ComposeMode.new.rawValue, source: nil,
                              to: to, subject: subject, body: body)
        openCompose(draft)
    }

    func composeReply(_ detail: MailDetail, mode: ComposeMode) {
        let key = detail.message.key
        guard !composeSourcePending.contains(key) else { return }
        composePreparationFailure = nil; composePreparationRetry = nil
        // Old caches may have lost Reply-To; resolve the original headers before
        // creating a reply instead of silently addressing the website or ourselves.
        if mode != .forward, !fixture, detail.replyHeadersChecked != true {
            guard let account = accounts.first(where: { $0.id == detail.message.accountID }) else { return }
            composeSourcePending.insert(key)
            status = "正在核对回复地址…"
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let session = self.session(account)
                    try await session.ready()
                    let loaded = try await self.api.detail(detail.message, store: session.store, browser: session.webView)
                    self.cache.store(loaded)
                    self.threadDetails[detail.message.key] = loaded
                    if self.activeKey == detail.message.key { self.detail = loaded }
                    self.status = ""
                    self.composeSourcePending.remove(key)
                    self.openReplyDraft(loaded, mode: mode)
                } catch {
                    self.composeSourcePending.remove(key)
                    self.status = "回复地址读取失败，请重新打开邮件后重试"
                    self.composePreparationRetry = { [weak self] in self?.composeReply(detail, mode: mode) }
                    self.composePreparationFailure = self.status
                }
            }
            return
        }
        openReplyDraft(detail, mode: mode)
    }

    func openReplyDraft(_ detail: MailDetail, mode: ComposeMode) {
        guard let account = accounts.first(where: { $0.id == detail.message.accountID }) else { return }
        let context = sessions[account.id]
        let own = context?.email ?? account.name
        let identities = (context?.addresses ?? []) + [own]
        // Use the addressed alias where possible, keeping the original account.
        let recipients = MailAddresses.extract(detail.to + "," + detail.cc).map { $0.lowercased() }
        let from = identities.first { recipients.contains($0.lowercased()) } ?? own
        var value = MailDraft(accountID: account.id, from: from, mode: mode.rawValue, source: detail)
        if mode != .forward {
            let addresses = MailAddresses.reply(detail, own: identities, all: mode == .replyAll)
            value.to = addresses.to; value.cc = addresses.cc
        }
        let prefix = mode == .forward ? "Fwd: " : "Re: "
        value.subject = detail.message.subject.lowercased().hasPrefix(prefix.lowercased()) ? detail.message.subject : prefix + detail.message.subject
        prepareCompose(value, preferInline: true)
    }

    func editDraft(_ original: MailDraft) {
        var draft = original
        if let existing = composeControllers.first(where: { $0.model.draft.id == draft.id }) { existing.show(); return }
        if let item = outboxStore.all().first(where: { ($0.draftID == draft.id || $0.id == draft.queuedItemID) && $0.state != "cancelled" }) {
            if item.state == "sent" { try? draftStore.remove(draft.id); draftsVersion += 1; status = "此草稿已经发送" }
            else { status = "此草稿已在发件箱，请先查看或取消已有任务" }
            return
        }
        if draft.state == "queued", let id = draft.queuedItemID,
           !outboxStore.all().contains(where: { $0.id == id && $0.state == "cancelled" }) {
            status = "关联发送记录缺失，请先核对已发送邮件；草稿仍保留在本机"; return
        }
        draft.state = "editing"; draft.queuedItemID = nil
        openCompose(draft)
    }

    private func prepareCompose(_ draft: MailDraft, preferInline: Bool = false) {
        composePreparationFailure = nil; composePreparationRetry = nil
        guard MailComposeSource.needsPreparation(draft) else { openCompose(draft, preferInline: preferInline); return }
        let key = draft.source?.message.key ?? draft.id
        guard !composeSourcePending.contains(key) else { return }
        composeSourcePending.insert(key); status = "正在保留原邮件内容与附件…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.composeSourcePending.remove(key) }
            do {
                let prepared = try await MailComposeSource.prepare(draft, state: self)
                self.openCompose(prepared, preferInline: preferInline); self.status = ""
            } catch {
                self.status = (error as? MailComposeSource.Failure)?.label
                    ?? (error as? MailInlineImageSend.Failure)?.label ?? "原邮件内容准备失败，请重试"
                self.composePreparationRetry = { [weak self] in self?.prepareCompose(draft, preferInline: preferInline) }
                self.composePreparationFailure = self.status
            }
        }
    }

    func editServerDraft(_ detail: MailDetail) {
        guard isDraft(detail.message) else { status = "请选择草稿文件夹中的邮件"; return }
        let allowed = sessions[detail.message.accountID]?.addresses ?? []
        guard let sourceFrom = MailAddresses.extract(detail.from).first,
              let from = allowed.first(where: { $0.caseInsensitiveCompare(sourceFrom) == .orderedSame }) else {
            status = "原草稿发件地址当前不可用，请先检查账号与别名"; return
        }
        var draft = MailDraft(accountID: detail.message.accountID, from: from, mode: ComposeMode.edit.rawValue,
                              source: detail, to: detail.to, cc: detail.cc, bcc: detail.bcc ?? "",
                              subject: detail.message.subject, body: MailHTML.plainText(detail.html))
        draft.cloudID = detail.message.id
        prepareCompose(draft)
    }

    func saveAsNew(_ detail: MailDetail) {
        var value = MailDraft(accountID: detail.message.accountID,
                              from: sessions[detail.message.accountID]?.addresses.first ?? "",
                              mode: ComposeMode.new.rawValue, source: nil,
                              to: "", subject: detail.message.subject, body: MailHTML.plainText(detail.html))
        value.body = MailHTML.plainText(detail.html)
        openCompose(value)
    }

    private func openCompose(_ draft: MailDraft, preferInline: Bool = false) {
        if preferInline && preferences.value.inlineReply && activeKey != nil && (!fixture || activeKey == draft.source?.message.key) {
            let model = ComposeModel(state: self, draft: draft)
            model.onClose = { [weak self] in
                self?.inlineReplyModel = nil
            }
            self.inlineReplyModel = model
            return
        }
        let controller = ComposeController(state: self, draft: draft)
        composeControllers.append(controller)
        composeCount = composeControllers.count
        controller.show()
    }

    func popOutInlineReply() {
        guard let model = inlineReplyModel else { return }
        _ = model.persistDraft()
        inlineReplyModel = nil
        let controller = ComposeController(state: self, draft: model.draft)
        composeControllers.append(controller)
        composeCount = composeControllers.count
        controller.show()
    }

    func closeInlineReply(save: Bool = true) {
        guard let model = inlineReplyModel else { return }
        if save {
            _ = model.persistDraft()
            inlineReplyModel = nil
        } else {
            model.discard()
        }
    }

    func composeClosed(_ controller: ComposeController) {
        composeControllers.removeAll { $0 === controller }
        composeCount = composeControllers.count
        draftsVersion += 1
    }

    func showDraftsWindow() {
        if let existing = draftsController { existing.window.makeKeyAndOrderFront(nil); return }
        let controller = DraftsWindowController(state: self)
        draftsController = controller
        controller.show()
    }

    func showSettings() {
        if let existing = settingsController { existing.window.makeKeyAndOrderFront(nil); return }
        let controller = SettingsWindowController(state: self)
        settingsController = controller
        controller.show()
    }

    // MARK: - Outbox

    func reloadOutbox() {
        outbox = outboxStore.all().filter { !["sent", "cancelled"].contains($0.state) }.sorted { ($0.scheduledAt ?? $0.createdAt) < ($1.scheduledAt ?? $1.createdAt) }
    }

    @discardableResult func enqueueSend(_ item: OutboxItem) -> Bool {
        guard outboxStore.enqueue(item) else { status = outboxStore.persistenceError ?? "此草稿已经加入发件箱"; return false }
        reloadOutbox()
        if item.scheduledAt == nil || (item.scheduledAt ?? .distantFuture) <= Date() {
            Task { @MainActor in await self.sendOutbox(item.id) }
        } else {
            status = "已安排稍后发送：\(item.scheduledAt?.mailFull ?? "")"
        }
        return true
    }

    func processOutbox() {
        guard !fixture else { return }
        let due = outbox.filter { $0.state == "queued" && ($0.scheduledAt ?? .distantPast) <= Date() }
        guard !due.isEmpty else { return }
        Task { @MainActor in
            for item in due { await self.sendOutbox(item.id) }
        }
    }

    func sendNow(_ id: String) {
        guard outboxStore.all().contains(where: { $0.id == id && $0.state == "queued" }),
              outboxStore.update(id, { $0.scheduledAt = Date() }) else { status = outboxStore.persistenceError ?? "当前任务无法发送"; return }
        reloadOutbox()
        Task { @MainActor in await self.sendOutbox(id) }
    }

    func cancelOutbox(_ id: String) {
        guard let item = outboxStore.all().first(where: { $0.id == id }), ["queued", "failed"].contains(item.state) else {
            status = "发送中或结果未确认的邮件不能直接删除，请先核对已发送邮件"; return
        }
        var draft = draftStore.all(accounts: Set(accounts.map(\.id))).first { $0.id == item.draftID || $0.queuedItemID == id }
        do {
            if draft == nil {
                var recovered = MailDraft(accountID: item.accountID, from: item.from, mode: "new", source: nil,
                                          to: item.to, cc: item.cc, bcc: item.bcc, subject: item.subject,
                                          body: MailHTML.plainText(item.html))
                recovered.htmlBody = item.html
                for file in outboxStore.attachments(id) {
                    let name = OutboxStore.attachmentName(file)
                    let temporary = try draftStore.folder(recovered.id).appendingPathComponent("recover-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let source = temporary.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: file, to: source)
                    recovered.files.append(try draftStore.importFile(source, id: recovered.id).path)
                }
                draft = recovered
            }
            guard var saved = draft else { return }
            saved.state = "queued"; saved.queuedItemID = id
            try draftStore.save(saved)
            guard outboxStore.cancel(id) else { status = outboxStore.persistenceError ?? "取消失败"; return }
            saved.state = "editing"; saved.queuedItemID = nil
            try draftStore.save(saved)
            outboxStore.releaseAttachments(id)
            reloadOutbox(); draftsVersion += 1
            status = "已取消发送，草稿已保留"
        } catch { reloadOutbox(); status = "草稿恢复未完成，原发件箱内容仍保留在本机，请重试" }
    }

    func confirmOutboxSent(_ id: String) {
        guard !fixture, var item = outboxStore.all().first(where: { $0.id == id && $0.state == "uncertain" }) else { return }
        let alert = NSAlert()
        alert.messageText = "已在已发送邮件中找到这封邮件？"
        alert.informativeText = "确认后将结束本机待发任务，不会再次发送。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "确认已发送")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        item.serverDraft = nil
        _ = finishAcknowledgedSend(item)
    }

    func retryOutbox(_ id: String) {
        guard let item = outboxStore.all().first(where: { $0.id == id }), ["failed", "uncertain"].contains(item.state) else { return }
        if item.state == "uncertain" {
            guard !fixture else { status = "请先核对已发送邮件"; return }
            let alert = NSAlert()
            alert.messageText = "请先核对已发送邮件"
            alert.informativeText = "上次发送结果未确认。如果邮件已发出，再试会重复发送。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "已核对，重新发送")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        guard outboxStore.update(id, { $0.state = "queued"; $0.error = nil; $0.serverFailure = nil; $0.failureStage = nil; $0.uploadDiagnostic = nil; $0.sendDiagnostic = nil; $0.postStarted = false }) else { status = outboxStore.persistenceError ?? "保存失败"; return }
        reloadOutbox()
        Task { @MainActor in await self.sendOutbox(id) }
    }

    func sendOutbox(_ id: String) async {
        guard var item = outboxStore.all().first(where: { $0.id == id }) else { return }
        guard item.state == "queued", !fixture || outboxSendHook != nil else { return }
        guard let account = accounts.first(where: { $0.id == item.accountID }) else {
            outboxStore.update(id) { $0.state = "failed"; $0.error = "账号已移除" }
            reloadOutbox(); return
        }
        let conversationFence = captureVisibleConversationSend(accountID: account.id, replyToMessageID: item.replyToMessageID)
        item.state = "sending"; item.attempts += 1; item.postStarted = false
        guard outboxStore.save(item) else { status = outboxStore.persistenceError ?? "保存失败，邮件未发送"; return }
        reloadOutbox()
        var postStarted = false
        var failureStage = "准备邮件"
        defer { uploadProgress.removeValue(forKey: id) }
        do {
            if fixture, let hook = outboxSendHook {
                guard outboxStore.update(id, { $0.postStarted = true }) else { throw MailFailure.response }
                postStarted = true
                try await hook(item)
                finishAcknowledgedSend(item)
                return
            }
            // Validate the durable self-contained draft before any network IO.
            // Only a transient copy receives provider-returned inline URLs.
            let preparedBody = try MailInlineImageSend.prepare(item.html)
            let sendLifetime = contextActionLifetime()
            guard acceptsContextAction(accountID: account.id, lifetime: sendLifetime), !Task.isCancelled else { throw CancellationError() }
            let context = try await mailbox(account)
            @MainActor func checkSendContext() throws {
                guard !Task.isCancelled,
                      acceptsContextAction(accountID: account.id, lifetime: sendLifetime),
                      MailInlineImageSend.sameContext(sessions[account.id], expected: context),
                      outboxStore.all().contains(where: { $0.id == id && $0.state == "sending" }) else { throw CancellationError() }
                _ = try MailSenderWire.fromAddress(item: item, allowedAddresses: sessions[account.id]?.addresses ?? [])
            }
            try checkSendContext()
            let session = session(account)
            try checkSendContext()
            try await session.ready()
            try checkSendContext()
            guard context.messageReference() != nil else { throw MailFailure.folder }
            let addresses = MailAddresses.validated(item.to) ?? []
            let copies = MailAddresses.validated(item.cc) ?? []
            let blind = MailAddresses.validated(item.bcc) ?? []
            guard !addresses.isEmpty, context.accountID == item.accountID else { throw MailFailure.rejected }
            // Reject revoked aliases, malformed bare identities and bad names
            // before uploads or send. Never fall back to another account/name.
            _ = try MailSenderWire.fromAddress(item: item, allowedAddresses: context.addresses)
            let attachmentFiles = outboxStore.attachments(id)
            let fileCount = preparedBody.images.count + attachmentFiles.count
            let attachmentBytes = try attachmentFiles.reduce(Int64(0)) { total, file in
                total + Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            let totalBytes = preparedBody.images.reduce(Int64(0)) { $0 + Int64($1.data.count) } + attachmentBytes
            let replying = item.replyToMessageID != nil
            if let replyID = item.replyToMessageID, Trust.numericID(replyID) == nil { throw MailFailure.response }
            if let parent = item.inReplyTo, MailAddresses.safeHeaderValue(parent) == nil { throw MailFailure.response }
            if replying, item.inReplyTo == nil, let source = item.replySource {
                failureStage = "读取回复关联"
                guard let replyID = item.replyToMessageID, Trust.numericID(replyID) != nil else { throw MailFailure.response }
                guard source.accountID == account.id, source.remoteID == context.remoteID,
                      source.origin == context.origin, source.id == replyID else { throw MailFailure.auth }
                let headers = try await api.headers(source, store: session.store, browser: session.webView)
                try checkSendContext()
                let parent = MailAddresses.safeHeaderValue(headers["message-id"])
                item.inReplyTo = parent; item.referencesHeader = MailAddresses.safeHeaderValue(headers["references"])
                guard outboxStore.update(id, { $0.inReplyTo = parent; $0.referencesHeader = item.referencesHeader; $0.replySource = source }) else { throw MailFailure.response }
            }
            // A legacy job without a source locator, or mail whose headers lack
            // Message-ID, must retain the remote-ID reply route.
            // Preserve the documented remote-ID reply route as a complete
            // transaction; never invent a private dmailid/mymid or mix schemas.
            let publicReplyFallback = replying && item.inReplyTo == nil
            failureStage = "获取上传配置"
            let domains = fileCount > 0 && !publicReplyFallback ? try await api.officialDomains(context: context, store: session.store, browser: session.webView) : nil
            try checkSendContext()
            var uploadIndex = 0, uploadedBytes: Int64 = 0
            func progress(_ name: String, bytes: Int64) -> (Int64, Int64) -> Void {
                uploadIndex += 1
                let currentIndex = uploadIndex, completed = uploadedBytes
                return { loaded, _ in
                    guard self.acceptsContextAction(accountID: account.id, lifetime: sendLifetime),
                          MailInlineImageSend.sameContext(self.sessions[account.id], expected: context) else { return }
                    self.uploadProgress[id] = MailUploadProgress(fileName: name, fileIndex: currentIndex,
                        fileCount: fileCount, completedBytes: completed, fileBytes: bytes,
                        uploadedBytes: loaded, totalBytes: totalBytes)
                }
            }
            failureStage = "上传正文图片"
            var publicUploads: [[String: String]] = []
            let transportHTML: String
            if publicReplyFallback {
                let body = try await MailInlineImageSend.transport(preparedBody, context: context) { data, name in
                    try checkSendContext()
                    let uploaded = try await api.uploadInline(data, name: name,
                        message: context.messageReference()!, store: session.store, browser: session.webView,
                        onProgress: progress("正文图片", bytes: Int64(data.count)))
                    try checkSendContext(); uploadedBytes += Int64(data.count)
                    return uploaded
                }
                transportHTML = body.html; publicUploads = body.attachments
            } else {
                transportHTML = try await MailInlineImageSend.officialTransport(preparedBody, context: context) { data, name in
                    try checkSendContext()
                    guard let domains else { throw MailFailure.response }
                    let update = progress("正文图片", bytes: Int64(data.count))
                    let uploaded = try await api.officialUpload(data, name: name, inline: true, context: context, domains: domains,
                                                               store: session.store, browser: session.webView, onProgress: update)
                    try checkSendContext()
                    uploadedBytes += Int64(data.count)
                    return uploaded
                }
            }
            try checkSendContext()
            var uploads: [MailOfficialProtocol.UploadedFile] = []
            failureStage = "上传附件"
            for file in attachmentFiles {
                let data = try Data(contentsOf: file)
                let name = OutboxStore.attachmentName(file)
                try checkSendContext()
                let update = progress(name, bytes: Int64(data.count))
                if publicReplyFallback {
                    publicUploads.append(try await api.upload(data, name: name, message: context.messageReference()!,
                        store: session.store, browser: session.webView, onProgress: update))
                } else {
                    guard let domains else { throw MailFailure.response }
                    uploads.append(try await api.officialUpload(data, name: name, inline: false, context: context, domains: domains,
                                                               store: session.store, browser: session.webView, onProgress: update))
                }
                try checkSendContext()
                uploadedBytes += Int64(data.count)
            }
            let from = try MailSenderWire.fromAddress(item: item, allowedAddresses: context.addresses)
            let sendDiagnostic: MailSendDiagnostic
            let transmit: @MainActor () async throws -> String?
            if publicReplyFallback {
                guard let replyID = item.replyToMessageID, Trust.numericID(replyID) != nil else { throw MailFailure.response }
                let reference = MailMessage(accountID: account.id, remoteID: context.remoteID,
                    folderID: context.inbox?.id ?? "0", id: replyID, origin: context.origin,
                    subject: item.subject, sender: item.from, preview: "", date: Date(), attachment: false, unread: false)
                var payload: [String: Any] = ["action": "reply", "fromAddress": from, "toAddress": addresses.joined(separator: ","),
                    "ccAddress": copies.joined(separator: ","), "bccAddress": blind.joined(separator: ","), "subject": Trust.text(item.subject, limit: 1000),
                    "content": transportHTML, "mailFormat": "html", "encoding": "UTF-8", "askReceipt": item.receipt ? "yes" : "no"]
                if !publicUploads.isEmpty { payload["attachments"] = publicUploads }
                if item.priority != 3 { payload["priority"] = item.priority == 1 ? "high" : "low" }
                var diagnostic = try MailSendDiagnostic(body: payload, reply: true, inlineImages: preparedBody.images.count,
                    ordinaryAttachments: attachmentFiles.count, uploadedBytes: uploadedBytes)
                diagnostic.protocolKind = "zoho-rest-headerless-reply"
                sendDiagnostic = diagnostic
                let frozenPayload = payload
                transmit = {
                    try await self.api.send(message: reference, store: session.store, browser: session.webView, body: frozenPayload, reply: true)
                }
            } else {
                let fields = try MailOfficialProtocol.sendFields(accountID: context.remoteID, from: from,
                    to: addresses.joined(separator: ","), cc: copies.joined(separator: ","), bcc: blind.joined(separator: ","),
                    subject: Trust.text(item.subject, limit: 1000), html: transportHTML, files: uploads,
                    receipt: item.receipt, priority: item.priority, inReplyTo: item.inReplyTo, references: item.referencesHeader)
                let multipart = try MailOfficialProtocol.multipart(fields: fields)
                sendDiagnostic = MailSendDiagnostic(officialFields: fields, requestBytes: multipart.body.count, reply: replying,
                    inlineImages: preparedBody.images.count, files: uploads, uploadedBytes: uploadedBytes)
                transmit = {
                    let receipt = try await self.api.officialSend(fields: fields, multipart: multipart, context: context,
                        store: session.store, browser: session.webView)
                    return receipt.messageID
                }
            }
            try checkSendContext()
            failureStage = "提交发送"
            if var progress = uploadProgress[id] { progress.awaitingSend = true; uploadProgress[id] = progress }
            guard outboxStore.update(id, { $0.postStarted = true; $0.sendDiagnostic = sendDiagnostic }) else { throw MailFailure.response }
            postStarted = true
            let acknowledgedID = try await transmit()
            guard finishAcknowledgedSend(item, messageID: acknowledgedID) else { return }
            guard acceptsContextAction(accountID: account.id, lifetime: sendLifetime),
                  MailInlineImageSend.sameContext(sessions[account.id], expected: context) else { return }
            let cloudIDs = Set((item.cloudDraftIDs ?? []) + (item.serverDraft.map { [$0.id] } ?? []))
            var cleanupFailed = false
            for draftID in cloudIDs {
                do { try checkSendContextAfterAcknowledgement(accountID: account.id, context: context, lifetime: sendLifetime)
                    try await api.removeDraftCopy(draftID, context: context, store: session.store, browser: session.webView)
                } catch { cleanupFailed = true }
            }
            if cleanupFailed { status = "邮件已发送；部分 Zoho 草稿副本未能清理" }
            refreshVisibleConversationAfterSend(conversationFence)
            // Archive only after the server acknowledged sending, never because
            // an item disappeared from the queue (it may have been cancelled).
            if let original = item.archiveAfterSend,
               original.accountID == account.id, original.remoteID == context.remoteID,
               original.origin == context.origin {
                perform(.archive, on: [original], quiet: true)
            }
            Task { @MainActor in self.refresh(silent: true) }
        } catch {
            let failure = error as? MailFailure
            let imageFailure = error as? MailInlineImageSend.Failure
            let serverFailure = error as? MailServerRejection
            let uploadFailure = error as? MailUploadFailure
            let responseFailure = error as? MailUploadResponseFailure
            let officialFailure = error as? MailOfficialFailure
            let rejected: Bool = !postStarted || imageFailure != nil || serverFailure?.definitelyRejected == true || (failure.map { [.auth, .rate, .rejected, .folder].contains($0) } ?? false)
            let failureLabel = failureStage + "：" + (officialFailure?.label ?? responseFailure?.label ?? serverFailure?.label ?? uploadFailure?.label ?? imageFailure?.label ?? failure?.label ?? MailFailure.network.label)
            let saved = outboxStore.update(id) {
                $0.state = rejected ? "failed" : "uncertain"
                $0.error = failureLabel
                $0.serverFailure = serverFailure
                $0.failureStage = failureStage
                $0.uploadDiagnostic = responseFailure?.diagnostic
            }
            if !saved { status = outboxStore.persistenceError ?? "发送状态保存失败，请核对已发送邮件"; reloadOutbox(); return }
            reloadOutbox()
            status = rejected ? "发送失败：\(failureLabel)" : "发送结果未确认，请在发件箱核对后再重试"
        }
    }

    private func checkSendContextAfterAcknowledgement(accountID: String, context: MailboxSession, lifetime: UInt64) throws {
        guard acceptsContextAction(accountID: accountID, lifetime: lifetime),
              MailInlineImageSend.sameContext(sessions[accountID], expected: context) else { throw MailFailure.auth }
    }

    @discardableResult private func finishAcknowledgedSend(_ item: OutboxItem, messageID: String? = nil) -> Bool {
        guard outboxStore.update(item.id, { $0.state = "sent"; $0.error = nil; $0.sentMessageID = messageID }) else {
            reloadOutbox(); status = "服务器已接收邮件，但本机状态保存失败。请勿重试，请先核对已发送邮件。"
            return false
        }
        if let draftID = item.draftID { try? draftStore.remove(draftID) }
        outboxStore.releaseAttachments(item.id)
        // Keep a durable terminal receipt: missing queue data is never success.
        _ = outboxStore.update(item.id) { $0.html = "" }
        reloadOutbox(); draftsVersion += 1; status = "邮件已发送"
        return true
    }

    // MARK: - Menu commands

    func activeMessage() -> MailMessage? {
        if let activeKey, let message = messageStore[activeKey] { return message }
        if let row = rows.first(where: { selectedKeys.contains($0.key) }) { return row }
        return rows.first
    }

    func selectedMessages() -> [MailMessage] {
        let selected = rows.filter { selectedKeys.contains($0.key) }
        if !selected.isEmpty { return selected }
        if let activeKey, let message = messageStore[activeKey] { return [message] }
        return []
    }

    func selectAllRows() { selectedKeys = Set(rows.map { $0.key }) }
    func archiveSelection() { perform(.archive, on: selectedMessages()) }
    func unarchiveSelection() { perform(.unarchive, on: selectedMessages()) }
    func deleteSelection() { perform(.trash, on: selectedMessages()) }
    func markReadSelection(_ unread: Bool) { perform(unread ? .unread : .read, on: selectedMessages()) }
    func flagSelection() {
        guard let message = activeMessage() else { return }
        toggleFlag(message)
    }
    func replyActive() {
        guard let message = activeMessage() else { return }
        if let detail, detail.message.key == message.key { composeReply(detail, mode: .reply); return }
        open(message)
        Task { @MainActor in
            for _ in 0..<40 {
                if let detail = self.detail, detail.message.key == message.key { self.composeReply(detail, mode: .reply); return }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }
    func forwardActive() {
        guard let message = activeMessage() else { return }
        if let detail, detail.message.key == message.key { composeReply(detail, mode: .forward); return }
        open(message)
        Task { @MainActor in
            for _ in 0..<40 {
                if let detail = self.detail, detail.message.key == message.key { self.composeReply(detail, mode: .forward); return }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }
    func nextMessage(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let index = activeConversationIndex() ?? -1
        let next = min(rows.count - 1, max(0, index + delta))
        selectedKeys = [rows[next].key]
        open(rows[next], preferLatest: true)
    }

    // MARK: - Fixture data

    func seedFixture() {
        guard messageStore.isEmpty else { return }
        let subjects = ["设计评审：Aurora 导航层级", "本周发布清单", "Re: 合同附件（第 3 版）", "订阅确认 · Northwind Studio",
                        "周五午餐", "Your invoice is ready", "团队周报 42", "Re: 字体授权问题", "新的品牌指南",
                        "欢迎使用 Mail Lite", "客户反馈汇总", "Re: 时间线确认"]
        let senders = ["林知遥", "Northwind Design", "Marta Ruiz", "Zoho Mail", "陈默", "Stripe", "周岚", "Type Foundry", "Brand Team", "Mail Lite", "客户成功组", "Alex Chen"]
        for (index, account) in accounts.enumerated() {
            var folders = [
                MailFolder(id: "500", name: "Inbox", path: "/Inbox", type: "Inbox"),
                MailFolder(id: "501", name: "Drafts", path: "/Drafts", type: "Drafts"),
                MailFolder(id: "502", name: "Sent", path: "/Sent", type: "Sent"),
                MailFolder(id: "503", name: "Snoozed", path: "/Snoozed", type: "Snoozed"),
                MailFolder(id: "504", name: "Trash", path: "/Trash", type: "Trash"),
                MailFolder(id: "505", name: "Spam", path: "/Spam", type: "Spam"),
                MailFolder(id: "506", name: "Studio", path: "/Studio", type: "Folder"),
                MailFolder(id: "507", name: "Receipts", path: "/Receipts", type: "Folder")
            ]
            folders[0].unread = 4 + index * 3
            let context = MailboxSession(accountID: account.id, remoteID: index == 0 ? "101" : "202",
                                         email: account.name,
                                         origin: URL(string: "https://mail.zoho.com")!, folders: folders,
                                         addresses: [account.name])
            sessions[account.id] = context
            foldersByAccount[account.id] = folders
            for item in 0..<26 {
                let date = Date().addingTimeInterval(-Double(item) * 3600 - Double(index) * 900)
                let row: [String: Any] = [
                    "messageId": "\(1000 + item + index * 100)", "folderId": "500",
                    "receivedTime": String(Int(date.timeIntervalSince1970 * 1000)),
                    "subject": subjects[(item + index) % subjects.count],
                    "sender": senders[(item + index * 2) % senders.count],
                    "summary": "这是用于界面验收的本地测试正文，未连接真实邮箱。所有数据仅存在于本次运行的临时目录。",
                    "status": item < 5 ? "0" : "1", "hasAttachment": item % 4 == 0,
                    "threadId": item % 6 == 0 ? "900" : "0",
                    "isPinned": item == 2, "flagid": item % 7 == 0 ? "important" : "flag_not_set"
                ]
                if let message = MailMessage.parse(row, accountID: account.id, remoteID: context.remoteID,
                                                   folderID: "500", origin: context.origin) {
                    messageStore[message.key] = message
                }
            }
        }
        for account in accounts {
            if let context = sessions[account.id] {
                cache.store(context)
            }
        }
        labelsByAccount[accounts[0].id] = [MailLabel(id: "701", name: "设计", color: "#5B6CFF"),
                                           MailLabel(id: "702", name: "待办", color: "#F5A623")]
        labelsByAccount[accounts[1].id] = [MailLabel(id: "703", name: "个人", color: "#22B07D")]
        readyAccounts = accounts.count
        totalAccounts = accounts.count
        rebuildRows()
        status = "本地演示数据 · 不会访问网络"
    }

    private func fixtureSession(_ account: MailAccount) -> MailboxSession? { sessions[account.id] }

    private func fixtureDetail(_ message: MailMessage) -> MailDetail {
        let html = """
        <p>你好，</p><p>这是一封用于界面验证的本地邮件，正文来自内置夹具，不包含任何真实邮件内容。</p>
        <p>新的阅读器使用独立、禁脚本的 WebKit 文档渲染白名单 HTML，外部图片需要显式加载。</p>
        <p>谢谢！<br/>\(message.sender)</p>
        """
        return MailDetail(message: message, from: "\(message.sender) <design@northwind.studio>",
                          to: "mira@aurora.mail", cc: "", replyTo: "", html: html,
                          attachments: message.attachment ? [MailAttachment(id: "1", name: "brief.pdf", size: 248_000, cid: "")] : [],
                          inline: [])
    }
}
