import Foundation

/// A platform-adapted policy, not an imitation of an iOS push subscription.
enum MailSyncEvent {
    case startup, manual, periodic, activation, wake, mutation

    func shouldReconcile(isActive: Bool, notificationsEnabled: Bool) -> Bool {
        switch self {
        case .periodic: return isActive || notificationsEnabled
        default: return true
        }
    }
}

/// Repeated requests coalesce into one following cycle; a running cycle is
/// never cancelled by a timer tick, so later accounts cannot be starved.
@MainActor final class MailSyncScheduler {
    private let cycle: () async -> Void
    private var task: Task<Void, Never>?
    private var cancelledTask: Task<Void, Never>?
    private var pending = false
    private var epoch: UInt64 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var running = false

    init(cycle: @escaping () async -> Void) { self.cycle = cycle }

    func request() {
        pending = true
        guard !running else { return }
        running = true
        let current = epoch
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.pending = false
                await self.cycle()
                guard self.epoch == current, !Task.isCancelled else { return }
            } while self.pending
            self.running = false
            self.task = nil
            self.finishWaiters()
        }
    }

    func stop() {
        epoch &+= 1
        pending = false
        running = false
        task?.cancel()
        cancelledTask = task
        task = nil
        finishWaiters()
    }

    func waitUntilIdle() async {
        if running { await withCheckedContinuation { waiters.append($0) } }
        // Cancellation may not abort an injected or WebKit request instantly.
        // Tests can release that request and await its fenced completion.
        await cancelledTask?.value
    }

    private func finishWaiters() {
        let completed = waiters
        waiters.removeAll()
        for waiter in completed { waiter.resume() }
    }
}

struct MailSyncReplyFence {
    let accountID: String
    let lifetime: UInt64
    let mutationRevision: UInt64
    var observationSerial: UInt64 = 0
}

struct MailSyncSnapshot {
    let context: MailboxSession
    let head: InboxPage
}

/// Narrow remote boundaries needed by synchronization regressions. Supplying
/// these to fixture AppState never constructs an AccountSession or logs in.
@MainActor struct MailSyncHooks {
    var fetchInbox: (MailAccount) async throws -> MailSyncSnapshot
    var performAction: ((MailAction, [MailMessage]) async throws -> Void)? = nil
    var fetchView: ((MailAccount, Scope, ListFilter, Int) async throws -> InboxPage)? = nil
    var fetchDetail: ((MailMessage) async throws -> MailDetail)? = nil
    var fetchThread: ((MailMessage) async throws -> [MailMessage])? = nil
}
