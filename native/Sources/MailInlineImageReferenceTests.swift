import Foundation
import WebKit

/// Synthetic references only. Never resolve the web-session URL or consult an account.
@MainActor func runMailInlineImageReferenceTests(_ require: (Bool, String) -> Void) async {
    let cid = "image001.jpg@example.test"
    let web = "https://us4-zmud.zoho.com/zm/ImageDisplay?na=100&nmsgId=200&f=fixture.jpg&mode=inline&cid=\(cid)&"
    let file = MailAttachment(id: "701", name: "fixture.jpg", size: 68, cid: " <\(cid)> ")
    let inline = [file]
    let accepted: [(String, String, String)] = [
        ("cid:\(cid)", cid, "plain CID"),
        ("CID:\(cid)", cid, "scheme case is insensitive"),
        ("cid:image001.jpg%40example.test", cid, "CID percent decoding once"),
        ("cid:%3Cimage001.jpg%40example.test%3E", cid, "encoded CID angle delimiters"),
        ("cid: <\(cid)> ", cid, "CID whitespace and angle normalization"),
        (web, cid, "synthetic Zoho shard ImageDisplay"),
        ("https://mail.zoho.com/zm/ImageDisplay?mode=inline&cid=\(cid)", cid, "ordinary Zoho mail host"),
        ("//us4-zmud.zoho.com/zm/ImageDisplay?mode=inline&cid=\(cid)", cid, "protocol relative trusted host"),
        ("/zm/ImageDisplay?mode=inline&cid=\(cid)", cid, "root relative trusted image path"),
        ("/zm/imagedisplay?mode=inline&cid=\(cid)", cid, "ImageDisplay path case contract"),
        ("/mail/ImageDisplay?mode=inline&cid=\(cid)", cid, "mail path used by real provider message"),
        ("https://mail.zoho.com/mail/ImageDisplay?mode=inline&cid=\(cid)", cid, "absolute mail path on trusted host"),
        ("https://us4-zmud.zoho.com/mail/ImageDisplay?mode=inline&cid=\(cid)", cid, "mail path on trusted shard"),
        ("//mail.zoho.com/mail/ImageDisplay?mode=inline&cid=\(cid)", cid, "protocol relative mail path"),
        ("/zm/ImageDisplay?mode=inline&cid=%3Cimage001.jpg%40example.test%3E", cid, "query is decoded exactly once"),
        ("cid:a+b@example.test", "a+b@example.test", "CID plus is literal"),
        ("/zm/ImageDisplay?mode=inline&cid=a+b%40example.test", "a+b@example.test", "query plus is not form space"),
        ("cid:literal%2540example.test", "literal%40example.test", "CID does not double decode"),
        ("/zm/ImageDisplay?mode=inline&cid=literal%2540example.test", "literal%40example.test", "query does not double decode")
    ]
    for (raw, expected, label) in accepted {
        require(MailInlineImageReference.cid(from: raw) == expected, "inline reference: \(label)")
    }
    for region in Region.all {
        let source = "https://mail.\(region.domain)/zm/ImageDisplay?mode=inline&cid=\(cid)"
        require(MailInlineImageReference.cid(from: source) == cid, "inline reference regional domain \(region.id)")
    }
    let rejected = [
        "", "cid:", "cid:<>" , "cid:a%0Db", "cid:a%0Ab", "cid:a%00b", "cid:a/b",
        "cid:a%2Fb", "cid:" + String(repeating: "x", count: 501),
        "https://example.test/zm/ImageDisplay?mode=inline&cid=\(cid)",
        "https://mail.zoho.com.example.test/zm/ImageDisplay?mode=inline&cid=\(cid)",
        "https://notmail.zoho.com/zm/ImageDisplay?mode=inline&cid=\(cid)",
        "https://us4-zmud.zoho.com.example.test/zm/ImageDisplay?mode=inline&cid=\(cid)",
        "https://user@mail.zoho.com/zm/ImageDisplay?mode=inline&cid=\(cid)",
        "https://mail.zoho.com:443/zm/ImageDisplay?mode=inline&cid=\(cid)",
        "http://mail.zoho.com/zm/ImageDisplay?mode=inline&cid=\(cid)",
        "file:///zm/ImageDisplay?mode=inline&cid=\(cid)", "javascript:cid:\(cid)",
        "/other/ImageDisplay?mode=inline&cid=\(cid)",
        "/mail/ImageDisplay/extra?mode=inline&cid=\(cid)",
        "/mail/ImageDisplay?mode=external&cid=\(cid)",
        "/mail/ImageDisplay?mode=inline&cid=\(cid)&cid=other",
        "https://mail.zoho.com.example.test/mail/ImageDisplay?mode=inline&cid=\(cid)",
        "https://untrusted.example.test/mail/ImageDisplay?mode=inline&cid=\(cid)",
        "/zm/ImageDisplay/extra?mode=inline&cid=\(cid)",
        "/zm/ImageDisplay?cid=\(cid)", "/zm/ImageDisplay?mode=external&cid=\(cid)",
        "/zm/ImageDisplay?mode=inline&cid=", "/zm/ImageDisplay?mode=inline&cid=\(cid)&cid=\(cid)",
        "/zm/ImageDisplay?mode=inline&cid=\(cid)&cid=other",
        "/zm/ImageDisplay?mode=inline&mode=external&cid=\(cid)",
        "/zm/ImageDisplay?mode=inline&cid=a%0Db", "/zm/ImageDisplay?mode=inline&cid=a%0Ab",
        "/zm/ImageDisplay?mode=inline&cid=a%00b", "/zm/ImageDisplay?mode=inline&cid=a%2Fb"
    ]
    for (index, raw) in rejected.enumerated() {
        require(MailInlineImageReference.cid(from: raw) == nil, "inline reference rejects malformed/untrusted fixture \(index)")
    }
    require(MailInlineImageReference.cid(from: "cid:" + String(repeating: "x", count: 500))?.count == 500,
            "inline reference accepts exact 500-character normalized CID boundary")
    require(MailInlineImageReference.attachment(for: web, inline: inline)?.id == file.id,
            "web session CID maps only to supplied message attachment membership")
    require(MailInlineImageReference.attachment(for: "cid:\(cid)", inline: inline)?.id == file.id,
            "attachment CID trim whitespace and angle brackets")
    require(MailInlineImageReference.attachment(for: "cid:IMAGE001.jpg@example.test", inline: inline) == nil,
            "CID identity remains case sensitive")
    require(MailInlineImageReference.attachment(for: "cid:fixture.jpg", inline: inline) == nil,
            "attachment filename never substitutes for CID")
    require(MailInlineImageReference.attachment(for: "cid:forged@example.test", inline: inline) == nil,
            "forged CID requires actual attachment membership")
    require(MailInlineImageReference.attachment(for: web, inline: []) == nil,
            "query account and message IDs grant no attachment membership")
    let duplicate = MailAttachment(id: "702", name: "other.png", size: 68, cid: cid)
    require(MailInlineImageReference.attachment(for: web, inline: [file, duplicate]) == nil,
            "normalized duplicate CID is ambiguous, not first-match wins")
    let encodedIdentity = MailAttachment(id: "703", name: "literal.png", size: 68, cid: "literal%40example.test")
    require(MailInlineImageReference.attachment(for: "cid:literal%2540example.test", inline: [encodedIdentity])?.id == "703",
            "membership does not decode normalized attachment CID again")

    let escapedWeb = web.replacingOccurrences(of: "&", with: "&amp;")
    let validHTML = "<div><img src='\(escapedWeb)' width='37' height='19' alt='fixture'></div>"
    let recognized = [
        validHTML, "<IMG SRC='cid:\(cid)'>", "<img src=cid:\(cid)>",
        "<img src='/zm/ImageDisplay?mode=inline&amp;cid=\(cid)'>",
        "<img data-src='cid:\(cid)'>", "<img data-cid='\(cid)'>",
        "<img src='' original-src='cid:\(cid)'>",
        "<img style=\"background-image: url('cid:\(cid)')\">",
        "<img style=\"width:100px;background: url('https://us4-zmud.zoho.com/zm/ImageDisplay?mode=inline&amp;cid=\(cid)')\">"
    ]
    for (index, html) in recognized.enumerated() {
        require(MailInlineImageReference.requiresAttachmentInfo(html: html), "parsed actual image src requires attachment metadata \(index)")
    }
    require(MailInlineImageReference.extractURLFromStyle("width:10px;background-image:url('https://example.com/p.png')") == "https://example.com/p.png", "extractURLFromStyle extracts single-quoted url")
    require(MailInlineImageReference.extractURLFromStyle("background: url(\"cid:logo@test\")") == "cid:logo@test", "extractURLFromStyle extracts double-quoted url")
    require(MailInlineImageReference.extractURLFromStyle("color: red; width: 100px;") == nil, "extractURLFromStyle returns nil when no url")
    require(MailInlineImageReference.requiresAttachmentInfo(html: "<v:imagedata src='cid:\(cid)'/>"), "VML imagedata triggers attachment metadata")
    require(MailInlineImageReference.requiresAttachmentInfo(html: "<td background='cid:\(cid)'>"), "td background triggers attachment metadata")
    require(MailInlineImageReference.requiresAttachmentInfo(html: "<div style=\"background-image: url('cid:\(cid)')\">"), "style background-image triggers attachment metadata")
    let ignored = [
        "<script>const x = \"<img src='cid:\(cid)'>\";</script>",
        "<!-- <img src='cid:\(cid)'> -->", "<p>cid:\(cid)</p>",
        "<a href='cid:\(cid)'>link</a>",
        "<div src='cid:\(cid)'></div>", "<img src='https://example.test/fixture.png'>",
        "<img src='/zm/ImageDisplay?mode=external&amp;cid=\(cid)'>",
        "<img src='/zm/ImageDisplay?mode=inline&amp;cid=\(cid)&amp;cid=other'>"
    ]
    for (index, html) in ignored.enumerated() {
        require(!MailInlineImageReference.requiresAttachmentInfo(html: html), "non-image/invalid source does not fetch metadata \(index)")
    }
    func message(_ attachment: Bool) -> MailMessage {
        MailMessage(accountID: "inline-fixture", remoteID: "100", folderID: "500", id: "200",
                    origin: URL(string: "https://mail.zoho.com")!, subject: "Inline fixture", sender: "fixture@example.test",
                    preview: "", date: Date(timeIntervalSince1970: 0), attachment: attachment, unread: false)
    }
    require(MailInlineImageReference.shouldLoadAttachmentInfo(message: message(true), metadata: [:], html: "<p>none</p>"),
            "attachment flag independently requests attachment info")
    for flag in [true, "true", "1", 1] as [Any] {
        require(MailInlineImageReference.shouldLoadAttachmentInfo(message: message(false), metadata: ["hasInline": flag], html: "<p>none</p>"),
                "truthy hasInline metadata requests attachment info: \(flag)")
    }
    for flag in [false, "false", "0", 0] as [Any] {
        require(!MailInlineImageReference.shouldLoadAttachmentInfo(message: message(false), metadata: ["hasInline": flag], html: "<p>none</p>"),
                "false hasInline does not fetch unneeded metadata: \(flag)")
        require(MailInlineImageReference.shouldLoadAttachmentInfo(message: message(false), metadata: ["hasInline": flag], html: validHTML),
                "actual CID-bearing image overrides false hasInline: \(flag)")
    }
    require(!MailInlineImageReference.shouldLoadAttachmentInfo(message: message(false), metadata: [:], html: "<p>none</p>"),
            "ordinary message has no attachment-info fetch")
    require(MailInlineImageReference.shouldLoadAttachmentInfo(message: message(false), metadata: ["hasinline": "true"], html: "<p>none</p>"),
            "lowercase hasinline metadata requests attachment info")
    require(MailInlineImageReference.shouldLoadAttachmentInfo(message: message(false), metadata: ["hasInlineAttachment": 1], html: "<p>none</p>"),
            "hasInlineAttachment numeric metadata requests attachment info")
    require(MailInlineImageReference.shouldLoadAttachmentInfo(message: message(false), metadata: [:], html: "<div><v:imagedata src='cid:\(cid)'/></div>"),
            "VML markup overrides absent metadata")

    // Document transformation checks for VML, td background, and style background-image
    let vmlDoc = MailHTML.document("<v:imagedata src='cid:\(cid)' width='100' height='50'/>", inline: inline, images: false)
    require(vmlDoc.contains("<img") && vmlDoc.contains("src=\"mail-inline://message/701\""), "v:imagedata converted to img with mail-inline source")

    let tdDoc = MailHTML.document("<table><tr><td background='cid:\(cid)'>Cell</td></tr></table>", inline: inline, images: false)
    require(tdDoc.contains("background=\"mail-inline://message/701\""), "td background converted to mail-inline source")

    let bgStyleDoc = MailHTML.document("<div style=\"background-image: url('cid:\(cid)'); width: 100px;\">Div</div>", inline: inline, images: false)
    require(bgStyleDoc.contains("background-image:url(mail-inline://message/701)"), "style background-image converted to mail-inline source")

    func imageSources(_ html: String) -> [String] {
        guard let parsed = MailHTML.parsed(html), let nodes = try? parsed.nodes(forXPath: "//img") else { return [] }
        return nodes.compactMap { ($0 as? XMLElement)?.attribute(forName: "src")?.stringValue }
    }
    for images in [false, true] {
        let document = MailHTML.document(validHTML, inline: inline, images: images)
        require(imageSources(document) == ["mail-inline://message/701"], "production document rewrites trusted web URL even images=\(images)")
        require(!document.contains("nmsgId="), "production document strips original web-session URL")
        require(document.contains("width=\"37\"") && document.contains("height=\"19\""), "rewrite retains typed image geometry")
        let unmatched = MailHTML.document(validHTML, inline: [], images: images)
        require(imageSources(unmatched).isEmpty, "unmatched trusted ImageDisplay never falls through to public image images=\(images)")
        require(unmatched.contains("<img") && unmatched.contains("width=\"37\""), "unmatched image retains geometry placeholder")
    }
    let foreign = "https://example.test/zm/ImageDisplay?mode=inline&cid=\(cid)"
    require(imageSources(MailHTML.document("<img src='\(MailHTML.escape(foreign))'>", inline: inline, images: true)) == [foreign],
            "foreign ordinary HTTPS image remains ordinary remote, never rewritten")
    require(imageSources(MailHTML.document("<img src='\(MailHTML.escape(foreign))'>", inline: inline, images: false)).isEmpty,
            "ordinary HTTPS image still obeys images flag")
    let invalidDocuments = [
        "https://mail.zoho.com.example.test/zm/ImageDisplay?mode=inline&cid=\(cid)",
        "/zm/ImageDisplay?mode=inline&cid=\(cid)&cid=other",
        "/zm/ImageDisplay?mode=external&cid=\(cid)", "cid:IMAGE001.jpg@example.test", "cid:forged@example.test"
    ]
    for (index, raw) in invalidDocuments.enumerated() {
        let html = "<img src='\(MailHTML.escape(raw))'>"
        require(!imageSources(MailHTML.document(html, inline: inline, images: true)).contains(where: { $0.hasPrefix("mail-inline:") }),
                "production document rejects spoof/duplicate/mode/nonmember rewrite \(index)")
    }
    require(imageSources(MailHTML.document(validHTML, inline: [file, duplicate], images: true)).isEmpty,
            "production document never rewrites or remotely loads ambiguous trusted CID")
    require(imageSources(MailHTML.document("<img src='cid:image001.jpg%40example.test'>", inline: inline, images: false)) == ["mail-inline://message/701"],
            "production document supports encoded cid URL")
    require(imageSources(MailHTML.document("<img src='' alt='fixture.jpg'>", inline: inline, images: false)) == ["mail-inline://message/701"],
            "production document matches empty src by attachment filename in alt")
    require(imageSources(MailHTML.document("<img alt='\(cid)'>", inline: inline, images: false)) == ["mail-inline://message/701"],
            "production document matches empty src by CID in alt")

    // Same structural failure as the reported parcel screenshot: display alt
    // differs from the actual attachment filename, while CID membership agrees.
    let parcelCID = "A1234567-1234-4567-89AB-123456789ABC"
    let parcelFile = MailAttachment(id: "701", name: "1.png", size: 68, cid: parcelCID)
    let parcelURL = "/mail/ImageDisplay?na=999&nmsgId=888&f=1.png&mode=inline&cid=\(parcelCID)&"
    let parcelHTML = "<img src='\(MailHTML.escape(parcelURL))' alt='image.png' width='1552' style='max-width:100%'>"
    require(MailInlineImageReference.requiresAttachmentInfo(html: parcelHTML), "mail ImageDisplay requests attachment manifest")
    require(MailInlineImageReference.attachment(for: parcelURL, alt: "image.png", inline: [parcelFile])?.id == "701",
            "different alt/filename resolves by authoritative CID")
    require(MailInlineImageReference.attachment(for: parcelURL, inline: []) == nil,
            "mail URL query IDs never grant attachment membership")
    let duplicateParcel = MailAttachment(id: "702", name: "other.png", size: 68, cid: parcelCID)
    require(MailInlineImageReference.attachment(for: parcelURL, inline: [parcelFile, duplicateParcel]) == nil,
            "mail path rejects ambiguous duplicate CID")
    for images in [false, true] {
        let document = MailHTML.document(parcelHTML, inline: [parcelFile], images: images)
        require(imageSources(document) == ["mail-inline://message/701"], "mail path renders locally regardless of remote preference")
        require(!document.contains("nmsgId=") && !document.contains("/mail/ImageDisplay"), "mail path strips provider query before rendering")
    }
    let parcelDetail = MailDetail(message: message(false), from: "", to: "", cc: "", replyTo: "", html: parcelHTML, attachments: [], inline: [parcelFile])
    require(parcelDetail.visibleAttachments.isEmpty, "recognized embedded image no longer appears as orphan attachment")
    let inventory = MailImageDiagnostics.inventory(parcelDetail)
    require(inventory.embedded == 1 && inventory.matched == 1 && inventory.unresolved == 0,
            "mail path diagnostic reports one matched embedded reference")
    require(MailImageDiagnostics.providerSessionSources(parcelDetail).isEmpty,
            "matched mail path never falls back to a web-session URL fetch")

    for (label, html, manifest) in [("zm", validHTML, inline), ("mail", parcelHTML, [parcelFile])] {
        let browser = InlineReferenceTestBrowser()
        defer { browser.close() }
        do {
            let document = MailHTML.document(html, inline: manifest, images: false)
            require(document.contains("img-src data: mail-inline:"), "\(label) WebKit fixture CSP excludes HTTPS image network loads")
            try await browser.load(document)
            let result = try await browser.imageResult()
            require(result["loaded"] as? Bool == true, "\(label) real WebKit decodes inline PNG to nonzero natural width")
            require(result["source"] as? String == "mail-inline://message/701", "\(label) real WebKit sees only local attachment source")
            require(browser.handler.requests == ["mail-inline://message/701"], "\(label) exactly one request for current message attachment")
            require(browser.handler.rejectedRequests == 0, "\(label) fixture serves only exact attachment membership")
        } catch {
            require(false, "\(label) isolated inline reference WebKit fixture: \(error)")
        }
    }

}

private enum InlineReferenceTestError: Error { case timeout, invalidResult }

@MainActor private final class InlineReferenceTestHandler: NSObject, WKURLSchemeHandler {
    var requests: [String] = []
    var rejectedRequests = 0
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        requests.append(url?.absoluteString ?? "missing-url")
        guard let url, url.absoluteString == "mail-inline://message/701", url.host == "message", url.path == "/701" else {
            rejectedRequests += 1
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: png.count, textEncodingName: nil))
        urlSchemeTask.didReceive(png)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor private final class InlineReferenceTestBrowser: NSObject, WKNavigationDelegate {
    let handler: InlineReferenceTestHandler
    let view: WKWebView
    private var navigation: CheckedContinuation<Void, Error>?
    private var navigationTimeout: DispatchWorkItem?
    override init() {
        let transport = InlineReferenceTestHandler()
        handler = transport
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(transport, forURLScheme: "mail-inline")
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }
    func close() {
        view.stopLoading()
        view.navigationDelegate = nil
        finish(.failure(InlineReferenceTestError.timeout))
    }
    private func finish(_ result: Result<Void, Error>) {
        navigationTimeout?.cancel()
        navigationTimeout = nil
        let pending = navigation
        navigation = nil
        pending?.resume(with: result)
    }
    func load(_ document: String) async throws {
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            navigation = pending
            let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(InlineReferenceTestError.timeout)) }
            navigationTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            view.loadHTMLString(document, baseURL: nil)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(InlineReferenceTestError.invalidResult)) }
    func imageResult() async throws -> [String: Any] {
        let value: Any = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            var pending: CheckedContinuation<Any, Error>? = continuation
            let timeout = DispatchWorkItem {
                let continuation = pending
                pending = nil
                continuation?.resume(throwing: InlineReferenceTestError.timeout)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            view.callAsyncJavaScript("""
                const deadline = Date.now() + 2500;
                while (Date.now() < deadline) {
                    const image = document.querySelector('img');
                    if (image && image.complete && image.naturalWidth > 0)
                        return { loaded: true, source: image.getAttribute('src') };
                    await new Promise(resolve => setTimeout(resolve, 25));
                }
                return { loaded: false, source: document.querySelector('img')?.getAttribute('src') || '' };
                """, arguments: [:], in: nil, in: .defaultClient) { result in
                    guard let continuation = pending else { return }
                    pending = nil
                    timeout.cancel()
                    continuation.resume(with: result)
                }
        }
        guard let result = value as? [String: Any] else { throw InlineReferenceTestError.invalidResult }
        return result
    }
}
