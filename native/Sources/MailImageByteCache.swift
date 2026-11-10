import Foundation

/// Memory-only cache of authenticated image/attachment bytes. The reader already
/// downloads every inline image to display a message; Reply/Forward reuses those
/// bytes instead of downloading each image again. Concurrent requests for the same
/// resource share one in-flight fetch. Nothing is written to disk.
@MainActor final class MailImageByteCache {
    static let maximumEntryBytes = MailBodyPolicy.maximumImageBytes
    private let storage = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var epoch = 0

    init(totalBytes: Int = 128 * 1024 * 1024) {
        storage.totalCostLimit = totalBytes
    }

    func data(for key: String, fetch: @escaping @MainActor () async throws -> Data) async throws -> Data {
        if let hit = storage.object(forKey: key as NSString) { return hit as Data }
        if let running = inFlight[key] { return try await running.value }
        let started = epoch
        let task = Task { @MainActor in try await fetch() }
        inFlight[key] = task
        do {
            let data = try await task.value
            if inFlight[key] == task { inFlight[key] = nil }
            if started == epoch, data.count <= Self.maximumEntryBytes {
                storage.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            }
            return data
        } catch {
            if inFlight[key] == task { inFlight[key] = nil }
            throw error
        }
    }

    /// Account removal drops every cached byte; in-flight results are not stored.
    func removeAll() {
        epoch &+= 1
        inFlight.removeAll()
        storage.removeAllObjects()
    }
}
