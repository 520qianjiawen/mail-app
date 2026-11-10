import Foundation
import WebKit

enum MailFailure: Error,Equatable {
    case auth, response, folder, network, rate,rejected
    var label: String {
        switch self {
        case .auth: return "需要登录或重新验证"
        case .folder: return "未能读取所需文件夹"
        case .rate: return "请求较多，请稍后刷新"
        case .response: return "暂时无法读取邮件列表"
        case .rejected:return "服务器未接受此操作，请检查输入后重试"
        case .network: return "连接失败，请稍后刷新"
        }
    }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct InboxPage {
    let messages: [MailMessage], remoteID: String, folderID: String, next: Int, more: Bool
    var email: String = ""
    var mailbox: MailboxSession? = nil
}
@MainActor final class MailAPI {
    let session: URLSession
    init(configuration:URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    static func cookieHeader(_ cookies: [HTTPCookie], for url: URL) -> String {
        let host = url.host ?? "", path = url.path.isEmpty ? "/" : url.path
        return cookies.filter {
            let domain = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
            let domainMatches = host == domain || ($0.domain.hasPrefix(".") && host.hasSuffix("." + domain))
            let cookiePath = $0.path.isEmpty ? "/" : $0.path
            let pathMatches = path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
            return domainMatches && pathMatches && (!$0.isSecure || url.scheme == "https") && ($0.expiresDate == nil || $0.expiresDate! > Date())
        }.sorted { $0.path.count > $1.path.count }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    func get(_ url: URL, cookies: [HTTPCookie], csrf: String, browser: WKWebView? = nil) async throws -> [[String: Any]] {
        guard Trust.mail(url) else { throw MailFailure.response }
        if let browser {
            let data = try await browserRequest(url,csrf:csrf,browser:browser)
            guard let rows = data as? [[String:Any]] else { throw MailFailure.response }; return rows
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField:"User-Agent")
        request.setValue("https://\(url.host!)/zm/",forHTTPHeaderField:"Referer")
        request.setValue(Self.cookieHeader(cookies, for: url), forHTTPHeaderField: "Cookie")
        request.setValue("zmrcsr=\(csrf)", forHTTPHeaderField: "X-ZCSRF-TOKEN")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MailFailure.response }
        if http.statusCode == 429 { throw MailFailure.rate }
        if [301,302,303,307,308,401,403].contains(http.statusCode) { throw MailFailure.auth }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 4 * 1024 * 1024 { throw MailFailure.response }
            data.append(byte)
        }
        return try decode(data,http:http.statusCode,url:url)
    }
    private func decode(_ data:Data,http:Int,url:URL) throws -> [[String:Any]] {
        guard let rows = try envelope(data,http:http) as? [[String:Any]] else { throw MailFailure.response }; return rows
    }
    func envelope(_ data:Data,http:Int,detailedErrors:Bool = false) throws -> Any {
        try Task.checkCancellation()
        if http == 429 { throw MailFailure.rate }
        if [301,302,303,307,308,401,403].contains(http) { throw MailFailure.auth }
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if detailedErrors, http != 200 { throw MailServerRejection(http: http, body: [:]) }
            throw MailFailure.response
        }
        if let error = body["data"] as? [String: Any], error["reauthUrl"] != nil || String(describing: error["errorCode"] ?? "").range(of: "AUTH|TOKEN|LOGIN|CSRF|TICKET", options: .regularExpression) != nil { throw MailFailure.auth }
        guard let status=body["status"] as? [String:Any],let code=status["code"] as? Int else{
            if detailedErrors, http != 200 { throw MailServerRejection(http: http, body: body) }
            throw MailFailure.response
        }
        guard http==200,code==200 else{
            if detailedErrors { throw MailServerRejection(http: http, body: body) }
            throw MailFailure.rejected
        }
        return body["data"] ?? NSNull()
    }
    func inbox(account:MailAccount,store:WKWebsiteDataStore,origin:URL,previous:InboxPage? = nil,browser:WKWebView,filter:Int = 0) async throws -> InboxPage {
        let context:MailboxSession
        if let saved=previous?.mailbox {context=saved}
        else {context=try await discover(account:account,store:store,origin:origin,browser:browser)}
        guard let folder=context.inbox else{throw MailFailure.folder}
        return try await messages(context:context,folder:folder,store:store,browser:browser,start:previous?.next ?? 1,filter:filter)
    }
    func csrf(_ store:WKWebsiteDataStore,origin:URL) async throws -> String {
        let cookies = await store.httpCookieStore.allCookies()
        guard let cookie = cookies.first(where:{$0.name == "zmcsr" && !Self.cookieHeader([$0],for:origin.appendingPathComponent("api/accounts")).isEmpty}) else { throw MailFailure.auth }; return cookie.value
    }
    func browserRequest(_ url:URL,csrf:String,browser:WKWebView,method:String = "GET",body:[String:Any]? = nil,binary:Bool = false,upload:Data? = nil,responseLimit:Int = 4*1024*1024,detailedErrors:Bool = false,onProgress: ((Int64, Int64) -> Void)? = nil) async throws -> Any {
        guard Trust.mail(url),Trust.mail(browser.url),browser.url?.host == url.host,["GET","POST","PUT","DELETE"].contains(method),(url.path == "/api/accounts" || url.path.hasPrefix("/api/accounts/")) else { throw MailFailure.auth }
        if let upload, let onProgress {
            guard method == "POST", body == nil, !binary else { throw MailFailure.response }
            return try await nativeUpload(upload, url: url, csrf: csrf, browser: browser,
                                          detailedErrors: detailedErrors, onProgress: onProgress)
        }
        let payload = try body.map{String(data:try JSONSerialization.data(withJSONObject:$0),encoding:.utf8)!} ?? ""
        let result = try await browser.callAsyncJavaScript("""
            if (location.origin !== expectedOrigin) throw new Error('origin');
            const abort = new AbortController(), timer = setTimeout(() => abort.abort(), 25000);
            try {
                const headers = {Accept:binary?'application/octet-stream':'application/json','X-ZCSRF-TOKEN':'zmrcsr='+csrf};
                let requestBody;
                if (upload) { const text=atob(upload); requestBody=Uint8Array.from(text,c=>c.charCodeAt(0)); headers['Content-Type']='application/octet-stream'; }
                else if (payload) { requestBody=payload; headers['Content-Type']='application/json'; }
                const response=await fetch(url,{method,body:requestBody,headers,credentials:'include',mode:'same-origin',redirect:'error',cache:'no-store',signal:abort.signal});
                const reader=response.body.getReader(),chunks=[];let size=0;
                while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>limit){await reader.cancel();throw new Error('size');}chunks.push(value);}
                const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.byteLength;}
                if(binary && response.status===200){let text='';for(let i=0;i<bytes.length;i+=16384)text+=String.fromCharCode(...bytes.subarray(i,i+16384));return {http:200,base64:btoa(text)};}
                return {http:response.status,body:new TextDecoder().decode(bytes)};
            } finally {clearTimeout(timer);}
            """,arguments:["url":url.absoluteString,"csrf":csrf,"expectedOrigin":"https://\(url.host!)","method":method,"payload":payload,"binary":binary,"upload":upload?.base64EncodedString() ?? "","limit":binary ? 25*1024*1024 : min(max(responseLimit, 1), MailBodyPolicy.maximumResponseBytes)],in:nil,contentWorld:.defaultClient)
        guard let response = result as? [String:Any],let code = response["http"] as? Int else { throw MailFailure.response }
        if binary,code == 200,let encoded = response["base64"] as? String,let data = Data(base64Encoded:encoded) { return data }
        guard let json = response["body"] as? String else { throw MailFailure.response }
        return try envelope(Data(json.utf8),http:code,detailedErrors:detailedErrors)
    }
    /// Real upload progress without executing cross-frame JavaScript. Cookies
    /// come only from this account's WebKit store, scoped to this exact URL.
    func nativeUpload(_ data: Data, url: URL, csrf: String, browser: WKWebView,
                      detailedErrors: Bool, onProgress: @escaping (Int64, Int64) -> Void) async throws -> Any {
        guard Trust.mail(url), Trust.mail(browser.url), browser.url?.host == url.host,
              data.count <= MailBodyPolicy.maximumImageBytes,
              url.path.range(of: "^/api/accounts/[0-9]{1,64}/messages/attachments$", options: .regularExpression) != nil else { throw MailFailure.auth }
        let expectedOrigin = browser.url?.host
        let cookies = await browser.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard Trust.mail(browser.url), browser.url?.host == expectedOrigin else { throw MailFailure.auth }
        let request = Self.uploadRequest(url: url, cookies: cookies, csrf: csrf, userAgent: browser.customUserAgent)
        do {
            let (bytes, response) = try await MailNativeUpload.perform(request, data: data, onProgress: onProgress)
            guard let http = response as? HTTPURLResponse, http.url == url else { throw MailFailure.response }
            guard bytes.count <= 4 * 1024 * 1024 else { throw MailFailure.response }
            guard Trust.mail(browser.url), browser.url?.host == expectedOrigin else { throw MailFailure.auth }
            let result = try envelope(bytes, http: http.statusCode, detailedErrors: detailedErrors)
            onProgress(Int64(data.count), Int64(data.count))
            return result
        } catch let error as URLError { throw MailUploadFailure(error) }
    }

    static func uploadRequest(url: URL, cookies: [HTTPCookie], csrf: String, userAgent: String?) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://\(url.host!)/zm/", forHTTPHeaderField: "Referer")
        request.setValue("https://\(url.host!)", forHTTPHeaderField: "Origin")
        request.setValue(Self.cookieHeader(cookies, for: url), forHTTPHeaderField: "Cookie")
        request.setValue("zmrcsr=\(csrf)", forHTTPHeaderField: "X-ZCSRF-TOKEN")
        request.httpShouldHandleCookies = false
        return request
    }

    func messageURL(_ message:MailMessage,suffix:String) throws -> URL {
        guard Trust.mail(message.origin),[message.remoteID,message.folderID,message.id].allSatisfy({Trust.numericID($0) != nil}) else { throw MailFailure.response }
        return message.origin.appendingPathComponent("api/accounts/\(message.remoteID)/folders/\(message.folderID)/messages/\(message.id)/\(suffix)")
    }
    func detail(_ message:MailMessage,store:WKWebsiteDataStore,browser:WKWebView) async throws -> MailDetail {
        let token = try await csrf(store,origin:message.origin)
        guard let metadata = try await browserRequest(messageURL(message,suffix:"details"),csrf:token,browser:browser) as? [String:Any],Trust.numericID(metadata["messageId"]) == message.id,
              let content = try await browserRequest(messageURL(message,suffix:"content"),csrf:token,browser:browser,responseLimit:MailBodyPolicy.maximumResponseBytes) as? [String:Any],Trust.numericID(content["messageId"]) == message.id,let fetchedHTML = content["content"] as? String,
              fetchedHTML.utf8.count <= MailBodyPolicy.maximumBytes else { throw MailFailure.response }
        var html = fetchedHTML
        var recovery = "not-needed"
        if MailOriginalHTML.needsRecovery(html) {
            do {
                let url = message.origin.appendingPathComponent("api/accounts/\(message.remoteID)/messages/\(message.id)/originalmessage")
                let response = try await browserRequest(url, csrf: token, browser: browser, responseLimit: 48*1024*1024)
                if let original = response as? [String: Any],
                   (original["messageId"] == nil || Trust.numericID(original["messageId"]) == message.id),
                   let raw = original["content"] as? String {
                    if raw.utf8.count > MailOriginalHTML.limit { recovery = "original-too-large" }
                    else if let full = MailOriginalHTML.html(raw) {
                        if MailOriginalHTML.improves(full, over: html) {
                            html = full
                            recovery = MailOriginalHTML.needsRecovery(full) ? "original-partial" : "original-mime"
                        } else { recovery = "original-empty" }
                    } else { recovery = "original-unparseable" }
                } else { recovery = "original-invalid-response" }
            } catch let failure as MailFailure { recovery = "original-read-failed:" + failure.label }
              catch { recovery = "original-read-failed" }
        }
        var files:[String:Any] = [:]
        if MailInlineImageReference.shouldLoadAttachmentInfo(message: message, metadata: metadata, html: html) || html.range(of: "<img", options: .caseInsensitive) != nil {
            if let info = try? await browserRequest(messageURL(message,suffix:"attachmentinfo").appending(queryItems:[URLQueryItem(name:"includeInline",value:"true")]),csrf:token,browser:browser) as? [String:Any] {
                files = info
                if message.attachment {
                    guard let rows = info["attachments"] as? [[String:Any]], !rows.isEmpty, rows.compactMap(MailAttachment.parse).count == rows.count else { throw MailFailure.response }
                }
            } else if message.attachment {
                throw MailFailure.response
            }
        }
        // Reply-To is an RFC header and is not reliably included in /details.
        let headerURL = try messageURL(message,suffix:"header").appending(queryItems:[URLQueryItem(name:"raw",value:"false")])
        guard let response = try await browserRequest(headerURL,csrf:token,browser:browser) as? [String:Any],
              Trust.numericID(response["messageId"]) == message.id,
              let headers = response["headerContent"] as? [String:Any] else { throw MailFailure.response }
        let headerReply = MailAddresses.headerAddress("Reply-To",in:headers)
        let metadataReply = MailAddresses.headerAddress("replyTo",in:metadata)
        let from = MailAddresses.headerAddress("From",in:headers)
        let to = MailAddresses.headerAddress("To",in:headers)
        let cc = MailAddresses.headerAddress("Cc",in:headers)
        var detail=MailDetail(message:message,from:from.isEmpty ? Trust.text(metadata["fromAddress"] ?? metadata["sender"],limit:1000) : from,to:to.isEmpty ? Trust.text(metadata["toAddress"],limit:4000) : to,cc:cc.isEmpty ? Trust.text(metadata["ccAddress"],limit:4000) : cc,replyTo:headerReply.isEmpty ? metadataReply : headerReply,html:html,attachments:(files["attachments"] as? [[String:Any]] ?? []).compactMap(MailAttachment.parse),inline:(files["inline"] as? [[String:Any]] ?? []).compactMap(MailAttachment.parse))
        func field(_ name: String) -> String? {
            let raw = headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            let value = (raw as? String) ?? (raw as? [String])?.joined(separator: " ")
            return MailAddresses.safeHeaderValue(value)
        }
        detail.rfcMessageID = field("Message-ID"); detail.rfcReferences = field("References"); detail.rfcInReplyTo = field("In-Reply-To")
        detail.replyHeadersChecked=true
        detail.sourceIP = MailSourceIP.parse(headers)
        detail.imageSourceRecovery=recovery
        detail.bcc=Trust.text(metadata["bccAddress"],limit:4000);return detail
    }
    func attachment(_ file:MailAttachment,message:MailMessage,store:WKWebsiteDataStore,browser:WKWebView) async throws -> Data {
        guard Trust.numericID(file.id) != nil,file.size <= 25*1024*1024 else { throw MailFailure.response }
        let token = try await csrf(store,origin:message.origin)
        guard let data = try await browserRequest(messageURL(message,suffix:"attachments/\(file.id)"),csrf:token,browser:browser,binary:true) as? Data else { throw MailFailure.response }; return data
    }
    /// Fetches a provider-hosted inline image through the account's own logged-in
    /// session cookies. Restricted to trusted mail hosts and /zm/ image paths; binary
    /// response must decode as a supported raster format. Uses direct URLSession with
    /// the account data store cookies without navigating the background browser.
    func sessionImage(_ url:URL,origin:URL,store:WKWebsiteDataStore) async throws -> Data {
        guard let host = url.host?.lowercased(),url.scheme == "https",url.user == nil,url.password == nil,url.port == nil,
              url.path.lowercased().hasPrefix("/zm/"),Trust.mail(origin),
              Region.all.contains(where:{host == "mail.\($0.domain)" || host.hasSuffix("-zmud.\($0.domain)")}) else { throw MailFailure.auth }
        let cookies = await store.httpCookieStore.allCookies()
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://\(origin.host!)/zm/", forHTTPHeaderField: "Referer")
        request.setValue(Self.cookieHeader(cookies, for: url), forHTTPHeaderField: "Cookie")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MailFailure.response }
        if http.statusCode == 429 { throw MailFailure.rate }
        if [301,302,303,307,308,401,403].contains(http.statusCode) { throw MailFailure.auth }
        guard http.statusCode == 200 else { throw MailFailure.response }
        var data = Data()
        for try await byte in bytes {
            if data.count >= MailBodyPolicy.maximumImageBytes { throw MailFailure.response }
            data.append(byte)
        }
        guard MailRasterImage.mimeType(for: data) != nil else { throw MailFailure.response }
        return data
    }
    func send(message:MailMessage,store:WKWebsiteDataStore,browser:WKWebView,body:[String:Any],reply:Bool) async throws -> String {
        guard Trust.numericID(message.remoteID) != nil,Trust.numericID(message.id) != nil else { throw MailFailure.response }
        let token = try await csrf(store,origin:message.origin)
        let url = message.origin.appendingPathComponent("api/accounts/\(message.remoteID)/messages" + (reply ? "/\(message.id)" : ""))
        let result = try await browserRequest(url,csrf:token,browser:browser,method:"POST",body:body,detailedErrors:true)
        return try Self.sentMessageID(result)
    }
    static func sentMessageID(_ result: Any) throws -> String {
        let row: [String: Any]?
        if let object = result as? [String: Any] { row = object }
        else if let list = result as? [[String: Any]], list.count == 1 { row = list[0] }
        else { row = nil }
        guard let id = Trust.numericID(row?["messageId"]) else { throw MailOfficialFailure.acknowledgement }
        return id
    }
    func uploadInline(_ data:Data,name:String,message:MailMessage,store:WKWebsiteDataStore,browser:WKWebView,onProgress: ((Int64, Int64) -> Void)? = nil) async throws -> [String:String] {
        guard data.count <= MailBodyPolicy.maximumImageBytes, Trust.numericID(message.remoteID) != nil,
              MailRasterImage.mimeType(for: data) != nil else { throw MailInlineImageSend.Failure.malformedImage }
        let token = try await csrf(store,origin:message.origin)
        let url = message.origin.appendingPathComponent("api/accounts/\(message.remoteID)/messages/attachments")
            .appending(queryItems:[.init(name:"fileName",value:(name as NSString).lastPathComponent),.init(name:"isInline",value:"true")])
        let response = try await browserRequest(url,csrf:token,browser:browser,method:"POST",upload:data,detailedErrors:true,onProgress:onProgress)
        guard let result = response as? [String:Any],
              let storeName=result["storeName"] as? String,let path=result["attachmentPath"] as? String,
              let file=result["attachmentName"] as? String,let imageURL=result["url"] as? String else {
            throw Self.uploadShapeFailure(response, inline: true, requestBytes: data.count)
        }
        return ["storeName":storeName,"attachmentPath":path,"attachmentName":file,"url":imageURL]
    }
    func upload(_ data:Data,name:String,message:MailMessage,store:WKWebsiteDataStore,browser:WKWebView,onProgress: ((Int64, Int64) -> Void)? = nil) async throws -> [String:String] {
        guard data.count <= 25*1024*1024,Trust.numericID(message.remoteID) != nil else { throw MailFailure.response }
        let token = try await csrf(store,origin:message.origin)
        let url = message.origin.appendingPathComponent("api/accounts/\(message.remoteID)/messages/attachments").appending(queryItems:[.init(name:"fileName",value:(name as NSString).lastPathComponent),.init(name:"isInline",value:"false")])
        let response = try await browserRequest(url,csrf:token,browser:browser,method:"POST",upload:data,detailedErrors:true,onProgress:onProgress)
        guard let result = response as? [String:Any],let storeName=result["storeName"] as? String,let path=result["attachmentPath"] as? String,let file=result["attachmentName"] as? String else {
            throw Self.uploadShapeFailure(response, inline: false, requestBytes: data.count)
        }
        return ["storeName":storeName,"attachmentPath":path,"attachmentName":file]
    }

    static func uploadShapeFailure(_ response: Any, inline: Bool, requestBytes: Int) -> MailUploadResponseFailure {
        let row = response as? [String: Any]
        var checks: [String] = row == nil ? ["data-object"] : []
        if let row {
            for key in ["storeName", "attachmentPath", "attachmentName"] + (inline ? ["url"] : []) {
                if row[key] as? String == nil { checks.append(key + "-string") }
            }
        }
        return MailUploadResponseFailure(diagnostic: MailUploadDiagnostic(data: response, stage: "response-fields", failedChecks: checks, requestBytes: requestBytes))
    }

}
