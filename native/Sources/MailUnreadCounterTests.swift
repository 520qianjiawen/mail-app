import Foundation

func runMailUnreadCounterTests(_ require: (Bool, String) -> Void) {
    let base: [String: Any] = ["folderId": "50", "folderName": "Inbox", "path": "/Inbox", "folderType": "Inbox"]
    func folder(_ counts: [String: Any] = [:]) -> MailFolder? {
        MailFolder.parse(base.merging(counts) { _, fresh in fresh })
    }
    require(folder()?.unread == nil, "missing remote unread counter remains unknown rather than zero")
    require(folder()?.total == nil, "missing remote message total remains unknown")
    require(folder(["unreadCount": 0])?.unread == 0, "explicit numeric unread zero is authoritative")
    require(folder(["unreadCount": "0"])?.unread == 0, "explicit string unread zero is retained")
    require(folder(["unreadCount": 345])?.unread == 345, "remote unread count is not limited to first 100 message rows")
    require(folder(["unread": "7"])?.unread == 7, "recognized unread counter alias is supported")
    require(folder(["unreadCount": "3", "unread": "9"])?.unread == 3, "primary unread counter takes precedence over alias")
    require(folder(["unreadCount": NSNull()])?.unread == nil, "JSON null unread counter is unknown")
    require(folder(["unreadCount": true])?.unread == nil, "boolean is not an unread count")
    require(folder(["unreadCount": -1])?.unread == nil, "negative numeric unread count is rejected")
    require(folder(["unreadCount": "-1"])?.unread == nil, "negative string unread count is rejected")
    require(folder(["unreadCount": 2.5])?.unread == nil, "fractional unread count is not truncated")
    require(folder(["unreadCount": "2.5"])?.unread == nil, "fractional counter string is unknown")
    require(folder(["unreadCount": "9223372036854775808"])?.unread == nil, "overflowing remote counter is rejected")
    require(folder(["unreadCount": "unavailable"])?.unread == nil, "malformed remote counter is unknown")
    require(folder(["messageCount": "240"])?.total == 240, "message total parses independently from unread count")
    require(folder(["messageCount": true])?.total == nil, "boolean message total is rejected")
    require(MailFolder.counter(String(Int.max)) == Int.max, "largest representable nonnegative counter remains exact")
    if let original = folder(), let data = try? JSONEncoder().encode(original),
       let restored = try? JSONDecoder().decode(MailFolder.self, from: data) {
        require(restored.unread == nil && restored.total == nil, "unknown counters remain unknown across cache encoding")
    } else {
        require(false, "unknown folder counters can be encoded and decoded")
    }
}
