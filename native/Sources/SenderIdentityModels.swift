import Foundation

/// Server-provided metadata, not permission to send from an arbitrary address.
struct MailSenderIdentity: Codable, Sendable, Equatable {
    let address: String
    let displayName: String?
}

enum SenderIdentityError: Error, LocalizedError, Equatable {
    case address, name, account, identity, persistence
    var errorDescription: String? {
        switch self {
        case .address: return "请选择单个有效的邮箱地址。"
        case .name: return "发件人名称最多 120 个字符（1024 字节），请移除换行及控制字符。"
        case .account: return "账号已移除，请重新选择账号。"
        case .identity: return "此发件地址已失效或尚未加载，请刷新账号后重试。"
        case .persistence: return "保存失败，原设置已保留，请重试。"
        }
    }
}

/// Pure Foundation policy. Account IDs, alias selectors and signature identities
/// always remain bare addresses; formattedFrom is only for a name-addr consumer.
enum SenderIdentityPolicy {
    static let maximumNameCharacters = 120
    static let maximumNameBytes = 1024

    /// Strict validation: never extract a mailbox from display text or headers.
    /// This intentionally accepts the same ASCII mailbox family as this client.
    static func normalizedAddress(_ raw: String) -> String? {
        guard raw.utf8.count <= 254, !raw.isEmpty,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let local = String(parts[0]), domain = String(parts[1])
        guard !local.isEmpty, local.utf8.count <= 64, !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."),
              local.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$", options: .regularExpression) != nil else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 &&
            label.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$", options: .regularExpression) != nil
        }) else { return nil }
        return raw.lowercased()
    }

    /// Preserve authored spaces, Unicode and punctuation; reject, never sanitize.
    @discardableResult static func validateName(_ name: String) throws -> String {
        guard name.count <= maximumNameCharacters, name.utf8.count <= maximumNameBytes,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else { throw SenderIdentityError.name }
        return name
    }

    /// Does not assert that any particular API accepts RFC name-addr syntax.
    /// Email-like text in the name is literal quoted text, never another mailbox.
    static func formattedFrom(address: String, name: String?) throws -> String {
        guard normalizedAddress(address) != nil else { throw SenderIdentityError.address }
        guard let name else { return address }
        try validateName(name)
        guard !name.isEmpty else { return address }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\" <" + address + ">"
    }
}
