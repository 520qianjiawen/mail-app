import Foundation

struct MailDraft:Codable,Sendable {
    var id=UUID().uuidString.lowercased()
    var accountID:String
    var from:String
    var mode:String
    var source:MailDetail?
    var to="",cc="",bcc="",subject="",body=""
    var rtf:Data?=nil
    var files:[String]=[]
    var updated=Date()
    var state="editing"
    var queuedItemID:String?=nil
    var cloudID:String?=nil
    var cloudUncertain=false
    var obsoleteCloudIDs:[String]?=nil
    var excludedForwardIDs:[String]?=nil
    var receipt=false
    var scheduleType:Int?=nil
    var priority:Int?=nil
    var managedSignature:SignatureDraftSegment?=nil
    // Optional keys preserve decoding of drafts written before the HTML composer.
    var htmlBody:String?=nil
    var htmlSignature:HTMLSignatureDraftState?=nil
}

final class DraftStore {
    let directory:URL
    init(directory:URL) {self.directory=directory.appendingPathComponent("drafts");try? FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
    func folder(_ id:String) throws -> URL {
        guard UUID(uuidString:id) != nil,id.count==36 else{throw MailFailure.response}
        return directory.appendingPathComponent(id,isDirectory:true)
    }
    func all(accounts:Set<String>) -> [MailDraft] {
        let children=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
        return children.compactMap {url in
            guard let target=try? folder(url.lastPathComponent),target.path==url.standardizedFileURL.path,let data=try? Data(contentsOf:target.appendingPathComponent("draft.json")),let value=try? JSONDecoder().decode(MailDraft.self,from:data),value.id==url.lastPathComponent,accounts.contains(value.accountID) else{return nil}
            return value
        }.sorted{$0.updated>$1.updated}
    }
    func save(_ value:MailDraft) throws {
        let target=try folder(value.id)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=target.appendingPathComponent("draft.json"),data=try JSONEncoder().encode(value)
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func remove(_ id:String) throws {
        let target=try folder(id)
        if FileManager.default.fileExists(atPath:target.path) {try FileManager.default.removeItem(at:target)}
    }
    func importFile(_ source:URL,id:String) throws -> URL {
        let size=(try source.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]))
        guard size.isRegularFile==true,(size.fileSize ?? Int.max)<=25*1024*1024 else{throw MailFailure.response}
        let target=try folder(id).appendingPathComponent("attachments",isDirectory:true).appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let destination=target.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at:source,to:destination)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
        return destination
    }
    func files(_ value:MailDraft) -> [URL] {
        guard let root=try? folder(value.id) else{return []}
        return value.files.compactMap {path in
            let url=URL(fileURLWithPath:path).standardizedFileURL
            guard url.path.hasPrefix(root.path+"/attachments/"),url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path+"/attachments/") else{return nil};return url
        }
    }
}
