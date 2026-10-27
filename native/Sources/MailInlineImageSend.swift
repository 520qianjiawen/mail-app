import Foundation
import CryptoKit
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Durable editor HTML stays self-contained. Only the transient send copy uses
/// the URLs returned by Zoho's documented isInline upload API, never guessed CIDs.
enum MailInlineImageSend {
    static let maximumBodyBytes = MailBodyPolicy.maximumBytes
    static let maximumImageBytes = MailBodyPolicy.maximumImageBytes

    enum Failure: Error {
        case bodyTooLarge, imageTooLarge, malformedImage, malformedHTML, uploadResponse
        var label: String {
            switch self {
            case .bodyTooLarge: return "正文与内嵌图片合计超过本机处理容量（64 MB），草稿仍保留，请缩减引用内容后重试"
            case .imageTooLarge: return "正文单张图片超过处理容量（25 MB），请改为附件或使用较小图片"
            case .malformedImage: return "正文图片数据不完整，请删除该图片并重新粘贴"
            case .malformedHTML: return "正文图片格式读取失败，请重新编辑后重试"
            case .uploadResponse: return "Zoho 未返回有效的正文图片地址，邮件尚未发送，草稿已保留"
            }
        }
    }
    struct Prepared {
        let html: String
        let imageCount: Int
        let imageBytes: Int
        var images: [Image] = []
    }
    struct Image {
        let sources: [String]
        let data: Data
        let name: String
    }
    struct Transport {
        let html: String
        let attachments: [[String: String]]
    }

    /// Inline uploads have their own official response and body references.
    /// They are not converted to REST `attachments` records.
    @MainActor static func officialTransport(_ prepared: Prepared, context: MailboxSession,
        upload: (Data, String) async throws -> MailOfficialProtocol.UploadedFile) async throws -> String {
        guard !prepared.images.isEmpty else { return prepared.html }
        var replacements: [String: String] = [:]
        for image in prepared.images {
            try Task.checkCancellation()
            let file = try await upload(image.data, image.name)
            try Task.checkCancellation()
            let url: URL
            do { url = try MailOfficialProtocol.imageURL(file, context: context) }
            catch {
                throw MailUploadResponseFailure(diagnostic: .official([["resData": [["fP": file.path, "sN": file.store, "url": file.imageURL ?? ""]]]],
                    stage: "official-image-url", failedChecks: ["origin-account-file-store-query"], requestBytes: image.data.count))
            }
            for source in image.sources { replacements[source] = url.absoluteString }
        }
        guard let html = SignatureHTML.replacingBodyImages(prepared.html, replacements: replacements),
              try prepare(html).imageCount == 0 else { throw Failure.malformedHTML }
        return html
    }

    @MainActor static func transport(_ prepared: Prepared, context: MailboxSession,
                                    upload: (Data, String) async throws -> [String: String]) async throws -> Transport {
        guard !prepared.images.isEmpty else { return Transport(html: prepared.html, attachments: []) }
        var replacements: [String: String] = [:], attachments: [[String: String]] = []
        for image in prepared.images {
            try Task.checkCancellation()
            let result = try await upload(image.data, image.name)
            try Task.checkCancellation()
            let url = try uploadedURL(result, context: context)
            for source in image.sources { replacements[source] = url.absoluteString }
            attachments.append(result.filter { ["storeName", "attachmentName", "attachmentPath"].contains($0.key) })
        }
        guard let html = SignatureHTML.replacingBodyImages(prepared.html, replacements: replacements),
              try prepare(html).imageCount == 0 else { throw Failure.malformedHTML }
        return Transport(html: html, attachments: attachments)
    }

    static func uploadedURL(_ result: [String: String], context: MailboxSession) throws -> URL {
        var failed: [String] = []
        func check(_ code: String, _ valid: Bool) { if !valid { failed.append(code) } }
        check("account-context", Trust.mail(context.origin) && Trust.numericID(context.remoteID) != nil)
        let raw = result["url"] ?? ""
        check("url-present", result["url"] != nil)
        check("url-text", raw.count <= 8192 && !raw.contains("\\") &&
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        let decoded = Trust.entities(raw)
        let url = URL(string: decoded, relativeTo: context.origin)?.absoluteURL
        check("url-parse", url != nil)
        check("url-trusted-origin", Trust.mail(url) && url?.host == context.origin.host && url?.port == context.origin.port)
        check("url-fragment", url?.fragment == nil)
        check("url-path", ["/zm/ImageSignature", "/mail/ImageSignature"].contains(url?.path ?? ""))
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let query = components?.queryItems
        check("query-present", query != nil)
        let items = query ?? []
        check("query-unique", Set(items.map(\.name)).count == items.count)
        check("query-key-set", Set(items.map(\.name)) == Set(["fileName", "accountId", "storeName", "frm"]))
        let name = result["attachmentName"] ?? "", store = result["storeName"] ?? ""
        check("attachment-name", result["attachmentName"] != nil && !name.isEmpty && name.count <= 1000)
        check("store-name", result["storeName"] != nil && !store.isEmpty && store.count <= 256)
        check("descriptor-path-match", result["attachmentPath"] == "/compose/" + name)
        check("url-account-match", items.first(where: { $0.name == "accountId" })?.value == context.remoteID)
        check("url-file-match", items.first(where: { $0.name == "fileName" })?.value == name)
        check("url-store-match", items.first(where: { $0.name == "storeName" })?.value == store)
        check("url-compose-marker", items.first(where: { $0.name == "frm" })?.value == "c")
        guard failed.isEmpty, let url else {
            throw MailUploadResponseFailure(diagnostic: MailUploadDiagnostic(data: result,
                stage: "image-url", failedChecks: failed))
        }
        return url
    }

    static func prepare(_ html: String) throws -> Prepared {
        guard html.utf8.count <= maximumBodyBytes else { throw Failure.bodyTooLarge }
        // Fast path does not parse or normalize ordinary mail/signature content.
        guard html.range(of: "data:", options: .caseInsensitive) != nil else {
            return Prepared(html: html, imageCount: 0, imageBytes: 0)
        }
        let lower = html.lowercased()
        guard !lower.contains("<!entity"), !lower.contains("<!doctype"), !html.contains("\0"),
              let document = try? XMLDocument(data: Data(("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">" + html).utf8), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement() else { throw Failure.malformedHTML }
        var nodes = 0, count = 0, bytes = 0
        var images: [Image] = [], indexes: [String: Int] = [:], decodedSources: [String: Int] = [:]
        let ignored: Set<String> = ["script", "style", "textarea", "template", "noscript", "head"]
        var pending: [(XMLNode, Int)] = [(root, 0)]
        while let (node, depth) = pending.popLast() {
            nodes += 1
            guard nodes <= MailBodyPolicy.maximumNodes, depth <= MailBodyPolicy.maximumDepth else { throw Failure.malformedHTML }
            if let element = node as? XMLElement {
                let tag = (element.name ?? "").lowercased()
                if ignored.contains(tag) { continue }
                if tag == "img", let source = element.attributes?.first(where: { ($0.name ?? "").lowercased() == "src" })?.stringValue,
                   source.lowercased().hasPrefix("data:") {
                    count += 1
                    if let index = decodedSources[source] { bytes += images[index].data.count }
                    else {
                        let data = try decodeImage(source)
                        bytes += data.count
                        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        if let index = indexes[hash] {
                            images[index] = Image(sources: images[index].sources + [source], data: data, name: images[index].name)
                            decodedSources[source] = index
                        } else {
                            let type = source.prefix(while: { $0 != ";" }).lowercased()
                            let ext = type.hasSuffix("jpeg") ? "jpg" : type.hasSuffix("gif") ? "gif" : type.hasSuffix("webp") ? "webp" : "png"
                            indexes[hash] = images.count; decodedSources[source] = images.count
                            images.append(Image(sources: [source], data: data, name: "inline-\(hash.prefix(24)).\(ext)"))
                        }
                    }
                }
            }
            pending.append(contentsOf: (node.children ?? []).reversed().map { ($0, depth + 1) })
        }
        return Prepared(html: html, imageCount: count, imageBytes: bytes, images: images)
    }

    static func decodeImage(_ source: String) throws -> Data {
        guard let comma = source.firstIndex(of: ",") else { throw Failure.malformedImage }
        let type = source[..<comma].lowercased()
        guard ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64"].contains(type) else { throw Failure.malformedImage }
        let encoded = source[source.index(after: comma)...]
        guard encoded.utf8.count <= ((maximumImageBytes + 2) / 3) * 4 else { throw Failure.imageTooLarge }
        guard !encoded.isEmpty, let data = Data(base64Encoded: String(encoded)), !data.isEmpty else { throw Failure.malformedImage }
        guard data.count <= maximumImageBytes else { throw Failure.imageTooLarge }
        let signature = [UInt8](data.prefix(12))
        let valid: Bool
        switch type {
        case "data:image/png;base64": valid = signature.starts(with: [137,80,78,71,13,10,26,10])
        case "data:image/jpeg;base64": valid = signature.starts(with: [255,216,255])
        case "data:image/gif;base64": valid = signature.starts(with: Array("GIF87a".utf8)) || signature.starts(with: Array("GIF89a".utf8))
        default: valid = signature.count == 12 && signature.prefix(4).elementsEqual(Array("RIFF".utf8)) && signature.suffix(4).elementsEqual(Array("WEBP".utf8))
        }
        guard valid else { throw Failure.malformedImage }
        return data
    }

    /// Account/lifetime checks are supplied by AppState; this identity comparison
    /// is shared by production pre/post-await fences and pure fixtures.
    static func sameContext(_ current: MailboxSession?, expected: MailboxSession) -> Bool {
        guard let current else { return false }
        return current.accountID == expected.accountID && current.remoteID == expected.remoteID && current.origin == expected.origin
    }
}
