import Foundation
import Combine
import Security

enum MailTrackingKeychain {
    static let service = "local.mail-lite.native.mail-tracking"
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "service"]
    }
    static func load() throws -> MailTrackingConnection? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let connection = try? JSONDecoder().decode(MailTrackingConnection.self, from: data), connection.valid else {
            throw MailTrackingFailure.authentication
        }
        return connection
    }
    static func save(_ connection: MailTrackingConnection) throws {
        guard connection.valid else { throw MailTrackingFailure.authentication }
        let attributes = [kSecValueData as String: try JSONEncoder().encode(connection)]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw MailTrackingFailure.storage }
        var q = query
        q[kSecValueData as String] = attributes[kSecValueData as String]
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw MailTrackingFailure.storage }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MailTrackingFailure.storage }
    }
}

@MainActor final class MailTrackingController: ObservableObject {
    let store: MailTrackingStore
    let api: MailTrackingAPI
    private let fixture: Bool
    private var connection: MailTrackingConnection?
    private var lifetime = UUID()
    private var timer: Timer?
    private var pollTask: Task<Void, Never>?
    private var polling = false
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var refreshing = false
    @Published private(set) var error: String?
    @Published private(set) var records: [MailTrackingRecord] = []
    @Published private(set) var lastRefresh: Date?
    var serverURL: String? { connection?.serverURL }
    var defaultEnabled: Bool { store.value.defaultEnabled }
    var connectionProvider: () async throws -> MailTrackingConnection = { throw MailTrackingFailure.disconnected }
    init(directory: URL, fixture: Bool = false, api: MailTrackingAPI = MailTrackingAPI()) {
        store = MailTrackingStore(directory: directory); self.fixture = fixture; self.api = api
        records = store.value.records
        if store.failed { error = "本机追踪记录无法读取，已暂停追踪，请保留原始数据。" }
        if !fixture {
            do { connection = try MailTrackingKeychain.load(); connected = connection != nil }
            catch { self.error = "无法读取 追踪服务配置，请重新连接。" }
        }
    }
    func start() {
        guard !fixture, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    func stop() {
        lifetime = UUID(); timer?.invalidate(); timer = nil
        pollTask?.cancel(); pollTask = nil
    }
    func connect(_ configuration: MailTrackingConnection? = nil) async {
        guard !connecting else { return }
        connecting = true; error = nil
        let generation = lifetime
        defer { connecting = false }
        do {
            let value: MailTrackingConnection
            if let configuration { value = configuration } else { value = try await connectionProvider() }
            try await api.validate(value)
            guard generation == lifetime, !Task.isCancelled else { return }
            if !fixture { try MailTrackingKeychain.save(value) }
            connection = value; connected = true
            refresh()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "追踪服务连接失败，请检查服务地址和访问密钥。" }
    }
    func disconnect() {
        do {
            if !fixture { try MailTrackingKeychain.remove() }
            lifetime = UUID(); pollTask?.cancel(); connection = nil; connected = false; error = nil
        } catch { self.error = "未能移除 追踪服务配置，请重试。" }
    }
    func setDefaultEnabled(_ value: Bool) {
        do { var next = store.value; next.defaultEnabled = value; try store.commit(next); objectWillChange.send() }
        catch { self.error = error.localizedDescription }
    }
    func record(for message: MailMessage) -> MailTrackingRecord? { records.first { $0.matches(message) } }
    func refresh() {
        guard !fixture, connected, !polling else { return }
        pollTask = Task { await poll() }
    }
    func poll() async {
        guard !polling, let connection else { return }
        polling = true; refreshing = true
        defer { polling = false; refreshing = false }
        let generation = lifetime
        do {
            for _ in 0..<5 {
                let cursor = store.value.cursors[connection.serviceID] ?? 0
                let (events, nextCursor, more) = try await api.logs(after: cursor, connection: connection)
                guard generation == lifetime, !Task.isCancelled else { return }
                var next = store.value
                for i in next.records.indices where next.records[i].memberUID == connection.serviceID {
                    next.records[i].merge(events)
                }
                next.cursors[connection.serviceID] = nextCursor
                try store.commit(next)
                records = next.records
                if !more || nextCursor <= cursor { break }
            }
            error = nil; lastRefresh = Date()
        } catch {
            guard generation == lifetime else { return }
            self.error = error.localizedDescription
            if case MailTrackingFailure.authentication = error { connected = false }
        }
    }
    func prepare(_ item: OutboxItem, context: MailboxSession) async throws -> MailTrackingRecord {
        guard let connection, connected else { throw MailTrackingFailure.disconnected }
        if !fixture && connection.origin?.scheme != "https" { throw MailTrackingFailure.disconnected }
        let generation = lifetime
        var record: MailTrackingRecord
        if let existing = store.value.records.first(where: { $0.id == item.id }) {
            guard existing.memberUID == connection.serviceID, existing.accountID == context.accountID,
                  existing.remoteID == context.remoteID, existing.originHost == context.origin.host else { throw MailTrackingFailure.authentication }
            if existing.registration == "ready", existing.fragment != nil { return existing }
            // Own server registration is idempotent for this persistent TID.
            // A timeout or restart can safely retry it without a second identity.
            record = existing
        } else {
            var tid: String
            repeat { tid = MailTrackingHTML.tid() } while store.value.records.contains(where: { $0.tid == tid })
            record = MailTrackingRecord(id: item.id, memberUID: connection.serviceID, tid: tid,
                accountID: item.accountID, remoteID: context.remoteID, originHost: context.origin.host ?? "",
                subject: item.subject, recipient: item.to)
            try store.save(record)
        }
        record.registration = "requesting"
        try store.save(record); records = store.value.records
        do {
            let fragment = try await api.register(tid: record.tid, connection: connection)
            // Persist the acknowledged idempotent registration before mail IO.
            record.fragment = fragment; record.registration = "ready"
            try store.save(record); records = store.value.records
            guard generation == lifetime, !Task.isCancelled else { throw CancellationError() }
            return record
        } catch MailTrackingFailure.quota {
            record.registration = "refused"; try store.save(record); records = store.value.records
            throw MailTrackingFailure.quota
        } catch MailTrackingFailure.authentication {
            record.registration = "refused"; try store.save(record); records = store.value.records
            connected = false
            throw MailTrackingFailure.authentication
        }
    }
    func acknowledged(_ id: String, messageID: String?) {
        guard var record = store.value.records.first(where: { $0.id == id }) else { return }
        record.sentMessageID = messageID; record.sentAt = Date()
        do { try store.save(record); records = store.value.records }
        catch { self.error = "邮件已发送，但追踪关联保存失败，请保留本机记录并刷新。" }
    }
}
