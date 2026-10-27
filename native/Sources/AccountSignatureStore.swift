import Foundation

@MainActor extension AppState {
    func signatureSettings(_ accountID: String) -> AccountSignatureSettings {
        SignaturePolicy.migrate(&preferences.value)
        return preferences.value.accountSignatures[accountID] ?? AccountSignatureSettings()
    }
    @discardableResult func saveLocalSignature(accountID: String, id: String? = nil, name: String, html: String) throws -> LocalMailSignature {
        guard accounts.contains(where: { $0.id == accountID }) else { throw SignatureStoreError.account }
        var settings = signatureSettings(accountID)
        guard id != nil || settings.items.count < 100 else { throw SignatureStoreError.limit }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.count) else { throw SignatureStoreError.name }
        guard !settings.items.contains(where: { $0.id != id && $0.name.lowercased() == trimmed.lowercased() }) else { throw SignatureStoreError.duplicate }
        guard let clean = SignaturePolicy.cleanHTML(html) else { throw SignatureStoreError.html }
        if let id, !settings.items.contains(where: { $0.id == id }) { throw SignatureStoreError.missing }
        let item = LocalMailSignature(id: id ?? UUID().uuidString.lowercased(), name: trimmed, html: clean)
        if let index = settings.items.firstIndex(where: { $0.id == item.id }) { settings.items[index] = item } else { settings.items.append(item) }
        let previous = preferences.value
        preferences.value.accountSignatures[accountID] = settings
        guard preferences.save() else { preferences.value = previous; throw SignatureStoreError.persistence }
        signaturesVersion += 1
        return item
    }
    @discardableResult func deleteLocalSignature(accountID: String, id: String) -> Bool {
        guard accounts.contains(where: { $0.id == accountID }) else { return false }
        var settings = signatureSettings(accountID)
        settings.items.removeAll { $0.id == id }
        let reference = "local:" + id
        func clear(_ input: SignatureDefaults) -> SignatureDefaults {
            SignatureDefaults(new: input.new == reference ? "none" : input.new, reply: input.reply == reference ? "none" : input.reply)
        }
        settings.defaults = clear(settings.defaults)
        settings.aliases = settings.aliases.mapValues(clear)
        let previous = preferences.value
        preferences.value.accountSignatures[accountID] = settings
        guard preferences.save() else { preferences.value = previous; return false }
        signaturesVersion += 1
        return true
    }
    @discardableResult func setSignatureChoice(accountID: String, alias: String?, reply: Bool, choice: String?) -> Bool {
        guard accounts.contains(where: { $0.id == accountID }), choice == nil || SignaturePolicy.isChoice(choice!) else { return false }
        var settings = signatureSettings(accountID)
        if let alias {
            let address = SignaturePolicy.address(alias)
            guard MailAddresses.validated(address)?.count == 1 else { return false }
            var rule = settings.aliases[address] ?? SignatureDefaults()
            if reply { rule.reply = choice } else { rule.new = choice }
            if rule.new == nil, rule.reply == nil { settings.aliases.removeValue(forKey: address) } else { settings.aliases[address] = rule }
        } else if reply { settings.defaults.reply = choice } else { settings.defaults.new = choice }
        let previous = preferences.value
        preferences.value.accountSignatures[accountID] = settings
        guard preferences.save() else { preferences.value = previous; return false }
        signaturesVersion += 1
        return true
    }
    func cachedRemoteSignatures(accountID: String, from: String) -> [MailSignature] {
        remoteSignatureCache[SignaturePolicy.identity(account: accountID, from: from)] ?? []
    }
    func fetchAccountSignatures(accountID: String, from: String) async throws -> [MailSignature] {
        guard signatureFetchingAllowed, let account = accounts.first(where: { $0.id == accountID }) else { throw MailFailure.auth }
        let epoch = signatureAccountEpoch[accountID, default: 0], lifetime = signatureFetchLifetime
        let options: [MailSignature]
        if let hook = signatureFetchHook { options = try await hook(account, from) }
        else if fixture { return cachedRemoteSignatures(accountID: accountID, from: from) }
        else {
            let context = try await mailbox(account), web = webSession(account)
            try await web.ready()
            options = try await api.signatures(context: context, store: web.store, browser: web.webView)
        }
        try Task.checkCancellation()
        guard accounts.contains(where: { $0.id == accountID }), signatureAccountEpoch[accountID, default: 0] == epoch, signatureFetchLifetime == lifetime else { throw CancellationError() }
        remoteSignatureCache[SignaturePolicy.identity(account: accountID, from: from)] = options
        return options
    }
}
