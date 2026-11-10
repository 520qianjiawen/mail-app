import Foundation

private final class MailTrackingMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw MailTrackingFailure.response }
            let (status, json) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor func runMailTrackingTests(_ require: @escaping (Bool, String) -> Void) async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-tracking-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory); MailTrackingMockProtocol.handler = nil }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MailTrackingMockProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let api = MailTrackingAPI(session: session)
    let connection = MailTrackingConnection(serverURL: "https://track.example.test", apiKey: String(repeating: "k", count: 32))
    let context = MailboxSession(accountID: "A", remoteID: "100", email: "owner@example.test", origin: URL(string: "https://mail.zoho.com")!, folders: [], addresses: ["owner@example.test"])
    var registrationCount = 0, unavailable = false, rows: [[String: Any]] = []
    var registeredIDs: [String] = [], hosts: [String] = []
    let image = "https://track.example.test/p/" + String(repeating: "a", count: 43) + ".png"
    MailTrackingMockProtocol.handler = { request in
        hosts.append(request.url?.host ?? "")
        require(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + connection.apiKey, "own service uses private bearer authentication")
        switch request.url!.path {
        case "/api/v1/status": return (200, ["data": ["protocol": "mail-lite-tracking/1"]])
        case "/api/v1/events":
            return (200, ["data": ["events": rows, "nextCursor": 99, "hasMore": false]])
        case "/api/v1/messages":
            require(request.httpMethod == "POST", "registration uses the owned message endpoint")
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; body.append(contentsOf: bytes.prefix(n)) }
            }
            let id = (try JSONSerialization.jsonObject(with: body) as! [String: Any])["id"] as! String
            registeredIDs.append(id); registrationCount += 1
            if unavailable { return (503, [:]) }
            return (200, ["data": ["id": id, "pixelURL": image]])
        default: throw MailTrackingFailure.response
        }
    }
    do {
        require(connection.valid && !MailTrackingConnection(serverURL: "http://track.example.test", apiKey: connection.apiKey).valid, "public service requires HTTPS")
        require(MailTrackingConnection(serverURL: "http://127.0.0.1:8787", apiKey: connection.apiKey).valid, "loopback is permitted for isolated integration tests")
        require(!MailTrackingConnection(serverURL: "https://user@track.example.test/path", apiKey: connection.apiKey).valid, "service URL rejects credentials and arbitrary paths")
        require(!MailTrackingConnection(serverURL: connection.serverURL, apiKey: "short").valid, "short API secrets are rejected")
        let tid = MailTrackingHTML.tid()
        require(UUID(uuidString: tid) != nil, "own identifiers are random UUIDs rather than third-party member IDs")
        let fragment = try MailTrackingHTML.fragment(pixelURL: image, connection: connection, tid: tid)
        require(fragment.contains("width=\"1\"") && !fragment.contains(connection.apiKey), "tracking pixel contains no API key")
        let body = MailTrackingHTML.append(fragment, to: "<html><body><p>fixture</p></BODY></html>", tid: tid)
        require(MailTrackingHTML.append(fragment, to: body, tid: tid) == body, "pixel insertion is idempotent")
        do { _ = try MailTrackingHTML.fragment(pixelURL: "https://other.example.test/p/" + String(repeating: "a", count: 43) + ".png", connection: connection, tid: tid); require(false, "foreign service pixel rejected") }
        catch { require(true, "foreign service pixel rejected") }
        let fields = try MailOfficialProtocol.sendFields(accountID: "100", from: "owner@example.test", to: "recipient@example.test", cc: "", bcc: "", subject: "fixture", html: body, files: [], receipt: false, priority: 3, inReplyTo: nil, references: nil)
        require(fields["text"]?.contains(image) == true && !(fields["plainText"] ?? "").contains(image), "Zoho HTML send retains the owned pixel without changing plain text")
        let controller = MailTrackingController(directory: directory, fixture: true, api: api)
        await controller.connect(connection)
        require(controller.connected, "connection validates the independent protocol")
        var item = OutboxItem(accountID: "A", from: "owner@example.test", to: "recipient@example.test"); item.trackingEnabled = true
        let first = try await controller.prepare(item, context: context)
        let retry = try await controller.prepare(item, context: context)
        require(first.tid == retry.tid && registrationCount == 1, "send retries reuse the already registered identity")
        require(MailTrackingStore(directory: directory).value.records.first?.tid == first.tid, "identity survives process restart")
        func row(_ id: Int, _ tid: String, counted: Bool) -> [String: Any] {
            ["id": id, "messageID": tid, "occurredAt": "2026-11-02T03:00:00.123Z", "sourceHash": "source-hash", "platform": "iOS", "agent": "AppleWebKit", "counted": counted]
        }
        rows = [row(1, first.tid, counted: true), row(2, first.tid, counted: false), row(3, first.tid, counted: true), row(99, "foreign", counted: true)]
        await controller.poll()
        require(controller.records.first?.count == 2, "two valid opens and a filtered duplicate produce two opens")
        await controller.poll()
        require(controller.records.first?.count == 2 && controller.store.value.cursors[connection.serviceID] == 99, "cursor polling does not recount and isolates unrelated messages")
        var many = first
        many.merge((1...110).map { MailTrackingEvent(id: Int64($0), userPK: Int64($0), tid: first.tid, rid: "1", date: Date(), ipHash: "hash", platform: "iOS", agent: "WebKit", robot: 0, clickURL: "", country: "", counted: true) })
        require(many.count == 110, "the independent implementation has no 99-open service cap")
        controller.acknowledged(item.id, messageID: "900")
        let message = MailMessage(accountID: "A", remoteID: "100", folderID: "sent", id: "900", origin: context.origin, subject: "fixture", sender: "owner", preview: "", date: Date(), attachment: false, unread: false)
        require(controller.record(for: message)?.count == 2, "exact sent-message identity associates the visible count")
        let clean = MailTrackingHTML.withoutOwnedPixels(body, records: [MailTrackingRecord(id: "owned", memberUID: connection.serviceID, tid: tid, accountID: "A", remoteID: "100", originHost: "mail.zoho.com", subject: "fixture", recipient: "recipient@example.test", fragment: fragment)])
        require(!clean.contains(image), "own sent-message reading and quotations cannot trigger self opens")
        let pending = OutboxItem(accountID: "A", from: "owner@example.test", to: "recipient@example.test")
        unavailable = true
        do { _ = try await controller.prepare(pending, context: context); require(false, "service failure blocks tracked send") }
        catch { require(true, "service failure blocks tracked send") }
        let pendingTid = registeredIDs.last!
        unavailable = false
        let recovered = try await controller.prepare(pending, context: context)
        require(recovered.tid == pendingTid && registeredIDs.suffix(2).allSatisfy { $0 == pendingTid }, "uncertain registration retries the same idempotent identifier")
        controller.disconnect()
        require(!controller.connected && controller.records.first?.count == 2, "disconnect keeps historical evidence")
        do { _ = try await controller.prepare(item, context: context); require(false, "disconnected tracked send blocked") }
        catch { require(true, "disconnected tracked send blocked") }
        require(hosts.allSatisfy { $0 == "track.example.test" }, "no service request goes to DreamMail or any third-party tracking host")
        var draft = MailDraft(accountID: "A", from: "owner@example.test", mode: "new"); draft.trackingEnabled = true
        require(try JSONDecoder().decode(MailDraft.self, from: JSONEncoder().encode(draft)).trackingEnabled == true, "tracking opt-in persists in local drafts")
        let metadata = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("mail-tracking.json").path)
        require((metadata[.posixPermissions] as? NSNumber)?.intValue == 0o600, "local tracking history is private")
    } catch { require(false, "independent tracking setup: \(error.localizedDescription)") }
}
