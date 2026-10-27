import AppKit
import WebKit

/// Entirely local stress fixtures: no accounts, uploads, cloud writes or sends.
@MainActor func runMailBodyCapacityTests(_ require: (Bool, String) -> Void) async {
    let began = Date()
    var members: [MailMessage] = []
    let state = AppState(fixture: true, syncHooks: MailSyncHooks(
        fetchInbox: { _ in throw MailFailure.network }, performAction: { _, _ in },
        fetchDetail: { message in MailDetail(message: message, from: message.sender,
            to: "design@northwind.studio", cc: "", replyTo: "sender@example.test",
            html: "<p>body-\(message.id)</p>", attachments: [], inline: [], replyHeadersChecked: true) },
        fetchThread: { _ in members }))
    defer { _ = state.shutdown() }
    state.preferences.value.markReadOnOpen = false
    let account = state.accounts[0]
    let origin = URL(string: "https://mail.zoho.com")!
    for number in 1...500 {
        var message = MailMessage(accountID: account.id, remoteID: "100", folderID: number % 2 == 0 ? "502" : "500",
            id: String(number), origin: origin, subject: "Capacity conversation", sender: "sender@example.test",
            preview: "message-\(number)", date: Date(timeIntervalSince1970: Double(number)), attachment: false, unread: false)
        message.threadID = "700"
        members.append(message)
    }
    state.messageStore[members[0].key] = members[0]; state.rebuildRows()
    state.open(members[0], preferLatest: true); await state.detailTask?.value
    require(state.threadRows.count == 500 && state.activeKey == members.last?.key,
            "500 independently fetched conversation members retain the actual latest member")
    require(Set(state.threadRows.map(\.key)).count == 500 && state.detail?.html == "<p>body-500</p>",
            "large conversation keeps every identity and opens the latest body")
    require(state.accountSessions.isEmpty, "500-member reading fixture creates no real authenticated sessions")

    let tiny = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5WQAAAAASUVORK5CYII=")!
    let inline = MailAttachment(id: "901", name: "logo.png", size: tiny.count, cid: "logo@fixture")
    var fetches = 0
    state.inlineImageDataHook = { _, _ in fetches += 1; return tiny }
    let history = (1...500).map { number in
        "<div><h3>message-\(number)</h3>" + String(repeating: "<p>earlier correspondence</p>", count: 20) + "<img src='cid:logo@fixture'></div>"
    }.joined()
    let source = MailDetail(message: members.last!, from: "sender@example.test", to: account.name, cc: "", replyTo: "sender@example.test",
        html: history, attachments: [], inline: [inline], replyHeadersChecked: true)
    do {
        let prepared = try await MailComposeSource.prepare(MailDraft(accountID: account.id, from: account.name,
            mode: "reply", source: source, to: "sender@example.test"), state: state)
        let checked = try MailInlineImageSend.prepare(prepared.source!.html)
        require(checked.imageCount == 500 && fetches == 1,
                "500 inherited image references survive with a single authenticated fetch for shared bytes")
        require(prepared.source!.html.contains("message-1") && prepared.source!.html.contains("message-500") && prepared.source!.html.components(separatedBy: "message-").count == 501,
                "500-message quoted history retains both ends without truncation")
    } catch { require(false, "500-message preparation: \(error)") }
    let nested = (1...500).map { "<blockquote><p>nested-\($0)</p>" }.joined() + "<p>last-nested-marker</p>" + String(repeating: "</blockquote>", count: 500)
    let cleanNested = SignatureHTML.sanitizeBody(nested)
    require(cleanNested?.contains("last-nested-marker") == true && cleanNested?.contains("nested-500") == true,
            "500 levels of quoted history survive iterative sanitization")
    require(SignatureHTML.sanitize(nested) == nil, "signature-specific complexity protection stays separate")

    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: 1536,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 6144, bitsPerPixel: 32)!
    var seed: UInt64 = 99
    for pixel in 0..<(1536 * 1536) {
        for channel in 0..<3 {
            seed = seed &* 6364136223846793005 &+ 1
            bitmap.bitmapData![pixel * 4 + channel] = UInt8(truncatingIfNeeded: seed >> 32)
        }
        bitmap.bitmapData![pixel * 4 + 3] = 255
    }
    let photo = bitmap.representation(using: .png, properties: [:])!
    require(photo.base64EncodedString().utf8.count > 7_000_000 && photo.count > 1024 * 1024,
            "real photo fixture exceeds former native and editor image-size guards")
    let largeFile = MailAttachment(id: "902", name: "large.png", size: photo.count, cid: "large@fixture")
    state.inlineImageDataHook = { _, _ in photo }
    let smallHTML = "<img src='data:image/png;base64,\(tiny.base64EncodedString())'>"
    var largeSource = MailDetail(message: members.last!, from: "sender@example.test", to: account.name, cc: "", replyTo: "",
        html: "<p>capacity-first</p><img src='cid:large@fixture'>" + String(repeating: smallHTML, count: 12) + "<p>capacity-last</p>",
        attachments: [], inline: [largeFile], replyHeadersChecked: true)
    largeSource.rfcMessageID = "<capacity@example.test>"
    do {
        var prepared = try await MailComposeSource.prepare(MailDraft(accountID: account.id, from: account.name,
            mode: "reply", source: largeSource, to: "sender@example.test"), state: state)
        let html = prepared.source!.html
        let checked = try MailInlineImageSend.prepare(html)
        require(html.utf8.count > 8 * 1024 * 1024 && checked.imageCount == 13,
                "reply above 8 MiB with 13 inline images passes production preparation and send preflight")
        require(checked.imageBytes == photo.count + 12 * tiny.count,
                "all inherited image bytes are retained without resizing or dropped images")
        var uploadBytes = 0
        let context = MailboxSession(accountID: account.id, remoteID: "100", email: "own@example.test",
            origin: origin, folders: [], addresses: ["own@example.test"])
        let transported = try await MailInlineImageSend.transport(checked, context: context) { data, name in
            uploadBytes += data.count
            return ["storeName": "store", "attachmentName": name, "attachmentPath": "/compose/" + name,
                "url": "/zm/ImageSignature?fileName=\(name)&accountId=100&storeName=store&frm=c"]
        }
        require(transported.html.utf8.count < 10_000 && uploadBytes == photo.count + tiny.count && transported.attachments.count == 2,
                "large original images become two deduplicated upload fixtures and compact send HTML, preserving every original byte")
        let editor = WebHTMLComposerHandle()
        defer { editor.dispose() }
        editor.webView?.frame = NSRect(x: 0, y: 0, width: 850, height: 600)
        editor.restoreHTML(html, signature: nil)
        let snapshot = await editor.flush()
        let decoded = try MailInlineImageSend.prepare(snapshot.outgoingHTML)
        require(editor.failure == nil && decoded.imageCount == 13 && decoded.imageBytes == checked.imageBytes,
                "real WK editor and draft restore retain every image beyond former native and JavaScript caps")
        let rendered = await editor.inspectDOM("const images=[...document.getElementById('editor').querySelectorAll('img')];await Promise.all(images.map(i=>i.decode().catch(()=>{})));return images.length===13&&images.every(i=>i.complete&&i.naturalWidth>0);") as? Bool
        require(rendered == true, "real WK engine decodes all 13 images, including the large original photo")
        prepared.htmlBody = snapshot.outgoingHTML
        try state.draftStore.save(prepared)
        let reopenedDraft = state.draftStore.all(accounts: [account.id]).first { $0.id == prepared.id }
        require(reopenedDraft?.htmlBody == snapshot.outgoingHTML, "large local draft reopens without truncation")
        let cloud = try MailCloudDraft.payload(prepared, html: snapshot.outgoingHTML)
        require(cloud["content"] as? String == snapshot.outgoingHTML,
                "cloud-draft payload uses the same larger body policy without making a network request")
        var item = OutboxItem(accountID: account.id, from: account.name, to: "sender@example.test")
        item.html = snapshot.outgoingHTML
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capacity-outbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = OutboxStore(directory: directory)
        require(queue.enqueue(item), "large outbox copy is durable before any send")
        require(OutboxStore(directory: directory).all().first?.html == item.html,
                "reopened outbox retains the complete large HTML and inline image body")
        print("Capacity fixture: \(html.utf8.count) HTML bytes; \(checked.imageCount) inline images; \(photo.count) original photo bytes.")
    } catch { require(false, "large-body production path: \(error)") }
    require(state.accountSessions.isEmpty, "stress suite never opens real accounts or performs uploads/sends")
    print("Capacity suite elapsed: \(String(format: "%.2f", Date().timeIntervalSince(began))) seconds.")
}
