import AppKit
import Foundation
import WebKit

/// Entirely local DOM fixtures: no accounts, requests, sending, or clipboard access.
@MainActor func runMailQuoteSeparatorTests(_ require: (Bool, String) -> Void) async {
    let marker = "//*[@data-mail-quote-separator]"
    func count(_ html: String, policy: Bool) -> Int {
        guard let doc = MailHTML.parsed(html) else { return -1 }
        if !policy { return (try? doc.nodes(forXPath: marker).count) ?? -1 }
        return ((try? doc.nodes(forXPath: "//*")) ?? []).compactMap { $0 as? XMLElement }
            .filter { MailQuoteSeparator.shouldDecorate($0) }.count
    }
    let cases: [(String, Int, String)] = [
        ("<p>Current</p><blockquote>Older</blockquote>", 1, "plain blockquote"),
        ("<blockquote>Older<blockquote>Oldest</blockquote></blockquote>", 2, "nested historical quotes"),
        ("<div>---- On 2026年10月23日, <b>张三</b> &lt;<a href='mailto:a@example.test'>a@example.test</a>&gt; wrote ----</div><blockquote>Older</blockquote>", 1, "Zoho Unicode inline header"),
        ("<p>On Fri, Oct 23, 2026, Ada wrote:</p><blockquote>Older</blockquote>", 1, "English header owns following quote"),
        ("<p>---- 原始邮件 ----</p><blockquote>Older</blockquote>", 1, "Chinese original header"),
        ("<div>-----Original Message-----</div><blockquote>Older</blockquote>", 1, "English original header"),
        ("<div class='gmail_quote'><div>On Fri, Ada wrote:</div><blockquote>Older<blockquote>Oldest</blockquote></blockquote></div>", 2, "Gmail wrapper owns direct pair only"),
        ("<div class='yahoo_quoted'><div>-----Original Message-----</div><blockquote>Older</blockquote></div>", 1, "Yahoo wrapper"),
        ("<div class='protonmail_quote'><p>---- 原始邮件 ----</p><blockquote>Older</blockquote></div>", 1, "Proton wrapper"),
        ("<div id='DiVrPlYfWdMsG'>Original Outlook header</div><div>Older body</div>", 1, "Outlook ID is case insensitive"),
        ("<hr><div><p>---- 原始邮件 ----</p><div>发件人：Ada</div><div>收件人：Bea</div><div>主题：Fixture</div></div><blockquote>Older</blockquote>", 0, "authored HR covers app source header group"),
        ("<div id='DIVRPLYFWDMSG'><b>From:</b> Ada<br><b>Sent:</b> Friday<br><b>To:</b> Bea<br><b>Subject:</b> fixture</div><blockquote>Older</blockquote>", 1, "Outlook structured raw wrapper owns following quote"),
        ("<div><b>From:</b> Ada<br><b>Sent:</b> Friday<br><b>To:</b> Bea<br><b>Subject:</b> fixture</div><blockquote>Older</blockquote>", 1, "structured Outlook header"),
        ("<blockquote><p>---- 原始邮件 ----</p>Older<blockquote>Oldest</blockquote></blockquote>", 2, "first child header inherits enclosing quote boundary"),
        ("<hr><!-- whitespace --> \n<br><blockquote>Older</blockquote>", 0, "author HR avoids duplicate"),
        ("<hr><p>---- 原始邮件 ----</p><blockquote>Older</blockquote>", 0, "author HR covers header and quote"),
        ("<p>From: my perspective, this is ordinary prose.</p><div>From: Ada<br>To: Bea</div>", 0, "plain From text"),
        ("<div><p>On Friday Ada wrote:</p><p>Ordinary body</p></div>", 1, "never mark flattened outer body"),
        ("<div>---- 原始邮件 ----<table><tr><td>Brand</td></tr></table></div>", 0, "signature table not header"),
        ("<div>On Friday Ada wrote:<img src='cid:logo@example.test'></div>", 0, "brand image not header"),
        ("<div class='not_gmail_quote'><p>Current message</p></div><p>Regards, Ada</p>", 0, "exact provider class tokens"),
        ("<p>We discussed -----Original Message----- yesterday.</p><div>Ordinary body</div>", 0, "embedded marker sentence")
    ]
    for (html, expected, label) in cases {
        require(count(html, policy: true) == expected, "quote policy: \(label)")
        for dark in [false, true] {
            let output = MailHTML.document(html, dark: dark)
            require(count(output, policy: false) == expected, "production quote markers dark=\(dark): \(label)")
            let inputText = MailHTML.plainText(html).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let outputText = MailHTML.plainText(output).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            require(inputText == outputText, "reader preserves authored text: \(label)")
            let beforeHR = ((try? MailHTML.parsed(html)?.nodes(forXPath: "//hr")) ?? []).count
            let afterHR = ((try? MailHTML.parsed(output)?.nodes(forXPath: "//hr")) ?? []).count
            require(beforeHR == afterHR, "reader never inserts or deletes author HR: \(label)")
        }
    }
    for index in 0..<40 {
        let html = "<div><p>Ordinary message \(index), From our team.</p><table><tr><td>Brand \(index)</td></tr></table><p>Regards</p></div>"
        require(count(MailHTML.document(html), policy: false) == 0, "plain randomized body has no separators \(index)")
    }
    let signature = "<table cellpadding='0'><tr><td>Sender Brand<img src='cid:logo@example.test' width='24' height='12'></td></tr></table>"
    let attachment = MailAttachment(id: "701", name: "logo.png", size: 68, cid: "logo@example.test")
    let retained = MailHTML.document("<p>Body</p>" + signature + "<blockquote>Older</blockquote>", inline: [attachment])
    require(count(retained, policy: false) == 1, "signature introduces no body/signature separator")
    require(retained.contains("<table") && retained.contains("Sender Brand") && retained.contains("src=\"mail-inline://message/701\""),
            "reader retains signature table, text and local CID source")
    require(count(MailHTML.document("<div data-mail-quote-separator='true'>Forged</div>"), policy: false) == 0,
            "external separator attributes are discarded")

    let browser = QuoteSeparatorTestBrowser()
    defer { browser.close() }
    for dark in [false, true] {
        do {
            try await browser.load(MailHTML.document("<p>Current</p><blockquote>Older</blockquote>", dark: dark))
            let value = try await browser.evaluate("const e=document.querySelector('[data-mail-quote-separator]'); if(!e)return {};const s=getComputedStyle(e);return {width:s.borderTopWidth,color:s.borderTopColor,style:s.borderTopStyle,padding:s.paddingTop,margin:s.marginTop,left:getComputedStyle(e).borderLeftWidth};")
            require(value["width"] as? String == "1px" && value["style"] as? String == "solid", "real reader paints 1px separator dark=\(dark)")
            require(value["color"] as? String == (dark ? "rgb(68, 71, 79)" : "rgb(223, 225, 230)"), "real reader separator palette dark=\(dark)")
            require(value["padding"] as? String == "16px" && value["margin"] as? String == "20px", "real reader separator spacing")
            require(value["left"] as? String == "2px", "existing quote left bar remains")
        } catch { require(false, "local reader quote WebKit fixture: \(error)") }
    }

    let editor = WebHTMLComposerHandle()
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = editor.webView
    window.makeKeyAndOrderFront(nil)
    defer { editor.dispose(); window.close() }
    let message = MailMessage(accountID: "fixture", remoteID: "100", folderID: "500", id: "200", origin: URL(string: "https://example.test")!, subject: "Quote fixture", sender: "ada@example.test", preview: "", date: Date(timeIntervalSince1970: 0), attachment: false, unread: false)
    let detail = MailDetail(message: message, from: "Ada <ada@example.test>", to: "Bea <bea@example.test>", cc: "", replyTo: "", html: "<p>Source original</p>", attachments: [], inline: [])
    let composeQuote = ComposeDocument.webQuote(source: detail)
    let readQuote = MailHTML.document(composeQuote)
    require(count(readQuote, policy: false) == 0, "real source header HR suppresses all duplicate reader borders")
    require(((try? MailHTML.parsed(readQuote)?.nodes(forXPath: "//hr")) ?? []).count == 1, "real source header retains exactly its authored HR")
    editor.loadReplyHTML(body: "<div><br></div>", quote: composeQuote)
    _ = await editor.flush()
    _ = await editor.replaceManagedSignatureHTML(signature, reference: "quote-fixture", identity: "fixture", beforeQuote: true, allowInsert: true)
    _ = await editor.flush()
    let shape = await editor.inspectDOM("""
    const root=document.getElementById('editor'),q=root.querySelector('[data-ml-quote]'),s=root.querySelector('[data-ml-signature]');
    const hr=q&&q.querySelector('hr');const header=q&&[...q.querySelectorAll('p')].find(e=>e.textContent.includes('原始邮件'));
    return {hr:!!hr,before:!!(hr&&header&&(hr.compareDocumentPosition(header)&Node.DOCUMENT_POSITION_FOLLOWING)),
      outside:!!(s&&q&&!q.contains(s)),sigHR:s?s.querySelectorAll('hr').length:-1,quoteText:q?q.textContent:''};
    """) as? [String: Any] ?? [:]
    require(shape["hr"] as? Bool == true && shape["before"] as? Bool == true, "actual reply quote owns HR before source header")
    require(shape["outside"] as? Bool == true && shape["sigHR"] as? Int == 0, "signature stays outside quote and has no injected HR")
    editor.focus(); editor.insertHTML("Typed reply")
    _ = await editor.flush()
    let typing = await editor.inspectDOM("""
    const root=document.getElementById('editor');const body=[...root.children].find(e=>!e.hasAttribute('data-ml-quote')&&!e.hasAttribute('data-ml-signature'));
    return {typed:!!body&&body.textContent.includes('Typed reply'),hrs:root.querySelectorAll('[data-ml-quote] hr').length};
    """) as? [String: Any] ?? [:]
    require(typing["typed"] as? Bool == true && typing["hrs"] as? Int == 1, "reply body remains typeable while quote HR is stable")
    require(!editor.html().contains("data-mail-quote-separator"), "reader-only decoration never enters outgoing HTML")
}

private enum QuoteSeparatorTestError: Error { case timeout, invalidResult }
@MainActor private final class QuoteSeparatorTestBrowser: NSObject, WKNavigationDelegate {
    private let view: WKWebView
    private var navigation: CheckedContinuation<Void, Error>?
    private var timeout: DispatchWorkItem?
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        super.init()
        view.navigationDelegate = self
    }
    func close() { view.stopLoading(); view.navigationDelegate = nil; finish(.failure(QuoteSeparatorTestError.timeout)) }
    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel(); timeout = nil
        let pending = navigation; navigation = nil; pending?.resume(with: result)
    }
    func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            navigation = pending
            let task = DispatchWorkItem { [weak self] in self?.finish(.failure(QuoteSeparatorTestError.timeout)) }
            timeout = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
            view.loadHTMLString(html, baseURL: nil)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(QuoteSeparatorTestError.invalidResult)) }
    func evaluate(_ script: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { pending in
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): pending.resume(returning: value as? [String: Any] ?? [:])
                case .failure(let error): pending.resume(throwing: error)
                }
            }
        }
    }
}
