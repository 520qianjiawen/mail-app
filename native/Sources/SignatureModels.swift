import Foundation
import CryptoKit

struct LocalMailSignature: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var html: String
}

struct SignatureDefaults: Codable, Equatable, Sendable {
    var new: String? = nil
    var reply: String? = nil
    init(new: String? = nil, reply: String? = nil) { self.new = new; self.reply = reply }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        new = c.contains(.new) && (try? c.decodeNil(forKey: .new)) != true ? ((try? c.decode(String.self, forKey: .new)) ?? "none") : nil
        reply = c.contains(.reply) && (try? c.decodeNil(forKey: .reply)) != true ? ((try? c.decode(String.self, forKey: .reply)) ?? "none") : nil
    }
}

struct SignatureSettingsMap: Decodable {
    let value: [String: AccountSignatureSettings]
    struct Key: CodingKey { var stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }; var intValue: Int? { nil }; init?(intValue: Int) { return nil } }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        var result: [String: AccountSignatureSettings] = [:]
        for key in c.allKeys {
            if let settings = try? c.decode(AccountSignatureSettings.self, forKey: key) { result[key.stringValue] = settings }
            else { var empty = AccountSignatureSettings(); empty.defaults = SignatureDefaults(new: "none", reply: "none"); result[key.stringValue] = empty }
        }
        value = result
    }
}

struct AccountSignatureSettings: Codable, Equatable, Sendable {
    var items: [LocalMailSignature] = []
    var defaults = SignatureDefaults()
    var aliases: [String: SignatureDefaults] = [:]
    var legacyMigrated = false
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decode([LossySignature].self, forKey: .items))?.compactMap(\.value) ?? []
        defaults = (try? c.decode(SignatureDefaults.self, forKey: .defaults)) ?? SignatureDefaults()
        aliases = (try? c.decode([String: SignatureDefaults].self, forKey: .aliases)) ?? [:]
        legacyMigrated = (try? c.decode(Bool.self, forKey: .legacyMigrated)) ?? false
        self = SignaturePolicy.normalized(self)
    }
    private struct LossySignature: Decodable {
        let value: LocalMailSignature?
        init(from decoder: Decoder) { value = try? LocalMailSignature(from: decoder) }
    }
}

struct SignatureDraftSegment: Codable, Sendable {
    var location: Int
    var length: Int
    var text: String
    var identity: String
    var reference: String
    var rtfSHA256: String
}

enum SignatureStoreError: Error, LocalizedError {
    case account, name, duplicate, html, missing, persistence, limit
    var errorDescription: String? {
        switch self {
        case .account: return "请选择有效账号"
        case .name: return "签名名称需为 1–80 个字符"
        case .limit: return "每个账号最多保存 100 个本机签名"
        case .duplicate: return "此账号已有同名签名"
        case .html: return "签名内容为空或超过 256 KB"
        case .missing: return "签名已被删除"
        case .persistence: return "本机签名保存失败，请检查存储位置；更改尚未保存"
        }
    }
}

enum SignaturePolicy {
    static func address(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    static func identity(account: String, from: String) -> String { account + "\u{1f}" + address(from) }
    static func isChoice(_ value: String) -> Bool {
        value == "automatic" || value == "none" || value.hasPrefix("local:") && UUID(uuidString: String(value.dropFirst(6))) != nil || value.hasPrefix("remote:") && validRemoteID(String(value.dropFirst(7)))
    }
    static func validRemoteID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 160 && id.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
    }
    static func cleanHTML(_ html: String) -> String? {
        SignatureHTML.sanitize(html)
    }
    static func normalized(_ value: AccountSignatureSettings) -> AccountSignatureSettings {
        var result = value
        var ids = Set<String>(), names = Set<String>()
        result.items = value.items.prefix(100).compactMap { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: item.id) != nil, (1...80).contains(name.count),
                  !ids.contains(item.id.lowercased()), !names.contains(name.lowercased()), let html = cleanHTML(item.html) else { return nil }
            ids.insert(item.id.lowercased()); names.insert(name.lowercased())
            return LocalMailSignature(id: item.id.lowercased(), name: name, html: html)
        }
        func defaults(_ input: SignatureDefaults) -> SignatureDefaults {
            SignatureDefaults(new: input.new.map { isChoice($0) ? $0 : "none" }, reply: input.reply.map { isChoice($0) ? $0 : "none" })
        }
        result.defaults = defaults(value.defaults)
        result.aliases = [:]
        for (alias, rule) in value.aliases.sorted(by: { $0.key < $1.key }) {
            let key = address(alias)
            if MailAddresses.validated(key)?.count == 1, result.aliases[key] == nil { result.aliases[key] = defaults(rule) }
        }
        return result
    }
    static func migrate(_ preferences: inout NativePreferences) {
        for account in preferences.accounts {
            var settings = normalized(preferences.accountSignatures[account.id] ?? AccountSignatureSettings())
            guard !settings.legacyMigrated else { preferences.accountSignatures[account.id] = settings; continue }
            if let legacy = preferences.signatures?[account.id], let html = cleanHTML(legacy), settings.items.isEmpty {
                let item = LocalMailSignature(name: "旧版本签名", html: html)
                settings.items = [item]
                if preferences.defaultSignatureByAccount[account.id] == nil, settings.defaults.new == nil, settings.defaults.reply == nil {
                    settings.defaults = SignatureDefaults(new: "local:" + item.id, reply: "local:" + item.id)
                }
            }
            if let legacy = preferences.defaultSignatureByAccount[account.id], validRemoteID(legacy) {
                if settings.defaults.new == nil { settings.defaults.new = "remote:" + legacy }
                if settings.defaults.reply == nil { settings.defaults.reply = "remote:" + legacy }
            }
            settings.legacyMigrated = true
            preferences.accountSignatures[account.id] = settings
        }
    }
    static func options(settings: AccountSignatureSettings, remote: [MailSignature]) -> [MailSignature] {
        let locals = normalized(settings).items.map { MailSignature(id: "local:" + $0.id, name: "本机 · " + $0.name, html: $0.html) }
        var ids = Set<String>()
        let servers = remote.prefix(100).compactMap { item -> MailSignature? in
            guard validRemoteID(item.id), ids.insert(item.id).inserted, let html = cleanHTML(item.html) else { return nil }
            return MailSignature(id: "remote:" + item.id, name: "服务器 · " + String(item.name.prefix(80)), html: html)
        }
        return locals + servers
    }
    static func choice(settings: AccountSignatureSettings, from: String, reply: Bool) -> String {
        let alias = settings.aliases[address(from)]
        return (reply ? alias?.reply : alias?.new) ?? (reply ? settings.defaults.reply : settings.defaults.new) ?? "automatic"
    }
    static func selected(settings: AccountSignatureSettings, from: String, reply: Bool, options: [MailSignature]) -> MailSignature? {
        let choice = choice(settings: settings, from: from, reply: reply)
        if choice == "none" { return nil }
        if choice == "automatic" { return options.count == 1 ? options.first : nil }
        return options.first { $0.id == choice }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

