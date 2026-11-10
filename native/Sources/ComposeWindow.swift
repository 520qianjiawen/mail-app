import SwiftUI
import AppKit
import Combine

enum ComposeMode: String { case new, reply, replyAll, forward, edit }

// MARK: - Controller

@MainActor final class ComposeController: NSObject, NSWindowDelegate {
    let state: AppState
    let model: ComposeModel
    let window: NSWindow
    var busy: Bool { model.sending || model.syncing }
    var draft: MailDraft { model.draft }
    private var isClosing = false
    private var didClose = false

    init(state: AppState, draft: MailDraft) {
        self.state = state
        model = ComposeModel(state: state, draft: draft)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = model.windowTitle
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 860, height: 640)
        let host = NSHostingView(rootView: ComposeView(model: model))
        window.contentView = host
        model.onClose = { [weak self] in self?.closeWindow() }
        model.onDismiss = { [weak self] in self?.close(save: true) }
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(save: Bool) {
        if isClosing {
            closeWindow()
            return
        }
        isClosing = true
        if !save || model.isCompletelyEmptyNewDraft {
            model.discard()
            closeWindow()
            return
        }
        model.editor.setEditingEnabled(false)
        model.cloudTask?.cancel()
        model.syncing = false
        Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var finished = false
                Task { @MainActor in
                    _ = await self.model.persistDraftFlushed()
                    if !finished {
                        finished = true
                        continuation.resume()
                    }
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if !finished {
                        finished = true
                        continuation.resume()
                    }
                }
            }
            self.model.persistFallbackDraft()
            self.closeWindow()
        }
    }
    func persistDraft() { model.persistDraft() }
    func persistDraftFlushed() async -> Bool { await model.persistDraftFlushed() }

    private func closeWindow() {
        guard !didClose else { return }
        didClose = true
        model.stopBackgroundWork()
        window.delegate = nil
        window.close()
        state.composeClosed(self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.sending { return false }
        if isClosing { return true }
        close(save: true)
        return false
    }
}

// MARK: - Model

@MainActor final class ComposeModel: NSObject, ObservableObject {
    let state: AppState
    var draft: MailDraft
    let editor = WebHTMLComposerHandle()
    var onClose: (() -> Void)?
    var onDismiss: (() -> Void)?
    private var signatureTask: Task<Void, Never>?
    private var signatureApplicationTask: Task<Void, Never>?
    private var automaticSignatureEligible = false
    private var signatureIdentityToken = UUID()
    private var signaturePreserveIdentity: String?
    private var signatureSubscription: AnyCancellable?
    private var senderIdentitySubscription: AnyCancellable?
    private var signaturesStopped = false
    var cloudTask: Task<Void, Never>?
    private(set) var sendTask: Task<Void, Never>?

    @Published var to: String
    @Published var cc: String
    @Published var bcc: String
    @Published var subject: String
    @Published var showCc: Bool
    @Published var showBcc: Bool
    @Published var fromIndex: Int = 0
    @Published var receipt: Bool
    @Published var trackingEnabled: Bool
    @Published var priority: Int
    @Published var scheduledAt: Date?
    @Published var attachments: [URL] = []
    @Published var status = ""
    @Published var sending = false { didSet { editor.setEditingEnabled(!sending && !syncing) } }
    @Published var syncing = false { didSet { editor.setEditingEnabled(!sending && !syncing) } }
    @Published private(set) var preparingReply = false
    var busy: Bool { sending || syncing }
    @Published var signatureOptions: [MailSignature] = []
    @Published var showSchedulePicker = false
    @Published var showTemplates = false
    @Published var templateItems: [MailMessage] = []
    @Published var templateLoading = false

    var fromOptions: [(String, String)] {
        var values: [(String, String)] = []
        let accountIDs: [String]
        if draft.cloudID == nil {
            var ids = [draft.accountID]
            for acc in state.accounts {
                if !ids.contains(acc.id) { ids.append(acc.id) }
            }
            accountIDs = ids
        } else {
            accountIDs = [draft.accountID]
        }
        for id in accountIDs {
            let sessionAddresses = state.sessions[id]?.addresses ?? []
            let addresses: [String]
            if !sessionAddresses.isEmpty {
                addresses = sessionAddresses
            } else if let accName = state.accounts.first(where: { $0.id == id })?.name, !accName.isEmpty {
                addresses = [accName]
            } else if id == draft.accountID && !draft.from.isEmpty {
                addresses = [draft.from]
            } else {
                addresses = []
            }
            for address in addresses { values.append((id, address)) }
        }
        return values
    }

    func senderLabel(accountID: String, address: String) -> String {
        let name = state.effectiveSenderDisplayName(accountID: accountID, from: address)
        return MailComposerSenderLabel.format(address: address, name: name)
    }

    var mode: ComposeMode { ComposeMode(rawValue: draft.mode) ?? .new }
    var windowTitle: String {
        switch mode {
        case .new: return "新邮件"
        case .reply: return "回复"
        case .replyAll: return "回复全部"
        case .forward: return "转发"
        case .edit: return "编辑草稿"
        }
    }
    var canSend: Bool {
        !sending && !syncing && !preparingReply && draft.state == "editing" && !draft.cloudUncertain && editor.failure == nil &&
        !state.outboxStore.all().contains { ($0.draftID == draft.id || $0.id == draft.queuedItemID) && $0.state != "cancelled" }
    }

    init(state: AppState, draft: MailDraft) {
        self.state = state
        self.draft = draft
        to = draft.to; cc = draft.cc; bcc = draft.bcc; subject = draft.subject
        showCc = !draft.cc.isEmpty || ComposeMode(rawValue: draft.mode) == .replyAll
        showBcc = !draft.bcc.isEmpty
        receipt = draft.receipt
        trackingEnabled = draft.trackingEnabled ?? false
        priority = [1, 3, 5].contains(draft.priority ?? 3) ? (draft.priority ?? 3) : 3
        attachments = state.draftStore.files(draft)
        super.init()
        editor.onPasteError = { [weak self] message in self?.status = message }
        editor.onReplyPreparationChange = { [weak self] in self?.preparingReply = $0 }
        let restored = draft.htmlBody != nil && draft.htmlSignature != nil
        if let html = draft.htmlBody {
            editor.restoreHTML(html, signature: draft.htmlSignature)
        } else if let rtf = draft.rtf, let value = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            // One-time legacy draft migration only. New HTML never enters AppKit import/export.
            let data = try? value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
            editor.loadHTML(data.flatMap { String(data: $0, encoding: .utf8) } ?? MailHTML.escape(value.string))
        } else if let source = draft.source, [.reply, .replyAll, .forward].contains(mode) {
            editor.loadReplyForMessageInBackground(body: draft.body, source: source)
        } else { editor.setText(draft.body) }
        automaticSignatureEligible = restored || draft.htmlBody == nil && draft.rtf == nil && draft.body.isEmpty && mode != .edit
        if restored { signaturePreserveIdentity = SignaturePolicy.identity(account: draft.accountID, from: draft.from) }
        else if !automaticSignatureEligible { signaturePreserveIdentity = "*" }
        if draft.managedSignature != nil && !restored { status = "已保留旧草稿签名；自动替换已暂停，请手动检查。" }
        loadSignatures()
        signatureSubscription = state.$signaturesVersion.dropFirst().sink { [weak self] _ in self?.loadSignatures(refreshRemote: false) }
        senderIdentitySubscription = state.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func syncFromIndex() {
        let previousIdentity = SignaturePolicy.identity(account: draft.accountID, from: draft.from)
        let options = fromOptions
        if let index = options.firstIndex(where: { $0.0 == draft.accountID && $0.1 == draft.from }) {
            fromIndex = index
        } else if let index = options.firstIndex(where: { $0.0 == draft.accountID }) {
            fromIndex = index
            draft.from = options[index].1
        }
        if SignaturePolicy.identity(account: draft.accountID, from: draft.from) != previousIdentity { loadSignatures() }
    }

    func applyFrom(_ index: Int) {
        guard !sending, !syncing else { return }
        let options = fromOptions
        guard options.indices.contains(index) else { return }
        let oldAccountID = draft.accountID
        let oldFrom = draft.from
        let oldDefaultBcc = state.defaultBcc(for: oldAccountID, from: oldFrom)

        fromIndex = index
        draft.accountID = options[index].0
        draft.from = options[index].1

        let newDefaultBcc = state.defaultBcc(for: draft.accountID, from: draft.from)
        if bcc.trimmed == oldDefaultBcc.trimmed {
            bcc = newDefaultBcc
            if !newDefaultBcc.isEmpty { showBcc = true }
        } else if !oldFrom.isEmpty && !draft.from.isEmpty && bcc.localizedCaseInsensitiveContains(oldFrom) {
            let parts = MailAddresses.extract(bcc)
            if parts.contains(where: { $0.caseInsensitiveCompare(oldFrom) == .orderedSame }) {
                let updated = parts.map { $0.caseInsensitiveCompare(oldFrom) == .orderedSame ? draft.from : $0 }
                bcc = updated.joined(separator: ", ")
                showBcc = true
            }
        }

        loadSignatures()
        scheduleSave()
    }

    func loadSignatures(refreshRemote: Bool = true) {
        signatureTask?.cancel()
        signatureIdentityToken = UUID()
        let token = signatureIdentityToken, accountID = draft.accountID, from = draft.from
        signatureOptions = []
        guard !signaturesStopped, state.accounts.contains(where: { $0.id == accountID }) else { return }
        updateSignatureOptions(remote: state.cachedRemoteSignatures(accountID: accountID, from: from))
        guard refreshRemote, !state.fixture || state.signatureFetchHook != nil else { return }
        signatureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let options = try await state.fetchAccountSignatures(accountID: accountID, from: from)
                try Task.checkCancellation()
                guard signatureIdentityToken == token, draft.accountID == accountID,
                      SignaturePolicy.address(draft.from) == SignaturePolicy.address(from), !signaturesStopped else { return }
                updateSignatureOptions(remote: options)
            } catch {
                guard !Task.isCancelled, signatureIdentityToken == token, !signaturesStopped else { return }
                // Cached server signatures and every local signature remain usable.
                status = "服务器签名读取失败；本机签名仍可使用。"
            }
        }
    }

    private func updateSignatureOptions(remote: [MailSignature]) {
        let settings = state.signatureSettings(draft.accountID)
        signatureOptions = SignaturePolicy.options(settings: settings, remote: remote)
        let identity = SignaturePolicy.identity(account: draft.accountID, from: draft.from)
        guard automaticSignatureEligible, signaturePreserveIdentity != "*", signaturePreserveIdentity != identity else { return }
        let signature = SignaturePolicy.selected(settings: settings, from: draft.from, reply: [.reply, .replyAll, .forward].contains(mode), options: signatureOptions)
        let token = signatureIdentityToken
        signatureApplicationTask = Task { @MainActor [weak self] in
            guard let self, token == signatureIdentityToken, !signaturesStopped else { return }
            let result = await editor.replaceManagedSignatureHTML(signature?.html, reference: signature?.id ?? "none", identity: identity, beforeQuote: draft.source != nil && [.reply, .replyAll, .forward].contains(mode), allowInsert: true, isCurrent: { [weak self] in self?.signatureIdentityToken == token && self?.signaturesStopped == false })
            guard token == signatureIdentityToken, !signaturesStopped else { return }
            switch result {
            case .changed: scheduleSave()
            case .protected:
                automaticSignatureEligible = false
                status = "已保留你编辑或删除的签名/引用；自动替换已暂停，请手动检查发件身份。"
            case .unchanged: break
            }
        }
    }

    var signatureWork: Task<Void, Never>? { signatureTask }
    func waitForSignatures() async { await signatureTask?.value; await signatureApplicationTask?.value; _ = await editor.flush() }

    // MARK: Send

    func send(schedule: Bool = false, archiveOriginal: Bool = false) {
        guard canSend else { return }
        if trackingEnabled && !state.tracking.connected {
            status = "请先配置自己的追踪服务，或关闭邮件追踪后发送。"
            return
        }
        guard let addresses = MailAddresses.validated(to), !addresses.isEmpty,
              let copies = MailAddresses.validated(cc), let blind = MailAddresses.validated(bcc) else {
            status = "请检查收件人、抄送和密送地址"
            return
        }
        let options = fromOptions
        guard options.indices.contains(fromIndex) else {
            status = "请选择发件地址"
            return
        }
        let (accountID, from) = options[fromIndex]
        // Freeze every envelope field and the selected per-address name before
        // the first await; settings can change while WebKit flushes the body.
        var captured = MailSenderWire.captureConfigured(state: state, accountID: accountID, from: from,
            to: addresses.joined(separator: ","), cc: copies.joined(separator: ","),
            bcc: blind.joined(separator: ","), subject: subject.trimmed)
        captured.cloudDraftIDs = Array(Set((draft.cloudID.map { [$0] } ?? []) + (draft.obsoleteCloudIDs ?? [])))
        captured.draftID = draft.id
        if mode == .edit, draft.cloudID != nil { captured.serverDraft = draft.source?.message }
        captured.receipt = receipt
        captured.trackingEnabled = trackingEnabled
        captured.priority = priority
        captured.replyToMessageID = mode == .reply || mode == .replyAll ? draft.source?.message.id : nil
        captured.forwardOf = mode == .forward ? draft.source?.message : nil
        if captured.replyToMessageID != nil {
            captured.replySource = draft.source?.message
            captured.inReplyTo = draft.source?.rfcMessageID
            captured.referencesHeader = draft.source?.rfcReferences
        }
        captured.archiveAfterSend = archiveOriginal ? draft.source?.message : nil
        captured.scheduledAt = schedule ? (scheduledAt ?? Date().addingTimeInterval(3600)) : nil
        let queued = captured
        let queuedAttachments = attachments
        if state.fixture && state.outboxSendHook == nil { status = "测试模式不会发送邮件"; return }
        sending = true
        sendTask = Task { @MainActor in
        let snapshot = await editor.flush()
        guard editor.failure == nil else { sending = false; status = "HTML 编辑器读取失败，邮件未加入队列"; return }
        var item = queued
        item.html = snapshot.outgoingHTML
        do {
            for file in queuedAttachments {
                _ = try state.outboxStore.importAttachment(file, id: item.id)
            }
        } catch {
            status = "附件无法加入发送队列（单个文件上限 25 MB）"
            sending = false
            return
        }
        // The editable draft and durable job share one identity. Only an
        // acknowledged queue write may close the composer or start a transport.
        self.draft.state = "queued"; self.draft.queuedItemID = item.id
        guard await self.persistDraftFlushed() else {
            self.draft.state = "editing"; self.draft.queuedItemID = nil
            self.sending = false; self.status = "草稿保存失败，邮件未发送"; return
        }
        guard state.enqueueSend(item) else {
            self.draft.state = "editing"; self.draft.queuedItemID = nil
            _ = await self.persistDraftFlushed()
            self.sending = false
            self.status = state.outboxStore.persistenceError ?? "此草稿已在发件箱，请先查看已有任务"
            return
        }
        self.sending = false
        self.status = item.scheduledAt == nil ? "已加入发件箱" : "已安排稍后发送"
        self.onClose?()
        }
    }

    // MARK: Draft persistence

    func scheduleSave() {
        draft.to = to; draft.cc = cc; draft.bcc = bcc; draft.subject = subject
        draft.receipt = receipt
        draft.trackingEnabled = trackingEnabled
        draft.priority = priority
        draft.updated = Date()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveNow), object: nil)
        perform(#selector(saveNow), with: nil, afterDelay: 0.7)
    }

    @objc func saveNow() {
        persistDraft()
    }

    /// Compatibility fire-and-forget entry; lifecycle/save/send use the awaited variant.
    @discardableResult func persistDraft() -> Bool {
        Task { @MainActor in _ = await persistDraftFlushed() }
        return true
    }

    @discardableResult func persistDraftFlushed() async -> Bool {
        guard draft.state != "sent" else { return true }
        let snapshot = await editor.flush()
        guard editor.failure == nil, draft.state != "sent" else {
            persistFallbackDraft()
            return draft.state == "sent"
        }
        draft.to = to; draft.cc = cc; draft.bcc = bcc; draft.subject = subject
        draft.receipt = receipt; draft.priority = priority; draft.trackingEnabled = trackingEnabled
        draft.body = snapshot.text
        draft.htmlBody = snapshot.html; draft.htmlSignature = snapshot.signature
        draft.rtf = nil; draft.managedSignature = nil
        draft.files = attachments.map { $0.path }; draft.updated = Date()
        do {
            try state.draftStore.save(draft)
            state.draftsVersion += 1
            return true
        } catch {
            persistFallbackDraft()
            return false
        }
    }

    var isCompletelyEmptyNewDraft: Bool {
        guard mode == .new else { return false }
        let hasTo = !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCc = !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSubject = !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFiles = !attachments.isEmpty
        // Strip signature/quote blocks before checking body — a new draft with only
        // a pre-inserted signature but no authored content is still considered empty.
        let html = editor.canonicalHTML
        let authoredText: String
        if html.isEmpty {
            authoredText = editor.plainText().trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            authoredText = MailHTML.authoredPlainText(from: html)
        }
        return !hasTo && !hasCc && !hasSubject && !hasFiles && authoredText.isEmpty
    }

    func persistFallbackDraft() {
        guard draft.state != "sent" else { return }
        draft.to = to; draft.cc = cc; draft.bcc = bcc; draft.subject = subject
        draft.receipt = receipt; draft.priority = priority; draft.trackingEnabled = trackingEnabled
        if !editor.canonicalHTML.isEmpty {
            draft.htmlBody = editor.canonicalHTML
        }
        draft.files = attachments.map { $0.path }
        draft.updated = Date()
        try? state.draftStore.save(draft)
        state.draftsVersion += 1
    }

    func stopBackgroundWork() {
        editor.dispose()
        signaturesStopped = true
        signatureIdentityToken = UUID()
        signatureSubscription?.cancel()
        senderIdentitySubscription?.cancel()
        signatureTask?.cancel()
        signatureTask = nil
        signatureApplicationTask?.cancel(); signatureApplicationTask = nil
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveNow), object: nil)
    }

    func discard() {
        guard draft.state == "editing" else { status = "邮件已在发件箱，请先取消已有任务"; return }
        stopBackgroundWork()
        try? state.draftStore.remove(draft.id)
        state.draftsVersion += 1
        onClose?()
    }

    // MARK: Attachments / signatures / templates

    func addAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let imported = try state.draftStore.importFile(url, id: draft.id)
                attachments.append(imported)
            } catch { status = "附件添加失败（单个文件上限 25 MB）" }
        }
        scheduleSave()
    }

    func removeAttachment(_ url: URL) {
        attachments.removeAll { $0 == url }
        try? FileManager.default.removeItem(at: url)
        scheduleSave()
    }

    func insertSignature(_ signature: MailSignature) {
        guard let option = signatureOptions.first(where: { $0.id == signature.id }) else { return }
        let identity = SignaturePolicy.identity(account: draft.accountID, from: draft.from)
        let token = signatureIdentityToken
        signatureApplicationTask = Task { @MainActor [weak self] in
            guard let self, token == signatureIdentityToken, !signaturesStopped else { return }
            let result = await editor.replaceManagedSignatureHTML(option.html, reference: option.id, identity: identity, beforeQuote: draft.source != nil && [.reply, .replyAll, .forward].contains(mode), allowInsert: true, isCurrent: { [weak self] in self?.signatureIdentityToken == token && self?.signaturesStopped == false })
            guard token == signatureIdentityToken else { return }
            if case .protected = result { status = "已保留你编辑的签名或引用；请手动调整正文。"; return }
            automaticSignatureEligible = true
            signaturePreserveIdentity = identity
            scheduleSave()
        }
    }

    func loadTemplates() {
        guard let account = state.accounts.first(where: { $0.id == draft.accountID }),
              let templates = state.systemFolder(account.id, "Templates") else {
            status = "此账号没有模板文件夹"
            return
        }
        templateLoading = true
        Task { @MainActor in
            defer { templateLoading = false }
            do {
                let context = try await state.mailbox(account)
                let session = state.webSession(account)
                try await session.ready()
                let page = try await state.api.messages(context: context, folder: templates,
                                                        store: session.store, browser: session.webView)
                templateItems = page.messages
            } catch { status = "模板读取失败" }
        }
    }

    func insertTemplate(_ message: MailMessage) {
        guard let account = state.accounts.first(where: { $0.id == message.accountID }) else { return }
        Task { @MainActor in
            do {
                let session = state.webSession(account)
                try await session.ready()
                let detail = try await state.api.detail(message, store: session.store, browser: session.webView)
                editor.insertHTML(detail.html)
                status = "已插入模板"
                scheduleSave()
            } catch { status = "模板插入失败" }
        }
    }
}

enum ComposeDocument {
    static let quoteMarker = "---- 原始邮件 ----"
    static let quoteDivider = "<hr style=\"border:0;height:1px;background-color:#dfe1e6;margin:20px 0 16px\">"

    static func webQuote(source: MailDetail) -> String {
        quoteDivider + "<div style=\"font:12pt Verdana,Arial,sans-serif;color:#000\"><p>\(quoteMarker)</p><div>发件人：\(MailHTML.escape(source.from))</div><div>收件人：\(MailHTML.escape(source.to))</div><div>主题：\(MailHTML.escape(source.message.subject))</div></div><blockquote>\(source.html)</blockquote>"
    }

    static func nativeDocument(_ html: String) -> String {
        // AppKit's HTML importer does not resolve -apple-system consistently;
        // give inherited email text an explicit font while retaining inline fonts.
        MailHTML.document(html, images: false).replacingOccurrences(of: "<body>",
            with: "<body style=\"font-family:Verdana,Arial,sans-serif;font-size:12px;font-weight:normal\">")
    }

    static func reply(source: MailDetail, body: String) -> String {
        let text = MailHTML.escape(body).replacingOccurrences(of: "\n", with: "<br>")
        let header = """
        <p>\(quoteMarker)</p>
        <div>发件人：\(MailHTML.escape(source.from))</div>
        <div>收件人：\(MailHTML.escape(source.to))</div>
        <div>日期：\(MailHTML.escape(source.message.date.mailFull))</div>
        <div>主题：\(MailHTML.escape(source.message.subject))</div>
        """
        return MailHTML.document("<p>\(text)<br></p>" + quoteDivider + "<div>" + header + "</div><blockquote>\(source.html)</blockquote>", images: false)
    }
}

// MARK: - Rich text editor

@MainActor final class EditorHandle {
    weak var textView: NSTextView?
    // ComposeModel is initialized before NSViewRepresentable creates NSTextView.
    // Retain the initial document until attach instead of dropping those writes.
    private var pendingContent: NSAttributedString?
    var signatureOwnership: EditorSignatureOwnership?
    var signatureWasEdited = false
    private var signatureSelectionObserver: NSObjectProtocol?
    deinit { if let signatureSelectionObserver { NotificationCenter.default.removeObserver(signatureSelectionObserver) } }
    func clearSignatureTypingAttributes() {
        guard let textView else { return }
        var attributes = textView.typingAttributes
        attributes.removeValue(forKey: Self.signatureKey)
        textView.typingAttributes = attributes
    }
    var currentAttributedContent: NSAttributedString { NSAttributedString(attributedString: textView?.attributedString() ?? pendingContent ?? NSAttributedString(string: "")) }
    func applySignatureContent(_ value: NSAttributedString, selection: NSRange) {
        if let textView {
            textView.textStorage?.setAttributedString(value)
            textView.setSelectedRange(NSRange(location: min(selection.location, value.length), length: min(selection.length, max(0, value.length - min(selection.location, value.length)))))
            clearSignatureTypingAttributes()
            textView.didChangeText()
        } else { pendingContent = NSAttributedString(attributedString: value) }
    }

    func attach(_ view: NSTextView) {
        if let signatureSelectionObserver { NotificationCenter.default.removeObserver(signatureSelectionObserver) }
        textView = view
        signatureSelectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearSignatureTypingAttributes() }
        }
        if let pendingContent {
            view.textStorage?.setAttributedString(pendingContent)
            self.pendingContent = nil
            view.setSelectedRange(NSRange(location: 0, length: 0))
        }
        clearSignatureTypingAttributes()
    }
    func setText(_ text: String) {
        setAttributed(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: NSColor.textColor]))
    }
    func setAttributed(_ value: NSAttributedString) {
        if let textView {
            textView.textStorage?.setAttributedString(value)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        } else {
            pendingContent = NSAttributedString(attributedString: value)
        }
    }
    func loadHTML(_ html: String) {
        if let value = try? NSAttributedString(data: Data(ComposeDocument.nativeDocument(html).utf8),
                                               options: [.documentType: NSAttributedString.DocumentType.html,
                                                         .characterEncoding: String.Encoding.utf8.rawValue],
                                               documentAttributes: nil) {
            setAttributed(value)
        } else {
            setText(MailHTML.plainText(html))
        }
    }
    @discardableResult func insertAutomaticSignature(_ html: String, beforeQuote: Bool) -> Bool {
        let current = textView?.attributedString() ?? pendingContent ?? NSAttributedString(string: "")
        let marker = (current.string as NSString).range(of: ComposeDocument.quoteMarker)
        // Do not guess a new location if the user deleted/rewrote the quote.
        if beforeQuote && marker.location == NSNotFound { return false }
        let position = beforeQuote ? marker.location : current.length
        let safe = ComposeDocument.nativeDocument("<br>" + html + "<br><br>")
        guard let signature = try? NSAttributedString(data: Data(safe.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return false }
        if let textView {
            let selection = textView.selectedRange()
            textView.insertText(signature, replacementRange: NSRange(location: position, length: 0))
            let location = selection.location > position ? selection.location + signature.length : selection.location
            textView.setSelectedRange(NSRange(location: location, length: selection.length))
            textView.didChangeText()
        } else {
            let value = NSMutableAttributedString(attributedString: current)
            value.insert(signature, at: position)
            pendingContent = value
        }
        return true
    }

    func insertHTML(_ html: String) {
        guard let textView else { return }
        let safe = ComposeDocument.nativeDocument(html)
        if let value = try? NSAttributedString(data: Data(safe.utf8),
                                               options: [.documentType: NSAttributedString.DocumentType.html],
                                               documentAttributes: nil) {
            textView.insertText(value, replacementRange: textView.selectedRange())
        } else {
            textView.insertText(MailHTML.plainText(html), replacementRange: textView.selectedRange())
        }
    }
    func html() -> String {
        guard let attributed = textView?.attributedString() ?? pendingContent else { return "<p></p>" }
        guard let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
              let html = String(data: data, encoding: .utf8) else {
            return "<pre>\(MailHTML.escape(plainText()))</pre>"
        }
        return html
    }
    func plainText() -> String { textView?.string ?? pendingContent?.string ?? "" }
    func rtfData() -> Data? {
        guard let attributed = textView?.attributedString() ?? pendingContent else { return nil }
        return try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    func toggle(_ trait: NSFontTraitMask) { toggleFontTrait(trait) }
    func toggleUnderline() { toggleUnderlineFormatting() }
    func toggleStrike() { toggleStrikeFormatting() }
    func insertLink(_ url: String) {
        guard let link = URL(string: url), Trust.outside(link) else { return }
        applyLinkFormatting(link)
    }
    func insertBullet() {
        guard let textView else { return }
        textView.insertText("• ", replacementRange: textView.selectedRange())
    }
}

// MARK: - SwiftUI compose

struct ComposeView: View {
    @ObservedObject var model: ComposeModel
    @FocusState private var focus: Field?
    @State private var linkDraft = ""
    @State private var editorEmpty = true
    @State private var fontFamily = "Verdana"
    @State private var fontSize: CGFloat = 12
    @State private var foreground = Color.primary
    @State private var customForeground = Color.blue
    @State private var lightPaper = true
    @State private var signatureImages = true
    @State private var formattingVisible = false
    @Environment(\.colorScheme) private var colorScheme

    var isInline: Bool = false
    var onPopOut: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    private var composeSurface: Color {
        colorScheme == .dark ? Color(red: 0.141, green: 0.141, blue: 0.149) : Color.white
    }

    enum Field { case to, cc, bcc, subject }

    init(model: ComposeModel, formattingInitiallyExpanded: Bool = false, isInline: Bool = false, onPopOut: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.model = model
        _formattingVisible = State(initialValue: formattingInitiallyExpanded)
        self.isInline = isInline
        self.onPopOut = onPopOut
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            DividerLine()
            addressRows
            DividerLine()
            HStack(spacing: 8) {
                Text("主题")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .frame(width: 48, alignment: .leading)
                TextField("输入主题…", text: $model.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($focus, equals: .subject)
                    .onChange(of: model.subject) { _, _ in model.scheduleSave() }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .accessibilityIdentifier("compose.subject")
            DividerLine()
            if formattingVisible {
                formatBar
                DividerLine()
            }
            ZStack(alignment: .topLeading) {
                WebHTMLComposer(handle: model.editor) {
                    model.scheduleSave()
                    Task { @MainActor in editorEmpty = await model.editor.flush().text.trimmed.isEmpty }
                }
                if model.preparingReply {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在准备原邮件引用…")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .padding(.leading, 18).padding(.top, 16)
                    .allowsHitTesting(false)
                } else if editorEmpty {
                    Text("在此输入回复…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                        .padding(.leading, 18).padding(.top, 16)
                        .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(!model.preparingReply)
            .accessibilityIdentifier("compose.messageBody")
            .background(lightPaper ? Color.white : composeSurface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.attachments.isEmpty { attachmentStrip.padding(.horizontal, 18).padding(.vertical, 8) }
            DividerLine()
            footer
        }
        .background(composeSurface)
        .frame(minWidth: isInline ? nil : 840, minHeight: isInline ? 260 : 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(model.sending || model.syncing)
        .popover(isPresented: $model.showSchedulePicker) { schedulePopover }
        .onChange(of: signatureImages) { _, value in model.editor.allowsSignatureImages = value }
        .onChange(of: model.priority) { _, _ in model.scheduleSave() }
        .onAppear {
            model.syncFromIndex()
            model.editor.onSelection = { family, points in fontFamily = family; fontSize = points }
            editorEmpty = model.editor.plainText().trimmed.isEmpty
            focus = model.mode == .new ? .to : nil
            if model.mode != .new { model.editor.focus() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { model.send() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(model.sending ? "发送中…" : "发送")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(MailFolderPalette.inbox)
            .controlSize(.regular)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canSend)
            .help("发送邮件（⌘↩）")
            if isInline {
                Button("放弃") {
                    model.discard()
                }
                .buttonStyle(GhostButtonStyle(tint: Palette.secondaryText))
                .help("放弃回复并返回阅读（Esc）")
            }
            toolbarDivider
            formatButton("paperclip", "添加附件") { model.addAttachments() }
            Button { formattingVisible.toggle() } label: {
                Text("Aa").font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill(formattingVisible ? Palette.accent.opacity(0.12) : Color.clear))
            }
            .buttonStyle(.plain)
            .foregroundStyle(formattingVisible ? Palette.accent : Palette.secondaryText)
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .accessibilityLabel(formattingVisible ? "收起格式工具" : "显示格式工具")
            .accessibilityValue(formattingVisible ? "已展开" : "已收起")
            .accessibilityIdentifier("compose.formatToggle")
            .help("显示或收起格式工具（⇧⌘T）")
            signatureMenu
            Toggle(isOn: Binding(get: { model.trackingEnabled }, set: { model.trackingEnabled = $0; model.scheduleSave() })) {
                Label("追踪", systemImage: "eye")
            }
            .toggleStyle(.button).controlSize(.small)
            .help("记录这封邮件的打开情况；需要在设置中连接自己的追踪服务。")
            .accessibilityIdentifier("compose.mailTracking")
            Menu {
                Button("稍后发送…", systemImage: "clock.badge.checkmark") { model.showSchedulePicker = true }
                    .disabled(!model.canSend)
                if model.draft.source != nil {
                    Button("发送并归档", systemImage: "archivebox") { model.send(archiveOriginal: true) }
                        .disabled(!model.canSend)
                }
                Divider()
                templateMenu
                Button("插入链接…", systemImage: "link") { insertLink() }
                Menu("插入表格") {
                    Button("2 × 2") { model.editor.insertTable(rows: 2, columns: 2) }
                    Button("3 × 3") { model.editor.insertTable(rows: 3, columns: 3) }
                    Button("4 × 4") { model.editor.insertTable(rows: 4, columns: 4) }
                }
                Divider()
                Toggle("请求已读回执", isOn: Binding(get: { model.receipt }, set: { model.receipt = $0; model.scheduleSave() }))
                Toggle("邮件追踪", isOn: Binding(get: { model.trackingEnabled }, set: { model.trackingEnabled = $0; model.scheduleSave() }))
                Button("邮件追踪设置…") { model.state.showTrackingSettings() }
                Menu("优先级") {
                    Button("高") { model.priority = 1 }
                    Button("普通") { model.priority = 3 }
                    Button("低") { model.priority = 5 }
                }
                Menu("图片隐私") {
                    Toggle("签名图片（可能追踪）", isOn: $signatureImages)
                    Toggle("正文远程图片（可能被追踪）", isOn: Binding(get: { model.editor.allowsRemoteImages }, set: { model.editor.allowsRemoteImages = $0; lightPaper = true }))
                }
                Divider()
                Button("丢弃草稿", role: .destructive) { model.discard() }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 26, height: 26) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("更多邮件操作")
            .help("更多邮件操作")
            .disabled(model.sending || model.syncing)
            Spacer(minLength: 8)
            Button {
                Task { @MainActor in model.status = await model.persistDraftFlushed() ? "草稿已保存在本机" : "草稿保存失败，请重试" }
            } label: {
                Image(systemName: "square.and.arrow.down").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .accessibilityLabel("保存草稿")
            .help("保存草稿（⌘S）")
            .disabled(model.sending || model.syncing)
            if model.draft.cloudUncertain {
                Button("核对云端草稿") { model.reconcileCloudDraft() }.buttonStyle(.plain)
                    .foregroundStyle(Palette.amber).disabled(model.sending || model.syncing)
            } else {
                Button { model.syncCloudDraft() } label: {
                    Label(model.syncing ? "同步中…" : "同步草稿", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.plain).keyboardShortcut("s", modifiers: [.command, .shift])
                .help("同步到 Zoho 草稿（⌘⇧S）").disabled(model.sending || model.syncing || model.draft.state != "editing")
            }
            if isInline {
                toolbarDivider
                if let onPopOut {
                    Button {
                        onPopOut()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("在新窗口中弹出继续编辑（Outlook 样式弹出）")
                    .accessibilityLabel("在新窗口中弹出继续编辑")
                }
                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("关闭回复并保存草稿（Esc）")
                    .accessibilityLabel("关闭回复")
                }
            } else {
                toolbarDivider
                Button {
                    model.onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("关闭窗口并保存草稿（⌘W 或 Esc）")
                .accessibilityLabel("关闭窗口")
                .keyboardShortcut("w", modifiers: .command)
                .keyboardShortcut(.cancelAction)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.secondaryText)
        .padding(.horizontal, 18).padding(.vertical, 7)
        .frame(minHeight: 44)
        .accessibilityIdentifier("compose.primaryActions")
    }

    private var toolbarDivider: some View {
        Rectangle().fill(Palette.hairline).frame(width: 1, height: 18)
    }

    private var selectedSenderLabel: String {
        let options = model.fromOptions
        guard options.indices.contains(model.fromIndex) else { return "选择发件地址" }
        let option = options[model.fromIndex]
        return model.senderLabel(accountID: option.0, address: option.1)
    }

    private var addressRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("发件人")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .frame(width: 48, alignment: .leading)
                Menu {
                    ForEach(Array(model.fromOptions.enumerated()), id: \.offset) { index, option in
                        if index > 0 && option.0 != model.fromOptions[index - 1].0 {
                            Divider()
                        }
                        Button { model.applyFrom(index) } label: {
                            if index == model.fromIndex {
                                Label(model.senderLabel(accountID: option.0, address: option.1), systemImage: "checkmark")
                            } else {
                                Text(model.senderLabel(accountID: option.0, address: option.1))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedSenderLabel)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Palette.tertiaryText)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.04)))
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 420, alignment: .leading)
                .accessibilityLabel("发件地址")
                .help(selectedSenderLabel)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            DividerLine()
            HStack(alignment: .top, spacing: 12) {
                RecipientEditor(title: "收件人", text: $model.to, suggestions: model.state.recipientSuggestions)
                    .focused($focus, equals: .to)
                Menu {
                    Toggle("显示抄送", isOn: Binding(get: { model.showCc || !model.cc.trimmed.isEmpty }, set: { model.showCc = $0 || !model.cc.trimmed.isEmpty }))
                        .disabled(!model.cc.trimmed.isEmpty)
                    Toggle("显示密送", isOn: Binding(get: { model.showBcc || !model.bcc.trimmed.isEmpty }, set: { model.showBcc = $0 || !model.bcc.trimmed.isEmpty }))
                        .disabled(!model.bcc.trimmed.isEmpty)
                } label: {
                    HStack(spacing: 3) {
                        Text("抄送/密送").font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.04)))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("抄送和密送显示选项")
                .help("显示抄送或密送地址栏；已有地址会保持显示")
            }
            .padding(.vertical, 7)
            if model.showCc || !model.cc.trimmed.isEmpty {
                DividerLine()
                RecipientEditor(title: "抄送", text: $model.cc, suggestions: model.state.recipientSuggestions)
                    .padding(.vertical, 7)
            }
            if model.showBcc || !model.bcc.trimmed.isEmpty {
                DividerLine()
                RecipientEditor(title: "密送", text: $model.bcc, suggestions: model.state.recipientSuggestions)
                    .padding(.vertical, 7)
            }
        }
        .padding(.horizontal, 18)
        .accessibilityIdentifier("compose.addresses")
        .onChange(of: model.to) { _, _ in model.scheduleSave() }
        .onChange(of: model.cc) { _, _ in model.scheduleSave() }
        .onChange(of: model.bcc) { _, _ in model.scheduleSave() }
    }

    private var formatBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    formatButton("arrow.uturn.backward", "撤销") { model.editor.undo() }
                    formatButton("arrow.uturn.forward", "重做") { model.editor.redo() }
                    toolbarDivider
                    formatButton("bold", "粗体") { model.editor.toggle(.boldFontMask) }
                    formatButton("italic", "斜体") { model.editor.toggle(.italicFontMask) }
                    formatButton("underline", "下划线") { model.editor.toggleUnderline() }
                    formatButton("strikethrough", "删除线") { model.editor.toggleStrike() }
                    toolbarDivider
                    Menu {
                        ForEach(["Verdana", "Arial", "Helvetica", "Times New Roman", "Georgia", "Menlo"], id: \.self) { name in
                            Button(name) { fontFamily = name; model.editor.setFontFamily(name) }
                        }
                    } label: { Text(fontFamily).font(.system(size: 12)).frame(width: 104, alignment: .leading) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("字体").help("字体")
                    toolbarDivider
                    Menu {
                        ForEach([10, 11, 12, 14, 16, 18, 24, 32], id: \.self) { size in
                            Button("\(size)") { fontSize = CGFloat(size); model.editor.setFontSize(CGFloat(size)) }
                        }
                    } label: { Text(String(format: "%g pt", Double(fontSize))).font(.system(size: 12)).frame(width: 48) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("字号（磅）").help("字号（磅）")
                    toolbarDivider
                    Menu {
                        Button("默认文字颜色") { foreground = .primary; model.editor.setForeground(.textColor) }
                        Button("黑色") { foreground = .black; model.editor.setForeground(.black) }
                        Button("蓝色") { foreground = .blue; model.editor.setForeground(.systemBlue) }
                        Button("红色") { foreground = .red; model.editor.setForeground(.systemRed) }
                        Button("绿色") { foreground = .green; model.editor.setForeground(.systemGreen) }
                        ColorPicker("自定义颜色", selection: $customForeground, supportsOpacity: false)
                    } label: {
                        Image(systemName: "textformat")
                            .overlay(alignment: .bottom) { Rectangle().fill(foreground).frame(height: 2).offset(y: 5) }
                            .frame(width: 24, height: 22)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .onChange(of: customForeground) { _, color in foreground = color; model.editor.setForeground(NSColor(color)) }
                    .accessibilityLabel("文字颜色").help("文字颜色")
                    Menu {
                        Button("黄色") { model.editor.setHighlight(.systemYellow) }
                        Button("绿色") { model.editor.setHighlight(.systemGreen) }
                        Button("蓝色") { model.editor.setHighlight(.systemTeal) }
                        Button("粉色") { model.editor.setHighlight(.systemPink) }
                        Divider()
                        Button("移除高亮") { model.editor.setHighlight(nil) }
                    } label: { Image(systemName: "highlighter") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("文字高亮").help("文字高亮")
                    toolbarDivider
                    Menu {
                        Button("左对齐") { model.editor.setAlignment(.left) }
                        Button("居中") { model.editor.setAlignment(.center) }
                        Button("右对齐") { model.editor.setAlignment(.right) }
                        Button("两端对齐") { model.editor.setAlignment(.justified) }
                    } label: { Image(systemName: "text.alignleft") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("段落对齐").help("段落对齐")
                    Menu {
                        Button("项目符号列表") { model.editor.insertList(numbered: false) }
                        Button("编号列表") { model.editor.insertList(numbered: true) }
                    } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("列表").help("列表")
                    Menu {
                        Button("增加缩进") { model.editor.indent(20) }
                        Button("减少缩进") { model.editor.indent(-20) }
                    } label: { Image(systemName: "increase.indent") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("缩进").help("缩进")
                    Menu {
                        ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { multiple in
                            Button(String(format: "%.2g 倍行距", multiple)) { model.editor.setLineSpacing(CGFloat(multiple)) }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("行距").help("行距")
                    toolbarDivider
                    formatButton("link", "插入链接") { insertLink() }
                    Menu {
                        Button("2 × 2") { model.editor.insertTable(rows: 2, columns: 2) }
                        Button("3 × 3") { model.editor.insertTable(rows: 3, columns: 3) }
                        Button("4 × 4") { model.editor.insertTable(rows: 4, columns: 4) }
                    } label: { Image(systemName: "tablecells") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("插入表格").help("插入表格")
                    formatButton("textformat.abc.dottedunderline", "清除格式") { model.editor.clearFormatting() }
                }
                .padding(.horizontal, 18).padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(Palette.secondaryText)
        .background(Color.primary.opacity(0.035))
        .frame(height: 36)
        .accessibilityIdentifier("compose.formatting")
    }

    private var signatureMenu: some View {
        Menu {
            if model.signatureOptions.isEmpty {
                Button("重新读取签名") { model.loadSignatures() }
            } else {
                ForEach(model.signatureOptions, id: \.id) { signature in
                    Button(signature.name.isEmpty ? "签名" : signature.name) { model.insertSignature(signature) }
                }
            }
        } label: { Image(systemName: "signature").font(.system(size: 15)).frame(width: 26, height: 26) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("插入签名").help("插入签名")
    }

    private var templateMenu: some View {
        Menu {
            if model.templateLoading { Text("正在读取模板…") }
            else if model.templateItems.isEmpty { Button("读取模板") { model.loadTemplates() } }
            else {
                ForEach(model.templateItems, id: \.key) { template in
                    Button(template.subject) { model.insertTemplate(template) }
                }
                Divider()
                Button("刷新模板") { model.loadTemplates() }
            }
        } label: { Label("插入模板", systemImage: "doc.on.doc") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("插入模板")
    }

    private func formatButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.secondaryText)
        .accessibilityLabel(help)
        .help(help)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.attachments, id: \.self) { url in
                    HStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Palette.accent.opacity(0.12))
                                .frame(width: 20, height: 20)
                            Image(systemName: "paperclip")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.accent)
                        }
                        Text(url.lastPathComponent).font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200)
                        Button { model.removeAttachment(url) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Palette.tertiaryText)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除附件：" + url.lastPathComponent)
                        .help("移除附件")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 0.75)
                    )
                    .help(url.lastPathComponent)
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden)
        .frame(height: 34)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.status.isEmpty ? "自动保存本机草稿 · ⌘↩ 发送" : model.status)
                .lineLimit(model.status.isEmpty ? 1 : nil)
                .textSelection(.enabled)
            Spacer()
            if model.receipt { Label("已读回执", systemImage: "envelope.badge") }
            if model.trackingEnabled { Label("邮件追踪", systemImage: "eye") }
            if model.priority != 3 { Label(model.priority == 1 ? "高优先级" : "低优先级", systemImage: "flag") }
            if let scheduled = model.scheduledAt {
                Text("定时：" + scheduled.mailRelative + " " + timeString(scheduled))
                    .foregroundStyle(Palette.amber)
            }
        }
        .font(.system(size: 10.5)).foregroundStyle(Palette.tertiaryText)
        .padding(.horizontal, 18).padding(.vertical, 6)
        .accessibilityIdentifier("compose.status")
    }

    private var schedulePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择发送时间").font(.system(size: 12, weight: .semibold))
            DatePicker("", selection: Binding(get: { model.scheduledAt ?? Date().addingTimeInterval(3600) },
                                              set: { model.scheduledAt = $0 }),
                       in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            HStack {
                Button("取消") { model.showSchedulePicker = false }
                Spacer()
                Button("加入发件箱") {
                    if model.scheduledAt == nil { model.scheduledAt = Date().addingTimeInterval(3600) }
                    model.showSchedulePicker = false
                    model.send(schedule: true)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func insertLink() {
        let alert = NSAlert()
        alert.messageText = "插入链接"
        let field = NSTextField(string: "https://")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "插入"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: field.stringValue), Trust.outside(url) {
            model.editor.insertLink(url.absoluteString)
            model.scheduleSave()
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; return formatter.string(from: date)
    }
}

// MARK: - Recipient chip editor

struct RecipientEditor: View {
    let title: String
    @Binding var text: String
    let suggestions: (String) -> [String]
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .frame(width: 48, alignment: .leading)
                    .padding(.top, 3)
                FlowLayout(spacing: 5) {
                    ForEach(tokens, id: \.self) { token in
                        HStack(spacing: 5) {
                            Text(String(token.prefix(2)).uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Palette.accent)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Palette.accent.opacity(0.14)))
                            Text(token)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(Color.primary)
                            Button { remove(token) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(Palette.tertiaryText)
                                    .frame(width: 14, height: 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 3)
                        .padding(.trailing, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: 0.5)
                        )
                    }
                    TextField("添加地址…", text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .frame(minWidth: 160, alignment: .leading)
                        .padding(.vertical, 2)
                        .onSubmit { commit() }
                        .onChange(of: input) { _, value in
                            if value.contains(",") || value.contains(";") { commit() }
                        }
                }
            }
            if !input.trimmed.isEmpty {
                let matches = suggestions(input.trimmed).filter { !tokens.contains($0) }
                if !matches.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(matches.prefix(4), id: \.self) { address in
                            Button {
                                add(address)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.crop.circle")
                                        .font(.system(size: 9.5))
                                    Text(address)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(Palette.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Palette.accent.opacity(0.09)))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.leading, 56)
                }
            }
        }
    }

    private var tokens: [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func commit() {
        let value = input.trimmed
        guard !value.isEmpty else { return }
        add(value)
    }

    private func add(_ value: String) {
        var values = tokens
        let clean = value.replacingOccurrences(of: ",", with: "").trimmed
        if !clean.isEmpty, !values.contains(clean) { values.append(clean) }
        text = values.joined(separator: ", ")
        input = ""
    }

    private func remove(_ value: String) {
        text = tokens.filter { $0 != value }.joined(separator: ", ")
    }
}

/// Minimal flow layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
