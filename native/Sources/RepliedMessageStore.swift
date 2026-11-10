import Foundation

/// Persistent store for locally-marked replied/forwarded messages.
/// Fully independent of Zoho server status2 field — survives cache clears, API refreshes, and app restarts.
/// Tracks by key, numeric message ID, and thread ID to guarantee matching across view scopes.
final class RepliedMessageStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var repliedKeys: Set<String>
    private var repliedIDs: Set<String>
    private var repliedThreadIDs: Set<String>
    private var forwardedKeys: Set<String>
    private var forwardedIDs: Set<String>

    init(directory: URL) {
        url = directory.appendingPathComponent("replied-messages.json")
        let data = (try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: [String]]
        } ?? [:]
        repliedKeys      = Set(data["repliedKeys"]      ?? data["replied"] ?? [])
        repliedIDs       = Set(data["repliedIDs"]       ?? [])
        repliedThreadIDs = Set(data["repliedThreadIDs"] ?? [])
        forwardedKeys    = Set(data["forwardedKeys"]    ?? data["forwarded"] ?? [])
        forwardedIDs     = Set(data["forwardedIDs"]     ?? [])
        for key in forwardedKeys {
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 4, let identity = Self.forwardIdentity(key: key, id: String(parts[3])) {
                forwardedIDs.insert(identity)
            }
        }
    }

    /// Seed replied status from outbox sent history (e.g. at app launch).
    func seedFromOutbox(_ items: [OutboxItem]) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for item in items where item.state == "sent" {
            if let source = item.forwardOf {
                if forwardedKeys.insert(source.key).inserted { changed = true }
                if let identity = Self.forwardIdentity(key: source.key, id: source.id), forwardedIDs.insert(identity).inserted { changed = true }
            }
            if let replyID = item.replyToMessageID, !replyID.isEmpty {
                if repliedIDs.insert(replyID).inserted { changed = true }
            }
            if let source = item.replySource {
                if repliedKeys.insert(source.key).inserted { changed = true }
                if repliedIDs.insert(source.id).inserted { changed = true }
                if let tid = source.threadID, !tid.isEmpty {
                    if repliedThreadIDs.insert(tid).inserted { changed = true }
                }
            }
        }
        if changed { saveLocked() }
    }

    func isReplied(key: String, id: String, threadID: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if repliedKeys.contains(key) { return true }
        if repliedIDs.contains(id) { return true }
        if let tid = threadID, repliedThreadIDs.contains(tid) { return true }
        return false
    }

    func isForwarded(key: String, id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return forwardedKeys.contains(key) || Self.forwardIdentity(key: key, id: id).map { forwardedIDs.contains($0) } == true
    }

    func markReplied(key: String, id: String, threadID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        if repliedKeys.insert(key).inserted { changed = true }
        if repliedIDs.insert(id).inserted { changed = true }
        if let tid = threadID, !tid.isEmpty {
            if repliedThreadIDs.insert(tid).inserted { changed = true }
        }
        if changed { saveLocked() }
    }

    func markForwarded(key: String, id: String) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        if forwardedKeys.insert(key).inserted { changed = true }
        if let identity = Self.forwardIdentity(key: key, id: id), forwardedIDs.insert(identity).inserted { changed = true }
        if changed { saveLocked() }
    }

    /// Apply local store status to a message if server status2 is nil or "0".
    func applyStatus(to message: inout MailMessage) {
        let r = isReplied(key: message.key, id: message.id, threadID: message.threadID)
        let f = isForwarded(key: message.key, id: message.id)
        if r || f {
            let replied = r || message.replied
            let forwarded = f || message.forwarded
            message.status2 = replied && forwarded ? "3" : replied ? "1" : "2"
        }
    }

    // MARK: - Private

    private static func forwardIdentity(key: String, id: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, !parts[0].isEmpty, !parts[1].isEmpty, !id.isEmpty else { return nil }
        return "\(parts[0]):\(parts[1]):\(id)"
    }

    private func saveLocked() {
        let dict: [String: [String]] = [
            "repliedKeys":      Array(repliedKeys),
            "repliedIDs":       Array(repliedIDs),
            "repliedThreadIDs": Array(repliedThreadIDs),
            "forwardedKeys":    Array(forwardedKeys),
            "forwardedIDs":     Array(forwardedIDs)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
