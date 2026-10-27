import Foundation

/// Pure view-filter policy shared by remote queries and local projections.
/// Smart scopes own their filter; selecting another toolbar filter leaves the
/// smart scope rather than displaying a selection that has no effect.
enum MailSyncPolicy {
    static func effectiveFilter(scopeKind: ScopeKind, selected: ListFilter) -> ListFilter {
        switch scopeKind {
        case .unread: return .unread
        case .attachments: return .attachments
        case .flagged: return .flagged
        default: return selected
        }
    }

    static func scopeKindAfterSelectingFilter(_ selected: ListFilter, in scopeKind: ScopeKind) -> ScopeKind {
        switch scopeKind {
        case .unread, .attachments, .flagged:
            return selected == effectiveFilter(scopeKind: scopeKind, selected: selected) ? scopeKind : .all
        default: return scopeKind
        }
    }

    static func apiFilter(_ filter: ListFilter) -> Int { filter.rawValue }

    static func matches(_ message: MailMessage, filter: ListFilter) -> Bool {
        switch filter {
        case .all: return true
        case .unread: return message.unread
        case .attachments: return message.attachment
        // Preserve existing local behavior. Server flaggedMails semantics are
        // not established here; this policy does not assert pin equivalence.
        case .flagged: return message.hasFlag || message.pinned == true
        }
    }
}
