import Foundation

/// Query membership is not canonical/offline storage. A successful empty result
/// is authoritative for this window, not deletion authority for cached mail.
struct MailViewQuery: Hashable {
    let accountID: String
    let kind: String
    let identifier: String
    let filter: Int

    static func make(accountID: String, scope: Scope, filter: ListFilter, inboxID: String?, sentID: String? = nil) -> MailViewQuery? {
        switch scope.kind {
        case .all, .unread, .flagged, .attachments:
            guard let inboxID else { return nil }
            return .init(accountID: accountID, kind: "folder", identifier: inboxID, filter: filter.rawValue)
        case .sent:
            guard let sentID else { return nil }
            return .init(accountID: accountID, kind: "folder", identifier: sentID, filter: filter.rawValue)
        case .folder:
            guard let folder = scope.folderID else { return nil }
            return .init(accountID: accountID, kind: "folder", identifier: folder, filter: filter.rawValue)
        case .label:
            guard let label = scope.label else { return nil }
            return .init(accountID: accountID, kind: "label", identifier: label.id, filter: filter.rawValue)
        case .search:
            return .init(accountID: accountID, kind: "search", identifier: scope.query, filter: filter.rawValue)
        case .offline, .outbox: return nil
        }
    }
}

struct MailViewWindow {
    var keys: [String]
    var next: Int
    var more: Bool
    var serial: UInt64
}
