import SwiftUI
import AppKit

/// All mutations here are local preferences. The only server operation is GET.
private struct SignatureEditingBuffer { let id: String?; let name: String; let html: String; let sourceMode: Bool }

struct AccountSignatureSettingsView: View {
    @ObservedObject var state: AppState
    @State private var selectedAccount = ""
    @State private var selectedAlias = "*"
    @State private var editingID: String?
    @State private var name = ""
    @State private var source = ""
    @State private var sourceMode = false
    @State private var editor = WebHTMLComposerHandle()
    @State private var remoteImages = true
    @State private var committing = false
    @State private var notice = ""
    @State private var remote: [MailSignature] = []
    @State private var loading = false
    @State private var requestID = UUID()
    @State private var editingBuffers: [String: SignatureEditingBuffer] = [:]

    init(state: AppState, initialAccountID: String = "") { self.state = state; _selectedAccount = State(initialValue: initialAccountID) }

    private var accountID: String { state.accounts.contains(where: { $0.id == selectedAccount }) ? selectedAccount : state.accounts.first?.id ?? "" }
    private var settings: AccountSignatureSettings { state.signatureSettings(accountID) }
    private var aliases: [String] { Array(Set((state.sessions[accountID]?.addresses ?? []).map(SignaturePolicy.address))).sorted() }
    private var remoteFrom: String { selectedAlias == "*" ? (aliases.first ?? state.sessions[accountID]?.email ?? "") : selectedAlias }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("账户签名").font(.system(size: 20, weight: .semibold))
            Text("本机保存，不同步服务器设置。支持原生 HTML 样式、图片、表格和链接；签名远程图片使用独立无 Cookie 通道显示（可能被追踪，可在下方关闭）。服务器签名只读取，或导入为本机副本。")
                .font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText).fixedSize(horizontal: false, vertical: true)
            if state.accounts.isEmpty {
                Text("添加账号后可管理签名。")
            } else {
                Picker("账号", selection: Binding(get: { accountID }, set: { changeAccount($0) })) {
                    ForEach(state.accounts) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 380)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本机签名").font(.system(size: 12, weight: .semibold))
                        ForEach(settings.items) { item in
                            Button { edit(item) } label: {
                                HStack { Text(item.name).lineLimit(2); Spacer(); if editingID == item.id { Image(systemName: "checkmark") } }
                            }.buttonStyle(GhostButtonStyle()).accessibilityLabel("编辑签名 " + item.name)
                        }
                        if settings.items.isEmpty { Text("还没有本机签名").font(.system(size: 11)).foregroundStyle(Palette.secondaryText) }
                        Button("新建签名") { clearEditor() }.buttonStyle(GhostButtonStyle())
                    }.frame(width: 166, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("签名名称", text: $name).textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            Button("B") { editor.toggle(.boldFontMask); syncSource() }.fontWeight(.bold)
                            Button("I") { editor.toggle(.italicFontMask); syncSource() }.italic()
                            Button("U") { editor.toggleUnderline(); syncSource() }.underline()
                            Button("链接…") { insertLink() }
                            Spacer()
                            Toggle("HTML 源码", isOn: $sourceMode).toggleStyle(.checkbox)
                                .onChange(of: sourceMode) { _, enabled in
                                    if enabled { committing = true; Task { @MainActor in source = await editor.flush().outgoingHTML; committing = false } }
                                    else { editor.loadHTML(source) }
                                }
                        }.buttonStyle(GhostButtonStyle()).font(.system(size: 11))
                        if sourceMode {
                            TextEditor(text: $source).font(.system(size: 11, design: .monospaced)).frame(height: 160)
                            Button("更新富文本预览") { editor.loadHTML(source); sourceMode = false }.buttonStyle(GhostButtonStyle())
                        } else {
                            WebHTMLComposer(handle: editor) { syncSource() }
                                .frame(height: 160).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
                        }
                        HStack {
                            Button(editingID == nil ? "保存新签名" : "保存更改") { save() }.buttonStyle(PrimaryButtonStyle())
                            if let id = editingID {
                                Button("删除") {
                                    if state.deleteLocalSignature(accountID: accountID, id: id) { clearEditor(); notice = "已从本机删除；引用此签名的默认规则已设为不使用。" }
                                    else { notice = SignatureStoreError.persistence.localizedDescription }
                                }.buttonStyle(GhostButtonStyle(tint: Palette.rose))
                            }
                        }
                    }
                }
                DividerLine()
                VStack(alignment: .leading, spacing: 9) {
                    Text("自动插入规则（本机）").font(.system(size: 12, weight: .semibold))
                    Picker("适用发件地址", selection: $selectedAlias) {
                        Text("整个账号").tag("*")
                        ForEach(aliases, id: \.self) { Text($0).tag($0) }
                    }.onChange(of: selectedAlias) { _, _ in
                        remote = state.cachedRemoteSignatures(accountID: accountID, from: remoteFrom)
                        requestID = UUID()
                        loading = false
                        fetchRemote()
                    }
                    choicePicker("新邮件", reply: false)
                    choicePicker("回复 / 回复全部 / 转发", reply: true)
                    Text("自动：仅有一个可用候选时插入；不是服务器默认设置。别名可覆盖账号规则；多候选时请选择具体签名。已手动改写的正文签名不会被自动删除。")
                        .font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                DividerLine()
                HStack {
                    Text("服务器签名（只读）").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(loading ? "读取中…" : "读取服务器签名") { fetchRemote() }.disabled(loading).buttonStyle(GhostButtonStyle())
                }
                ForEach(Array(remote.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.name.isEmpty ? item.id : item.name).font(.system(size: 11))
                        Spacer()
                        Button("导入本机副本") { importRemote(item) }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
            if !notice.isEmpty { Text(notice).font(.system(size: 11)).foregroundStyle(Palette.secondaryText).textSelection(.enabled) }
        }.disabled(committing).onAppear {
            editor.allowsRemoteImages = remoteImages
            if selectedAccount.isEmpty { selectedAccount = accountID }
            remote = state.cachedRemoteSignatures(accountID: accountID, from: remoteFrom)
            if name.isEmpty { if let first = settings.items.first { edit(first) } else { clearEditor() } }
            fetchRemote()
        }.onDisappear { Task { @MainActor in _ = await editor.flush(); editor.dispose() } }.onChange(of: state.accounts.map(\.id)) { _, ids in
            if !ids.contains(selectedAccount) { editingBuffers = editingBuffers.filter { ids.contains($0.key) }; selectedAccount = ids.first ?? ""; resetIdentity() }
        }
    }

    private func choicePicker(_ title: String, reply: Bool) -> some View {
        let rule = selectedAlias == "*" ? settings.defaults : settings.aliases[selectedAlias] ?? SignatureDefaults()
        let selected = (reply ? rule.reply : rule.new) ?? (selectedAlias == "*" ? "automatic" : "inherit")
        return Picker(title, selection: Binding(get: { selected }, set: { choice in
            let ok = state.setSignatureChoice(accountID: accountID, alias: selectedAlias == "*" ? nil : selectedAlias, reply: reply, choice: choice == "inherit" ? nil : choice)
            notice = ok ? "默认规则已保存到本机。" : SignatureStoreError.persistence.localizedDescription
        })) {
            if selectedAlias != "*" { Text("跟随账号").tag("inherit") }
            Text("自动（唯一候选）").tag("automatic")
            Text("不使用签名").tag("none")
            ForEach(SignaturePolicy.options(settings: settings, remote: remote), id: \.id) { item in Text(item.name).tag(item.id) }
            if selected != "automatic", selected != "none", selected != "inherit", !SignaturePolicy.options(settings: settings, remote: remote).contains(where: { $0.id == selected }) {
                Text(selected.hasPrefix("remote:") ? "已选服务器签名（尚未读取）" : "已选签名不可用").tag(selected)
            }
        }
    }
    private func clearEditor() { editingID = nil; name = ""; source = ""; sourceMode = false; editor.setText("") }
    private func changeAccount(_ next: String) {
        let previous = accountID, previousID = editingID, previousName = name, wasSource = sourceMode, sourceHTML = source
        committing = true
        Task { @MainActor in
            let snapshot = await editor.flush()
            guard editor.failure == nil else { notice = "HTML 编辑器读取失败，请重试"; committing = false; return }
            editingBuffers[previous] = SignatureEditingBuffer(id: previousID, name: previousName, html: wasSource ? sourceHTML : snapshot.outgoingHTML, sourceMode: wasSource)
            selectedAccount = next; resetIdentity(); committing = false
        }
    }
    private func resetIdentity() {
        requestID = UUID(); selectedAlias = "*"; remote = state.cachedRemoteSignatures(accountID: accountID, from: remoteFrom); loading = false
        if let buffer = editingBuffers[accountID] { editingID = buffer.id; name = buffer.name; source = buffer.html; sourceMode = buffer.sourceMode; editor.loadHTML(buffer.html) }
        else if let first = settings.items.first { edit(first) } else { clearEditor() }
        notice = "切换账号保留本页未保存编辑；离开本页前请点击保存。"
        fetchRemote()
    }
    private func edit(_ item: LocalMailSignature) { editingID = item.id; name = item.name; source = item.html; sourceMode = false; editor.loadHTML(item.html); notice = "" }
    private func syncSource() { /* DOM is canonical; read it only at awaited source/save boundaries. */ }
    private func save() {
        let account = accountID, id = editingID, title = name, wasSource = sourceMode, raw = source
        committing = true
        Task { @MainActor in
            let snapshot = await editor.flush()
            defer { committing = false }
            guard editor.failure == nil else { notice = "HTML 编辑器读取失败，请重试"; return }
            do {
                let item = try state.saveLocalSignature(accountID: account, id: id, name: title, html: wasSource ? raw : snapshot.outgoingHTML)
                editingID = item.id; name = item.name; source = item.html
                notice = "已保存到本机，服务器未修改。"
            } catch { notice = error.localizedDescription }
        }
    }

    private func insertLink() {
        let alert = NSAlert(); alert.messageText = "插入链接"
        let field = NSTextField(string: "https://"); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "插入"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { editor.insertLink(field.stringValue); syncSource() }
    }
    private func fetchRemote() {
        let account = accountID, from = remoteFrom, ticket = UUID()
        requestID = ticket; loading = true
        Task { @MainActor in
            do {
                let values = try await state.fetchAccountSignatures(accountID: account, from: from)
                guard requestID == ticket, accountID == account else { return }
                remote = values; loading = false
                if let first = values.first, settings.items.isEmpty, editingID == nil, name.isEmpty {
                    editor.loadHTML(first.html)
                    name = first.name.isEmpty ? "服务器签名" : first.name
                }
            } catch {
                guard requestID == ticket else { return }
                loading = false
            }
        }
    }
    private func importRemote(_ signature: MailSignature) {
        do {
            var candidate = String(signature.name.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty { candidate = "服务器签名" }
            let base = candidate; var suffix = 2
            while settings.items.contains(where: { $0.name.lowercased() == candidate.lowercased() }) { candidate = base + " " + String(suffix); suffix += 1 }
            let item = try state.saveLocalSignature(accountID: accountID, name: candidate, html: signature.html)
            edit(item); notice = "已导入本机副本，后续编辑不影响服务器。"
        } catch { notice = error.localizedDescription }
    }
}
