import Foundation

@MainActor func runMailSenderIdentityTests(_ require: (Bool, String) -> Void) async {
    func expectError(_ label: String, _ body: () throws -> Void) {
        do { try body(); require(false, label) } catch { require(true, label) }
    }
    // No profile, session construction, network, or delivery: pure name-addr rules.
    do {
        require(SenderIdentityPolicy.normalizedAddress("Owner@Example.test") == "owner@example.test", "sender identity normalizes only validated bare mailbox keys")
        let badAddresses = ["", "Name <a@example.test>", "a@example.test,b@example.test", "a@example.test;", "a@example.test\r\nBcc:x@example.test", " a@example.test", "a@example.test ", "a..b@example.test", ".a@example.test", "a.@example.test", "a@-example.test", "a@example..test", "a@localhost", "a@example.test>anything", "a@example.test\u{0}"]
        for address in badAddresses {
            require(SenderIdentityPolicy.normalizedAddress(address) == nil, "reject malformed sender mailbox: \(String(reflecting: address))")
            expectError("formatter rejects malformed mailbox") { _ = try SenderIdentityPolicy.formattedFrom(address: address, name: "Name") }
        }
        require(try SenderIdentityPolicy.formattedFrom(address: "Owner@Example.test", name: nil) == "Owner@Example.test", "unknown name preserves original bare address spelling")
        require(try SenderIdentityPolicy.formattedFrom(address: "a@example.test", name: "") == "a@example.test", "explicit blank emits bare mailbox")
        let unicode = "研发团队 · Zoë，東京"
        require(try SenderIdentityPolicy.formattedFrom(address: "a@example.test", name: unicode) == "\"\(unicode)\" <a@example.test>", "Unicode sender display name is preserved in quoted name-addr")
        require(try SenderIdentityPolicy.validateName("  Team  ") == "  Team  ", "name spaces are preserved rather than silently stripped")
        let escaped = try SenderIdentityPolicy.formattedFrom(address: "a@example.test", name: "A \"B\" \\ C")
        require(escaped == "\"A \\\"B\\\" \\\\ C\" <a@example.test>", "quoted display name escapes both quotes and backslashes")
        let emailLike = "other@example.test <literal>, \"quoted\""
        require(try SenderIdentityPolicy.formattedFrom(address: "a@example.test", name: emailLike) == "\"other@example.test <literal>, \\\"quoted\\\"\" <a@example.test>", "email-like display name remains literal quoted text")
        for name in ["A\rB", "A\nB", "A\tB", "A\u{0}B", "A\u{7F}B", "A\u{85}B", "A\u{2028}B", "A\u{2029}B", String(repeating: "界", count: 121)] {
            expectError("reject sender name controls/newlines/overlength without truncating") { _ = try SenderIdentityPolicy.validateName(name) }
        }
        require(try SenderIdentityPolicy.validateName(String(repeating: "界", count: 120)).count == 120, "120 Unicode characters are accepted")
        let largeCluster = "a" + String(repeating: "\u{301}", count: 600)
        expectError("UTF8 byte bound rejects pathological single grapheme") { _ = try SenderIdentityPolicy.validateName(largeCluster) }
        let old = try JSONDecoder().decode(NativePreferences.self, from: Data("{\"accounts\":[]}".utf8))
        require(old.senderDisplayNames.isEmpty, "old preferences decode with absent sender names")
        let oldSession = Data("{\"accountID\":\"test\",\"remoteID\":\"100\",\"email\":\"a@example.test\",\"origin\":\"https://mail.zoho.com\",\"folders\":[],\"addresses\":[\"a@example.test\"]}".utf8)
        require(try JSONDecoder().decode(MailboxSession.self, from: oldSession).senderIdentities == nil, "old mailbox sessions decode unknown sender metadata")
        let identity = MailSenderIdentity(address: "a@example.test", displayName: nil)
        require(try JSONDecoder().decode(MailSenderIdentity.self, from: JSONEncoder().encode(identity)) == identity, "unknown display name survives Codable round trip")
    } catch { require(false, "sender pure model setup: \(error)") }

    do {
        let state = AppState(fixture: true)
        defer { _ = state.shutdown() }
        let a = state.accounts[0].id, b = state.accounts[1].id
        let primary = "owner@example.test", alias = "alias@example.test", unknown = "unknown@example.test"
        state.sessions[a] = MailboxSession(accountID: a, remoteID: "100", email: primary, origin: URL(string: "https://mail.zoho.com")!, folders: [], addresses: [primary, alias, unknown], senderIdentities: [
            .init(address: primary, displayName: "Server Owner"), .init(address: alias, displayName: "Server Alias"),
            .init(address: "forged@example.test", displayName: "Metadata does not grant membership")
        ])
        state.sessions[b] = MailboxSession(accountID: b, remoteID: "200", email: primary, origin: URL(string: "https://mail.zoho.com")!, folders: [], addresses: [primary], senderIdentities: [.init(address: primary, displayName: "Other Account")])
        require(state.effectiveSenderDisplayName(accountID: a, from: primary) == "Server Owner", "missing local override falls back to matching server identity")
        require(state.effectiveSenderDisplayName(accountID: a, from: unknown) == nil, "missing server name remains unknown instead of account label")
        try state.saveSenderDisplayName(accountID: a, from: "OWNER@EXAMPLE.TEST", name: "Local Owner")
        try state.saveSenderDisplayName(accountID: a, from: alias, name: "Local Alias")
        require(state.preferences.value.senderDisplayNames[a]?[primary] == "Local Owner", "save stores normalized bare mailbox key")
        require(state.effectiveSenderDisplayName(accountID: a, from: primary) == "Local Owner" && state.effectiveSenderDisplayName(accountID: a, from: alias) == "Local Alias", "main mailbox and alias have separate names")
        require(state.effectiveSenderDisplayName(accountID: b, from: primary) == "Other Account", "same mailbox string is isolated by account")
        try state.saveSenderDisplayName(accountID: a, from: primary, name: "")
        require(state.effectiveSenderDisplayName(accountID: a, from: primary) == "" && state.senderDisplayNameOverride(accountID: a, from: primary) == "", "explicit blank overrides known server name without restoring fallback")
        let reload = PreferenceFile(directory: state.preferences.directory)
        require(reload.value.senderDisplayNames[a]?[primary] == "" && reload.value.senderDisplayNames[a]?[alias] == "Local Alias", "saved blank and alias settings survive actual preference reload")
        try state.removeSenderDisplayNameOverride(accountID: a, from: primary)
        require(state.effectiveSenderDisplayName(accountID: a, from: primary) == "Server Owner" && state.senderDisplayNameOverride(accountID: a, from: primary) == nil, "remove override restores server fallback distinct from explicit blank")
        expectError("metadata-only identity cannot be configured") { try state.saveSenderDisplayName(accountID: a, from: "forged@example.test", name: "X") }
        expectError("unknown account cannot be configured") { try state.saveSenderDisplayName(accountID: "absent", from: primary, name: "X") }
        expectError("name validation applies at store boundary") { try state.saveSenderDisplayName(accountID: a, from: primary, name: "X\nBcc: other@example.test") }
        state.sessions[a]?.addresses.removeAll { $0 == alias }
        require(state.effectiveSenderDisplayName(accountID: a, from: alias) == nil && !state.availableSenderIdentities(accountID: a).contains(where: { $0.address == alias }), "revoked alias is hidden and stored name is not effective")
        expectError("revoked alias rejects stale editor save") { try state.saveSenderDisplayName(accountID: a, from: alias, name: "Stale") }
        expectError("revoked alias rejects stale override removal") { try state.removeSenderDisplayNameOverride(accountID: a, from: alias) }
        try state.saveSenderDisplayName(accountID: b, from: primary, name: "Independent")
        state.accounts.removeAll { $0.id == a }
        try state.cleanupSenderDisplayNames(accountID: a)
        require(state.preferences.value.senderDisplayNames[a] == nil && PreferenceFile(directory: state.preferences.directory).value.senderDisplayNames[a] == nil, "removed-account cleanup deletes persisted primary and revoked alias settings")
        require(state.effectiveSenderDisplayName(accountID: b, from: primary) == "Independent", "account cleanup preserves sibling names")
        require(state.accountSessions.isEmpty, "sender tests never construct real browser or mail sessions")
    } catch { require(false, "sender CRUD setup: \(error)") }

    do {
        let state = AppState(fixture: true)
        defer { _ = state.shutdown() }
        let account = state.accounts[0].id, address = "owner@example.test"
        state.sessions[account] = MailboxSession(accountID: account, remoteID: "100", email: address, origin: URL(string: "https://mail.zoho.com")!, folders: [], addresses: [address])
        try state.saveSenderDisplayName(accountID: account, from: address, name: "Before")
        let previous = state.preferences.value.senderDisplayNames
        let directory = state.preferences.directory.standardizedFileURL
        let target = directory.appendingPathComponent("preferences.json").standardizedFileURL
        guard directory.lastPathComponent.hasPrefix("mail-lite-fixture-"), target.deletingLastPathComponent() == directory else {
            require(false, "sender persistence failure target is an isolated fixture"); return
        }
        // Verified fixture-only target: replace its JSON file with a directory to
        // force atomic-write failure even when permission bits are ineffective.
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        expectError("sender save reports IO failure") { try state.saveSenderDisplayName(accountID: account, from: address, name: "After") }
        require(state.preferences.value.senderDisplayNames == previous, "failed sender save rolls back in-memory values")
        expectError("sender restore reports IO failure") { try state.removeSenderDisplayNameOverride(accountID: account, from: address) }
        require(state.preferences.value.senderDisplayNames == previous, "failed sender restore rolls back override removal")
        expectError("sender cleanup reports IO failure") { try state.cleanupSenderDisplayNames(accountID: account) }
        require(state.preferences.value.senderDisplayNames == previous, "failed cleanup rolls back dictionary removal")
    } catch { require(false, "sender persistence failure setup: \(error)") }
}
