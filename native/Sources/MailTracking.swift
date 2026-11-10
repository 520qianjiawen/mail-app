import Foundation
import CryptoKit

enum MailTrackingFailure: LocalizedError {
    case disconnected, response, authentication, quota, pending, storage, connection
    var errorDescription: String? {
        switch self {
        case .disconnected: return "请先在设置的邮件追踪中配置自己的追踪服务。"
        case .response: return "追踪服务未返回有效结果，邮件尚未发送。"
        case .authentication: return "追踪服务密钥无效，请重新配置连接。"
        case .quota: return "追踪服务拒绝登记，邮件尚未发送。"
        case .pending: return "追踪记录尚未确认，请检查服务连接后重试。"
        case .storage: return "追踪记录保存失败，邮件尚未发送。"
        case .connection: return "无法连接自己的追踪服务，请检查网络后刷新。"
        }
    }
}

struct MailTrackingConnection: Codable, Equatable, Sendable {
    var serverURL: String
    var apiKey: String
    var origin: URL? {
        guard var url = URLComponents(string: serverURL), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else { return nil }
        url.scheme = scheme; url.host = host; url.path = ""
        return url.url
    }
    var valid: Bool {
        origin != nil && apiKey.utf8.count >= 32 && apiKey.utf8.count <= 512 &&
        !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    var serviceID: String { origin?.absoluteString ?? "" }
}

struct MailTrackingEvent: Codable, Equatable, Sendable, Identifiable {
    var id: Int64
    var userPK: Int64
    var tid: String
    var rid: String
    var date: Date
    var ipHash: String
    var platform: String
    var agent: String
    var robot: Int
    var clickURL: String
    var country: String
    var counted: Bool? = nil
    var valid: Bool { counted ?? (!platform.isEmpty && platform.lowercased() != "unknown" && !agent.isEmpty && robot != 2) }
    static func parse(_ value: [String: Any]) -> Self? {
        guard let id = value["id"] as? NSNumber, id.int64Value > 0,
              let tid = value["messageID"] as? String, !tid.isEmpty,
              let stamp = value["occurredAt"] as? String, let counted = value["counted"] as? Bool else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { return nil }
        return Self(id: id.int64Value, userPK: id.int64Value, tid: tid, rid: "1", date: date,
            ipHash: value["sourceHash"] as? String ?? "", platform: value["platform"] as? String ?? "",
            agent: value["agent"] as? String ?? "", robot: counted ? 0 : 2, clickURL: "", country: "", counted: counted)
    }

}

struct MailTrackingRecord: Codable, Sendable, Identifiable {
    var id: String                         // durable outbox ID
    var memberUID: String // legacy storage key; value is own service origin
    var tid: String
    var accountID: String
    var remoteID: String
    var originHost: String
    var subject: String
    var recipient: String
    var createdAt: Date = Date()
    var registration: String = "prepared" // prepared / requesting / ready / refused
    var fragment: String? = nil
    var sentMessageID: String? = nil
    var sentAt: Date? = nil
    var events: [MailTrackingEvent] = []
    var opens: [MailTrackingEvent] { events.filter { $0.valid && $0.clickURL.isEmpty } }
    var count: Int { opens.count }
    var latest: Date? { opens.map(\.date).max() }
    var label: String { count > 0 ? "已读 \(count) 次" : "追踪中" }
    mutating func merge(_ incoming: [MailTrackingEvent]) {
        // The owned service assigns stable event IDs and applies the short
        // interval/bot filters once. Polling/restarts must not recount events.
        var known = Set(events.map(\.id))
        for event in incoming where event.tid == tid && event.rid == "1" {
            if known.insert(event.id).inserted { events.append(event) }
        }
    }

    func matches(_ message: MailMessage) -> Bool {
        sentMessageID == message.id && accountID == message.accountID && remoteID == message.remoteID && originHost == message.origin.host
    }
}

struct MailTrackingDocument: Codable {
    var records: [MailTrackingRecord] = []
    var cursors: [String: Int64] = [:]
    var defaultEnabled: Bool = false
}

@MainActor final class MailTrackingStore {
    private let file: URL
    private(set) var value = MailTrackingDocument()
    private(set) var failed = false
    init(directory: URL) {
        file = directory.appendingPathComponent("mail-tracking.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { value = try JSONDecoder().decode(MailTrackingDocument.self, from: Data(contentsOf: file)) }
            catch { failed = true }
        }
    }
    func commit(_ next: MailTrackingDocument) throws {
        guard !failed else { throw MailTrackingFailure.storage }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forWritingTo: file)
            do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
            value = next
        } catch { throw MailTrackingFailure.storage }
    }
    func save(_ record: MailTrackingRecord) throws {
        var next = value
        if let i = next.records.firstIndex(where: { $0.id == record.id }) { next.records[i] = record }
        else { next.records.append(record) }
        try commit(next)
    }
}

enum MailTrackingHTML {
    static func tid() -> String { UUID().uuidString.lowercased() }
    static func fragment(pixelURL: String, connection: MailTrackingConnection, tid: String) throws -> String {
        guard let origin = connection.origin, let url = URL(string: pixelURL),
              url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: "^/p/[A-Za-z0-9_-]{40,96}\\.png$", options: .regularExpression) != nil else { throw MailTrackingFailure.response }
        return "<img data-mail-lite-track=\"\(tid)\" src=\"\(MailHTML.escape(url.absoluteString))\" style=\"border:0;width:1px;height:1px;overflow:hidden;\" alt=\"\" width=\"1\" height=\"1\" />"
    }
    static func append(_ fragment: String, to html: String, tid: String) -> String {
        if html.contains("data-mail-lite-track=\"\(tid)\"") { return html }
        if let body = html.range(of: "</body", options: .caseInsensitive) {
            var result = html; result.insert(contentsOf: fragment, at: body.lowerBound); return result
        }
        return html + fragment
    }
    static func withoutOwnedPixels(_ html: String, records: [MailTrackingRecord]) -> String {
        let fragments = records.compactMap(\.fragment)
        guard !fragments.isEmpty else { return html }
        let pattern = #"<(?:img|a)\b[^>]*\b(?:src|href)\s*=\s*["']([^"']+)["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return html }
        let urls = Set(fragments.flatMap { value in
            regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match -> String? in
                Range(match.range(at: 1), in: value).map { Trust.entities(String(value[$0])) }
            }
        })
        var result = html
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let source = Range(match.range(at: 1), in: html), urls.contains(Trust.entities(String(html[source]))),
                  let full = Range(match.range, in: result) else { continue }
            // Removing an opening empty anchor is harmless; its inert empty
            // children/closing tag are left to the existing HTML sanitizer.
            result.removeSubrange(full)
        }
        return result
    }
}

final class MailTrackingAPI: @unchecked Sendable {
    let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: config, delegate: NoTrackingRedirect(), delegateQueue: nil)
    }
    func request(_ path: String, fields: [String: Any]? = nil, query: [URLQueryItem] = [], connection: MailTrackingConnection) async throws -> [String: Any] {
        guard connection.valid, let origin = connection.origin else { throw MailTrackingFailure.authentication }
        guard ["api/v1/status", "api/v1/messages", "api/v1/events"].contains(path) else { throw MailTrackingFailure.response }
        var parts = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!)
        request.httpMethod = fields == nil ? "GET" : "POST"
        request.setValue("Bearer " + connection.apiKey, forHTTPHeaderField: "Authorization")
        if let fields {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MailTrackingFailure.connection }
        guard let http = response as? HTTPURLResponse else { throw MailTrackingFailure.response }
        if [401, 403].contains(http.statusCode) { throw MailTrackingFailure.authentication }
        guard http.statusCode == 200, data.count <= 8 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["data"] as? [String: Any] else { throw MailTrackingFailure.response }
        return result
    }
    func validate(_ connection: MailTrackingConnection) async throws {
        let result = try await request("api/v1/status", connection: connection)
        guard result["protocol"] as? String == "mail-lite-tracking/1" else { throw MailTrackingFailure.response }
    }
    func logs(after cursor: Int64, connection: MailTrackingConnection) async throws -> ([MailTrackingEvent], Int64, Bool) {
        let result = try await request("api/v1/events", query: [.init(name: "after", value: String(cursor)), .init(name: "limit", value: "2000")], connection: connection)
        guard let rows = result["events"] as? [[String: Any]], let next = result["nextCursor"] as? NSNumber,
              next.int64Value >= cursor, let more = result["hasMore"] as? Bool else { throw MailTrackingFailure.response }
        let events = rows.compactMap(MailTrackingEvent.parse)
        guard events.count == rows.count else { throw MailTrackingFailure.response }
        return (events, next.int64Value, more)
    }
    func register(tid: String, connection: MailTrackingConnection) async throws -> String {
        let result = try await request("api/v1/messages", fields: ["id": tid], connection: connection)
        guard result["id"] as? String == tid, let image = result["pixelURL"] as? String else { throw MailTrackingFailure.response }
        return try MailTrackingHTML.fragment(pixelURL: image, connection: connection, tid: tid)
    }
}

private final class NoTrackingRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
