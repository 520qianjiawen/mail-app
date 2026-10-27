import Foundation
import WebKit

/// Zoho webmail endpoints that go beyond listing and reading. Every request is
/// still confined to the account's own authenticated origin. Endpoints that are
/// not covered by public Zoho documentation are marked `experimental`: the UI
/// surfaces a clear failure instead of pretending success.
@MainActor extension MailAPI {

    func messages(context: MailboxSession, folder: MailFolder, labelID: String? = nil,
                  store: WKWebsiteDataStore, browser: WKWebView,
                  start: Int = 1, filter: Int = 0) async throws -> InboxPage {
        guard context.folders.contains(where: { $0.id == folder.id }), Trust.numericID(context.remoteID) != nil else {
            throw MailFailure.folder
        }
        var query = ["folderId": folder.id, "start": String(max(1, start)), "limit": "100",
                     "sortBy": "date", "sortorder": "false",
                     "status": filter == 1 ? "unread" : "all", "includeto": "true"]
        if filter == 2 { query["attachedMails"] = "true" }
        if filter == 3 { query["flaggedMails"] = "true" }
        if filter == 4 { query["includearchive"] = "true" }
        if let labelID { query["labelId"] = labelID }
        let rows = try await listRequest(context, path: "messages/view", query: query, store: store, browser: browser)
        let messages = rows.compactMap { row -> MailMessage? in
            guard let folderID = Trust.numericID(row["folderId"]) else { return nil }
            return MailMessage.parse(row, accountID: context.accountID, remoteID: context.remoteID,
                                     folderID: folderID, origin: context.origin)
        }
        return .init(messages: messages, remoteID: context.remoteID, folderID: folder.id,
                     next: start + rows.count, more: rows.count == 100, email: context.email, mailbox: context)
    }

    // MARK: - Labels

    func labels(context: MailboxSession, store: WKWebsiteDataStore, browser: WKWebView) async throws -> [MailLabel] {
        guard Trust.numericID(context.remoteID) != nil else { throw MailFailure.response }
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/labels")
        guard let rows = try await browserRequest(url, csrf: token, browser: browser) as? [[String: Any]] else {
            throw MailFailure.response
        }
        return rows.compactMap { row -> MailLabel? in
            guard let id = Trust.numericID(row["labelId"] ?? row["id"]) else { return nil }
            let name = Trust.text(row["labelName"] ?? row["name"], limit: 60)
            guard !name.isEmpty else { return nil }
            return MailLabel(id: id, name: name, color: Trust.text(row["color"] ?? row["labelColor"], limit: 16))
        }
    }

    func createLabel(name: String, context: MailboxSession, store: WKWebsiteDataStore, browser: WKWebView) async throws {
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/labels")
        _ = try await browserRequest(url, csrf: token, browser: browser, method: "POST",
                                     body: ["labelName": Trust.text(name, limit: 60)])
    }

    func deleteLabel(id: String, context: MailboxSession, store: WKWebsiteDataStore, browser: WKWebView) async throws {
        guard Trust.numericID(id) != nil else { throw MailFailure.folder }
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/labels/\(id)")
        _ = try await browserRequest(url, csrf: token, browser: browser, method: "DELETE")
    }

    // MARK: - Folders

    func createFolder(name: String, parent: String?, context: MailboxSession,
                      store: WKWebsiteDataStore, browser: WKWebView) async throws {
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/folders")
        var body: [String: Any] = ["folderName": Trust.text(name, limit: 80)]
        if let parent, Trust.numericID(parent) != nil { body["parentFolderId"] = parent }
        _ = try await browserRequest(url, csrf: token, browser: browser, method: "POST", body: body)
    }

    func renameFolder(id: String, name: String, context: MailboxSession,
                      store: WKWebsiteDataStore, browser: WKWebView) async throws {
        guard Trust.numericID(id) != nil else { throw MailFailure.folder }
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/folders/\(id)")
        _ = try await browserRequest(url, csrf: token, browser: browser, method: "PUT",
                                     body: ["folderName": Trust.text(name, limit: 80)])
    }

    func deleteFolder(id: String, context: MailboxSession,
                      store: WKWebsiteDataStore, browser: WKWebView) async throws {
        guard Trust.numericID(id) != nil, context.folders.contains(where: { $0.id == id }),
              context.folders.first(where: { $0.id == id })?.systemName == nil else { throw MailFailure.folder }
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/folders/\(id)")
        _ = try await browserRequest(url, csrf: token, browser: browser, method: "DELETE")
    }

    /// Empty the server Trash/Spam folder. No local message is dropped until
    /// the server confirms the request.
    func emptyFolder(id: String, context: MailboxSession,
                     store: WKWebsiteDataStore, browser: WKWebView) async throws {
        guard Trust.numericID(id) != nil, context.folders.contains(where: { $0.id == id }) else { throw MailFailure.folder }
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/folders/\(id)/messages")
            .appending(queryItems: [URLQueryItem(name: "expunge", value: "true")])
        _ = try await browserRequest(url, csrf: token, browser: browser, method: "DELETE")
    }

    /// Permanent delete from Trash/Spam. The caller confirms with the user first.
    func deleteForever(_ messages: [MailMessage], context: MailboxSession,
                       store: WKWebsiteDataStore, browser: WKWebView) async throws {
        guard !messages.isEmpty, messages.allSatisfy({ $0.accountID == context.accountID && $0.remoteID == context.remoteID }),
              messages.allSatisfy({ Trust.numericID($0.id) != nil && Trust.numericID($0.folderID) != nil }) else {
            throw MailFailure.response
        }
        let token = try await csrf(store, origin: context.origin)
        for message in messages {
            let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/folders/\(message.folderID)/messages/\(message.id)")
                .appending(queryItems: [URLQueryItem(name: "expunge", value: "true")])
            _ = try await browserRequest(url, csrf: token, browser: browser, method: "DELETE")
        }
    }

    // MARK: - Account settings

    func blockSender(_ address: String, context: MailboxSession,
                     store: WKWebsiteDataStore, browser: WKWebView) async throws {
        guard MailAddresses.extract(address).first?.lowercased() == address.lowercased() else { throw MailFailure.response }
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/settings/blocklist")
        _ = try await browserRequest(url, csrf: token, browser: browser, method: "POST", body: ["email": address])
    }

    func unblockSender(_ address: String, context: MailboxSession,
                       store: WKWebsiteDataStore, browser: WKWebView) async throws {
        guard MailAddresses.extract(address).first?.lowercased() == address.lowercased() else { throw MailFailure.response }
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/settings/blocklist")
            .appending(queryItems: [URLQueryItem(name: "email", value: address)])
        _ = try await browserRequest(url, csrf: token, browser: browser, method: "DELETE")
    }

    func vacation(context: MailboxSession, store: WKWebsiteDataStore, browser: WKWebView) async throws -> [String: Any] {
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/settings/vacation")
        guard let body = try await browserRequest(url, csrf: token, browser: browser) as? [String: Any] else {
            throw MailFailure.response
        }
        return body
    }

    func setVacation(enabled: Bool, message: String, context: MailboxSession,
                     store: WKWebsiteDataStore, browser: WKWebView) async throws {
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/settings/vacation")
        _ = try await browserRequest(url, csrf: token, browser: browser, method: "PUT",
                                     body: ["vacationEnabled": enabled, "message": Trust.text(message, limit: 4000)])
    }

    // MARK: - Contacts (recipient suggestions)

    func contacts(_ search: String, context: MailboxSession,
                  store: WKWebsiteDataStore, browser: WKWebView) async throws -> [String] {
        let value = Trust.text(search, limit: 80)
        guard !value.isEmpty else { return [] }
        let token = try await csrf(store, origin: context.origin)
        let url = context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/contacts")
            .appending(queryItems: [URLQueryItem(name: "search", value: value), URLQueryItem(name: "limit", value: "8")])
        guard let rows = try await browserRequest(url, csrf: token, browser: browser) as? [[String: Any]] else { return [] }
        return rows.flatMap { row in
            MailAddresses.extract(Trust.text(row["email"] ?? row["primaryEmail"], limit: 320))
        }
    }
}
