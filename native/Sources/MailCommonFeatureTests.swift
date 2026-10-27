import Foundation

@MainActor func runMailCommonFeatureTests(_ state: AppState, root: URL, _ require: (Bool, String) -> Void) async {
    let account = state.accounts[0]
    state.sessions[account.id] = MailboxSession(accountID: account.id, remoteID: "100", email: "own@example.test", origin: URL(string: "https://mail.zoho.com")!,
        folders: [.init(id: "500", name: "Inbox", path: "/Inbox", type: "Inbox", unread: 0),
                  .init(id: "600", name: "Drafts", path: "/Drafts", type: "Drafts", unread: 0)], addresses: ["own@example.test"])
    let value = MailDraft(accountID: account.id, from: "own@example.test", mode: "new", source: nil, to: "recipient@example.test", subject: "cloud fixture", body: "kept locally")
    let model = ComposeModel(state: state, draft: value)
    defer { model.stopBackgroundWork() }
    var posts = 0, cleanupAfterSave = false
    state.cloudDraftSaveHook = { _, body in
        posts += 1
        guard body["mode"] as? String == "draft", body["action"] == nil else { throw MailFailure.rejected }
        return String(710 + posts)
    }
    state.cloudDraftRemoveHook = { _ in
        cleanupAfterSave = state.draftStore.all(accounts: [account.id]).first { $0.id == value.id }?.cloudID == "712"
    }
    model.syncCloudDraft(); await model.cloudTask?.value
    require(posts == 1 && model.draft.cloudID == "711" && !model.draft.cloudUncertain, "cloud draft acknowledgement records numeric identity without invoking send")
    require(state.draftStore.all(accounts: [account.id]).first { $0.id == value.id }?.cloudID == "711", "cloud ownership survives local reopen")
    model.syncCloudDraft(); await model.cloudTask?.value
    require(posts == 2 && model.draft.cloudID == "712" && cleanupAfterSave, "older draft cleanup occurs only after new identity has been durably saved")
    require(model.draft.obsoleteCloudIDs?.isEmpty == true, "acknowledged older-copy cleanup clears pending identities")
    state.cloudDraftSaveHook = { _, _ in throw MailFailure.network }
    model.syncCloudDraft(); await model.cloudTask?.value
    require(model.draft.cloudUncertain && !model.canSend, "unknown cloud POST result preserves ambiguity and prevents accidental resubmission")
    require(state.draftStore.all(accounts: [account.id]).first { $0.id == value.id }?.cloudUncertain == true,
            "unknown cloud result remains protected after reopen")
    let priorTask = model.cloudTask
    model.syncCloudDraft(); await priorTask?.value
    require(model.draft.cloudUncertain, "protected draft does not silently clear uncertainty on another save click")

    let message = MailMessage(accountID: account.id, remoteID: "100", folderID: "500", id: "900", origin: URL(string: "https://mail.zoho.com")!,
                              subject: "source", sender: "from@example.test", preview: "", date: Date(), attachment: false, unread: false)
    var source = MailDetail(message: message, from: "from@example.test", to: "own@example.test", cc: "", replyTo: "", html: "<p>source</p>", attachments: [], inline: [])
    source.rfcMessageID = "<reply@example.test>"; source.rfcReferences = "<first@example.test>"
    let reply = MailDraft(accountID: account.id, from: "own@example.test", mode: "reply", source: source, to: "from@example.test")
    let payload = try? MailCloudDraft.payload(reply, html: "<p>reply</p>")
    require(payload?["inReplyTo"] as? String == "<reply@example.test>" && payload?["refHeader"] as? String == "<first@example.test> <reply@example.test>",
            "reply cloud draft uses RFC identifiers rather than provider numeric IDs")
    require(MailAddresses.safeHeaderValue("<first@example.test>\r\n <second@example.test>") == "<first@example.test> <second@example.test>", "valid folded RFC references are unfolded safely")
    require(MailAddresses.safeHeaderValue("<reply@example.test>\r\nBcc: evil@example.test") == nil, "nonfolded injected header is rejected")

    let nested = "<div><p>Current message is retained.</p><div><p>Signature retained.</p><blockquote>Old quote</blockquote><p>Old footer</p></div><p>More old history</p></div>"
    let projection = MailHistoryProjection.summary(nested)
    require(projection.folded && projection.html.contains("Current message") && projection.html.contains("Signature retained"), "folded reading preserves ancestors containing current content")
    require(!projection.html.contains("Old quote") && !projection.html.contains("Old footer") && !projection.html.contains("More old history"), "history folding removes only the derived history tail")
    require(nested.contains("Old quote") && MailHistoryProjection.summary("<blockquote>Entire main message</blockquote>").folded == false,
            "original HTML remains untouched and quote-only main messages stay visible")
    require(!MailHistoryProjection.summary("<p>From the top of the mountain, I write.</p><p>Main message.</p>").folded, "ordinary From prose is never a historical header")
    let outlook = "<p>This is the new content.</p><div><b>From:</b> old<br><b>Sent:</b> date<br><b>To:</b> recipient<br><b>Subject:</b> subject</div><p>old body</p>"
    let old = MailHistoryProjection.summary(outlook)
    require(old.folded && old.html.contains("new content") && !old.html.contains("old body"), "verified Outlook header folds without removing the current message")

    let folder = root.appendingPathComponent("exports")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    do {
        let first = try MailAttachmentExport.save(Data("first".utf8), name: "quote.txt", directory: folder)
        let second = try MailAttachmentExport.save(Data("second".utf8), name: "quote.txt", directory: folder)
        require(first != second && (try? String(contentsOf: first)) == "first" && (try? String(contentsOf: second)) == "second",
                "save-all keeps both same-name attachments without overwriting")
        let third = try MailAttachmentExport.save(Data("third".utf8), name: "../escape.txt", directory: folder)
        require(third.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path && !FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path), "attachment names cannot escape chosen destination")
    } catch { require(false, "attachment export fixture failed: \(error)") }
}
