import Foundation

@MainActor extension AppState {
    /// Only current server-approved send addresses grant membership. Metadata and
    /// account labels are never promoted to selectable sender addresses.
    func availableSenderIdentities(accountID: String) -> [MailSenderIdentity] {
        guard accounts.contains(where: { $0.id == accountID }), let session = sessions[accountID], session.accountID == accountID else { return [] }
        var seen = Set<String>()
        return session.addresses.compactMap { address in
            guard let key = SenderIdentityPolicy.normalizedAddress(address), seen.insert(key).inserted else { return nil }
            let metadata = session.senderIdentities?.first { SenderIdentityPolicy.normalizedAddress($0.address) == key }
            let name = metadata?.displayName.flatMap { try? SenderIdentityPolicy.validateName($0) }
            return MailSenderIdentity(address: address, displayName: name)
        }
    }

    func senderDisplayNameOverride(accountID: String, from: String) -> String? {
        guard let key = SenderIdentityPolicy.normalizedAddress(from),
              availableSenderIdentities(accountID: accountID).contains(where: { SenderIdentityPolicy.normalizedAddress($0.address) == key }),
              let name = preferences.value.senderDisplayNames[accountID]?[key] else { return nil }
        return try? SenderIdentityPolicy.validateName(name)
    }

    /// nil means unknown server metadata; "" means explicitly bare. Callers must
    /// not substitute an account's local label for either state.
    func effectiveSenderDisplayName(accountID: String, from: String) -> String? {
        if let local = senderDisplayNameOverride(accountID: accountID, from: from) { return local }
        guard let key = SenderIdentityPolicy.normalizedAddress(from) else { return nil }
        return availableSenderIdentities(accountID: accountID).first { SenderIdentityPolicy.normalizedAddress($0.address) == key }?.displayName
    }

    func saveSenderDisplayName(accountID: String, from: String, name: String) throws {
        let key = try checkedSenderIdentity(accountID: accountID, from: from)
        try SenderIdentityPolicy.validateName(name)
        let previous = preferences.value
        preferences.value.senderDisplayNames[accountID, default: [:]][key] = name
        guard preferences.save() else { preferences.value = previous; throw SenderIdentityError.persistence }
        objectWillChange.send()
    }

    func removeSenderDisplayNameOverride(accountID: String, from: String) throws {
        let key = try checkedSenderIdentity(accountID: accountID, from: from)
        let previous = preferences.value
        preferences.value.senderDisplayNames[accountID]?.removeValue(forKey: key)
        if preferences.value.senderDisplayNames[accountID]?.isEmpty == true { preferences.value.senderDisplayNames.removeValue(forKey: accountID) }
        guard preferences.save() else { preferences.value = previous; throw SenderIdentityError.persistence }
        objectWillChange.send()
    }

    /// May be called after account removal. For an existing atomic account-delete
    /// transaction, remove the dictionary key there instead of saving twice.
    func cleanupSenderDisplayNames(accountID: String) throws {
        let previous = preferences.value
        preferences.value.senderDisplayNames.removeValue(forKey: accountID)
        guard preferences.save() else { preferences.value = previous; throw SenderIdentityError.persistence }
        objectWillChange.send()
    }

    private func checkedSenderIdentity(accountID: String, from: String) throws -> String {
        guard accounts.contains(where: { $0.id == accountID }) else { throw SenderIdentityError.account }
        guard let key = SenderIdentityPolicy.normalizedAddress(from) else { throw SenderIdentityError.address }
        guard availableSenderIdentities(accountID: accountID).contains(where: { SenderIdentityPolicy.normalizedAddress($0.address) == key }) else { throw SenderIdentityError.identity }
        return key
    }
}
