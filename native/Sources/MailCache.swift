import Foundation
import SQLite3

final class MailCache {
    private var database:OpaquePointer?
    init(directory:URL) {
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = directory.appendingPathComponent("mail-cache.sqlite")
        guard sqlite3_open_v2(file.path,&database,SQLITE_OPEN_CREATE|SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { return }
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        execute("PRAGMA journal_mode=DELETE"); execute("PRAGMA secure_delete=ON"); execute("PRAGMA busy_timeout=2000")
        execute("CREATE TABLE IF NOT EXISTS inbox (key TEXT PRIMARY KEY, account TEXT NOT NULL, received REAL NOT NULL, payload BLOB NOT NULL)")
        execute("CREATE INDEX IF NOT EXISTS inbox_date ON inbox(received DESC)")
        execute("CREATE TABLE IF NOT EXISTS details (key TEXT PRIMARY KEY, updated REAL NOT NULL, payload BLOB NOT NULL)")
        execute("CREATE TABLE IF NOT EXISTS offline_pins (key TEXT PRIMARY KEY)")
        execute("CREATE TABLE IF NOT EXISTS catalogs (account TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        execute("CREATE TABLE IF NOT EXISTS source_ips (key TEXT PRIMARY KEY, account TEXT NOT NULL, updated REAL NOT NULL, payload BLOB NOT NULL)")
    }
    deinit { if let database { sqlite3_close(database) } }
    private let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    private func execute(_ sql:String) { sqlite3_exec(database,sql,nil,nil,nil) }
    func messages(accounts:Set<String>) -> [MailMessage] {
        var statement:OpaquePointer?; guard sqlite3_prepare_v2(database,"SELECT payload FROM inbox ORDER BY received DESC",-1,&statement,nil) == SQLITE_OK else { return [] }; defer{sqlite3_finalize(statement)}
        var result:[MailMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement,0), let message = try? JSONDecoder().decode(MailMessage.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(statement,0)))), accounts.contains(message.accountID) else { continue }
            result.append(message)
        }; return result
    }
    func store(_ messages:[MailMessage], account:String, replace:Bool,folderID:String? = nil) {
        let replaceKeys = replace && folderID != nil ? self.messages(accounts:[account]).filter{$0.folderID == folderID}.map{$0.key} : []
        execute("BEGIN IMMEDIATE")
        if replace {
            if folderID != nil {
                for key in replaceKeys {
                    var statement:OpaquePointer?;sqlite3_prepare_v2(database,"DELETE FROM inbox WHERE key=?",-1,&statement,nil);sqlite3_bind_text(statement,1,key,-1,transient);sqlite3_step(statement);sqlite3_finalize(statement)
                }
            }
            else {
                var statement:OpaquePointer?; sqlite3_prepare_v2(database,"DELETE FROM inbox WHERE account=?",-1,&statement,nil)
                sqlite3_bind_text(statement,1,account,-1,transient); sqlite3_step(statement); sqlite3_finalize(statement)
            }
        }
        for message in messages {
            guard let data = try? JSONEncoder().encode(message) else { continue }
            var statement:OpaquePointer?; sqlite3_prepare_v2(database,"INSERT OR REPLACE INTO inbox VALUES(?,?,?,?)",-1,&statement,nil)
            sqlite3_bind_text(statement,1,message.key,-1,transient); sqlite3_bind_text(statement,2,account,-1,transient); sqlite3_bind_double(statement,3,message.date.timeIntervalSince1970)
            _ = data.withUnsafeBytes{sqlite3_bind_blob(statement,4,$0.baseAddress,Int32(data.count),transient)}
            sqlite3_step(statement); sqlite3_finalize(statement)
        }; execute("COMMIT")
    }
    func removeMessage(_ key:String) {
        for table in ["inbox","details","source_ips"] {
            var s:OpaquePointer?;guard sqlite3_prepare_v2(database,"DELETE FROM \(table) WHERE key=?",-1,&s,nil)==SQLITE_OK else{continue}
            sqlite3_bind_text(s,1,key,-1,transient);sqlite3_step(s);sqlite3_finalize(s)
        }
    }
    func contexts(accounts:Set<String>)->[MailboxSession] {
        var s:OpaquePointer?;guard sqlite3_prepare_v2(database,"SELECT payload FROM catalogs",-1,&s,nil)==SQLITE_OK else{return []};defer{sqlite3_finalize(s)}
        var values:[MailboxSession]=[]
        while sqlite3_step(s)==SQLITE_ROW {
            guard let bytes=sqlite3_column_blob(s,0),let value=try? JSONDecoder().decode(MailboxSession.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(s,0)))),accounts.contains(value.accountID),Trust.mail(value.origin),Trust.numericID(value.remoteID) != nil else{continue}
            values.append(value)
        };return values
    }
    func store(_ context:MailboxSession) {
        guard let data=try? JSONEncoder().encode(context) else{return}
        var s:OpaquePointer?;guard sqlite3_prepare_v2(database,"INSERT OR REPLACE INTO catalogs VALUES(?,?)",-1,&s,nil)==SQLITE_OK else{return};defer{sqlite3_finalize(s)}
        sqlite3_bind_text(s,1,context.accountID,-1,transient);_=data.withUnsafeBytes{sqlite3_bind_blob(s,2,$0.baseAddress,Int32(data.count),transient)};sqlite3_step(s)
    }
    func removeAccount(_ account:String) {
        var sourceStatement: OpaquePointer?
        if sqlite3_prepare_v2(database, "DELETE FROM source_ips WHERE account=?", -1, &sourceStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(sourceStatement, 1, account, -1, transient); sqlite3_step(sourceStatement)
        }
        sqlite3_finalize(sourceStatement)
        for message in messages(accounts:[account]) {removeMessage(message.key)}
        var s:OpaquePointer?;sqlite3_prepare_v2(database,"DELETE FROM catalogs WHERE account=?",-1,&s,nil);sqlite3_bind_text(s,1,account,-1,transient);sqlite3_step(s);sqlite3_finalize(s)
    }
    func clearDetails() { execute("DELETE FROM details WHERE key NOT IN (SELECT key FROM offline_pins)") }
    @discardableResult func setPinned(_ key: String, _ pinned: Bool) -> Bool {
        var statement: OpaquePointer?
        let sql = pinned ? "INSERT OR IGNORE INTO offline_pins(key) VALUES(?)" : "DELETE FROM offline_pins WHERE key=?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        return sqlite3_step(statement) == SQLITE_DONE
    }
    func restorePins(_ keys: [String]) { for key in keys { _ = setPinned(key, true) } }
    func detailKeys() -> [String] {
        var statement:OpaquePointer?;guard sqlite3_prepare_v2(database,"SELECT key FROM details",-1,&statement,nil) == SQLITE_OK else{return []};defer{sqlite3_finalize(statement)}
        var keys:[String]=[]
        while sqlite3_step(statement) == SQLITE_ROW {if let text=sqlite3_column_text(statement,0){keys.append(String(cString:text))}}
        return keys
    }
    func detail(_ message:MailMessage) -> MailDetail? {
        var statement:OpaquePointer?; guard sqlite3_prepare_v2(database,"SELECT payload FROM details WHERE key=?",-1,&statement,nil) == SQLITE_OK else { return nil }; defer{sqlite3_finalize(statement)}
        sqlite3_bind_text(statement,1,message.key,-1,transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement,0), let detail = try? JSONDecoder().decode(MailDetail.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(statement,0)))), detail.message.key == message.key else { return nil }; return detail
    }
    func store(_ detail:MailDetail) {
        if let source = detail.sourceIP { storeSourceIP(source, for: detail.message) }
        guard let data = try? JSONEncoder().encode(detail) else { return }
        var statement:OpaquePointer?; sqlite3_prepare_v2(database,"INSERT OR REPLACE INTO details VALUES(?,?,?)",-1,&statement,nil)
        sqlite3_bind_text(statement,1,detail.message.key,-1,transient); sqlite3_bind_double(statement,2,Date().timeIntervalSince1970)
        _ = data.withUnsafeBytes{sqlite3_bind_blob(statement,3,$0.baseAddress,Int32(data.count),transient)}
        sqlite3_step(statement); sqlite3_finalize(statement)
        execute("DELETE FROM details WHERE key NOT IN (SELECT key FROM offline_pins) AND key NOT IN (SELECT key FROM details WHERE key NOT IN (SELECT key FROM offline_pins) ORDER BY updated DESC LIMIT 200)")
    }

    func sourceIP(_ message: MailMessage) -> MailSourceIP? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, "SELECT payload FROM source_ips WHERE key=?", -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, message.key, -1, transient)
            if sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0),
               let value = try? JSONDecoder().decode(MailSourceIPRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))), value.matches(message) {
                return value.source
            }
        }
        // Migrate source data from pre-existing body caches once, without a network request.
        if let old = detail(message), MailSourceIPRecord(message: old.message, source: .init(candidates: [])).matches(message), let source = old.sourceIP {
            storeSourceIP(source, for: message); return source
        }
        return nil
    }
    func storeSourceIP(_ source: MailSourceIP, for message: MailMessage) {
        guard let data = try? JSONEncoder().encode(MailSourceIPRecord(message: message, source: source)) else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO source_ips VALUES(?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, message.key, -1, transient)
        sqlite3_bind_text(statement, 2, message.accountID, -1, transient)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_step(statement)
        execute("DELETE FROM source_ips WHERE key NOT IN (SELECT key FROM source_ips ORDER BY updated DESC LIMIT 10000)")
    }
}
