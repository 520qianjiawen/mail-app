import Foundation
import WebKit

enum MailOfficialFailure: Error {
    case uploadResponse, imageReference, acknowledgement
    var label: String {
        switch self {
        case .uploadResponse: return "Zoho 上传回执不完整，邮件未发送，草稿已保留"
        case .imageReference: return "Zoho 正文图片引用不完整，邮件未发送，草稿已保留"
        case .acknowledgement: return "Zoho 未返回完整发送回执，请核对已发送邮件，勿直接重复发送"
        }
    }
}

@MainActor extension MailAPI {
    func officialDomains(context: MailboxSession, store: WKWebsiteDataStore, browser: WKWebView) async throws -> MailOfficialProtocol.Domains {
        guard Trust.mail(context.origin), browser.url?.host == context.origin.host,
              Trust.mail(browser.url) else { throw MailFailure.auth }
        let csrf = try await csrf(store, origin: context.origin)
        let result = try await browser.callAsyncJavaScript("""
            if(location.origin!==origin)throw Error('origin');
            const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),25000);
            try{const r=await fetch('/zm/AttachmentAPI?action=zmudDomains',{
                method:'GET',headers:{Accept:'application/json','X-ZCSRF-TOKEN':'zmrcsr='+csrf},
                credentials:'include',mode:'same-origin',redirect:'error',cache:'no-store',signal:controller.signal});
                const text=await r.text();if(text.length>1048576)throw Error('size');
                return {http:r.status,body:text};}finally{clearTimeout(timer)}
            """, arguments: ["origin": context.origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "csrf": csrf], in: nil, contentWorld: .defaultClient)
        guard Trust.mail(browser.url), browser.url?.host == context.origin.host,
              let response = result as? [String: Any], let code = response["http"] as? Int,
              let body = response["body"] as? String else { throw MailFailure.response }
        return try MailOfficialProtocol.Domains.parse(officialResponse(Data(body.utf8), http: code), origin: context.origin)
    }

    /// Private upload records are separate from REST cloud-draft uploads.
    func officialUpload(_ data: Data, name: String, inline: Bool, context: MailboxSession,
                        domains: MailOfficialProtocol.Domains, store: WKWebsiteDataStore, browser: WKWebView,
                        onProgress: @escaping (Int64, Int64) -> Void) async throws -> MailOfficialProtocol.UploadedFile {
        guard data.count <= MailBodyPolicy.maximumImageBytes, domains.origin == context.origin,
              Trust.numericID(context.remoteID) != nil else { throw MailFailure.response }
        if inline, MailRasterImage.mimeType(for: data) == nil { throw MailInlineImageSend.Failure.malformedImage }
        var url = domains.upload.appendingPathComponent(inline ? "uploadImage" : "uploadTemp")
        if inline { url = url.appending(queryItems: [.init(name: "accId", value: context.remoteID), .init(name: "frm", value: "c")]) }
        let multipart = try MailOfficialProtocol.multipart(fields: [:], file: (name, data))
        let request = try await officialRequest(url: url, context: context, store: store, browser: browser,
                                                contentType: multipart.contentType, uploadDomain: domains.upload.host)
        let (bytes, response): (Data, URLResponse)
        do {
            (bytes, response) = try await MailNativeUpload.perform(request, data: multipart.body) { loaded, _ in
                // Delegate byte counts include framing. Report only file bytes.
                let first = Int64(multipart.fileRange!.lowerBound)
                onProgress(min(Int64(data.count), max(0, loaded - first)), Int64(data.count))
            }
        } catch let error as URLError { throw MailUploadFailure(error) }
        guard Trust.mail(browser.url), browser.url?.host == context.origin.host,
              let http = response as? HTTPURLResponse, http.url == url else { throw MailFailure.response }
        let value = try officialResponse(bytes, http: http.statusCode)
        do { return try MailOfficialProtocol.UploadedFile.parse(value, name: name, inline: inline) }
        catch { throw MailUploadResponseFailure(diagnostic: .official(value, stage: "official-upload-fields",
            failedChecks: [inline ? "resData-fP-sN-url" : "resData-fP-sN"], requestBytes: data.count)) }
    }

    func officialSend(fields: [String: String], multipart: MailOfficialProtocol.Multipart, context: MailboxSession, store: WKWebsiteDataStore,
                      browser: WKWebView) async throws -> MailOfficialProtocol.Receipt {
        guard fields["accountId"] == context.remoteID else { throw MailFailure.auth }
        let action = fields["attachName"] == nil && fields["attEntObj"] == nil ? "sendMail" : "sendMailWithAttachment"
        let url = context.origin.appendingPathComponent("zm/MailSendAPI").appending(queryItems: [.init(name: "action", value: action)])
        let request = try await officialRequest(url: url, context: context, store: store, browser: browser,
                                                contentType: multipart.contentType)
        let (bytes, response) = try await MailNativeUpload.perform(request, data: multipart.body) { _, _ in }
        guard Trust.mail(browser.url), browser.url?.host == context.origin.host,
              let http = response as? HTTPURLResponse, http.url == url else { throw MailFailure.response }
        let value = try officialResponse(bytes, http: http.statusCode)
        do { return try MailOfficialProtocol.Receipt.parse(value) }
        catch { throw MailOfficialFailure.acknowledgement }
    }

    func officialResponse(_ bytes: Data, http: Int) throws -> Any {
        guard bytes.count <= 4 * 1024 * 1024 else { throw MailFailure.response }
        if http == 429 { throw MailFailure.rate }
        if [301, 302, 303, 307, 308, 401, 403].contains(http) { throw MailFailure.auth }
        let value = try? JSONSerialization.jsonObject(with: bytes)
        let root = value as? [String: Any] ?? [:]
        let data = root["data"] as? [String: Any] ?? [:]
        if data["reauthUrl"] != nil { throw MailFailure.auth }
        let response = root["response"] as? [String: Any] ?? [:]
        if http != 200 || response["error"] != nil || root["error"] != nil {
            var diagnostic = root
            if let error = response["error"] { diagnostic["error"] = error }
            throw MailServerRejection(http: http, body: diagnostic)
        }
        if root["status"] != nil { _ = try envelope(bytes, http: http, detailedErrors: true) }
        guard let value else { throw MailFailure.response }
        return value
    }

    private func officialRequest(url: URL, context: MailboxSession, store: WKWebsiteDataStore,
                                 browser: WKWebView, contentType: String, uploadDomain: String? = nil) async throws -> URLRequest {
        guard Trust.mail(context.origin), Trust.mail(browser.url), browser.url?.host == context.origin.host,
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { throw MailFailure.auth }
        if let uploadDomain {
            guard let region = Region.all.first(where: { $0.origin.host == context.origin.host }),
                  uploadDomain.hasSuffix("." + region.domain), url.host == uploadDomain,
                  ["/uploadImage", "/uploadTemp"].contains(url.path) else { throw MailFailure.auth }
        } else {
            guard url.host == context.origin.host, url.path == "/zm/MailSendAPI" else { throw MailFailure.auth }
        }
        let token = try await csrf(store, origin: context.origin)
        let cookies = await store.httpCookieStore.allCookies()
        guard Trust.mail(browser.url), browser.url?.host == context.origin.host else { throw MailFailure.auth }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(browser.customUserAgent ?? "Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(context.origin.appendingPathComponent("zm/").absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://" + context.origin.host!, forHTTPHeaderField: "Origin")
        request.setValue(Self.cookieHeader(cookies, for: url), forHTTPHeaderField: "Cookie")
        request.setValue("zmrcsr=" + token, forHTTPHeaderField: "X-ZCSRF-TOKEN")
        return request
    }
}
