import Foundation

/// Parent test entry point may call this alongside the existing model tests.
/// No AppState, account sessions, storage or network is constructed.
func runMailSyncPolicyTests(_ require: (Bool, String) -> Void) {
    let origin = URL(string: "https://mail.zoho.com")!
    let read = MailMessage(accountID: "fixture", remoteID: "100", folderID: "500", id: "1",
                           origin: origin, subject: "read", sender: "fixture@example.test",
                           preview: "", date: Date(timeIntervalSince1970: 0), attachment: false, unread: false)
    var unread = read
    unread.unread = true
    let attached = MailMessage(accountID: "fixture", remoteID: "100", folderID: "500", id: "2",
                               origin: origin, subject: "attachment", sender: "fixture@example.test",
                               preview: "", date: Date(timeIntervalSince1970: 0), attachment: true, unread: false)
    var flagged = read
    flagged.flag = "important"
    var pinned = read
    pinned.pinned = true

    for (scope, expected, api) in [(ScopeKind.unread, ListFilter.unread, 1),
                                   (.attachments, .attachments, 2), (.flagged, .flagged, 3)] {
        for selected in ListFilter.allCases {
            let effective = MailSyncPolicy.effectiveFilter(scopeKind: scope, selected: selected)
            require(effective == expected && MailSyncPolicy.apiFilter(effective) == api,
                    "smart scope \(scope.rawValue) overrides stale toolbar \(selected.rawValue) for API and local policy")
        }
    }
    let initialUnread = MailSyncPolicy.effectiveFilter(scopeKind: .unread, selected: .all)
    require([read, unread].filter { MailSyncPolicy.matches($0, filter: initialUnread) }.count == 1 &&
            MailSyncPolicy.matches(unread, filter: initialUnread) &&
            !MailSyncPolicy.matches(read, filter: initialUnread), "initial Unread scope excludes read messages with toolbar all")
    require(MailSyncPolicy.matches(attached, filter: .attachments) && !MailSyncPolicy.matches(read, filter: .attachments),
            "attachment predicate agrees with effective attachment selection")
    require(MailSyncPolicy.matches(flagged, filter: .flagged) && MailSyncPolicy.matches(pinned, filter: .flagged) &&
            !MailSyncPolicy.matches(read, filter: .flagged), "flagged local predicate preserves existing flag or pin behavior")

    for scope in [ScopeKind.all, .sent, .folder, .label, .search, .offline, .outbox] {
        for selected in ListFilter.allCases {
            require(MailSyncPolicy.effectiveFilter(scopeKind: scope, selected: selected) == selected &&
                    MailSyncPolicy.scopeKindAfterSelectingFilter(selected, in: scope) == scope,
                    "ordinary scope \(scope.rawValue) preserves user filter \(selected.rawValue)")
        }
    }
    for (scope, intrinsic) in [(ScopeKind.unread, ListFilter.unread), (.attachments, .attachments), (.flagged, .flagged)] {
        for selected in ListFilter.allCases {
            let next = MailSyncPolicy.scopeKindAfterSelectingFilter(selected, in: scope)
            require(next == (selected == intrinsic ? scope : .all) &&
                    MailSyncPolicy.effectiveFilter(scopeKind: next, selected: selected) == selected,
                    "toolbar selection \(selected.rawValue) remains effective from smart scope \(scope.rawValue)")
        }
    }
}
