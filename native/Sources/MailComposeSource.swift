import Foundation

/// Materialize only resources authenticated against the source message. Ordinary
/// HTTPS images stay authored URLs; CID/provider images become validated bytes.
enum MailComposeSource {
    enum Failure: Error {
        case image, attachment, quote
        var label: String {
            switch self {
            case .image: return "原邮件内嵌图片读取失败或过大，未创建缺图的回复。请重试。"
            case .attachment: return "原邮件附件读取失败，未创建不完整的转发或草稿。请重试。"
            case .quote: return "原邮件内容过大或格式无法保留，未创建缺少原文的回复。"
            }
        }
    }

    static func needsPreparation(_ draft: MailDraft) -> Bool {
        guard let source = draft.source, draft.htmlBody == nil else { return false }
        return draft.mode == "edit" || draft.mode == "forward" ||
            source.html.range(of: "<img", options: .caseInsensitive) != nil ||
            source.html.range(of: "imagedata", options: .caseInsensitive) != nil ||
            source.html.range(of: "cid:", options: .caseInsensitive) != nil ||
            source.html.range(of: "mail-inline:", options: .caseInsensitive) != nil ||
            source.html.range(of: "/zm/", options: .caseInsensitive) != nil
    }

    @MainActor static func prepare(_ original: MailDraft, state: AppState) async throws -> MailDraft {
        guard let source = original.source else { return original }
        guard source.html.utf8.count <= MailBodyPolicy.maximumBytes else { throw Failure.quote }
        var draft = original
        let previousDraft = (try? state.draftStore.folder(draft.id)).map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("draft.json").path) } ?? false
        var completed = false
        defer { if !completed && !previousDraft { try? state.draftStore.remove(draft.id) } }
        let lifetime = state.contextActionLifetime()
        func check() throws {
            guard !Task.isCancelled, state.acceptsContextAction(accountID: source.message.accountID, lifetime: lifetime) else { throw MailFailure.auth }
            if !state.fixture {
                guard let context = state.sessions[source.message.accountID], context.remoteID == source.message.remoteID,
                      context.origin == source.message.origin else { throw MailFailure.auth }
            }
        }
        try check()
        guard let document = MailHTML.parsed(source.html), let root = document.rootElement() else { throw Failure.quote }
        var pending = [XMLNode](arrayLiteral: root), imageNodes: [XMLElement] = [], seen = 0
        while let node = pending.popLast() {
            seen += 1
            guard seen <= SignatureHTML.bodyMaximumNodes else { throw Failure.quote }
            if let element = node as? XMLElement, element.name?.lowercased() == "img" { imageNodes.append(element) }
            pending.append(contentsOf: node.children ?? [])
        }
        // Resolve every authenticated image up front. Distinct resources load
        // concurrently (bytes the reader already fetched come from memory), so a
        // quote with many images no longer waits for one download after another.
        struct Pending { let element: XMLElement; let raw: String; let key: String? }
        var plan: [Pending] = []
        var fetches: [String: @MainActor () async throws -> Data] = [:]
        for element in imageNodes {
            let raw = MailInlineImageReference.imageSource(from: element) ?? ""
            let alt = element.attribute(forName: "alt")?.stringValue
            let localID = URL(string: raw)?.scheme == "mail-inline" ? URL(string: raw)?.lastPathComponent : nil
            let file = MailInlineImageReference.attachment(for: raw, alt: alt, inline: source.inline) ?? source.inline.first { $0.id == localID }
            let provider = MailInlineImageReference.sessionImageURL(raw, origin: source.message.origin)
            guard file != nil || provider != nil || raw.lowercased().hasPrefix("cid:") || localID != nil else {
                plan.append(Pending(element: element, raw: raw, key: nil)); continue
            }
            let key = file.map { "attachment:" + $0.id } ?? raw
            if fetches[key] == nil {
                if let file { fetches[key] = { try await state.attachmentData(file, message: source.message) } }
                else if provider != nil { fetches[key] = { try await state.sessionImageData(raw, message: source.message) } }
                else { throw Failure.image }
            }
            plan.append(Pending(element: element, raw: raw, key: key))
        }
        var resolved: [String: String] = [:]
        if !fetches.isEmpty {
            try check()
            do {
                let jobs = Array(fetches)
                try await withThrowingTaskGroup(of: (String, Data).self) { group in
                    var next = 0
                    func enqueue() {
                        guard next < jobs.count else { return }
                        let (key, fetch) = jobs[next]; next += 1
                        group.addTask { @MainActor in (key, try await fetch()) }
                    }
                    for _ in 0..<min(4, jobs.count) { enqueue() }
                    while let (key, data) = try await group.next() {
                        try check()
                        guard let image = quoteImage(data) else { throw Failure.image }
                        resolved[key] = "data:\(image.mime);base64,\(image.data.base64EncodedString())"
                        enqueue()
                    }
                }
                try check()
            } catch { throw Failure.image }
        }
        var projectedBytes = source.html.utf8.count
        for item in plan {
            guard let key = item.key else {
                if !item.raw.isEmpty {
                    item.element.removeAttribute(forName: "src")
                    item.element.addAttribute(XMLNode.attribute(withName: "src", stringValue: item.raw) as! XMLNode)
                }
                continue
            }
            guard let dataURL = resolved[key] else { throw Failure.image }
            let growth = max(0, dataURL.utf8.count - item.raw.utf8.count)
            guard growth <= MailBodyPolicy.maximumBytes - projectedBytes else { throw MailInlineImageSend.Failure.bodyTooLarge }
            projectedBytes += growth
            item.element.removeAttribute(forName: "src")
            item.element.addAttribute(XMLNode.attribute(withName: "src", stringValue: dataURL) as! XMLNode)
        }
        let body = (try? document.nodes(forXPath: "//body").first)?.children?.map { $0.xmlString(options: .nodeCompactEmptyElement) }.joined() ?? source.html
        // Sanitizing a quote that now carries base64 images takes ~1 s per 8 MB;
        // keep it off the main thread so the window stays responsive.
        let clean = try await Task.detached(priority: .userInitiated) { () throws -> String in
            guard let clean = SignatureHTML.sanitizeBody(body) else { throw Failure.quote }
            _ = try MailInlineImageSend.prepare(clean)
            return clean
        }.value
        try check()
        var prepared = MailDetail(message: source.message, from: source.from, to: source.to, cc: source.cc,
                                  replyTo: source.replyTo, html: clean, attachments: source.attachments, inline: [])
        prepared.rfcMessageID = source.rfcMessageID; prepared.rfcReferences = source.rfcReferences; prepared.rfcInReplyTo = source.rfcInReplyTo
        prepared.bcc = source.bcc; prepared.replyHeadersChecked = source.replyHeadersChecked
        draft.source = prepared
        if draft.mode == "edit" { draft.htmlBody = clean; draft.body = MailHTML.plainText(clean) }
        if ["forward", "edit"].contains(draft.mode) {
            do {
                for file in source.visibleAttachments {
                    try check()
                    let data = try await state.attachmentData(file, message: source.message)
                    try check()
                    guard data.count <= 25 * 1024 * 1024 else { throw Failure.attachment }
                    let scratch = try state.draftStore.folder(draft.id).appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: scratch) }
                    let name = (file.name as NSString).lastPathComponent
                    guard !name.isEmpty, name != ".", name != ".." else { throw Failure.attachment }
                    let temporary = scratch.appendingPathComponent(name)
                    try data.write(to: temporary)
                    let imported = try state.draftStore.importFile(temporary, id: draft.id)
                    draft.files.append(imported.path)
                }
            } catch { throw Failure.attachment }
        }
        try check()
        try state.draftStore.save(draft)
        completed = true
        return draft
    }

    /// Received inline resources retain their original bytes. The small-image
    /// paste encoder's budget must never be applied to inherited mail content.
    static func quoteImage(_ data: Data) -> (data: Data, mime: String)? {
        guard let mime = MailRasterImage.mimeType(for: data),
              ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) else { return nil }
        guard data.count <= MailBodyPolicy.maximumImageBytes else { return nil }
        return (data, mime)
    }
}
