import Foundation

/// Metadata can label an already authorized address; it never adds permission.
enum SenderIdentityDiscovery {
    static func parse(primary: String, accountName: Any?, rows: [[String: Any]], allowedAddresses: [String]) -> [MailSenderIdentity] {
        let allowed = Set(allowedAddresses.compactMap(SenderIdentityPolicy.normalizedAddress))
        var names: [String: String] = [:]
        if let key = SenderIdentityPolicy.normalizedAddress(primary), allowed.contains(key),
           let name = accountName as? String, (try? SenderIdentityPolicy.validateName(name)) != nil { names[key] = name }
        for row in rows {
            guard let raw = row["fromAddress"] as? String,
                  let key = SenderIdentityPolicy.normalizedAddress(raw), allowed.contains(key),
                  let name = row["displayName"] as? String,
                  (try? SenderIdentityPolicy.validateName(name)) != nil else { continue }
            names[key] = name
        }
        return allowedAddresses.compactMap { address in
            guard let key = SenderIdentityPolicy.normalizedAddress(address) else { return nil }
            return MailSenderIdentity(address: address, displayName: names[key])
        }
    }
}

func runSenderIdentityDiscoveryTests(_ require: (Bool, String) -> Void) {
    let values = SenderIdentityDiscovery.parse(primary: "main@example.test", accountName: "Primary server name", rows: [
        ["fromAddress": "MAIN@example.test", "displayName": "Specific primary"],
        ["fromAddress": "alias@example.test", "displayName": "Alias business"],
        ["fromAddress": "other@example.test", "displayName": "Not permitted"],
        ["fromAddress": "unknown@example.test", "displayName": "Bad\r\nBcc: victim@example.test"]
    ], allowedAddresses: ["main@example.test", "alias@example.test", "unknown@example.test"])
    require(values.first { $0.address == "main@example.test" }?.displayName == "Specific primary", "per-address server display name overrides account-wide metadata only for same primary")
    require(values.first { $0.address == "alias@example.test" }?.displayName == "Alias business", "server aliases retain independent display names")
    require(values.first { $0.address == "unknown@example.test" }?.displayName == nil, "invalid remote name remains unknown instead of entering sender header")
    require(!values.contains { $0.address == "other@example.test" }, "display metadata cannot grant a new From alias")
    let fallback = SenderIdentityDiscovery.parse(primary: "main@example.test", accountName: "Primary only", rows: [], allowedAddresses: ["main@example.test", "alias@example.test"])
    require(fallback.first?.displayName == "Primary only" && fallback.last?.displayName == nil, "account-wide display name never becomes an invented alias default")
}
