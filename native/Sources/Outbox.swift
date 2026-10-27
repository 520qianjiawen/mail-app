import Foundation
import Darwin

/// A durable outbox entry. It is written before any network request so an
/// interrupted send can be reconciled instead of silently repeated.
struct OutboxItem: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString.lowercased()
    var draftID: String? = nil
    var serverDraft: MailMessage? = nil
    var cloudDraftIDs: [String]? = nil
    var postStarted: Bool? = nil
    var accountID: String
    var from: String
    /// Frozen at compose-send selection, before the editor flush. Missing legacy
    /// values stay bare; later settings changes never rewrite a queued identity.
    var senderDisplayName: String? = nil
    var to: String
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var html: String = ""
    var replyToMessageID: String? = nil
    var replySource: MailMessage? = nil
    var inReplyTo: String? = nil
    var referencesHeader: String? = nil
    var sentMessageID: String? = nil
    var forwardOf: MailMessage? = nil
    var archiveAfterSend: MailMessage? = nil
    var forwardAttachmentIDs: [String] = []
    var receipt: Bool = false
    var priority: Int = 3
    var scheduledAt: Date? = nil
    var createdAt: Date = Date()
    var state: String = "queued"          // queued | sending | sent | failed | uncertain
    var error: String? = nil
    var serverFailure: MailServerRejection? = nil
    var failureStage: String? = nil
    var uploadDiagnostic: MailUploadDiagnostic? = nil
    var sendDiagnostic: MailSendDiagnostic? = nil
    var attempts: Int = 0
    var label: String = ""
}

final class OutboxStore {
    let directory: URL
    private let file: URL
    private let lock = NSLock()
    private var items: [OutboxItem]
    private var unreadable = false
    private(set) var persistenceError: String?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent("outbox.json")
        items = []
        if FileManager.default.fileExists(atPath: file.path) {
            do { items = try JSONDecoder().decode([OutboxItem].self, from: Data(contentsOf: file)) }
            catch { unreadable = true; persistenceError = "发件箱无法读取，已暂停发送，请保留本机数据后检查。" }
        }
        var recovered = items
        for i in recovered.indices where recovered[i].state == "sending" {
            recovered[i].state = "uncertain"
            recovered[i].error = "上次发送被中断，请先在已发送邮件中核对，避免重复发送。"
        }
        if recovered.contains(where: { $0.state == "uncertain" }) { _ = commit(recovered) }
    }

    func all() -> [OutboxItem] { lock.lock(); defer { lock.unlock() }; return items }

    @discardableResult func enqueue(_ item: OutboxItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !items.contains(where: { $0.id == item.id ||
            (item.draftID != nil && $0.draftID == item.draftID && $0.state != "cancelled") }) else { return false }
        return commit(items + [item])
    }

    @discardableResult func save(_ item: OutboxItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var next = items
        if let index = next.firstIndex(where: { $0.id == item.id }) { next[index] = item } else { next.append(item) }
        return commit(next)
    }

    @discardableResult func update(_ id: String, _ change: (inout OutboxItem) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        var next = items; change(&next[index])
        return commit(next)
    }

    @discardableResult func remove(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard commit(items.filter { $0.id != id }) else { return false }
        try? FileManager.default.removeItem(at: folder(id))
        return true
    }

    /// A request in flight cannot be recalled or safely discarded locally.
    @discardableResult func cancel(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = items.firstIndex(where: { $0.id == id }),
              ["queued", "failed"].contains(items[index].state) else { return false }
        var next = items; next[index].state = "cancelled"; next[index].error = nil
        return commit(next)
    }

    func releaseAttachments(_ id: String) { try? FileManager.default.removeItem(at: folder(id)) }

    static func attachmentName(_ url: URL) -> String {
        let name = url.lastPathComponent
        guard let separator = name.range(of: "__") else { return name }
        return String(name[separator.upperBound...])
    }

    func folder(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }

    func attachmentDirectory(_ id: String) throws -> URL {
        let target = folder(id).appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return target
    }

    /// Copy an attachment next to the queue entry so later edits of the
    /// original file cannot change what is eventually sent.
    func importAttachment(_ source: URL, id: String) throws -> String {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 25 * 1024 * 1024 else { throw MailFailure.response }
        let directory = try attachmentDirectory(id)
        let destination = directory.appendingPathComponent("\(UUID().uuidString.prefix(8))__\(source.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination.path
    }

    func attachments(_ id: String) -> [URL] {
        let directory = folder(id).appendingPathComponent("attachments", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().map { directory.appendingPathComponent($0) }
    }

    private func commit(_ next: [OutboxItem]) -> Bool {
        guard !unreadable else { return false }
        let temporary = directory.appendingPathComponent(".outbox-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let data = try JSONEncoder().encode(next)
            try data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
            guard rename(temporary.path, file.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            items = next; persistenceError = nil
            return true
        } catch {
            persistenceError = "发件箱保存失败，邮件未开始发送。请检查磁盘空间与目录权限。"
            return false
        }
    }
}
