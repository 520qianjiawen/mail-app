import AppKit

@MainActor private final class SignatureTestGate {
    private var entered = false, released = false
    private var entry: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; let waiting = entry; entry.removeAll(); waiting.forEach { $0.resume() }
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entry.append($0) } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor private func signatureContext(_ state: AppState) {
    for account in state.accounts {
        state.sessions[account.id] = MailboxSession(accountID: account.id, remoteID: "100", email: account.id + "@example.test", origin: URL(string: "https://mail.zoho.com")!, folders: [], addresses: [account.id + "@example.test", "alias-" + account.id + "@example.test"])
    }
}

@MainActor func runMailAccountSignatureTests(_ require: (Bool, String) -> Void) async {
    func expectError(_ label: String, _ body: () throws -> Void) { do { try body(); require(false, label) } catch { require(true, label) } }
    func occurrences(_ needle: String, _ body: String) -> Int { body.components(separatedBy: needle).count - 1 }
    // Real preferences, fixture-only directories; validation and failed persistence.
    do {
        let state = AppState(fixture: true), a = state.accounts[0].id, b = state.accounts[1].id
        let one = try state.saveLocalSignature(accountID: a, name: "Work", html: "<b>WORK-SIGNATURE</b><script>bad()</script><img src='https://outside.example/x'>")
        require(!one.html.contains("script") && one.html.contains("https://outside.example/x"), "local HTML removes scripts while retaining authored HTTPS image source")
        require(state.signatureSettings(a).items.count == 1 && state.signatureSettings(b).items.isEmpty, "local signatures are isolated by account")
        let reloaded = PreferenceFile(directory: state.preferences.directory)
        require(reloaded.value.accountSignatures[a]?.items.first?.id == one.id, "local signature CRUD persists through real preferences file")
        expectError("duplicate names are rejected case insensitively") { _ = try state.saveLocalSignature(accountID: a, name: "work", html: "<p>x</p>") }
        expectError("empty name is rejected") { _ = try state.saveLocalSignature(accountID: a, name: "  ", html: "<p>x</p>") }
        expectError("empty HTML is rejected") { _ = try state.saveLocalSignature(accountID: a, name: "X", html: "<script>x</script>") }
        expectError("oversized HTML is rejected") { _ = try state.saveLocalSignature(accountID: a, name: "X", html: String(repeating: "x", count: 256 * 1024 + 1)) }
        expectError("unknown account cannot receive a signature") { _ = try state.saveLocalSignature(accountID: "absent", name: "X", html: "X") }
        expectError("editing missing ID cannot silently create another record") { _ = try state.saveLocalSignature(accountID: a, id: UUID().uuidString, name: "X", html: "X") }
        let edited = try state.saveLocalSignature(accountID: a, id: one.id, name: "Renamed", html: "<i>EDITED-SIGNATURE</i>")
        require(edited.id == one.id && state.signatureSettings(a).items.count == 1, "editing preserves ID without duplicate rows")
        require(state.setSignatureChoice(accountID: a, alias: nil, reply: false, choice: "local:" + one.id), "account new default persists")
        require(state.setSignatureChoice(accountID: a, alias: "Alias@Example.test", reply: true, choice: "local:" + one.id), "alias override normalizes address")
        require(state.deleteLocalSignature(accountID: a, id: one.id), "delete succeeds with real disk write")
        let deleted = state.signatureSettings(a)
        require(deleted.items.isEmpty && deleted.defaults.new == "none" && deleted.aliases["alias@example.test"]?.reply == "none", "delete revokes explicit account and alias references without unrelated fallback")
        var full = AccountSignatureSettings(); full.legacyMigrated = true
        full.items = (0..<100).map { LocalMailSignature(name: "Signature \($0)", html: "<p>\($0)</p>") }
        state.preferences.value.accountSignatures[a] = full
        expectError("100-item limit rejects new data instead of silently dropping persisted row") { _ = try state.saveLocalSignature(accountID: a, name: "Overflow", html: "x") }
        _ = state.shutdown()
    } catch { require(false, "CRUD test setup: \(error)") }
    do {
        var prefs = NativePreferences(); prefs.accounts = [MailAccount(id: "legacy", name: "Legacy", region: "global")]
        prefs.signatures = ["legacy": "<p>LEGACY-LOCAL</p>"]; prefs.defaultSignatureByAccount = ["legacy": "77"]
        SignaturePolicy.migrate(&prefs)
        let first = prefs.accountSignatures["legacy"]!
        SignaturePolicy.migrate(&prefs)
        require(first.items.count == 1 && prefs.accountSignatures["legacy"]?.items.first?.id == first.items.first?.id, "legacy HTML migration is idempotent")
        require(first.defaults.new == "remote:77" && first.defaults.reply == "remote:77", "legacy remote default ID migrates without invented alias mapping")
        let roundtrip = try JSONDecoder().decode(NativePreferences.self, from: JSONEncoder().encode(prefs))
        require(roundtrip.accountSignatures["legacy"] == first, "signature settings Codable round trip preserves migration marker and rules")
        let id = UUID().uuidString.lowercased()
        let malformed = """
        {"accounts":[],"future_unknown":{"x":1},"accountSignatures":{"ok":{"items":[{"id":"\(id)","name":"A","html":"<b>safe</b>"},{"id":"\(id)","name":"Duplicate","html":"x"},{"id":false},{"id":"invalid","name":"Bad","html":"x"}],"defaults":{"new":"garbage","reply":22},"unknown":true},"bad":false}}
        """
        let decoded = try JSONDecoder().decode(NativePreferences.self, from: Data(malformed.utf8))
        require(decoded.accountSignatures["ok"]?.items.count == 1, "malformed and duplicate rows are skipped without discarding valid row")
        require(decoded.accountSignatures["ok"]?.defaults == SignatureDefaults(new: "none", reply: "none"), "invalid choices fail closed rather than selecting an unrelated sole signature")
        require(decoded.accountSignatures["bad"]?.defaults.new == "none", "malformed account setting does not erase valid sibling account")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signature-write-failure-" + UUID().uuidString)
        try Data("regular file".utf8).write(to: directory)
        let blocked = PreferenceFile(directory: directory)
        require(!blocked.save(), "preferences exposes actual directory-is-file write failure")
        let state = AppState(fixture: true), account = state.accounts[0].id
        let before = state.preferences.value.accountSignatures
        let target = state.preferences.directory.appendingPathComponent("preferences.json").standardizedFileURL
        guard target.deletingLastPathComponent() == state.preferences.directory.standardizedFileURL,
              state.preferences.directory.lastPathComponent.hasPrefix("mail-lite-fixture-") else { require(false, "fixture failure target identity"); return }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        expectError("CRUD surfaces disk failure instead of claiming saved") { _ = try state.saveLocalSignature(accountID: account, name: "Not saved", html: "x") }
        require(state.preferences.value.accountSignatures == before, "failed local CRUD rolls in-memory preference mutation back")
        require(!state.setSignatureChoice(accountID: account, alias: nil, reply: false, choice: "none"), "default selection reports disk failure")
        require(state.preferences.value.accountSignatures == before, "failed default save rolls in-memory rules back")
        _ = state.shutdown()
    } catch { require(false, "migration/persistence setup: \(error)") }

    // Pure rule semantics, including no stale/unknown-ID fallback.
    do {
        var settings = AccountSignatureSettings()
        let a = LocalMailSignature(name: "A", html: "<p>A</p>"), b = LocalMailSignature(name: "B", html: "<p>B</p>")
        settings.items = [a, b]; settings.defaults = SignatureDefaults(new: "local:" + a.id, reply: "none")
        settings.aliases["alias@example.test"] = SignatureDefaults(new: "local:" + b.id, reply: "automatic")
        let options = SignaturePolicy.options(settings: settings, remote: [MailSignature(id: "1", name: "Server", html: "<b>Remote</b>")])
        require(SignaturePolicy.selected(settings: settings, from: "owner@example.test", reply: false, options: options)?.id == "local:" + a.id, "new mail resolves account new rule")
        require(SignaturePolicy.selected(settings: settings, from: "owner@example.test", reply: true, options: options) == nil, "reply-none wins even with sole/available server signature")
        require(SignaturePolicy.selected(settings: settings, from: "ALIAS@example.test", reply: false, options: options)?.id == "local:" + b.id, "alias From selection overrides only that identity")
        require(SignaturePolicy.selected(settings: settings, from: "alias@example.test", reply: true, options: options) == nil, "automatic does not arbitrarily choose among multiple candidates")
        settings.defaults.new = "remote:missing"
        require(SignaturePolicy.selected(settings: settings, from: "owner@example.test", reply: false, options: Array(options.prefix(1))) == nil, "missing explicit default does not fall back to unrelated sole candidate")
        require(SignaturePolicy.options(settings: settings, remote: [MailSignature(id: "1", name: "A", html: "X"), MailSignature(id: "1", name: "B", html: "Y")]).count == 3, "remote duplicate IDs are not repeated in selection menu")
    }
    // Real NSTextView ownership, quote placement, caret, user editing/deletion.
    do {
        let editor = EditorHandle(), view = NSTextView()
        editor.setText("USER BODY\n" + ComposeDocument.quoteMarker + "\nQUOTED SIGNATURE")
        editor.attach(view); view.setSelectedRange(NSRange(location: 3, length: 0))
        _ = editor.replaceManagedSignature("<b>OWNED-A</b>", reference: "remote:1", identity: "PRIVATE-IDENTITY-DO-NOT-EXPORT", beforeQuote: true, allowInsert: true)
        let first = editor.plainText()
        let outgoing = editor.html(), ownerToken = editor.signatureOwnership!.token
        require(!outgoing.contains("MailLiteOwnedSignature") && !outgoing.contains(ownerToken) && !outgoing.contains("PRIVATE-IDENTITY-DO-NOT-EXPORT"), "outgoing HTML exports formatting but no internal ownership token or account identity")
        require((first as NSString).range(of: "OWNED-A").location < (first as NSString).range(of: ComposeDocument.quoteMarker).location, "managed reply signature is before quote marker")
        require(first.contains("USER BODY") && first.contains("QUOTED SIGNATURE") && view.selectedRange().location == 3, "insertion preserves body quote and existing caret")
        _ = editor.replaceManagedSignature("<i>OWNED-B</i>", reference: "remote:1", identity: "B", beforeQuote: true, allowInsert: true)
        require(!editor.plainText().contains("OWNED-A") && occurrences("OWNED-B", editor.plainText()) == 1, "same signature ID under changed identity replaces instead of accumulates")
        _ = editor.replaceManagedSignature(nil, identity: "C", beforeQuote: true, allowInsert: true)
        require(!editor.plainText().contains("OWNED-B") && editor.plainText().contains("QUOTED SIGNATURE"), "none removes only owned signature, never quote signature")
        let typed = EditorHandle(), typedView = NSTextView(); typed.attach(typedView)
        _ = typed.replaceManagedSignature("<b>TYPING-A</b>", reference: "remote:1", identity: "A", beforeQuote: false, allowInsert: true)
        typedView.setSelectedRange(NSRange(location: 0, length: 0)); typedView.insertText("MY BODY", replacementRange: typedView.selectedRange())
        require(typed.hasVerifiedSignature, "normal typing before signature does not inherit ownership marker")
        let caret = typedView.selectedRange()
        _ = typed.replaceManagedSignature("<b>TYPING-B</b>", reference: "remote:2", identity: "B", beforeQuote: false, allowInsert: true)
        require(typed.plainText().contains("MY BODY") && !typed.plainText().contains("TYPING-A") && typed.plainText().contains("TYPING-B") && typedView.selectedRange() == caret, "From replacement preserves typed body and caret")
        let owned = (typed.plainText() as NSString).range(of: "TYPING-B")
        typedView.setSelectedRange(owned); typedView.insertText("USER EDITED", replacementRange: owned)
        if case .protected = typed.replaceManagedSignature("<b>NEW BRAND</b>", reference: "remote:3", identity: "C", beforeQuote: false, allowInsert: true) { require(true, "user-edited signature revokes automatic ownership") } else { require(false, "user-edited signature revokes automatic ownership") }
        require(typed.plainText().contains("USER EDITED") && !typed.plainText().contains("NEW BRAND"), "user signature edit is never deleted or followed by silent automatic duplicate")
        let removed = EditorHandle(); removed.setText("")
        _ = removed.replaceManagedSignature("<p>DELETED</p>", identity: "A", beforeQuote: false, allowInsert: true)
        removed.setText("")
        _ = removed.replaceManagedSignature("<p>SHOULD NOT RETURN</p>", identity: "B", beforeQuote: false, allowInsert: true)
        require(removed.plainText().isEmpty, "user deletion of managed segment does not resurrect another signature")
        let quoteGone = EditorHandle(); quoteGone.setText("User removed quote")
        _ = quoteGone.replaceManagedSignature("<p>NO INSERT</p>", identity: "A", beforeQuote: true, allowInsert: true)
        require(quoteGone.plainText() == "User removed quote", "missing reply quote marker prevents guessed insertion")
    }
    // Actual ComposeModel local/remote paths, manual choices and restored drafts.
    do {
        let state = AppState(fixture: true); signatureContext(state)
        let a = state.accounts[0].id, b = state.accounts[1].id
        let from = state.sessions[a]!.addresses[0], alias = state.sessions[a]!.addresses[1]
        let local = try state.saveLocalSignature(accountID: a, name: "Local", html: "<b>LOCAL-OFFLINE</b>")
        let other = try state.saveLocalSignature(accountID: a, name: "Alias", html: "<p>ALIAS-BRAND</p>")
        _ = state.setSignatureChoice(accountID: a, alias: nil, reply: false, choice: "local:" + local.id)
        _ = state.setSignatureChoice(accountID: a, alias: alias, reply: false, choice: "local:" + other.id)
        _ = state.setSignatureChoice(accountID: a, alias: nil, reply: true, choice: "none")
        state.signatureFetchHook = { _, _ in throw MailFailure.network }
        let model = ComposeModel(state: state, draft: MailDraft(accountID: a, from: from, mode: "new"))
        await model.waitForSignatures()
        require(model.editor.plainText().contains("LOCAL-OFFLINE") && model.signatureOptions.contains(where: { $0.id == "local:" + local.id }), "failed remote request preserves usable local default and menu")
        require(state.accountSessions.isEmpty, "signature fixture performs no real session construction")
        let aliasIndex = model.fromOptions.firstIndex { $0.0 == a && $0.1 == alias }!
        model.sending = true
        model.applyFrom(aliasIndex)
        require(model.draft.from == from, "sending HTML snapshot freezes From identity until queue handoff completes")
        model.sending = false
        model.applyFrom(aliasIndex); await model.waitForSignatures()
        require(model.editor.plainText().contains("ALIAS-BRAND") && !model.editor.plainText().contains("LOCAL-OFFLINE"), "actual ComposeModel From alias applies correct rule and replaces owned local signature")
        let before = state.preferences.value.accountSignatures[a]
        model.insertSignature(model.signatureOptions.first { $0.id == "local:" + local.id }!)
        await model.waitForSignatures()
        require(state.preferences.value.accountSignatures[a] == before, "manual insertion never modifies account default rules")
        require(occurrences("LOCAL-OFFLINE", model.editor.plainText()) == 1 && !model.editor.plainText().contains("ALIAS-BRAND"), "manual selection replaces current owned signature rather than appending")
        require(await model.persistDraftFlushed(), "managed draft persists browser HTML and ownership proof")
        let saved = state.draftStore.all(accounts: [a]).first { $0.id == model.draft.id }!
        let reopened = ComposeModel(state: state, draft: saved); await reopened.waitForSignatures()
        require(occurrences("LOCAL-OFFLINE", reopened.editor.plainText()) == 1 && !reopened.editor.plainText().contains("ALIAS-BRAND"), "restored draft retains manual signature without default duplication")
        require((await reopened.editor.flush()).signature != nil, "HTML ownership proof restores exact managed DOM segment")
        let bIndex = reopened.fromOptions.firstIndex { $0.0 == b }!
        reopened.applyFrom(bIndex); await reopened.waitForSignatures()
        require(!reopened.editor.plainText().contains("LOCAL-OFFLINE") && reopened.signatureOptions.isEmpty, "changing account removes former account's owned signature and menu")
        let sourceMessage = MailMessage(accountID: a, remoteID: "100", folderID: "500", id: "9", origin: URL(string: "https://mail.zoho.com")!, subject: "Source", sender: "sender@example.test", preview: "", date: Date(), attachment: false, unread: false)
        let source = MailDetail(message: sourceMessage, from: "sender@example.test", to: from, cc: "", replyTo: "", html: "<p>QUOTED-ORIGINAL</p>", attachments: [], inline: [])
        var replyDraft = MailDraft(accountID: a, from: from, mode: "reply"); replyDraft.source = source
        let replyModel = ComposeModel(state: state, draft: replyDraft); await replyModel.waitForSignatures()
        require(!replyModel.editor.plainText().contains("LOCAL-OFFLINE") && replyModel.editor.plainText().contains("QUOTED-ORIGINAL"), "actual reply mode honors separate none rule and preserves quote")
        model.stopBackgroundWork(); reopened.stopBackgroundWork(); replyModel.stopBackgroundWork()
        await state.removeAccountAndWait(state.accounts.first { $0.id == a }!)
        require(state.preferences.value.accountSignatures[a] == nil && state.preferences.value.defaultSignatureByAccount[a] == nil && state.preferences.value.signatures?[a] == nil, "account removal clears local rules alias overrides and legacy signatures")
        _ = state.shutdown()
    } catch { require(false, "Compose local/draft setup: \(error)") }
    do {
        let state = AppState(fixture: true); signatureContext(state)
        let a = state.accounts[0].id, from = state.sessions[a]!.addresses[0], alias = state.sessions[a]!.addresses[1]
        let first = SignatureTestGate(), second = SignatureTestGate(), third = SignatureTestGate()
        var primaryRequests = 0
        state.signatureFetchHook = { _, address in
            if address == from {
                primaryRequests += 1
                if primaryRequests == 1 { await first.pause(); return [MailSignature(id: "7", name: "Old", html: "<b>STALE-A</b>")] }
                await third.pause(); return [MailSignature(id: "7", name: "Fresh", html: "<b>FRESH-A</b>")]
            }
            await second.pause(); return [MailSignature(id: "7", name: "New", html: "<b>CURRENT-B</b>")]
        }
        let model = ComposeModel(state: state, draft: MailDraft(accountID: a, from: from, mode: "new"))
        await first.wait()
        let oldWork = model.signatureWork
        model.applyFrom(model.fromOptions.firstIndex { $0.1 == alias }!)
        await second.wait()
        require(model.signatureOptions.isEmpty, "From change clears prior identity menu while async request is pending")
        second.release(); await model.waitForSignatures()
        require(model.editor.plainText().contains("CURRENT-B"), "same-account alias response selects correct current identity")
        model.applyFrom(model.fromOptions.firstIndex { $0.1 == from }!)
        await third.wait(); third.release(); await model.waitForSignatures()
        require(model.editor.plainText().contains("FRESH-A") && !model.editor.plainText().contains("CURRENT-B"), "A to B to A replaces same-ID signature using a new request epoch")
        first.release(); await oldWork?.value
        require(!model.editor.plainText().contains("STALE-A") && occurrences("FRESH-A", model.editor.plainText()) == 1, "old same-account same-From same-ID response cannot defeat new identity epoch")
        require(state.cachedRemoteSignatures(accountID: a, from: from).first?.html.contains("FRESH-A") == true && state.accountSessions.isEmpty, "cancelled old identity cannot overwrite fresh cache or construct browser session")
        model.stopBackgroundWork(); _ = state.shutdown()
    }
    do {
        let state = AppState(fixture: true); signatureContext(state)
        let a = state.accounts[0].id, from = state.sessions[a]!.addresses[0]
        let item = try state.saveLocalSignature(accountID: a, name: "Resolved", html: "<b>CANONICAL-FROM-LOCAL</b>")
        _ = state.setSignatureChoice(accountID: a, alias: nil, reply: false, choice: "none")
        _ = state.setSignatureChoice(accountID: a, alias: from, reply: false, choice: "local:" + item.id)
        let blank = SignatureTestGate()
        state.signatureFetchHook = { _, address in
            if address.isEmpty { await blank.pause(); return [MailSignature(id: "11", name: "Old blank", html: "<p>BLANK-FROM-STALE</p>")] }
            return []
        }
        let model = ComposeModel(state: state, draft: MailDraft(accountID: a, from: "", mode: "new"))
        await blank.wait(); let old = model.signatureWork
        model.syncFromIndex(); await model.waitForSignatures()
        blank.release(); await old?.value
        require(model.draft.from == from && model.editor.plainText().contains("CANONICAL-FROM-LOCAL") && !model.editor.plainText().contains("BLANK-FROM-STALE"), "syncFromIndex canonicalizes blank From then loads exact alias default and drops old blank response")
        model.stopBackgroundWork(); _ = state.shutdown()
    } catch { require(false, "blank From setup: \(error)") }
    for removeAccount in [false, true] {
        let state = AppState(fixture: true), gate = SignatureTestGate(), account = state.accounts[0]
        state.signatureFetchHook = { _, _ in await gate.pause(); return [MailSignature(id: "9", name: "Late", html: "<p>LATE</p>")] }
        let pending = Task { @MainActor in try? await state.fetchAccountSignatures(accountID: account.id, from: "identity@example.test") }
        await gate.wait()
        if removeAccount { await state.removeAccountAndWait(account) } else { _ = state.shutdown() }
        gate.release()
        let result = await pending.value
        require(result == nil && state.cachedRemoteSignatures(accountID: account.id, from: "identity@example.test").isEmpty, removeAccount ? "late server signature cannot resurrect removed account cache" : "late settings signature fetch cannot cache after shutdown")
        if !removeAccount {
            let afterShutdown = try? await state.fetchAccountSignatures(accountID: account.id, from: "new@example.test")
            require(afterShutdown == nil, "new signature fetch cannot start after shutdown")
        }
        _ = state.shutdown()
    }
}
