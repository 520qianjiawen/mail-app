import Foundation

/// In-memory per-account FIFO. Enqueue is synchronous on MainActor, so UI
/// invocation order is established before any asynchronous task starts.
/// Different accounts have independent tails. This is not an offline journal.
@MainActor final class MailMutationQueue {
    private struct Tail {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var tails: [String: Tail] = [:]
    private var accountEpochs: [String: UInt64] = [:]
    private var lifetime: UInt64 = 0
    private var retiredTasks: [Tail] = []

    @discardableResult
    func enqueue(accountID: String, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tails[accountID]?.task
        let accountEpoch = accountEpochs[accountID, default: 0]
        let queueLifetime = lifetime
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.lifetime == queueLifetime,
                  self.accountEpochs[accountID, default: 0] == accountEpoch,
                  !Task.isCancelled else { return }
            await operation()
            if self.tails[accountID]?.id == id { self.tails[accountID] = nil }
        }
        tails[accountID] = Tail(id: id, task: task)
        return task
    }

    func invalidate(accountID: String) {
        accountEpochs[accountID, default: 0] &+= 1
        if let tail = tails[accountID] {
            tail.task.cancel()
            retire(tail)
        }
        tails[accountID] = nil
    }

    func stop() {
        lifetime &+= 1
        for tail in tails.values { tail.task.cancel(); retire(tail) }
        tails.removeAll()
    }

    private func retire(_ tail: Tail) {
        retiredTasks.append(tail)
        Task { @MainActor [weak self] in
            await tail.task.value
            self?.retiredTasks.removeAll { $0.id == tail.id }
        }
    }

    func waitUntilIdle() async {
        // Tests enqueue all intended work before calling this method. New UI
        // work after this snapshot is a separate intent, not a global barrier.
        let retired = retiredTasks
        let tasks = tails.values.map(\.task) + retired.map(\.task)
        for task in tasks { await task.value }
        let completedIDs = Set(retired.map(\.id))
        retiredTasks.removeAll { completedIDs.contains($0.id) }
    }
}
