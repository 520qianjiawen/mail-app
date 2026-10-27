import Foundation

@MainActor func runMailSendRepairTests(_ require: (Bool, String) -> Void) async {
    await runMailOfficialProtocolTests(require)
    let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5WQAAAAASUVORK5CYII="
    let context = MailboxSession(accountID: "fixture", remoteID: "100", email: "own@example.test",
        origin: URL(string: "https://mail.zoho.com")!, folders: [], addresses: ["own@example.test"])
    func response(_ name: String = "uploaded.png") -> [String: String] {
        ["storeName": "53862395", "attachmentName": name, "attachmentPath": "/compose/" + name,
         "url": "/zm/ImageSignature?fileName=\(name)&accountId=100&storeName=53862395&frm=c"]
    }
    do {
        let original = "<p style='color:#007aff'>保持正文 &amp; 格式</p><img src='\(png)' width='20'>" +
            "<blockquote><img src='\(png)' alt='quoted'><p>quote-end</p></blockquote>" +
            "<img src='https://example.test/logo.png'>"
        let prepared = try MailInlineImageSend.prepare(original)
        var uploads = 0
        let wire = try await MailInlineImageSend.transport(prepared, context: context) { data, name in
            uploads += 1
            require(data == (try? MailInlineImageSend.decodeImage(png)), "upload receives exact original image bytes")
            require(name.hasSuffix(".png"), "upload keeps a MIME-appropriate file extension")
            return response()
        }
        require(uploads == 1 && wire.attachments.count == 1, "repeated inline content uploads once and yields one documented attachment descriptor")
        require(!wire.html.contains("data:image") && wire.html.components(separatedBy: "/zm/ImageSignature?").count == 3,
                "each real image node receives the provider-returned URL")
        require(wire.html.contains("quote-end") && wire.html.contains("color:#007aff") && wire.html.contains("https://example.test/logo.png"),
                "transport preserves body, quote, formatting and unrelated HTTPS images")
        require(prepared.html == original && prepared.html.contains(png), "wire conversion never mutates the durable self-contained draft")
        require(wire.attachments[0]["url"] == nil && Set(wire.attachments[0].keys) == Set(["storeName", "attachmentName", "attachmentPath"]),
                "attachment payload contains documented upload descriptor fields only")
        var retries = 0
        _ = try await MailInlineImageSend.transport(prepared, context: context) { _, _ in retries += 1; return response("retry.png") }
        require(retries == 1, "retry builds fresh provider references from the retained original")

        // Zoho real-world response returns HTML entity &amp; in the URL query string
        var entityResponse = response("entity.png")
        entityResponse["url"] = entityResponse["url"]!.replacingOccurrences(of: "&", with: "&amp;")
        let entityURL = try MailInlineImageSend.uploadedURL(entityResponse, context: context)
        require(entityURL.path == "/zm/ImageSignature", "HTML entity encoded url in upload response is accepted and parsed")

        var foreign = response(); foreign["url"] = foreign["url"]!.replacingOccurrences(of: "accountId=100", with: "accountId=200")
        var evil = response(); evil["url"] = "https://evil.example" + evil["url"]!
        var wrongFile = response(); wrongFile["attachmentName"] = "wrong.png"
        var duplicate = response(); duplicate["url"]! += "&accountId=100"
        var wrongStore = response(); wrongStore["storeName"] = "other"
        for (label, value) in [("foreign account", foreign), ("external host", evil), ("mismatched file", wrongFile), ("duplicate query keys", duplicate), ("mismatched store", wrongStore), ("missing response", [:])] {
            do { _ = try MailInlineImageSend.uploadedURL(value, context: context); require(false, "reject \(label)") }
            catch { require(error is MailUploadResponseFailure, "reject \(label)") }
        }
        let api = MailAPI()
        let arrayFailure = MailAPI.uploadShapeFailure([["storeName": 42, "attachmentPath": "/compose/private-file", "attachmentName": "private-file"]], inline: true, requestBytes: 1024)
        require(arrayFailure.diagnostic.dataShape == "array[1]" && arrayFailure.diagnostic.fieldTypes["storeName"] == "number" && arrayFailure.diagnostic.failedChecks == ["data-object"],
                "upload diagnostics identify real data-container shape and field types without silently accepting another format")
        let missingURL = MailAPI.uploadShapeFailure(["storeName": "fixture", "attachmentPath": "/compose/private-file", "attachmentName": "private-file"], inline: true, requestBytes: 2048)
        require(missingURL.diagnostic.failedChecks == ["url-string"] && missingURL.diagnostic.requestBytes == 2048,
                "upload diagnostics distinguish a missing URL from network failure")
        do { _ = try MailInlineImageSend.uploadedURL(wrongStore, context: context); require(false, "invalid upload URL diagnostics") }
        catch let error as MailUploadResponseFailure {
            require(error.diagnostic.failedChecks.contains("url-store-match"), "upload URL failure reports the exact failing predicate")
        }
        let privateShape = MailUploadDiagnostic(data: ["url": "/zm/ImageSignature?fileName=PRIVATE.png&accountId=PRIVATE_ID&storeName=PRIVATE_STORE&frm=c&token=PRIVATE_TOKEN", "attachmentName": "PRIVATE_NAME", "attachmentPath": "/compose/PRIVATE_PATH", "storeName": "PRIVATE_STORE", "content": "PRIVATE_BODY", "private@example.test": "PRIVATE_MAIL"], stage: "image-url", failedChecks: ["query-key-set"])
        let diagnosticJSON = String(decoding: try JSONEncoder().encode(privateShape), as: UTF8.self)
        require(!diagnosticJSON.contains("PRIVATE_") && !diagnosticJSON.contains("private@example.test") && privateShape.urlQueryKeys?.contains("token") == true,
                "diagnostics retain query key names but exclude every private response value")
        require(MailUploadProgressBridge.count(["loaded": 50, "total": 100], expected: 100, previous: 20) == 50,
                "upload progress accepts actual monotonic byte counts")
        for value: [String: Any] in [["loaded": true, "total": 100], ["loaded": -1, "total": 100], ["loaded": 101, "total": 100], ["loaded": 10, "total": 100], ["loaded": 50, "total": 90]] {
            require(MailUploadProgressBridge.count(value, expected: 100, previous: 20) == nil,
                    "upload progress rejects invalid, backwards or mismatched byte events")
        }
        var display = MailUploadProgress(fileName: "fixture.pdf", fileIndex: 2, fileCount: 3,
            completedBytes: 100, fileBytes: 200, uploadedBytes: 100, totalBytes: 400)
        require(display.fraction == 0.5 && display.label.contains("50%") && display.label.contains("2/3"),
                "batch progress includes completed files and current bytes without resetting percentage")
        display.awaitingSend = true
        require(display.label.contains("正在提交发送") && !display.label.contains("已发送"),
                "finished upload is visibly distinct from an acknowledged send")
        var progressEvents: [Int64] = []
        let progressReceiver = MailUploadProgressBridge(total: 100) { loaded, _ in progressEvents.append(loaded) }
        progressReceiver.receive(50, expected: 100)
        progressReceiver.receive(40, expected: 100)
        progressReceiver.receive(100, expected: 100)
        progressReceiver.close()
        progressReceiver.receive(100, expected: 100)
        require(progressEvents == [50, 100], "native upload receiver ignores delayed, backwards and closed-task events")
        let uploadURL = URL(string: "https://mail.zoho.com/api/accounts/100/messages/attachments?fileName=fixture.png&isInline=true")!
        let cookie = HTTPCookie(properties: [.domain: "mail.zoho.com", .path: "/", .name: "session", .value: "fixture", .secure: "TRUE"])!
        let foreignCookie = HTTPCookie(properties: [.domain: "mail.zoho.eu", .path: "/", .name: "other", .value: "never", .secure: "TRUE"])!
        let uploadRequest = MailAPI.uploadRequest(url: uploadURL, cookies: [cookie, foreignCookie], csrf: "fixture-csrf", userAgent: "fixture-UA")
        require(uploadRequest.httpMethod == "POST" && uploadRequest.value(forHTTPHeaderField: "Cookie") == "session=fixture" &&
                uploadRequest.value(forHTTPHeaderField: "X-ZCSRF-TOKEN") == "zmrcsr=fixture-csrf" &&
                uploadRequest.value(forHTTPHeaderField: "Origin") == "https://mail.zoho.com" &&
                uploadRequest.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream" && !uploadRequest.httpShouldHandleCookies,
                "native upload preserves bare byte body, browser origin and only exact-account scoped credentials")
        require(MailUploadFailure(URLError(.timedOut)).label.contains("-1001"), "upload failure retains actionable native network code")
        let body: [String: Any] = ["status": ["code": 400, "description": "Invalid Input"],
            "data": ["errorCode": "INVALID_INPUT", "parameter": "content", "message": "private@example.test sensitive request body"]]
        var detailed: MailServerRejection?
        do { _ = try api.envelope(JSONSerialization.data(withJSONObject: body), http: 400, detailedErrors: true) }
        catch let error as MailServerRejection { detailed = error }
        require(detailed?.errorCode == "INVALID_INPUT" && detailed?.parameter == "content" && detailed?.definitelyRejected == true,
                "send error retains HTTP status, provider code and known rejected parameter")
        let encoded = try JSONEncoder().encode(detailed)
        require(!String(decoding: encoded, as: UTF8.self).contains("private@example.test") && !String(decoding: encoded, as: UTF8.self).contains("sensitive"),
                "diagnostics do not persist arbitrary server-reflected mail content")
        do { _ = try api.envelope(JSONSerialization.data(withJSONObject: body), http: 400); require(false, "legacy read rejection unchanged") }
        catch { require((error as? MailFailure) == .rejected, "legacy read rejection unchanged") }
        let tooLarge = MailServerRejection(http: 413, body: [:])
        require(tooLarge.reason == "size" && tooLarge.definitelyRejected && tooLarge.label.contains("413"), "413 receives an actionable size diagnosis")
        let internalError = MailServerRejection(http: 500, body: ["status": ["code": 500]])
        require(!internalError.definitelyRejected, "send POST 5xx is uncertain and cannot be retried blindly")
        require(internalError.label.contains("发送结果尚未确认") && !internalError.label.contains("未接受"),
                "server error wording never claims a definite rejection")
        let moreInfoError = MailServerRejection(http: 500, body: ["status": ["code": 500], "data": ["moreInfo": "The input passed is invalid"]])
        require(moreInfoError.reason == "input" && !moreInfoError.definitelyRejected && moreInfoError.responseFields?["data.moreInfo"] == "string",
                "documented moreInfo drives a safe category without changing uncertain 5xx semantics")
        let moreInfoSize = MailServerRejection(http: 500, body: ["data": ["moreInfo": "Maximum message size exceeded: PRIVATE_BODY"]])
        let sizeDiagnosticJSON = String(decoding: try JSONEncoder().encode(moreInfoSize), as: UTF8.self)
        require(moreInfoSize.reason == "size" && !sizeDiagnosticJSON.contains("PRIVATE_BODY"),
                "moreInfo size diagnosis excludes reflected mail content")
        let moreInfoObject = MailServerRejection(http: 500, body: ["data": ["moreInfo": ["message": "Permission not allowed PRIVATE_TOKEN"]]])
        require(moreInfoObject.reason == "policy" && moreInfoObject.responseFields?["data.moreInfo"] == "object",
                "structured moreInfo retains only its type and known error category")
        let requestSummary = try MailSendDiagnostic(body: ["fromAddress": "private@example.test", "content": "<p>PRIVATE_BODY</p>",
            "attachments": [response().filter { $0.key != "url" }, ["storeName": "PRIVATE_STORE", "attachmentPath": "/Mail/PRIVATE_PATH", "attachmentName": "PRIVATE_NAME"]]],
            reply: true, inlineImages: 1, ordinaryAttachments: 1, uploadedBytes: 4096)
        require(requestSummary.operation == "reply" && requestSummary.attachmentDescriptors == 2 && requestSummary.composeDescriptors == 1 && requestSummary.mailDescriptors == 1 && requestSummary.descriptorFieldsValid,
                "send summary captures exact attachment counts and descriptor path kinds")
        let summaryJSON = String(decoding: try JSONEncoder().encode(requestSummary), as: UTF8.self)
        require(!summaryJSON.contains("PRIVATE_") && !summaryJSON.contains("private@example.test") && requestSummary.requestBytes > requestSummary.bodyBytes,
                "send summary excludes content, identity, file and store values")
        let legacyRejection = try JSONDecoder().decode(MailServerRejection.self, from: Data("{\"http\":500,\"statusCode\":500}".utf8))
        require(legacyRejection.responseFields == nil && !legacyRejection.definitelyRejected, "legacy queue server errors remain decodable")
        let state = AppState(fixture: true)
        defer { _ = state.shutdown() }
        let a = state.accounts[0]
        var item = OutboxItem(accountID: a.id, from: "own@example.test", to: "recipient@example.test", html: original)
        item.sendDiagnostic = requestSummary
        state.outboxSendHook = { _ in throw detailed! }
        require(state.outboxStore.enqueue(item), "rejected-send fixture starts from a durable queue")
        await state.sendOutbox(item.id)
        let stored = state.outboxStore.all().first { $0.id == item.id }
        require(stored?.state == "failed" && stored?.serverFailure?.errorCode == "INVALID_INPUT" && stored?.html == original,
                "explicit server rejection persists diagnostics and all draft images")
        require(stored?.sendDiagnostic == requestSummary, "send summary survives durable outbox save and failure")
        var malformedItem = item; malformedItem.id = UUID().uuidString.lowercased()
        state.outboxSendHook = { _ in throw missingURL }
        _ = state.outboxStore.enqueue(malformedItem); await state.sendOutbox(malformedItem.id)
        let malformedStored = state.outboxStore.all().first { $0.id == malformedItem.id }
        require(malformedStored?.uploadDiagnostic?.failedChecks == ["url-string"] && malformedStored?.html == original,
                "upload-shape diagnostic survives in durable queue while retaining original mail")
        item.id = UUID().uuidString.lowercased()
        state.outboxSendHook = { _ in throw internalError }
        _ = state.outboxStore.enqueue(item); await state.sendOutbox(item.id)
        require(state.outboxStore.all().first { $0.id == item.id }?.state == "uncertain", "production outbox keeps a 5xx send result uncertain")
        require(state.accountSessions.isEmpty, "send lifecycle fixtures open no real sessions")

        // Optional read-only validation against an existing failed queue. No
        // AppState, account session, upload, send, queue write or retry is used.
        if let path = ProcessInfo.processInfo.environment["MAIL_LITE_READONLY_FAILED_QUEUE"] {
            let items = try JSONDecoder().decode([OutboxItem].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            for failed in items where failed.state == "failed" && !failed.html.isEmpty {
                let checked = try MailInlineImageSend.prepare(failed.html)
                var count = 0
                let converted = try await MailInlineImageSend.transport(checked, context: context) { _, name in
                    count += 1; return response(name)
                }
                let convertedCheck = try MailInlineImageSend.prepare(converted.html)
                require(count == checked.images.count && converted.html.utf8.count < failed.html.utf8.count &&
                        convertedCheck.imageCount == 0,
                        "read-only failed-body copy converts every inline source without sending or mutating queue")
                require(MailHTML.plainText(converted.html) == MailHTML.plainText(failed.html),
                        "failed-body transport retains all readable original reply and quoted text")
                print("Read-only failed-body conversion: \(failed.html.utf8.count) -> \(converted.html.utf8.count) HTML bytes; \(checked.imageCount) image nodes; \(count) unique image fixtures.")
            }
        }
    } catch { require(false, "send repair setup: \(error)") }
}
