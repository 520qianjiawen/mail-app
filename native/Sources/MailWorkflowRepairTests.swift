import Foundation
import AppKit

@MainActor private final class WorkflowGate {
    var entered = false
    var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor func runMailWorkflowRepairTests(_ require: (Bool, String) -> Void) async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mail-workflow-repair-\(UUID().uuidString)")
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let regularFile = root.appendingPathComponent("not-a-directory")
    try! Data("fixture".utf8).write(to: regularFile)
    let broken = OutboxStore(directory: regularFile)
    var item = OutboxItem(accountID: "test", from: "own@example.test", to: "recipient@example.test")
    item.draftID = UUID().uuidString.lowercased()
    require(!broken.enqueue(item) && broken.all().isEmpty && broken.persistenceError != nil,
            "failed durable enqueue leaves memory unchanged and reports failure")
    let folder = root.appendingPathComponent("queue"), queue = OutboxStore(directory: folder)
    require(queue.enqueue(item), "first queue job persists")
    var duplicate = item; duplicate.id = UUID().uuidString.lowercased()
    require(!queue.enqueue(duplicate) && queue.all().count == 1, "same draft cannot create a second independent send")
    require(queue.update(item.id) { $0.state = "sending" }, "persist in-flight state")
    require(!queue.cancel(item.id), "in-flight transport cannot be removed as a successful cancellation")
    let reopened = OutboxStore(directory: folder)
    require(reopened.all().first?.state == "uncertain", "interrupted send reopens as uncertain instead of stuck sending")
    require(!reopened.cancel(item.id), "uncertain delivery is not silently discarded")
    let moved = root.appendingPathComponent("old-queue")
    try! fm.moveItem(at: folder, to: moved)
    try! Data("blocked".utf8).write(to: folder)
    require(!reopened.update(item.id, { $0.state = "queued" }) && reopened.all().first?.state == "uncertain",
            "failed state persistence leaves the previous in-memory state intact")
    require(!reopened.remove(item.id) && reopened.all().count == 1, "failed removal does not discard queue data in memory")
    require(OutboxStore.attachmentName(URL(fileURLWithPath: "/fixture/12345678__quote__v2.txt")) == "quote__v2.txt", "attachment import prefix removal preserves authored double underscores")
    let corruptFolder = root.appendingPathComponent("corrupt")
    try! fm.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
    try! Data("corrupt-data".utf8).write(to: corruptFolder.appendingPathComponent("outbox.json"))
    let corrupt = OutboxStore(directory: corruptFolder)
    require(!corrupt.enqueue(item), "corrupt queue fails closed instead of overwriting prior mail")
    require((try? String(contentsOf: corruptFolder.appendingPathComponent("outbox.json"))) == "corrupt-data", "unreadable queue bytes remain intact")

    let state = AppState(fixture: true), a = state.accounts[0]
    defer { _ = state.shutdown(); try? fm.removeItem(at: state.preferences.directory) }
    state.sessions[a.id] = MailboxSession(accountID: a.id, remoteID: "100", email: "own@example.test",
        origin: URL(string: "https://mail.zoho.com")!, folders: [.init(id: "500", name: "Inbox", path: "/Inbox", type: "Inbox", unread: 0)],
        addresses: ["own@example.test", "alias@example.test"])
    func message(_ n: Int, folder: String = "500") -> MailMessage {
        MailMessage(accountID: a.id, remoteID: "100", folderID: folder, id: String(n), origin: URL(string: "https://mail.zoho.com")!,
                    subject: "workflow fixture", sender: "sender@example.test", preview: "", date: Date(timeIntervalSince1970: Double(n)), attachment: false, unread: true)
    }
    func detail(_ n: Int) -> MailDetail {
        MailDetail(message: message(n), from: "sender@example.test", to: "own@example.test", cc: "", replyTo: "", html: "<p>offline fixture</p>", attachments: [], inline: [])
    }
    state.cache.store(detail(1)); state.toggleOffline(message(1))
    for n in 2...205 { state.cache.store(detail(n)) }
    require(state.preferences.value.offlineSaved.contains(message(1).key) && state.cache.detail(message(1)) != nil,
            "offline pinned body survives more than 200 newer details")
    state.cache.clearDetails()
    require(state.cache.detail(message(1)) != nil && state.cache.detail(message(205)) == nil,
            "cache cleanup preserves explicitly saved offline bodies only")
    state.toggleOffline(message(1)); state.cache.clearDetails()
    require(state.cache.detail(message(1)) == nil, "unpin allows a formerly saved body to be cleared")

    var draft = MailDraft(accountID: a.id, from: "own@example.test", mode: "new", source: nil,
                          to: "recipient@example.test", subject: "scheduled local fixture", body: "body")
    let file = root.appendingPathComponent("file.txt"); try! Data("attachment".utf8).write(to: file)
    draft.files = [try! state.draftStore.importFile(file, id: draft.id).path]
    try! state.draftStore.save(draft)
    state.outboxSendHook = { _ in throw MailFailure.rejected }
    let model = ComposeModel(state: state, draft: draft)
    var closed = false; model.onClose = { closed = true }
    model.scheduledAt = Date().addingTimeInterval(3600)
    model.send(schedule: true); model.send(schedule: true)
    await model.sendTask?.value
    require(closed && !model.canSend, "accepted scheduled job closes compose and cannot send a second copy")
    let scheduled = state.outbox.first { $0.draftID == draft.id }
    require(scheduled != nil && state.outbox.filter { $0.draftID == draft.id }.count == 1, "composer double click creates exactly one durable job")
    if let scheduled {
        require(state.outboxStore.attachments(scheduled.id).count == 1, "queue owns its attachment snapshot")
        state.cancelOutbox(scheduled.id)
        let restored = state.draftStore.all(accounts: [a.id]).first { $0.id == draft.id }
        require(restored?.state == "editing" && restored?.queuedItemID == nil, "cancel restores editing state instead of deleting draft")
        require(restored.map { state.draftStore.files($0).count } == 1, "cancel preserves original draft attachment")
    }
    model.stopBackgroundWork()

    var replySource = detail(2)
    replySource.rfcMessageID = "<original-parent@example.test>"
    replySource.rfcReferences = "<earlier@example.test>"
    replySource.replyHeadersChecked = true
    var replyDraft = MailDraft(accountID: a.id, from: "own@example.test", mode: "reply", source: replySource,
        to: "recipient@example.test", subject: "frozen reply fixture", body: "reply")
    replyDraft.htmlBody = "<p>reply fixture</p>"
    let replyModel = ComposeModel(state: state, draft: replyDraft)
    replyModel.scheduledAt = Date().addingTimeInterval(3600)
    replyModel.send(schedule: true)
    replyModel.draft.source?.rfcMessageID = "<changed-after-click@example.test>"
    await replyModel.sendTask?.value
    let frozenReply = state.outboxStore.all().first { $0.draftID == replyDraft.id }
    require(frozenReply?.inReplyTo == "<original-parent@example.test>" && frozenReply?.referencesHeader == "<earlier@example.test>",
            "reply freezes RFC headers before asynchronous editor flush")
    require(frozenReply?.replySource?.key == replySource.message.key,
            "reply persists source account and real folder rather than assuming Inbox")
    let reopenedReplyQueue = OutboxStore(directory: state.outboxStore.directory)
    require(reopenedReplyQueue.all().first(where: { $0.draftID == replyDraft.id })?.inReplyTo == "<original-parent@example.test>",
            "frozen reply association survives durable queue reopen")
    if let frozenReply { state.cancelOutbox(frozenReply.id) }
    replyModel.stopBackgroundWork()

    let failedState = AppState(fixture: true)
    var transportCalls = 0
    failedState.outboxSendHook = { _ in transportCalls += 1 }
    try! fm.removeItem(at: failedState.outboxStore.directory)
    try! Data("blocked".utf8).write(to: failedState.outboxStore.directory)
    let failedDraft = MailDraft(accountID: failedState.accounts[0].id, from: "own@example.test", mode: "new", source: nil, to: "recipient@example.test", body: "retained")
    let failedModel = ComposeModel(state: failedState, draft: failedDraft)
    var failedClosed = false; failedModel.onClose = { failedClosed = true }
    failedModel.send(); await failedModel.sendTask?.value
    require(transportCalls == 0 && failedState.outbox.isEmpty, "composer disk failure never enters transport")
    require(!failedClosed && failedModel.canSend && failedState.draftStore.all(accounts: [failedState.accounts[0].id]).first?.body.contains("retained") == true,
            "enqueue failure keeps the editable draft and composer instead of closing or losing content")
    failedModel.stopBackgroundWork(); _ = failedState.shutdown(); try? fm.removeItem(at: failedState.preferences.directory)

    let gate = WorkflowGate()
    state.outboxSendHook = { _ in await gate.pause() }
    var live = OutboxItem(accountID: a.id, from: "own@example.test", to: "recipient@example.test")
    live.draftID = UUID().uuidString.lowercased()
    require(state.enqueueSend(live), "isolated fake transport enters through production enqueue")
    for _ in 0..<500 where !gate.entered { await Task.yield() }
    require(gate.entered, "fake transport can suspend the actual sending lifecycle")
    state.cancelOutbox(live.id)
    require(state.outboxStore.all().first { $0.id == live.id }?.state == "sending", "cancel during transport leaves in-flight job intact")
    gate.release()
    for _ in 0..<500 where state.outboxStore.all().first(where: { $0.id == live.id })?.state != "sent" { await Task.yield() }
    require(state.outboxStore.all().first { $0.id == live.id }?.state == "sent", "only explicit transport acknowledgement creates a terminal sent receipt")
    require(!state.outbox.contains { $0.id == live.id }, "completed receipt is hidden from active outbox")

    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5WQAAAAASUVORK5CYII=")!
    let inline = MailAttachment(id: "901", name: "logo.png", size: png.count, cid: "logo@fixture")
    let attachment = MailAttachment(id: "902", name: "quote.txt", size: 5, cid: "")
    state.inlineImageDataHook = { file, _ in file.id == inline.id ? png : Data("quote".utf8) }
    let source = MailDetail(message: message(300), from: "Alias <alias@example.test>", to: "recipient@example.test", cc: "", replyTo: "",
                          html: "<p><b>Rich body</b></p><img src='cid:logo@fixture'>", attachments: [attachment], inline: [inline])
    do {
        let forward = MailDraft(accountID: a.id, from: "alias@example.test", mode: "forward", source: source)
        let prepared = try await MailComposeSource.prepare(forward, state: state)
        require(prepared.source?.html.contains("data:image/png;base64,") == true && prepared.source?.html.contains("cid:") == false,
                "reply/forward materializes CID bytes before editor sanitization")
        require(state.draftStore.files(prepared).count == 1 && prepared.source?.html.contains("<b>") == true,
                "forward preserves original attachment and rich body")
        var edit = MailDraft(accountID: a.id, from: "alias@example.test", mode: "edit", source: source)
        edit.cloudID = source.message.id
        let preparedEdit = try await MailComposeSource.prepare(edit, state: state)
        require(preparedEdit.htmlBody?.contains("<b>") == true && state.draftStore.files(preparedEdit).count == 1,
                "server draft restoration keeps HTML and original files")
        require(preparedEdit.cloudID == source.message.id && preparedEdit.from == "alias@example.test", "server draft restoration preserves cloud identity and From alias")
    } catch { require(false, "source preparation failed: \(error)") }
    let lazySource = MailDetail(message: message(301), from: "sender@example.test", to: "own@example.test", cc: "", replyTo: "",
                                html: "<p>Lazy image</p><img data-src='https://images.example.test/logo.png'>", attachments: [], inline: [])
    do {
        let lazy = try await MailComposeSource.prepare(MailDraft(accountID: a.id, from: "own@example.test", mode: "reply", source: lazySource), state: state)
        require(lazy.source?.html.contains("src=\"https://images.example.test/logo.png\"") == true, "reply preserves recognized lazy image sources through sanitization")
    } catch { require(false, "lazy source fixture failed") }
    let orphan = MailAttachment(id: "903", name: "orphan.png", size: png.count, cid: "")
    let orphanDetail = MailDetail(message: message(302), from: "sender@example.test", to: "own@example.test", cc: "", replyTo: "", html: "<p>No embedded reference</p>", attachments: [], inline: [orphan])
    require(orphanDetail.visibleAttachments.map(\.id) == [orphan.id], "manifest images without CID are exposed as attachments rather than silently lost")
    state.inlineImageDataHook = { _, _ in throw MailFailure.network }
    do {
        _ = try await MailComposeSource.prepare(MailDraft(accountID: a.id, from: "own@example.test", mode: "reply", source: source), state: state)
        require(false, "failed CID download must not create a silently damaged quote")
    } catch { require(true, "failed CID download fails visibly before compose creation") }

    // The real long conversation contained 4,195 nodes: the former signature
    // limit blocked it before a composer could be presented.
    state.inlineImageDataHook = { _, _ in png }
    let longSource = MailDetail(message: source.message, from: source.from, to: source.to, cc: source.cc,
        replyTo: source.replyTo, html: String(repeating: "<p>Earlier correspondence</p>", count: 2200) + source.html,
        attachments: source.attachments, inline: source.inline)
    do {
        let prepared = try await MailComposeSource.prepare(MailDraft(accountID: a.id, from: "own@example.test", mode: "reply", source: longSource), state: state)
        require(prepared.source?.html.contains("Earlier correspondence") == true,
                "long ordinary correspondence is retained instead of blocking reply")
        require(try MailInlineImageSend.prepare(prepared.source!.html).imageCount == 1,
                "long prepared quote passes the actual send image preflight")
        require(SignatureHTML.sanitize(longSource.html) == nil,
                "signature-specific complexity limit stays unchanged")
    } catch { require(false, "long conversation preparation: \(error)") }

    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 4096, bitsPerPixel: 32)!
    var noise: UInt64 = 17
    for index in 0..<(1024 * 1024) {
        for channel in 0..<3 {
            noise = noise &* 6364136223846793005 &+ 1
            bitmap.bitmapData![index * 4 + channel] = UInt8(truncatingIfNeeded: noise >> 32)
        }
        bitmap.bitmapData![index * 4 + 3] = 255
    }
    let largePNG = bitmap.representation(using: .png, properties: [:])!
    require(largePNG.count > 1024 * 1024, "large quoted photograph fixture exceeds the former one-MiB limit")
    state.inlineImageDataHook = { _, _ in largePNG }
    do {
        let prepared = try await MailComposeSource.prepare(MailDraft(accountID: a.id, from: "own@example.test", mode: "reply", source: source), state: state)
        let checked = try MailInlineImageSend.prepare(prepared.source!.html)
        require(checked.imageCount == 1 && checked.imageBytes == largePNG.count,
                "original photo above one MiB is retained without lossy resizing")
        require(source.html.contains("cid:logo@fixture") && source.inline.first?.id == inline.id,
                "reply image conversion leaves received source and attachment identity unchanged")
    } catch { require(false, "large quote photo preparation: \(error)") }
    require(MailComposeSource.quoteImage(png)?.data == png,
            "ordinary small image is preserved byte-for-byte")
    require(MailComposeSource.quoteImage(Data("not an image".utf8)) == nil,
            "image conversion still rejects invalid resource bytes")

    let composerCount = state.composeControllers.count
    let replyGate = WorkflowGate()
    var imageRequests = 0
    state.inlineImageDataHook = { _, _ in imageRequests += 1; await replyGate.pause(); throw MailFailure.network }
    state.composeReply(source, mode: .reply)
    require(state.composeSourcePending.contains(source.message.key), "reply immediately publishes a visible preparation state")
    state.composeReply(source, mode: .reply)
    for _ in 0..<500 where !replyGate.entered { await Task.yield() }
    replyGate.release()
    for _ in 0..<500 where state.composeSourcePending.contains(source.message.key) { await Task.yield() }
    require(imageRequests == 1 && state.composeControllers.count == composerCount,
            "repeated click while preparing neither duplicates downloads nor opens incomplete composers")
    require(state.composePreparationFailure != nil && state.composePreparationRetry != nil && state.composeSourcePending.isEmpty,
            "preparation failure is published with retry and releases the busy state")
    state.inlineImageDataHook = { _, _ in png }
    state.composePreparationRetry?()
    for _ in 0..<500 where state.composeSourcePending.contains(source.message.key) { await Task.yield() }
    require(state.composeControllers.count == composerCount + 1 && state.composePreparationFailure == nil,
            "retry after resource recovery opens one reply composer and clears the error")
    if state.composeControllers.count > composerCount { state.composeControllers.last?.close(save: false) }
    let editor = WebHTMLComposerHandle()
    var quoteError = ""; editor.onPasteError = { quoteError = $0 }
    editor.loadReplyHTML(body: "<p>reply</p>", quote: String(repeating: "<p>x</p>", count: SignatureHTML.bodyMaximumNodes))
    require(editor.failure != nil && !quoteError.isEmpty, "oversized quote is a visible failure rather than an empty quote")
    editor.dispose()

    let related = "Content-Type: multipart/related; boundary=b; start=\"<root>\"\n\n--b\nContent-Type: image/png\nContent-ID: <image>\n\nAAAA\n--b\nContent-Type: text/html\nContent-ID: <root>\n\n<p>Root body</p>\n--b--"
    require(MailOriginalHTML.html(related)?.contains("Root body") == true, "related MIME selects explicit root instead of first image part")
    require(MailOriginalHTML.html(related.replacingOccurrences(of: "start=\"<root>\"", with: "start=\"<missing>\"")) == nil,
            "unknown related root is rejected without substituting an attachment")
    require(MailOriginalHTML.improves("<img src='https://images.example.test/a'><img>", over: "<img><img>"),
            "partial original-image recovery is accepted without requiring every source to be repaired")
    require(!MailOriginalHTML.improves("<img><img>", over: "<img src='https://images.example.test/a'><img>"),
            "recovery never substitutes a version with fewer available image references")

    state.messageStore[message(400).key] = message(400)
    state.perform(.notSpam, on: [message(400)])
    require(state.messageStore[message(400).key] == nil, "non-spam acknowledgement immediately removes old-folder row")
    await runMailCommonFeatureTests(state, root: root, require)
    await runWorkflowPaginationRepairTests(require)
}

@MainActor private func runWorkflowPaginationRepairTests(_ require: (Bool, String) -> Void) async {
    var removed = false
    func context(_ a: MailAccount) -> MailboxSession {
        MailboxSession(accountID: a.id, remoteID: "100", email: "own@example.test", origin: URL(string: "https://mail.zoho.com")!,
            folders: [.init(id: "500", name: "Inbox", path: "/Inbox", type: "Inbox", unread: 0),
                      .init(id: "700", name: "Sent", path: "/Sent", type: "Sent", unread: 0)], addresses: ["own@example.test"])
    }
    let state = AppState(fixture: true, syncHooks: MailSyncHooks(fetchInbox: { a in
        MailSyncSnapshot(context: context(a), head: InboxPage(messages: [], remoteID: "100", folderID: "500", next: 1, more: false))
    }, fetchView: { a, _, _, start in
        let ids = (1...200).filter { !removed || $0 != 1 }
        let batch = ids.dropFirst(start - 1).prefix(100)
        let rows = batch.map { n in
            MailMessage(accountID: a.id, remoteID: "100", folderID: "700", id: String(n), origin: URL(string: "https://mail.zoho.com")!,
                        subject: "pagination fixture", sender: "from@example.test", preview: "", date: Date(timeIntervalSince1970: Double(n)), attachment: false, unread: true)
        }
        return InboxPage(messages: rows, remoteID: "100", folderID: "700", next: start + rows.count, more: start - 1 + rows.count < ids.count)
    }))
    defer { _ = state.shutdown(); try? FileManager.default.removeItem(at: state.preferences.directory) }
    func settle() async {
        await state.syncScheduler.waitUntilIdle(); await state.refreshTask?.value; await state.viewSyncScheduler.waitUntilIdle()
    }
    state.start(); await settle()
    state.scope = Scope(kind: .folder, accountID: state.accounts[0].id, folderID: "700")
    state.refresh(); await settle(); state.loadMore(); await settle()
    require(state.rows.count == 200, "fixture loads a real second query page")
    removed = true
    state.handleSyncEvent(.activation, isActive: true); await settle()
    require(state.rows.count == 199 && state.visibleLimit >= 200, "activation refresh revalidates all loaded pages without truncating to 100")
    require(!state.rows.contains { $0.id == "1" }, "range refresh also removes remotely deleted membership instead of preserving stale tail rows")

    let replySource = MailDetail(message: state.rows[0], from: "sender@example.test", to: "own@example.test", cc: "", replyTo: "", html: "<p>Original message</p>", attachments: [], inline: [])
    state.activeKey = replySource.message.key
    state.openReplyDraft(replySource, mode: .reply)
    require(state.inlineReplyModel != nil, "inline reply opens in ReaderPane when preference enabled and message active")
    require(state.composeControllers.isEmpty, "inline reply does not pop out an external window")
    state.popOutInlineReply()
    require(state.inlineReplyModel == nil, "pop out clears inline reply model")
    require(state.composeControllers.count == 1, "pop out opens compose window controller")
    state.composeControllers.first?.close(save: false)
    require(state.composeControllers.isEmpty, "closing composer controller removes it")
    state.openReplyDraft(replySource, mode: .reply)
    require(state.inlineReplyModel != nil, "opening reply draft sets inline reply model")
    state.closeInlineReply(save: false)
    require(state.inlineReplyModel == nil, "discarding inline reply clears inline reply model")

}
