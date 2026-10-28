import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Wire models from the shipped IPA. This does not accept REST upload records.
/// Evidence and remaining coverage are recorded in analysis/ipa-send-chain-20261026.
enum MailOfficialProtocol {
    struct Domains: Equatable {
        let origin: URL
        let upload: URL
        let download: URL?

        static func parse(_ value: Any, origin: URL) throws -> Domains {
            guard Trust.mail(origin), let region = Region.all.first(where: { $0.origin.host == origin.host }),
                  let rows = value as? [Any] else { throw MailFailure.response }
            func endpoint(_ raw: Any?) throws -> URL? {
                guard let raw else { return nil }
                guard let text = raw as? String, !text.isEmpty, text.count < 512,
                      !text.contains("\\"), !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      let url = URL(string: text.contains("://") ? text : "https://" + text),
                      url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
                      let host = url.host?.lowercased(), host.hasSuffix("." + region.domain),
                      url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else { throw MailFailure.response }
                return URL(string: "https://" + host + "/")
            }
            var pairs: [Domains] = []
            for row in rows.compactMap({ $0 as? [String: Any] }) where row["upload"] != nil {
                guard let upload = try endpoint(row["upload"]) else { throw MailFailure.response }
                pairs.append(Domains(origin: origin, upload: upload, download: try endpoint(row["download"])))
            }
            guard let first = pairs.first, pairs.allSatisfy({ $0 == first }) else { throw MailFailure.response }
            return first
        }
    }

    struct UploadedFile: Equatable {
        let name: String
        let path: String
        let store: String
        let imageURL: String?

        /// IPA 035/036: top-level array -> resData -> fP/sN/(url).
        /// REST attachmentPath/storeName objects are intentionally rejected.
        static func parse(_ value: Any, name: String, inline: Bool) throws -> UploadedFile {
            guard let rows = value as? [[String: Any]], rows.count == 1,
                  rows[0]["errorCode"] == nil,
                  let data = rows[0]["resData"] as? [[String: Any]], data.count == 1,
                  data[0]["errorCode"] == nil, data[0]["error"] == nil,
                  let path = data[0]["fP"] as? String, let store = data[0]["sN"] as? String,
                  valid(path, limit: 8192), valid(store, limit: 512),
                  valid(name, limit: 1000), !path.contains(","), !store.contains(",") else { throw MailFailure.response }
            let url = data[0]["url"] as? String
            if inline, url == nil || !valid(url!, limit: 8192) { throw MailFailure.response }
            return UploadedFile(name: name, path: path, store: store, imageURL: url)
        }

        private static func valid(_ text: String, limit: Int) -> Bool {
            !text.isEmpty && text.count <= limit && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    struct Receipt: Equatable {
        let messageID: String
        let changeID: String
        let uuid: String?

        /// IPA 034 requires a usable message ID, not merely HTTP 200.
        static func parse(_ value: Any) throws -> Receipt {
            guard let root = value as? [String: Any], let response = root["response"] as? [String: Any],
                  response["error"] == nil, let success = response["success"] as? [String: Any],
                  let id = Trust.numericID(success["msgid"]), let cid = response["CID"] else { throw MailFailure.response }
            let change: String
            if let text = cid as? String { change = text }
            else if let number = cid as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { change = number.stringValue }
            else { throw MailFailure.response }
            guard !change.isEmpty, change.count <= 256,
                  !change.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MailFailure.response }
            return Receipt(messageID: id, changeID: change, uuid: success["uuid"] as? String)
        }
    }

    static func sendFields(accountID: String, from: String, to: String, cc: String, bcc: String,
                           subject: String, html: String, files: [UploadedFile], receipt: Bool,
                           priority: Int, inReplyTo: String?, references: String?) throws -> [String: String] {
        guard Trust.numericID(accountID) != nil, [1, 3, 5].contains(priority),
              MailAddresses.validated(to)?.isEmpty == false,
              MailAddresses.validated(cc) != nil, MailAddresses.validated(bcc) != nil else { throw MailFailure.rejected }
        var fields = ["accountId": accountID, "fromAddress": from, "toAddress": to, "ccAddress": cc, "bccAddress": bcc,
                      "subject": subject, "text": html, "plainText": try plainText(html),
                      "mailFormat": "2", "encoding": "UTF-8", "mode": "compose", "sendImm": "true",
                      "askReceipt": receipt ? "yes" : "no"]
        if priority != 3 { fields["priority"] = String(priority) }
        fields.merge(attachmentFields(files)) { _, new in new }
        if let parent = inReplyTo {
            guard let safe = MailAddresses.safeHeaderValue(parent) else { throw MailFailure.response }
            fields["inReplyTo"] = safe
            var chain = (references ?? "").replacingOccurrences(of: "\r?\n[ \t]+", with: " ", options: .regularExpression)
            guard !chain.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MailFailure.response }
            if !chain.split(whereSeparator: { $0.isWhitespace }).contains(Substring(safe)) {
                chain = chain.isEmpty ? safe : chain + " " + safe
            }
            // IPA 014 trims the RFC References header, never the message body.
            if (chain as NSString).length > 4999 {
                chain = (chain as NSString).substring(from: (chain as NSString).length - 4999)
                if let start = chain.firstIndex(of: "<") { chain = String(chain[start...]) }
                else { chain = safe }
            }
            fields["refHeader"] = chain
        }
        return fields
    }

    /// IPA 006 joins three parallel lists. Only filename commas are encoded;
    /// existing remote attachment entities (attEntObj) are a separate model.
    static func attachmentFields(_ files: [UploadedFile]) -> [String: String] {
        guard !files.isEmpty else { return [:] }
        return ["attachName": files.map { $0.name.replacingOccurrences(of: ",", with: "%2C") }.joined(separator: ","),
                "filePath": files.map(\.path).joined(separator: ","),
                "storeName": files.map(\.store).joined(separator: ",")]
    }

    static func imageURL(_ file: UploadedFile, context: MailboxSession) throws -> URL {
        guard Trust.mail(context.origin) else {
            throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                stage: "context.origin", failedChecks: ["origin-untrusted:\(context.origin)"], requestBytes: 0))
        }
        guard let raw = file.imageURL, !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                stage: "raw-url", failedChecks: ["raw-invalid:\(file.imageURL ?? "nil")"], requestBytes: 0))
        }
        let entitiesRaw = Trust.entities(raw)
        guard let resolvedURL = URL(string: entitiesRaw, relativeTo: context.origin)?.absoluteURL,
              var parts = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: true) else {
            throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                stage: "url-parse", failedChecks: ["components-parse-failed"], requestBytes: 0))
        }
        guard let initial = parts.url, Trust.mail(initial), initial.host == context.origin.host, initial.fragment == nil else {
            throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                stage: "url-host", failedChecks: ["host-mismatch:urlHost=\(parts.host ?? "nil"),ctxHost=\(context.origin.host ?? "nil")"], requestBytes: 0))
        }
        if parts.path == "/zm/ImageSignatureForAPI" { parts.path = "/zm/ImageSignature" }
        if parts.path == "/mail/ImageSignatureForAPI" { parts.path = "/mail/ImageSignature" }
        guard ["/zm/ImageSignature", "/mail/ImageSignature"].contains(parts.path) else {
            throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                stage: "url-path", failedChecks: ["unexpected-path:\(parts.path)"], requestBytes: 0))
        }
        guard let items = parts.queryItems, Set(items.map(\.name)).count == items.count else {
            throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                stage: "queryItems", failedChecks: ["duplicate-or-nil-query"], requestBytes: 0))
        }
        let allowed: Set<String> = ["fileName", "storeName", "accountId", "frm", "fileId"]
        let actualKeys = Set(items.map(\.name))
        guard actualKeys.isSubset(of: allowed) else {
            let unknown = actualKeys.subtracting(allowed).joined(separator: ",")
            throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                stage: "keys-subset", failedChecks: ["unknown-keys:\(unknown)"], requestBytes: 0))
        }
        guard let name = items.first(where: { $0.name == "fileName" })?.value, !name.isEmpty else {
            throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                stage: "name-empty", failedChecks: ["name-empty"], requestBytes: 0))
        }
        let expectedName = (file.path as NSString).lastPathComponent
        guard name == file.name || name == expectedName else {
            throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                stage: "name-match", failedChecks: ["name-diff:got=\(name),exp=\(expectedName)"], requestBytes: 0))
        }
        guard items.first(where: { $0.name == "storeName" })?.value == file.store else {
            let gotStore = items.first(where: { $0.name == "storeName" })?.value ?? "nil"
            throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                stage: "store-match", failedChecks: ["store-diff:got=\(gotStore),exp=\(file.store)"], requestBytes: 0))
        }
        if let accItem = items.first(where: { $0.name == "accountId" }) {
            guard accItem.value == context.remoteID else {
                throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                    stage: "acc-match", failedChecks: ["acc-diff:got=\(accItem.value ?? "nil"),ctx=\(context.remoteID)"], requestBytes: 0))
            }
        }
        if let frmItem = items.first(where: { $0.name == "frm" }) {
            guard frmItem.value == "c" else {
                throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                    stage: "frm-match", failedChecks: ["frm-diff:got=\(frmItem.value ?? "nil")"], requestBytes: 0))
            }
        }
        guard let url = parts.url else { throw MailOfficialFailure.imageReference }
        return url
    }

    struct Multipart {
        let body: Data
        let contentType: String
        /// Actual payload byte range, excluding multipart framing.
        let fileRange: Range<Int>?
    }

    static func multipart(fields: [String: String], file: (name: String, data: Data)? = nil,
                          boundary: String = "MailLite-" + UUID().uuidString) throws -> Multipart {
        guard boundary.range(of: "^[A-Za-z0-9-]{1,100}$", options: .regularExpression) != nil else { throw MailFailure.response }
        var bytes = Data(), fileRange: Range<Int>?
        func append(_ text: String) { bytes.append(contentsOf: text.utf8) }
        func quoted(_ text: String) throws -> String {
            guard !text.isEmpty, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MailFailure.response }
            return text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        for key in fields.keys.sorted() {
            let name = try quoted(key), value = fields[key]!
            guard !value.contains("\r\n--" + boundary) else { throw MailFailure.response }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        if let file {
            let name = try quoted((file.name as NSString).lastPathComponent)
            guard file.data.range(of: Data(("\r\n--" + boundary).utf8)) == nil else { throw MailFailure.response }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"attach\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            let start = bytes.count
            bytes.append(file.data); fileRange = start..<bytes.count
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return Multipart(body: bytes, contentType: "multipart/form-data; boundary=" + boundary, fileRange: fileRange)
    }

    /// Keeps long quote chains off recursive text-cleaning paths.
    static func plainText(_ html: String) throws -> String {
        guard html.utf8.count <= MailBodyPolicy.maximumBytes, !html.contains("\0"),
              html.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let doc = MailHTML.parsed(html),
              let root = doc.rootElement() else { throw MailFailure.response }
        let ignored: Set<String> = ["script", "style", "head", "noscript", "template"]
        let blocks: Set<String> = ["p", "div", "tr", "blockquote", "pre", "li", "section"]
        var pending: [(XMLNode, Int, Bool)] = [(root, 0, false)], parts: [String] = []
        var count = 0
        while let (node, depth, closing) = pending.popLast() {
            if closing { parts.append("\n"); continue }
            count += 1
            guard count <= MailBodyPolicy.maximumNodes, depth <= MailBodyPolicy.maximumDepth else { throw MailFailure.response }
            if node.kind == .text { parts.append(node.stringValue ?? ""); continue }
            let tag = (node.name ?? "").lowercased()
            if ignored.contains(tag) { continue }
            if tag == "br" { parts.append("\n") }
            if blocks.contains(tag) { pending.append((node, depth, true)) }
            for child in (node.children ?? []).reversed() { pending.append((child, depth + 1, false)) }
        }
        return parts.joined()
    }
}
