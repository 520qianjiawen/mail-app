import Foundation
import CryptoKit

struct Region: Sendable {
    let id: String, name: String, domain: String
    var origin: URL { URL(string: "https://mail.\(domain)")! }
    static let all: [Region] = [
        .init(id: "global", name: "国际", domain: "zoho.com"), .init(id: "china", name: "中国", domain: "zoho.com.cn"),
        .init(id: "europe", name: "欧洲", domain: "zoho.eu"), .init(id: "india", name: "印度", domain: "zoho.in"),
        .init(id: "australia", name: "澳大利亚", domain: "zoho.com.au"), .init(id: "japan", name: "日本", domain: "zoho.jp"),
        .init(id: "canada", name: "加拿大", domain: "zohocloud.ca"), .init(id: "saudi", name: "沙特", domain: "zoho.sa"),
        .init(id: "uae", name: "阿联酋", domain: "zoho.ae"), .init(id: "singapore", name: "新加坡", domain: "zoho.sg")
    ]
    static func find(_ id: String) -> Region? { all.first { $0.id == id } }
}

struct MailAccount: Codable, Hashable, Sendable, Identifiable {
    var id: String, name: String, region: String
    var dataIdentifier: UUID {
        let hex = SHA256.hash(data: Data(("MailLite.Native." + id).utf8)).map { String(format: "%02x", $0) }.joined()
        return UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))")!
    }
}

enum Trust {
    static func mail(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        return Region.all.contains { url.host == "mail.\($0.domain)" }
    }
    static func inside(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        if url.scheme == "blob" { return mail(URL(string: String(url.absoluteString.dropFirst(5)))) }
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        return mail(url) || Region.all.contains { url.host == "accounts.\($0.domain)" } ||
            ["accounts.google.com", "login.microsoftonline.com", "login.live.com", "appleid.apple.com", "appleid.apple.com.cn"].contains(url.host ?? "")
    }
    static func outside(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme ?? "") && url.user == nil && url.password == nil &&
        !url.absoluteString.contains("%0A") && !url.absoluteString.contains("%0D")
    }
    static func numericID(_ value: Any?) -> String? {
        let string: String
        if let value = value as? String { string = value }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { string = value.stringValue }
        else { return nil }
        return string.range(of: "^[0-9]{1,64}$", options: .regularExpression) != nil ? string : nil
    }
    static func entities(_ value: String) -> String {
        var text = value
        let named = ["&amp;":"&", "&lt;":"<", "&gt;":">", "&quot;":"\"", "&#39;":"'", "&#x27;":"'", "&apos;":"'", "&nbsp;":" "]
        for (key, replacement) in named { text = text.replacingOccurrences(of: key, with: replacement) }
        guard text.contains("&#") else { return text }
        let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]{1,6});")
        guard let regex else { return text }
        var result = "", index = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[index..<range.lowerBound]
            let hex = text[Range(match.range(at: 1), in: text) ?? range].isEmpty == false
            let digits = String(text[Range(match.range(at: 2), in: text) ?? range])
            if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) { result.append(Character(scalar)) }
            index = range.upperBound
        }
        result += text[index...]
        return result
    }
    static func text(_ value: Any?, limit: Int = 240) -> String {
        guard let value = value as? String else { return "" }
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return String(entities(clean).prefix(limit))
    }
}

struct MailMessage: Codable, Sendable {
    let accountID: String, remoteID: String, folderID: String, id: String, origin: URL
    let subject: String, sender: String, preview: String, date: Date, attachment: Bool
    var unread: Bool
    var threadID: String? = nil
    var threadCount: Int? = nil
    var flag: String? = nil
    var archived: Bool? = nil
    var pinned: Bool? = nil
    var snoozedUntil: Date? = nil
    var labels: [String]? = nil
    var fromAddress: String? = nil
    var key: String { "\(accountID):\(remoteID):\(folderID):\(id)" }
    var hasFlag: Bool { !["0","flag_not_set",""].contains(flag ?? "") }
    static func conversations(_ messages:[MailMessage])->[MailMessage] {
        let sorted=messages.sorted{$0.date == $1.date ? $0.key<$1.key : $0.date>$1.date}
        var rows:[MailMessage]=[],positions:[String:Int]=[:],counts:[String:Int]=[:]
        for message in sorted {
            let key=message.threadID.map{"\(message.accountID):\(message.remoteID):\(message.origin.host ?? ""):\($0)"} ?? message.key
            counts[key,default:0]+=1
            if let index=positions[key] {
                rows[index].unread = rows[index].unread || message.unread
                rows[index].threadCount=max(rows[index].threadCount ?? 1,max(counts[key] ?? 1,message.threadCount ?? 1))
            } else {positions[key]=rows.count;rows.append(message)}
        };return rows
    }
    static func parse(_ row: [String: Any], accountID: String, remoteID: String, folderID: String, origin: URL) -> MailMessage? {
        guard Trust.mail(origin), let id = Trust.numericID(row["messageId"]), Trust.numericID(remoteID) != nil, Trust.numericID(folderID) != nil else { return nil }
        if let folder = row["folderId"], Trust.numericID(folder) != folderID { return nil }
        let timestamp = Double(String(describing: row["receivedTime"] ?? row["receivedtime"] ?? row["sentDateInGMT"] ?? "0")) ?? 0
        let summary = Trust.text(row["summary"], limit: 500).replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        var message = MailMessage(accountID: accountID, remoteID: remoteID, folderID: folderID, id: id, origin: origin,
            subject: Trust.text(row["subject"]).isEmpty ? "（无主题）" : Trust.text(row["subject"]),
            sender: Trust.text(row["sender"] ?? row["fromAddress"], limit: 160),
            preview: String(Trust.entities(summary).prefix(200)),
            date: Date(timeIntervalSince1970: timestamp.isFinite && timestamp >= 0 && timestamp < 8_640_000_000_000_000 ? timestamp / 1000 : 0),
            attachment: (row["hasAttachment"] as? Bool == true) || (Int(String(describing: row["hasAttachment"] ?? "0")) ?? 0) > 0, unread: ["0","unread"].contains(String(describing: row["status"] ?? "1").lowercased()))
        if let rawFrom = row["fromAddress"] as? String,
           let addresses = MailAddresses.validated(Trust.text(rawFrom, limit: 320)), addresses.count == 1 {
            message.fromAddress = addresses[0]
        }
        if let id=Trust.numericID(row["threadId"]),id != "0" {message.threadID=id}
        message.threadCount=Int(String(describing:row["threadCount"] ?? "0"))
        message.flag=Trust.text(String(describing:row["flagid"] ?? "flag_not_set"),limit:40)
        message.archived=["true","1"].contains(String(describing:row["isArchived"] ?? "false").lowercased())
        message.pinned=["true","1"].contains(String(describing:row["isPinned"] ?? row["pinned"] ?? "false").lowercased())
        if let snoozed=Double(String(describing:row["snoozeTime"] ?? "0")),snoozed>0 {message.snoozedUntil=Date(timeIntervalSince1970:snoozed/1000)}
        if let ids=row["labelId"] as? [String] {message.labels=ids.filter{Trust.numericID($0) != nil}}
        else if let id=Trust.numericID(row["labelId"]) {message.labels=[id]}
        return message
    }
}

struct SavedSearch: Codable, Hashable, Sendable, Identifiable {
    var id=UUID().uuidString
    var name:String
    var query:String
}

struct NativePreferences: Codable {
    var accounts: [MailAccount] = []
    var width: Double = 1280, height: Double = 850
    var signatures: [String:String]? = nil
    var listWidth: Double = 392
    var sidebarWidth: Double = 232
    var appearanceMode: MailAppearanceMode = .system
    var compactRows: Bool = false
    var previewLines: Int = 1
    var notificationsEnabled: Bool = false
    var notifyInboxOnly: Bool = true
    var playSound: Bool = false
    var badgeEnabled: Bool = true
    var markReadOnOpen: Bool = true
    var inlineReply: Bool = true
    var loadRemoteImages: Bool = false
    var readingPaneRight: Bool = true
    var searchHistory: [String] = []
    var savedSearches: [SavedSearch] = []
    var lastAccountID: String? = nil
    var lastFolderID: String? = nil
    var lastScopeKind: String = "all"
    var defaultSignatureByAccount: [String:String] = [:]
    var accountSignatures: [String:AccountSignatureSettings] = [:]
    // Missing address = server fallback; present empty string = explicit bare address.
    var senderDisplayNames: [String:[String:String]] = [:]
    var vacationEnabled: [String:Bool] = [:]
    var vacationMessage: [String:String] = [:]
    var offlineSaved: [String] = []
    var mailReminders: [String: MailReminderRecord] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([MailAccount].self, forKey: .accounts) ?? []
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1280
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 850
        signatures = try c.decodeIfPresent([String:String].self, forKey: .signatures)
        listWidth = try c.decodeIfPresent(Double.self, forKey: .listWidth) ?? 392
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 232
        appearanceMode = (try? c.decodeIfPresent(MailAppearanceMode.self, forKey: .appearanceMode)) ?? .system
        compactRows = try c.decodeIfPresent(Bool.self, forKey: .compactRows) ?? false
        previewLines = try c.decodeIfPresent(Int.self, forKey: .previewLines) ?? 1
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        notifyInboxOnly = try c.decodeIfPresent(Bool.self, forKey: .notifyInboxOnly) ?? true
        playSound = try c.decodeIfPresent(Bool.self, forKey: .playSound) ?? false
        badgeEnabled = try c.decodeIfPresent(Bool.self, forKey: .badgeEnabled) ?? true
        markReadOnOpen = try c.decodeIfPresent(Bool.self, forKey: .markReadOnOpen) ?? true
        inlineReply = try c.decodeIfPresent(Bool.self, forKey: .inlineReply) ?? true
        loadRemoteImages = try c.decodeIfPresent(Bool.self, forKey: .loadRemoteImages) ?? false
        readingPaneRight = try c.decodeIfPresent(Bool.self, forKey: .readingPaneRight) ?? true
        searchHistory = try c.decodeIfPresent([String].self, forKey: .searchHistory) ?? []
        savedSearches = try c.decodeIfPresent([SavedSearch].self, forKey: .savedSearches) ?? []
        lastAccountID = try c.decodeIfPresent(String.self, forKey: .lastAccountID)
        lastFolderID = try c.decodeIfPresent(String.self, forKey: .lastFolderID)
        lastScopeKind = try c.decodeIfPresent(String.self, forKey: .lastScopeKind) ?? "all"
        defaultSignatureByAccount = try c.decodeIfPresent([String:String].self, forKey: .defaultSignatureByAccount) ?? [:]
        accountSignatures = (try? c.decodeIfPresent(SignatureSettingsMap.self, forKey: .accountSignatures))?.value ?? [:]
        senderDisplayNames = (try? c.decodeIfPresent([String:[String:String]].self, forKey: .senderDisplayNames)) ?? [:]
        vacationEnabled = try c.decodeIfPresent([String:Bool].self, forKey: .vacationEnabled) ?? [:]
        vacationMessage = try c.decodeIfPresent([String:String].self, forKey: .vacationMessage) ?? [:]
        offlineSaved = try c.decodeIfPresent([String].self, forKey: .offlineSaved) ?? []
        mailReminders = (try? c.decodeIfPresent([String: MailReminderRecord].self, forKey: .mailReminders)) ?? [:]
    }
}

struct MailFolder: Codable,Hashable,Sendable,Identifiable {
    let id:String,name:String,path:String,type:String
    var unread:Int?=nil
    var total:Int?=nil
    var systemName:String? {
        let part=String(path.drop(while:{$0 == "/"}))
        return Self.names[part] != nil && !part.contains("/") ? part : nil
    }
    static let names=["Inbox":"收件箱","Drafts":"草稿","Templates":"模板","Snoozed":"已延迟","Sent":"已发送","Spam":"垃圾邮件","Trash":"回收站","Outbox":"发件箱"]
    var title:String {systemName.flatMap{Self.names[$0]} ?? name}
    static func parse(_ row:[String:Any])->MailFolder? {
        guard let id=Trust.numericID(row["folderId"]) else{return nil}
        let name=Trust.text(row["folderName"],limit:160),path=Trust.text(row["path"],limit:1000)
        guard !name.isEmpty,!path.isEmpty else{return nil}
        var folder=MailFolder(id:id,name:name,path:path,type:Trust.text(row["folderType"],limit:80))
        // A missing counter is unknown, not a confirmed zero. In particular,
        // partial folder responses must not overwrite a known unread total.
        folder.unread=counter(row["unreadCount"]) ?? counter(row["unread"])
        folder.total=counter(row["messageCount"])
        return folder
    }
    static func counter(_ value: Any?) -> Int? {
        let text: String
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            text = number.stringValue
        } else if let string = value as? String { text = string }
        else { return nil }
        guard text.range(of: "^[0-9]{1,19}$", options: .regularExpression) != nil,
              let count = Int(text) else { return nil }
        return count
    }
}
struct MailboxSession:Codable,Sendable {
    let accountID:String,remoteID:String,email:String,origin:URL
    var folders:[MailFolder]
    var addresses:[String]
    var senderIdentities:[MailSenderIdentity]? = nil
    var inbox:MailFolder? {folders.first{$0.systemName == "Inbox"}}
    var sent:MailFolder? {folders.first{$0.systemName == "Sent"}}
    func messageReference(folder:String? = nil)->MailMessage? {
        guard let id=folder ?? inbox?.id else{return nil}
        return MailMessage(accountID:accountID,remoteID:remoteID,folderID:id,id:"0",origin:origin,subject:"",sender:email,preview:"",date:Date(),attachment:false,unread:false)
    }
}
struct MailLabel: Codable, Hashable, Sendable, Identifiable {
    let id:String,name:String,color:String
    static let palette=["#5B6CFF","#FF7A59","#22B07D","#F5A623","#B05CE6","#2AA6C9","#E85D75","#6B7A90"]
    var tintIndex:Int { abs(name.unicodeScalars.reduce(0){$0+Int($1.value)}) % Self.palette.count }
}

enum MailAction:Equatable {
    case read,unread,archive,unarchive,trash,move(String),flag(String),spam,notSpam
    case pin(Bool),snooze(Date?),label(String,Bool)
    var mode:String {
        switch self {
        case .read:return "markAsRead"
        case .unread:return "markAsUnread"
        case .archive:return "archiveMails"
        case .unarchive:return "unArchiveMails"
        case .trash,.move:return "moveMessage"
        case .flag:return "setFlag"
        case .spam:return "moveToSpam"
        case .notSpam:return "markNotSpam"
        case .pin(let value):return value ? "pin" : "unpin"
        case .snooze(let date):return date == nil ? "unsnooze" : "snooze"
        case .label(_,let add):return add ? "addLabel" : "removeLabel"
        }
    }
    func payload(_ messages:[MailMessage]) throws -> [String:Any] {
        guard let first=messages.first,!messages.isEmpty,messages.allSatisfy({$0.accountID == first.accountID && $0.remoteID == first.remoteID && $0.origin == first.origin && Trust.numericID($0.id) != nil}) else{throw MailFailure.response}
        var body:[String:Any]=["mode":mode,"messageId":Array(Set(messages.map{$0.id})).sorted()]
        if case .move(let folder)=self {guard Trust.numericID(folder) != nil else{throw MailFailure.folder};body["destfolderId"]=folder;body["isArchive"]=true}
        if case .flag(let flag)=self {guard ["info","important","followup","flag_not_set"].contains(flag) else{throw MailFailure.response};body["flagid"]=flag;body["isArchive"]=true}
        if case .snooze(let date)=self {if let date {guard date > Date() else{throw MailFailure.response};body["snoozeTime"]=Int(date.timeIntervalSince1970*1000)}}
        if case .label(let id,let add)=self {guard Trust.numericID(id) != nil else{throw MailFailure.folder};body["labelId"]=id;body["isArchive"]=true;body["labelAction"]=add ? "add" : "remove"}
        if self == .trash {throw MailFailure.folder} // Resolve the source account's Trash before dispatch.
        return body
    }
}
final class PreferenceFile {
    let directory: URL
    var value: NativePreferences
    let imported: Bool
    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mail Lite")
        self.directory = directory ?? support.appendingPathComponent("Native")
        let file = self.directory.appendingPathComponent("preferences.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(NativePreferences.self, from: data) {
            value = saved; imported = false
        } else if directory == nil, let data = try? Data(contentsOf: support.appendingPathComponent("preferences.json")),
                  let saved = try? JSONDecoder().decode(NativePreferences.self, from: data) {
            // Browser sessions cannot migrate from Electron. Do not present old
            // account labels as accounts signed into this client.
            value = saved; value.accounts = []; imported = false
        } else { value = .init(); imported = false }
        var seen = Set<String>()
        value.accounts = value.accounts.filter {
            $0.id.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil && Region.find($0.region) != nil && seen.insert($0.id).inserted
        }.map { .init(id: $0.id, name: Trust.text($0.name, limit: 80), region: $0.region) }
        value.width = min(2560, max(960, value.width.isFinite ? value.width : 1280))
        value.height = min(1600, max(640, value.height.isFinite ? value.height : 850))
    }
    @discardableResult func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(value), target = directory.appendingPathComponent("preferences.json")
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        } catch { return false }
    }
}
