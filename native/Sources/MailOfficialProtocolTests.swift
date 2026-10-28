import Foundation

@MainActor func runMailOfficialProtocolTests(_ require: (Bool, String) -> Void) async {
    let origin = URL(string: "https://mail.zoho.com")!
    let context = MailboxSession(accountID: "fixture", remoteID: "100", email: "own@example.test",
        origin: origin, folders: [], addresses: ["own@example.test"])
    func rejected(_ name: String, _ action: () throws -> Void) {
        do { try action(); require(false, name) } catch { require(true, name) }
    }
    do {
        let domains = try MailOfficialProtocol.Domains.parse([1000, ["upload": "zmupload-accl.zoho.com", "download": "zmdownload-accl.zoho.com", "scanExpiryTimeInMins": 30]], origin: origin)
        require(domains.upload.host == "zmupload-accl.zoho.com" && domains.origin == origin,
                "official domain array accepts observed status-prefix shape and binds to mail origin")
        for bad in ["evil.example", "mail.zoho.eu", "user@zmupload.zoho.com", "zmupload.zoho.com:8443", "zmupload.zoho.com/path", "zmupload.zoho.com?token=private", "http://zmupload.zoho.com"] {
            rejected("official upload domain rejects foreign region, userinfo, port, path, query and insecure scheme") {
                _ = try MailOfficialProtocol.Domains.parse([["upload": bad]], origin: origin)
            }
        }
        rejected("official domains never choose one of conflicting upload hosts") {
            _ = try MailOfficialProtocol.Domains.parse([["upload": "one.zoho.com"], ["upload": "two.zoho.com"]], origin: origin)
        }
        let imageURL = "/zm/ImageSignature?fileName=fixture.png&storeName=store&accountId=100&frm=c"
        let inline = try MailOfficialProtocol.UploadedFile.parse([["resData": [["fP": "/compose/fixture.png", "sN": "store", "url": imageURL]]]], name: "original.png", inline: true)
        require(try MailOfficialProtocol.imageURL(inline, context: context).host == origin.host,
                "official inline URL uses its server filename rather than local upload name")
        let imageURLWithFileID = "/zm/ImageSignature?fileName=fixture.png&storeName=store&accountId=100&fileId=123456&frm=c"
        let inlineWithFileID = try MailOfficialProtocol.UploadedFile.parse([["resData": [["fP": "/compose/fixture.png", "sN": "store", "url": imageURLWithFileID]]]], name: "original.png", inline: true)
        require(try MailOfficialProtocol.imageURL(inlineWithFileID, context: context).host == origin.host,
                "official inline URL accepts optional fileId returned by server")
        let hashedPathURL = "/zm/ImageSignature?fileName=upload.png&storeName=store&accountId=100&frm=c"
        let hashedInline = try MailOfficialProtocol.UploadedFile.parse([["resData": [["fP": "/compose/25f5a22965edde6da00b0", "sN": "store", "url": hashedPathURL]]]], name: "upload.png", inline: true)
        require(try MailOfficialProtocol.imageURL(hashedInline, context: context).host == origin.host,
                "official inline URL matches uploaded file name when server returns hashed storage path")
        let attachment = try MailOfficialProtocol.UploadedFile.parse([["resData": [["fP": "/compose/file.mp4", "sN": "other"]]]], name: "测试, video.mp4", inline: false)
        let lists = MailOfficialProtocol.attachmentFields([attachment])
        require(lists["attachName"] == "测试%2C video.mp4" && lists["filePath"] == attachment.path && lists["storeName"] == attachment.store,
                "IPA attachment triples retain parallel order and encode only filename commas")
        rejected("official upload rejects a REST descriptor instead of mixing schemas") {
            _ = try MailOfficialProtocol.UploadedFile.parse(["attachmentPath": "/compose/file", "attachmentName": "file", "storeName": "store"], name: "file", inline: false)
        }
        rejected("official upload requires exactly one file response") {
            _ = try MailOfficialProtocol.UploadedFile.parse([["resData": [["fP": "a", "sN": "s"], ["fP": "b", "sN": "s"]]]], name: "file", inline: false)
        }
        for raw in [imageURL.replacingOccurrences(of: "100", with: "200"), imageURL + "&accountId=100", "https://evil.example" + imageURL,
                    imageURL.replacingOccurrences(of: "storeName=store", with: "storeName=wrong")] {
            let invalid = MailOfficialProtocol.UploadedFile(name: inline.name, path: inline.path, store: inline.store, imageURL: raw)
            rejected("official inline response rejects a foreign account, duplicate key, host or store") {
                _ = try MailOfficialProtocol.imageURL(invalid, context: context)
            }
        }
        let binary = Data([0, 255, 13, 10, 128])
        let multipart = try MailOfficialProtocol.multipart(fields: ["text": "<p>中文 & body</p>", "mailFormat": "2"], file: ("a\".bin", binary), boundary: "fixture-boundary")
        require(multipart.body.subdata(in: multipart.fileRange!) == binary && multipart.contentType == "multipart/form-data; boundary=fixture-boundary",
                "multipart keeps exact file bytes and actual payload range")
        let text = String(decoding: multipart.body, as: UTF8.self)
        require(text.contains("name=\"attach\"; filename=\"a\\\".bin\"") && text.hasSuffix("--fixture-boundary--\r\n") && text.contains("<p>中文 & body</p>"),
                "multipart uses attach file part, UTF-8 values, quoted filenames and terminating CRLF")
        rejected("multipart rejects header injection in filenames") {
            _ = try MailOfficialProtocol.multipart(fields: [:], file: ("evil\r\nInjected: true.bin", binary))
        }
        rejected("multipart rejects boundary injection in field values") {
            _ = try MailOfficialProtocol.multipart(fields: ["text": "x\r\n--fixture-boundary"], boundary: "fixture-boundary")
        }
        let quote = String(repeating: "<blockquote>", count: 600) + "中文 long quote" + String(repeating: "</blockquote>", count: 600)
        let refs = (0..<1000).map { "<reference-\($0)@example.test>" }.joined(separator: " ")
        let fields = try MailOfficialProtocol.sendFields(accountID: "100", from: "own@example.test", to: "other@example.test", cc: "", bcc: "", subject: "fixture",
            html: "<p>new reply</p>" + quote, files: [attachment], receipt: true, priority: 1, inReplyTo: "<parent@example.test>", references: refs)
        require(fields["text"]?.contains("long quote") == true && fields["plainText"]?.contains("中文 long quote") == true,
                "official send keeps long quote body and extracts UTF-8 plain text without recursive cleanup")
        require(fields["mailFormat"] == "2" && fields["mode"] == "compose" && fields["sendImm"] == "true" && fields["askReceipt"] == "yes",
                "official send uses IPA compose fields and format 2")
        require(((fields["refHeader"] ?? "") as NSString).length <= 4999 && fields["refHeader"]?.hasSuffix("<parent@example.test>") == true,
                "official References trimming preserves newest complete parent without limiting body")
        require(fields["attEntObj"] == nil && fields["mymid"] == nil && fields["dmailid"] == nil && fields["attachments"] == nil && fields["content"] == nil,
                "uploaded files never manufacture private remote attachment entities or mix REST fields")
        let receipt = try MailOfficialProtocol.Receipt.parse(["response": ["CID": "change", "success": ["msgid": "900719925474099303", "uuid": "fixture"]]])
        require(receipt.messageID == "900719925474099303", "official receipt keeps exact large message ID")
        require(try MailAPI.sentMessageID(["messageId": "900719925474099303"]) == "900719925474099303", "REST compatibility receipt also requires and preserves a real message ID")
        for bad: Any in [NSNull(), [:], ["success": true], ["messageId": true], [["messageId": "1"], ["messageId": "2"]]] {
            rejected("REST compatibility cannot clear the draft on a missing or ambiguous receipt") { _ = try MailAPI.sentMessageID(bad) }
        }
        for bad: [String: Any] in [["response": ["CID": "change", "success": [:]]], ["status": ["code": 200], "data": ["messageId": "100"]], ["response": ["CID": "change", "success": ["msgid": true]]], ["response": ["success": ["msgid": "100"]]]] {
            rejected("HTTP success without a full official receipt is not an acknowledged send") { _ = try MailOfficialProtocol.Receipt.parse(bad) }
        }
        let api = MailAPI()
        do { _ = try api.officialResponse(Data("{\"response\":{\"error\":{\"code\":\"SERVER_ERROR\"}}}".utf8), http: 500); require(false, "official 500 ambiguity") }
        catch let error as MailServerRejection { require(!error.definitelyRejected, "official POST 500 remains uncertain without an automatic resend") }
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5WQAAAAASUVORK5CYII="
        let original = "<p>body</p><img src='\(png)'><blockquote><img src='\(png)'></blockquote>"
        let prepared = try MailInlineImageSend.prepare(original)
        var uploaded = 0
        let transported = try await MailInlineImageSend.officialTransport(prepared, context: context) { _, _ in uploaded += 1; return inline }
        require(uploaded == 1 && !transported.contains("data:image") && transported.components(separatedBy: "ImageSignature?").count == 3 && prepared.html == original,
                "official inline transfer deduplicates uploads, rewrites both body references and preserves original draft")
        let wire = try MailOfficialProtocol.multipart(fields: fields)
        let diagnostic = MailSendDiagnostic(officialFields: fields, requestBytes: wire.body.count, reply: true, inlineImages: 1, files: [attachment], uploadedBytes: 2048)
        require(diagnostic.protocolKind == "zoho-mail-send-api" && diagnostic.requestBytes == wire.body.count && diagnostic.attachmentDescriptors == 1 && diagnostic.inlineImages == 1,
                "official diagnostics count real multipart bytes and separate ordinary files from body images")
        let shape = MailUploadDiagnostic.official([["resData": [["fP": "/compose/PRIVATE_FILE", "sN": "PRIVATE_STORE", "url": "/zm/ImageSignature?fileName=PRIVATE_FILE&storeName=PRIVATE_STORE&token=PRIVATE_TOKEN"]]]],
            stage: "official-image-url", failedChecks: ["query"])
        let shapeJSON = String(decoding: try JSONEncoder().encode(shape), as: UTF8.self)
        require(shape.fieldTypes["resData.fP"] == "string" && shape.urlQueryKeys?.contains("token") == true,
                "private upload failure retains nested response types and query key names")
        require(!shapeJSON.contains("PRIVATE_"), "private upload diagnostics never retain filenames, identifiers, tokens or query values")
    } catch { require(false, "official protocol fixture threw \(type(of: error))") }
}
