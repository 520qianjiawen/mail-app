import Foundation

@MainActor func runMailSenderWireTests(_ require: (Bool, String) -> Void) async {
    func expectRejected(_ label: String, _ body: () throws -> Void) {
        do { try body(); require(false, label) }
        catch { require((error as? MailFailure) == .rejected, label) }
    }
    do {
        let primary = "owner@example.test", alias = "alias@example.test"
        let allowed = [primary, alias]
        func capture(_ from: String, _ name: String?, account: String = "A") -> OutboxItem {
            MailSenderWire.capture(accountID: account, from: from, name: name,
                to: "to@example.test", cc: "cc@example.test", bcc: "bcc@example.test", subject: "Frozen subject")
        }
        let named = capture(primary, "研发 · Zoë \"Team\" \\ Mail")
        require(try MailSenderWire.fromAddress(item: named, allowedAddresses: allowed) == "\"研发 · Zoë \\\"Team\\\" \\\\ Mail\" <owner@example.test>", "actual send-wire helper quotes Unicode and escapes quote/backslash")
        require(named.from == primary, "wire formatting never mutates bare queued sender")
        let aliasItem = capture(alias, "Alias Team")
        require(try MailSenderWire.fromAddress(item: aliasItem, allowedAddresses: allowed) == "\"Alias Team\" <alias@example.test>", "alias gets its own frozen display name")
        for name: String? in [nil, ""] {
            require(try MailSenderWire.fromAddress(item: capture(primary, name), allowedAddresses: allowed) == primary, "unknown and explicit blank names both emit bare sender")
        }
        require(try MailSenderWire.fromAddress(item: capture("OWNER@EXAMPLE.TEST", "Team"), allowedAddresses: allowed) == "\"Team\" <OWNER@EXAMPLE.TEST>", "allowlist comparison normalizes exact bare mailbox")
        expectRejected("revoked alias fails rather than routing through primary") {
            _ = try MailSenderWire.fromAddress(item: aliasItem, allowedAddresses: [primary])
        }
        expectRejected("other account's address cannot route through this account") {
            _ = try MailSenderWire.fromAddress(item: capture("other@example.test", "Other", account: "B"), allowedAddresses: allowed)
        }
        for address in ["Name <owner@example.test>", "owner@example.test\r\nBcc:x@example.test", "owner@example.test,alias@example.test"] {
            expectRejected("malformed or preformatted identity rejected before HTTP") {
                _ = try MailSenderWire.fromAddress(item: capture(address, "Team"), allowedAddresses: allowed + [address])
            }
        }
        for name in ["Name\r\nBcc:x@example.test", "Name\nX: y", "Name\tInjected", "Name\u{0}"] {
            expectRejected("invalid name fails rather than silently falling back to bare") {
                _ = try MailSenderWire.fromAddress(item: capture(primary, name), allowedAddresses: allowed)
            }
        }
        let encoded = try JSONEncoder().encode(named)
        let restored = try JSONDecoder().decode(OutboxItem.self, from: encoded)
        require(restored.senderDisplayName == named.senderDisplayName && restored.from == primary, "durable queue freezes sender name across reload/retry")
        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyObject.removeValue(forKey: "senderDisplayName")
        let legacy = try JSONDecoder().decode(OutboxItem.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        let legacyWire = try MailSenderWire.fromAddress(item: legacy, allowedAddresses: allowed)
        require(legacy.senderDisplayName == nil && legacyWire == primary, "legacy outbox without name stays bare rather than acquiring current settings")
    } catch { require(false, "sender wire pure setup: \(error)") }

    do {
        let state = AppState(fixture: true)
        defer { _ = state.shutdown() }
        let a = state.accounts[0].id, b = state.accounts[1].id
        let primary = "owner@example.test", alias = "alias@example.test"
        for id in [a, b] {
            state.sessions[id] = MailboxSession(accountID: id, remoteID: id == a ? "100" : "200",
                email: primary, origin: URL(string: "https://mail.zoho.com")!, folders: [], addresses: [primary, alias])
        }
        state.sessions[a]?.senderIdentities = [.init(address: primary, displayName: "Provider default")]
        let untouched = MailSenderWire.captureConfigured(state: state, accountID: a, from: primary,
            to: "to@example.test", cc: "", bcc: "", subject: "")
        require(state.effectiveSenderDisplayName(accountID: a, from: primary) == "Provider default" && untouched.senderDisplayName == nil,
                "provider metadata labels the UI without opting untouched sender into named From syntax")
        require(try MailSenderWire.fromAddress(item: untouched, allowedAddresses: [primary]) == primary,
                "unconfigured sender retains original bare-address server behavior")
        try state.saveSenderDisplayName(accountID: a, from: primary, name: "Primary A")
        let customized = MailSenderWire.captureConfigured(state: state, accountID: a, from: primary,
            to: "to@example.test", cc: "", bcc: "", subject: "")
        require(customized.senderDisplayName == "Primary A", "production capture uses explicit local display-name override")
        try state.removeSenderDisplayNameOverride(accountID: a, from: primary)
        let restoredDefault = MailSenderWire.captureConfigured(state: state, accountID: a, from: primary,
            to: "to@example.test", cc: "", bcc: "", subject: "")
        require(restoredDefault.senderDisplayName == nil, "restoring provider default removes custom send-name syntax")
        try state.saveSenderDisplayName(accountID: a, from: primary, name: "Primary A")
        try state.saveSenderDisplayName(accountID: a, from: alias, name: "Alias A")
        try state.saveSenderDisplayName(accountID: b, from: primary, name: "Primary B")
        let queued = MailSenderWire.capture(accountID: a, from: alias,
            name: state.effectiveSenderDisplayName(accountID: a, from: alias),
            to: "old@example.test", cc: "copy@example.test", bcc: "blind@example.test", subject: "Original")
        try state.saveSenderDisplayName(accountID: a, from: alias, name: "Changed during flush")
        await Task.yield()
        require(queued.senderDisplayName == "Alias A" && queued.accountID == a && queued.from == alias && queued.subject == "Original" && queued.to == "old@example.test" && queued.cc == "copy@example.test" && queued.bcc == "blind@example.test", "production capture helper freezes envelope and name before editor await/settings change")
        require(try MailSenderWire.fromAddress(item: queued, allowedAddresses: state.sessions[a]!.addresses) == "\"Alias A\" <alias@example.test>", "queued payload retains original name after settings edit")
        for mode in [ComposeMode.new, .reply, .replyAll, .forward] {
            var draft = MailDraft(accountID: a, from: primary, mode: mode.rawValue)
            draft.htmlBody = "<p>fixture</p>"; draft.htmlSignature = nil
            let model = ComposeModel(state: state, draft: draft)
            defer { model.stopBackgroundWork() }
            model.syncFromIndex()
            require(model.senderLabel(accountID: a, address: primary).contains("Primary A") && model.senderLabel(accountID: b, address: primary).contains("Primary B"), "compose label uses per-account sender name, not account label")
            if let index = model.fromOptions.firstIndex(where: { $0.0 == a && $0.1 == alias }) {
                model.applyFrom(index)
                require(model.draft.from == alias && !model.draft.from.contains("<"), "\(mode.rawValue) From switching keeps draft/signature/sync identity bare")
                let item = MailSenderWire.capture(accountID: model.draft.accountID, from: model.draft.from,
                    name: state.effectiveSenderDisplayName(accountID: model.draft.accountID, from: model.draft.from),
                    to: "to@example.test", cc: "", bcc: "", subject: "")
                require(item.from == alias && item.senderDisplayName == "Changed during flush", "\(mode.rawValue) new queue uses current configured alias name via shared capture")
            } else { require(false, "\(mode.rawValue) exposes allowed alias option") }
        }
        state.sessions[a]?.addresses.removeAll { $0 == alias }
        expectRejected("revoked alias blocks already frozen queue before send") {
            _ = try MailSenderWire.fromAddress(item: queued, allowedAddresses: state.sessions[a]!.addresses)
        }
        require(state.accountSessions.isEmpty, "wire fixtures never construct browser/network sessions")
    } catch { require(false, "sender wire fixture setup: \(error)") }
}
