import Foundation
import WebKit

@MainActor extension MailAPI {
    func discover(account:MailAccount,store:WKWebsiteDataStore,origin:URL,browser:WKWebView) async throws -> MailboxSession {
        let token=try await csrf(store,origin:origin),cookies=await store.httpCookieStore.allCookies()
        let rows=try await get(origin.appendingPathComponent("api/accounts"),cookies:cookies,csrf:token,browser:browser)
        let remote=rows.first{($0["primaryEmailAddress"] as? String)?.lowercased() == account.name.lowercased()} ?? rows.first{($0["isDefaultAccount"] as? Bool)==true} ?? rows.first
        guard let id=Trust.numericID(remote?["accountId"]),let email=MailAddresses.extract(Trust.text(remote?["primaryEmailAddress"],limit:320)).first else{throw MailFailure.response}
        let folderRows=try await get(origin.appendingPathComponent("api/accounts/\(id)/folders"),cookies:cookies,csrf:token,browser:browser)
        let folders=folderRows.compactMap(MailFolder.parse)
        guard folders.contains(where:{$0.systemName == "Inbox"}) else{throw MailFailure.folder}
        // Only addresses supplied by this authenticated account may appear as From.
        let sendDetails=remote?["sendMailDetails"] as? [[String:Any]] ?? []
        let aliases=sendDetails.flatMap{MailAddresses.extract(Trust.text($0["fromAddress"],limit:320))}
        let addresses = Array(Set([email] + aliases)).sorted()
        let identities = SenderIdentityDiscovery.parse(primary: email, accountName: remote?["displayName"], rows: sendDetails, allowedAddresses: addresses)
        return .init(accountID:account.id,remoteID:id,email:email,origin:origin,folders:folders,addresses:addresses,senderIdentities:identities)
    }
    func messages(context:MailboxSession,folder:MailFolder,store:WKWebsiteDataStore,browser:WKWebView,start:Int = 1,filter:Int = 0) async throws -> InboxPage {
        guard context.folders.contains(where:{$0.id == folder.id}),Trust.numericID(context.remoteID) != nil else{throw MailFailure.folder}
        var query=["folderId":folder.id,"start":String(max(1,start)),"limit":"100","sortBy":"date","sortorder":"false","status":filter == 1 ? "unread" : "all","includeto":"true"]
        if filter == 2 {query["attachedMails"]="true"}
        if filter == 3 {query["flaggedMails"]="true"}
        if filter == 4 {query["includearchive"]="true"}
        let rows=try await listRequest(context,path:"messages/view",query:query,store:store,browser:browser)
        let messages=rows.compactMap{MailMessage.parse($0,accountID:context.accountID,remoteID:context.remoteID,folderID:folder.id,origin:context.origin)}
        return .init(messages:messages,remoteID:context.remoteID,folderID:folder.id,next:start+rows.count,more:rows.count==100,email:context.email,mailbox:context)
    }
    func listRequest(_ context:MailboxSession,path:String,query:[String:String],store:WKWebsiteDataStore,browser:WKWebView) async throws -> [[String:Any]] {
        // ── NEW: OAuth REST API path ───────────────────────────────────────────
        // Accounts listed in zohoOAuthAccounts use native URLSession + Bearer token.
        if let credential = zohoOAuthAccounts.first(where: { $0.email == context.email }) {
            return try await ZohoOAuthManager.shared.listRequest(path: path, query: query, credential: credential)
        }
        // ── OLD: WebKit session path (original implementation) ─────────────────
        // All accounts NOT listed in zohoOAuthAccounts continue through here.
        guard Trust.numericID(context.remoteID) != nil else{throw MailFailure.response}
        let token=try await csrf(store,origin:context.origin)
        let url=context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/\(path)").appending(queryItems:query.sorted{$0.key<$1.key}.map{URLQueryItem(name:$0.key,value:$0.value)})
        guard let rows=try await browserRequest(url,csrf:token,browser:browser) as? [[String:Any]] else{throw MailFailure.response};return rows
    }
    func oauthDetail(_ message: MailMessage, credential: ZohoOAuthCredential) async throws -> MailDetail {
        let prefix = "folders/\(message.folderID)/messages/\(message.id)/"
        let metadata = try await ZohoOAuthManager.shared.objectRequest(path: prefix + "details", credential: credential)
        guard Trust.numericID(metadata["messageId"]) == message.id else { throw MailFailure.response }
        let content = try await ZohoOAuthManager.shared.objectRequest(path: prefix + "content", credential: credential)
        guard Trust.numericID(content["messageId"]) == message.id,
              let fetchedHTML = content["content"] as? String,
              fetchedHTML.utf8.count <= MailBodyPolicy.maximumBytes else { throw MailFailure.response }
        let html = fetchedHTML
        var files: [String: Any] = [:]
        if MailInlineImageReference.shouldLoadAttachmentInfo(message: message, metadata: metadata, html: html) || html.range(of: "<img", options: .caseInsensitive) != nil {
            if let info = try? await ZohoOAuthManager.shared.objectRequest(path: prefix + "attachmentinfo", query: ["includeInline": "true"], credential: credential) {
                files = info
            }
        }
        let headerObj = try await ZohoOAuthManager.shared.objectRequest(path: prefix + "header", query: ["raw": "false"], credential: credential)
        let headers = (headerObj["headerContent"] as? [String: Any]) ?? [:]
        let headerReply = MailAddresses.headerAddress("Reply-To", in: headers)
        let metadataReply = MailAddresses.headerAddress("replyTo", in: metadata)
        let from = MailAddresses.headerAddress("From", in: headers)
        let to = MailAddresses.headerAddress("To", in: headers)
        let cc = MailAddresses.headerAddress("Cc", in: headers)
        var detail = MailDetail(message: message,
                                from: from.isEmpty ? Trust.text(metadata["fromAddress"] ?? metadata["sender"], limit: 1000) : from,
                                to: to.isEmpty ? Trust.text(metadata["toAddress"], limit: 4000) : to,
                                cc: cc.isEmpty ? Trust.text(metadata["ccAddress"], limit: 4000) : cc,
                                replyTo: headerReply.isEmpty ? metadataReply : headerReply,
                                html: html,
                                attachments: (files["attachments"] as? [[String: Any]] ?? []).compactMap(MailAttachment.parse),
                                inline: (files["inline"] as? [[String: Any]] ?? []).compactMap(MailAttachment.parse))
        func field(_ name: String) -> String? {
            let raw = headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            let value = (raw as? String) ?? (raw as? [String])?.joined(separator: " ")
            return MailAddresses.safeHeaderValue(value)
        }
        detail.rfcMessageID = field("Message-ID"); detail.rfcReferences = field("References"); detail.rfcInReplyTo = field("In-Reply-To")
        detail.sourceIP = MailSourceIP.parse(headers)
        detail.replyHeadersChecked = true
        return detail
    }
    func oauthThread(_ message: MailMessage, context: MailboxSession, credential: ZohoOAuthCredential) async throws -> [MailMessage] {
        guard let id = message.threadID, Trust.numericID(id) != nil else { return [message] }
        var result: [MailMessage] = [], start = 1
        for _ in 0..<20 {
            let rows = try await ZohoOAuthManager.shared.listRequest(
                path: "messages/view",
                query: ["threadId": id, "start": String(start), "limit": "100", "sortBy": "date", "sortorder": "false", "includesent": "true", "includearchive": "true", "includeto": "true"],
                credential: credential
            )
            let messages = rows.compactMap { row -> MailMessage? in
                guard let folder = Trust.numericID(row["folderId"]),
                      let parsed = MailMessage.parse(row, accountID: message.accountID, remoteID: message.remoteID, folderID: folder, origin: message.origin),
                      parsed.threadID == id else { return nil }
                return parsed
            }
            result.append(contentsOf: messages)
            if rows.count < 100 { return result }
            start += rows.count
        }
        return result
    }
    func search(context:MailboxSession,query:String,store:WKWebsiteDataStore,browser:WKWebView,start:Int = 1) async throws -> InboxPage {
        let value=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.count<=1000,!value.contains("\n"),!value.contains("\r") else{throw MailFailure.response}
        let key=value.contains(":") ? value : "entire:\(value)"
        let rows=try await listRequest(context,path:"messages/search",query:["searchKey":key,"receivedTime":String(Int(Date().timeIntervalSince1970*1000)),"start":String(start),"limit":"100","includeto":"true"],store:store,browser:browser)
        let messages=rows.compactMap{row->MailMessage? in
            guard let folder=Trust.numericID(row["folderId"]) else{return nil}
            return MailMessage.parse(row,accountID:context.accountID,remoteID:context.remoteID,folderID:folder,origin:context.origin)
        }
        return .init(messages:messages,remoteID:context.remoteID,folderID:"0",next:start+rows.count,more:rows.count==100,email:context.email,mailbox:context)
    }
    func thread(_ message:MailMessage,context:MailboxSession,store:WKWebsiteDataStore,browser:WKWebView,start:Int = 1) async throws -> InboxPage {
        guard context.accountID==message.accountID,context.remoteID==message.remoteID,context.origin==message.origin,let id=message.threadID,Trust.numericID(id) != nil else{throw MailFailure.response}
        let rows=try await listRequest(context,path:"messages/view",query:["threadId":id,"start":String(start),"limit":"100","sortBy":"date","sortorder":"false","includesent":"true","includearchive":"true","includeto":"true"],store:store,browser:browser)
        let messages=rows.compactMap{row->MailMessage? in
            guard let folder=Trust.numericID(row["folderId"]),let parsed=MailMessage.parse(row,accountID:message.accountID,remoteID:message.remoteID,folderID:folder,origin:message.origin),parsed.threadID==id else{return nil}
            return parsed
        }
        return .init(messages:messages,remoteID:message.remoteID,folderID:message.folderID,next:start+rows.count,more:rows.count==100,email:context.email,mailbox:context)
    }
    func perform(_ action:MailAction,messages:[MailMessage],context:MailboxSession,store:WKWebsiteDataStore,browser:WKWebView) async throws {
        guard messages.allSatisfy({$0.accountID==context.accountID && $0.remoteID==context.remoteID && $0.origin==context.origin}) else{throw MailFailure.auth}
        if action == .trash, let trash = context.folders.first(where: { $0.systemName == "Trash" }),
           messages.allSatisfy({ $0.folderID == trash.id }) {
            try await deleteForever(messages, context: context, store: store, browser: browser)
            return
        }
        let resolved:MailAction
        if action == .trash {
            guard let trash=context.folders.first(where:{$0.systemName=="Trash"}),messages.allSatisfy({$0.folderID != trash.id}) else{throw MailFailure.folder}
            resolved = .move(trash.id)
        } else {resolved=action}
        if case .move(let id)=resolved {guard context.folders.contains(where:{$0.id==id}) else{throw MailFailure.folder}}
        let payload=try resolved.payload(messages)
        if let credential = zohoOAuthAccounts.first(where: { $0.email == context.email }) {
            try await ZohoOAuthManager.shared.updateMessage(payload: payload, credential: credential)
            return
        }
        let token=try await csrf(store,origin:context.origin)
        _=try await browserRequest(context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/updatemessage"),csrf:token,browser:browser,method:"PUT",body:payload)
    }
    func saveDraft(_ body:[String:Any],context:MailboxSession,store:WKWebsiteDataStore,browser:WKWebView) async throws -> String {
        guard body["mode"] as? String == "draft",context.addresses.contains(body["fromAddress"] as? String ?? "") else{throw MailFailure.response}
        let token=try await csrf(store,origin:context.origin)
        let result=try await browserRequest(context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/messages"),csrf:token,browser:browser,method:"POST",body:body)
        let row=(result as? [String:Any]) ?? (result as? [[String:Any]])?.first
        guard let id=Trust.numericID(row?["messageId"]) else{throw MailFailure.response};return id
    }
    func headers(_ message:MailMessage,store:WKWebsiteDataStore,browser:WKWebView) async throws -> [String:String] {
        let fields = try await headerFields(message, store: store, browser: browser)
        var value:[String:String]=[:]
        for (key,content) in fields {value[key.lowercased()]=(content as? [String])?.joined(separator:" ") ?? (content as? String ?? "")}
        return value
    }
    func sourceIPHeaders(_ message:MailMessage,store:WKWebsiteDataStore,browser:WKWebView) async throws -> MailSourceIP {
        MailSourceIP.parse(try await headerFields(message, store: store, browser: browser))
    }
    private func headerFields(_ message:MailMessage,store:WKWebsiteDataStore,browser:WKWebView) async throws -> [String:Any] {
        let token=try await csrf(store,origin:message.origin)
        guard let result=try await browserRequest(messageURL(message,suffix:"header").appending(queryItems:[.init(name:"raw",value:"false")]),csrf:token,browser:browser) as? [String:Any],Trust.numericID(result["messageId"])==message.id,let fields=result["headerContent"] as? [String:Any] else{throw MailFailure.response}
        return fields
    }
    func removeDraftCopy(_ id:String,context:MailboxSession,store:WKWebsiteDataStore,browser:WKWebView) async throws {
        guard let draft=context.folders.first(where:{$0.systemName=="Drafts"}),Trust.numericID(id) != nil else{throw MailFailure.folder}
        let token=try await csrf(store,origin:context.origin)
        let url=context.origin.appendingPathComponent("api/accounts/\(context.remoteID)/folders/\(draft.id)/messages/\(id)").appending(queryItems:[.init(name:"expunge",value:"false")])
        _=try await browserRequest(url,csrf:token,browser:browser,method:"DELETE")
    }
    func signatures(context:MailboxSession,store:WKWebsiteDataStore,browser:WKWebView) async throws -> [MailSignature] {
        let token=try await csrf(store,origin:context.origin)
        guard let rows=try await browserRequest(context.origin.appendingPathComponent("api/accounts/signature"),csrf:token,browser:browser) as? [[String:Any]] else{throw MailFailure.response}
        // Resolve relative signature assets before normalization can discard them.
        // Only the active, same-origin mail page supplies a document base.
        let page = browser.url
        let base = page.flatMap { url -> URL? in
            guard url.scheme == "https", url.host == context.origin.host,
                  (url.port ?? 443) == (context.origin.port ?? 443) else { return nil }
            return url
        } ?? context.origin
        return rows.compactMap { row in
            guard let id = Trust.numericID(row["id"]), let raw = row["content"] as? String,
                  let html = SignatureHTML.sanitize(raw, baseURL: base) else { return nil }
            return MailSignature(id: id, name: Trust.text(row["name"], limit: 120), html: html)
        }
    }
}
struct MailSignature:Sendable {let id:String,name:String,html:String}
