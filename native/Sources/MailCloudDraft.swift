import Foundation
import AppKit

/// Official create-draft API plus acknowledgement-first replacement of known
/// older copies. No undocumented update-draft fields or send action are used.
enum MailCloudDraft {
    static func payload(_ draft: MailDraft, html: String) throws -> [String: Any] {
        guard let to = MailAddresses.validated(draft.to), !to.isEmpty,
              let cc = MailAddresses.validated(draft.cc), let bcc = MailAddresses.validated(draft.bcc) else { throw MailFailure.rejected }
        let body = try MailInlineImageSend.prepare(html)
        var value: [String: Any] = ["mode": "draft", "fromAddress": draft.from, "toAddress": to.joined(separator: ","),
            "ccAddress": cc.joined(separator: ","), "bccAddress": bcc.joined(separator: ","),
            "subject": draft.subject, "content": body.html, "mailFormat": "html", "encoding": "UTF-8",
            "askReceipt": draft.receipt ? "yes" : "no"]
        if let source = draft.source, ["reply", "replyAll", "edit"].contains(draft.mode) {
            let reply = draft.mode == "edit" ? source.rfcInReplyTo : source.rfcMessageID
            if let reply = validHeader(reply) {
                value["inReplyTo"] = reply
                var refs = validHeader(source.rfcReferences) ?? ""
                if draft.mode != "edit", !refs.split(separator: " ").contains(Substring(reply)) { refs = refs.isEmpty ? reply : refs + " " + reply }
                if !refs.isEmpty { value["refHeader"] = refs }
            } else if draft.mode != "edit" { throw MailFailure.response }
        }
        return value
    }
    static func validHeader(_ value: String?) -> String? {
        MailAddresses.safeHeaderValue(value)
    }
}

@MainActor extension ComposeModel {
    func syncCloudDraft() {
        guard !sending, !syncing, draft.state == "editing", !draft.cloudUncertain else { return }
        syncing = true; status = "正在保存草稿…"
        cloudTask = Task { @MainActor in
            var attempted = false, acknowledged = false
            defer { syncing = false; state.draftsVersion += 1 }
            guard await persistDraftFlushed() else { status = "本机草稿保存失败，未同步"; return }
            do {
                guard let account = state.accounts.first(where: { $0.id == draft.accountID }),
                      let addresses = MailAddresses.validated(to), !addresses.isEmpty else {
                    status = "草稿已保存在本机，填写有效收件人后可同步到 Zoho"; return
                }
                let lifetime = state.contextActionLifetime()
                let context: MailboxSession
                if state.fixture {
                    guard let saved = state.sessions[account.id] else { throw MailFailure.auth }; context = saved
                } else { context = try await state.mailbox(account) }
                guard context.addresses.contains(draft.from), context.folders.contains(where: { $0.systemName == "Drafts" }),
                      let reference = context.messageReference() else { throw MailFailure.auth }
                @MainActor func check() throws {
                    guard !Task.isCancelled, state.acceptsContextAction(accountID: account.id, lifetime: lifetime),
                          MailInlineImageSend.sameContext(state.sessions[account.id], expected: context) else { throw MailFailure.auth }
                }
                try check()
                let snapshot = await editor.flush()
                guard editor.failure == nil else { throw MailFailure.response }
                draft.htmlBody = snapshot.html; draft.htmlSignature = snapshot.signature; draft.body = snapshot.text
                var value = draft
                if var source = value.source, ["reply", "replyAll", "edit"].contains(value.mode), source.rfcMessageID == nil, !state.fixture {
                    let session = state.webSession(account)
                    let headers = try await state.api.headers(source.message, store: session.store, browser: session.webView)
                    try check()
                    source.rfcMessageID = MailCloudDraft.validHeader(headers["message-id"])
                    source.rfcReferences = MailCloudDraft.validHeader(headers["references"])
                    source.rfcInReplyTo = MailCloudDraft.validHeader(headers["in-reply-to"])
                    value.source = source; draft.source = source
                }
                var payload = try MailCloudDraft.payload(value, html: snapshot.outgoingHTML)
                var uploads: [[String: String]] = []
                if !state.fixture {
                    let session = state.webSession(account)
                    try await session.ready(); try check()
                    for file in attachments {
                        let bytes = try Data(contentsOf: file)
                        uploads.append(try await state.api.upload(bytes, name: file.lastPathComponent, message: reference,
                                                               store: session.store, browser: session.webView))
                        try check()
                    }
                }
                if !uploads.isEmpty { payload["attachments"] = uploads }
                draft.cloudUncertain = true
                try state.draftStore.save(draft) // Persist ambiguity marker before POST.
                try check(); attempted = true
                let id: String
                if state.fixture {
                    guard let hook = state.cloudDraftSaveHook else { throw MailFailure.rejected }
                    id = try await hook(draft, payload)
                } else {
                    let session = state.webSession(account)
                    id = try await state.api.saveDraft(payload, context: context, store: session.store, browser: session.webView)
                }
                guard Trust.numericID(id) != nil else { throw MailFailure.response }
                acknowledged = true
                let old = Set((draft.obsoleteCloudIDs ?? []) + (draft.cloudID.map { [$0] } ?? []))
                draft.cloudID = id; draft.obsoleteCloudIDs = old.filter { $0 != id }; draft.cloudUncertain = false
                try state.draftStore.save(draft) // New copy must be owned locally before any old-copy cleanup.
                try check()
                var retained: [String] = []
                for previous in draft.obsoleteCloudIDs ?? [] {
                    do {
                        try check()
                        if state.fixture {
                            guard let hook = state.cloudDraftRemoveHook else { retained.append(previous); continue }
                            try await hook(previous)
                        } else {
                            let session = state.webSession(account)
                            try await state.api.removeDraftCopy(previous, context: context, store: session.store, browser: session.webView)
                        }
                    } catch { retained.append(previous) }
                }
                draft.obsoleteCloudIDs = retained
                try state.draftStore.save(draft)
                syncFromIndex()
                status = retained.isEmpty ? "草稿已同步到 Zoho" : "新草稿已同步，旧副本清理未完成"
            } catch {
                let rejected = (error as? MailFailure).map { [MailFailure.auth, .rate, .rejected].contains($0) } ?? false
                draft.cloudUncertain = attempted && !acknowledged && !rejected
                try? state.draftStore.save(draft)
                status = draft.cloudUncertain ? "云端结果未确认，请先核对 Zoho 草稿；本机内容已保留" :
                    acknowledged ? "云端草稿已保存，本机记录或旧副本清理失败，请先核对" : "草稿已保存在本机，Zoho 同步失败，请检查登录或地址"
            }
        }
    }

    func reconcileCloudDraft() {
        guard draft.cloudUncertain, !sending, !syncing, !state.fixture else { return }
        let alert = NSAlert()
        alert.messageText = "已核对 Zoho 草稿文件夹？"
        alert.informativeText = "上次同步结果未确认。请先核对是否已生成草稿，再解除保护，避免重复创建。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "已核对，解除保护")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        draft.cloudUncertain = false
        do { try state.draftStore.save(draft); status = "本机草稿已保留，可继续编辑" }
        catch { draft.cloudUncertain = true; status = "本机保存失败，请重试" }
    }
}
