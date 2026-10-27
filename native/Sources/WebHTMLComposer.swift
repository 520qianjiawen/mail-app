import SwiftUI
import AppKit
import WebKit

/// Proof is tied to one DOM wrapper and its exact authored HTML, never to text search.
struct HTMLSignatureDraftState: Codable, Sendable, Equatable {
    var key: String
    var identity: String
    var reference: String
    var baseline: String
}

struct WebHTMLSnapshot {
    var html: String
    var outgoingHTML: String
    var text: String
    var signature: HTMLSignatureDraftState?
}

/// Images use a separate, cookie-free ephemeral transport; never an account WK store.
private final class ComposerImageTransport: NSObject, WKURLSchemeHandler, URLSessionDataDelegate {
    private struct Transfer { let schemeTask: WKURLSchemeTask; var data = Data(); var response: URLResponse? }
    private var transfers: [Int: Transfer] = [:]
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 20
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil, task.countOfBytesReceived < 5_000_000 else { completionHandler(nil); return }
        var clean = request; clean.httpShouldHandleCookies = false
        clean.setValue(nil, forHTTPHeaderField: "Cookie"); clean.setValue(nil, forHTTPHeaderField: "Authorization"); clean.setValue(nil, forHTTPHeaderField: "Referer")
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let encoded = task.request.url?.query, let raw = encoded.removingPercentEncoding,
              let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil else { task.didFailWithError(URLError(.badURL)); return }
        var request = URLRequest(url: url); request.httpShouldHandleCookies = false
        let download = session.dataTask(with: request)
        transfers[download.taskIdentifier] = Transfer(schemeTask: task)
        tasks[ObjectIdentifier(task)] = download; download.resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.url?.scheme == "https", response.expectedContentLength <= 5_000_000,
              ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(response.mimeType ?? ""),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { completionHandler(.cancel); return }
        transfers[dataTask.taskIdentifier]?.response = response; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var transfer = transfers[dataTask.taskIdentifier] else { dataTask.cancel(); return }
        guard transfer.data.count + data.count <= 5_000_000 else { dataTask.cancel(); return }
        transfer.data.append(data); transfers[dataTask.taskIdentifier] = transfer
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        tasks.removeValue(forKey: ObjectIdentifier(transfer.schemeTask))
        guard error == nil, let response = transfer.response else { transfer.schemeTask.didFailWithError(error ?? URLError(.cannotDecodeContentData)); return }
        transfer.schemeTask.didReceive(URLResponse(url: transfer.schemeTask.request.url!, mimeType: response.mimeType, expectedContentLength: transfer.data.count, textEncodingName: nil))
        transfer.schemeTask.didReceive(transfer.data); transfer.schemeTask.didFinish()
    }
    func shutdown() { transfers.removeAll(); tasks.values.forEach { $0.cancel() }; tasks.removeAll(); session.invalidateAndCancel() }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        guard let download = tasks.removeValue(forKey: ObjectIdentifier(task)) else { return }
        transfers.removeValue(forKey: download.taskIdentifier); download.cancel()
    }
}

@MainActor private final class ComposerScriptRelay: NSObject, WKScriptMessageHandler {
    weak var target: WebHTMLComposerHandle?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(userContentController, didReceive: message) }
}

@MainActor final class WebHTMLComposerHandle: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let world = WKContentWorld.world(name: "MailLiteComposer")
    private let imageTransport = ComposerImageTransport()
    private let messageRelay = ComposerScriptRelay()
    private var readinessTimeout: Task<Void, Never>?
    private var disposed = false
    private(set) var webView: WKWebView!
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var tail: Task<Void, Never>?
    private var cached = WebHTMLSnapshot(html: "", outgoingHTML: "", text: "", signature: nil)
    var onChange: (() -> Void)?
    var onPasteError: ((String) -> Void)?
    private var editingEnabled = true
    var onSelection: ((String, CGFloat) -> Void)?
    private(set) var failure: String?
    var allowsRemoteImages = false { didSet { updateImagePolicy() } }
    var allowsSignatureImages = true { didSet { updateImagePolicy() } }
    private func updateImagePolicy() { commandScript("window.ml.images(\(allowsRemoteImages), \(allowsSignatureImages));") }
    var canonicalHTML: String { cached.html }

    override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(imageTransport, forURLScheme: "mlimage")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        messageRelay.target = self
        configuration.userContentController.add(messageRelay, contentWorld: world, name: "changed")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        let pasteView = ComposerPasteWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 300), configuration: configuration)
        pasteView.onImagePaste = { [weak self] board in self?.pasteClipboard(from: board) ?? true }
        webView = pasteView
        webView.navigationDelegate = self
        webView.appearance = NSAppearance(named: .aqua)
        webView.loadHTMLString(Self.shell, baseURL: nil)
        readinessTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, !ready else { return }; fail("HTML 编辑器加载超时")
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        readinessTimeout?.cancel(); ready = true; let waiting = readyWaiters; readyWaiters = []; waiting.forEach { $0.resume() }
    }
    private func fail(_ message: String) {
        failure = message; readinessTimeout?.cancel()
        onPasteError?(message)
        ready = true; let waiting = readyWaiters; readyWaiters = []; waiting.forEach { $0.resume() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("HTML 编辑进程已退出，请重新打开草稿") }
    func dispose() {
        guard !disposed else { return }; disposed = true
        fail("HTML 编辑器已关闭")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "changed", contentWorld: world)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = nil; webView.stopLoading(); imageTransport.shutdown()
        onChange = nil; onSelection = nil; onPasteError = nil; (webView as? ComposerPasteWebView)?.onImagePaste = nil; messageRelay.target = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .other && !ready && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "changed", message.frameInfo.isMainFrame else { return }
        if let paste = message.body as? [String: String], let token = paste["pasteRaster"] {
            let board = (webView as? ComposerPasteWebView)?.pasteboardProvider() ?? .general
            _ = pasteClipboard(from: board, capturedToken: token); return
        }
        if let selection = message.body as? [String: Any], let font = selection["font"] as? String, let size = selection["size"] as? Double {
            onSelection?(font, CGFloat(size)); return
        }
        onChange?()
    }
    private func awaitReady() async { if !ready { await withCheckedContinuation { readyWaiters.append($0) } } }
    private func evaluate(_ script: String) async -> Any? {
        await awaitReady()
        guard failure == nil, !disposed else { return nil }
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: world, completionHandler: { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                })
            }
        } catch { failure = error.localizedDescription; return nil }
    }
    @discardableResult private func queued(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let preceding = tail
        let task = Task { @MainActor in await preceding?.value; await operation() }
        tail = task; return task
    }
    private static func json(_ value: String) -> String { String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }
    private func commandScript(_ script: String) { queued { [self] in _ = await evaluate(script) } }
    /// Synchronous conversion is bounded to 32 MB input / 2048px output. Queue insertion
    /// before returning so an immediate Save/Send flush includes this paste.
    @discardableResult private func pasteClipboard(from board: NSPasteboard, capturedToken: String? = nil) -> Bool {
        guard editingEnabled, !disposed else { return true }
        guard failure == nil else { onPasteError?(failure ?? "编辑器暂未就绪，请重新打开草稿"); return true }
        guard ready else { onPasteError?("编辑器正在准备，请稍后再粘贴"); return true }
        let content: ComposerPasteImage.Content
        switch ComposerPasteImage.read(from: board) {
        case .none:
            switch ComposerPasteText.read(from: board) {
            case .none: return false
            case .invalid(let message): onPasteError?(message); return true
            case .html(let html): content = .images(html)
            }
        case .images(let html): content = .images(html)
        case .invalid(let message): content = .invalid(message)
        }
        switch content {
        case .none: return false
        case .invalid(let message): onPasteError?(message); return true
        case .images(let html):
            let token = capturedToken ?? UUID().uuidString
            // Dispatch capture now, not when the asynchronous command tail eventually runs.
            // WebKit processes this request before subsequent user-selection changes.
            if capturedToken == nil {
                webView.callAsyncJavaScript("window.ml.capturePaste(token);", arguments: ["token": token], in: nil, in: world) { _ in }
            }
            queued { [self] in
                let result = await evaluate("return window.ml.pasteImage(\(Self.json(html)), \(Self.json(token)), \(ComposerPasteImage.maximumBodyBytes - 32768));") as? String
                if result == "size" { onPasteError?("正文和图片超过本机处理容量（64 MB），请缩减引用内容后再粘贴") }
                else if result == "selection" { onPasteError?("粘贴位置已变化，请重新选择正文位置后粘贴") }
            }
            return true
        }
    }
    func html() -> String { cached.outgoingHTML }
    func plainText() -> String { cached.text }
    private static let blankBody = "<div style=\"font:12pt Verdana,Arial,sans-serif;color:#000;min-height:1.4em\"><br></div>"
    func setText(_ text: String) {
        if text.isEmpty { loadHTML(Self.blankBody); return }
        loadHTML("<div style=\"font:12pt Verdana,Arial,sans-serif;color:#000\">" + MailHTML.escape(text).replacingOccurrences(of: "\n", with: "<br>") + "</div>")
    }
    func loadHTML(_ html: String) {
        guard let clean = SignatureHTML.sanitizeBody(html) else {
            fail("正文格式无效或超过本机处理容量（64 MB），原内容仍保留"); return
        }
        cached = WebHTMLSnapshot(html: clean, outgoingHTML: clean, text: MailHTML.plainText(clean), signature: nil)
        commandScript("window.ml.load(\(Self.json(clean)), null, false);")
    }
    /// Initial reply construction supplies a structural quote boundary, not a text heuristic.
    func loadReplyHTML(body: String, quote: String) {
        guard let cleanBody = SignatureHTML.sanitizeBody(body), let cleanQuote = SignatureHTML.sanitizeBody(quote) else {
            fail("原邮件内容过大或格式无法保留，请保留原文后重试"); return
        }
        let html = cleanBody + "<div data-ml-quote=\"true\">" + cleanQuote + "</div>"
        guard html.utf8.count <= MailBodyPolicy.maximumBytes else { fail("回复原文超过本机处理容量（64 MB），原邮件仍保留"); return }
        cached = WebHTMLSnapshot(html: html, outgoingHTML: cleanBody + "<div>" + cleanQuote + "</div>", text: MailHTML.plainText(html), signature: nil)
        commandScript("window.ml.load(\(Self.json(html)), null, true);")
    }
    func restoreHTML(_ html: String, signature: HTMLSignatureDraftState?) {
        guard let outgoing = SignatureHTML.sanitizeBody(html) else { fail("草稿正文格式无效或超过本机处理容量（64 MB），原草稿仍保留"); return }
        cached = WebHTMLSnapshot(html: html, outgoingHTML: outgoing, text: MailHTML.plainText(html), signature: signature)
        let state = signature.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        commandScript("window.ml.load(\(Self.json(html)), \(state), true);")
    }
    func flush() async -> WebHTMLSnapshot {
        let task = queued { [self] in
            guard let value = await evaluate("return window.ml.snapshot();") as? [String: Any],
                  let html = value["html"] as? String, let outgoing = value["outgoingHTML"] as? String else {
                if failure == nil { failure = "HTML 编辑器未返回有效快照" }
                return
            }
            var owner: HTMLSignatureDraftState?
            if let state = value["signature"] as? [String: String], let key = state["key"], let identity = state["identity"], let reference = state["reference"], let baseline = state["baseline"] {
                owner = HTMLSignatureDraftState(key: key, identity: identity, reference: reference, baseline: baseline)
            }
            cached = WebHTMLSnapshot(html: html, outgoingHTML: outgoing, text: value["text"] as? String ?? "", signature: owner)
        }
        await task.value; return cached
    }
    func replaceManagedSignatureHTML(_ html: String?, reference: String, identity: String, beforeQuote: Bool, allowInsert: Bool, isCurrent: @escaping @MainActor () -> Bool = { true }) async -> ManagedSignatureResult {
        let clean = html.flatMap { SignatureHTML.sanitize($0) }
        guard html == nil || clean != nil else { return .protected }
        var result: ManagedSignatureResult = .protected
        let key = UUID().uuidString
        let task = queued { [self] in
            guard isCurrent() else { result = .unchanged; return }
            let value = await evaluate("return window.ml.signature(\(clean.map(Self.json) ?? "null"), \(Self.json(key)), \(Self.json(identity)), \(Self.json(reference)), \(beforeQuote), \(allowInsert));") as? String
            result = value == "changed" ? .changed : value == "unchanged" ? .unchanged : .protected
        }
        await task.value; _ = await flush(); return result
    }
    func insertHTML(_ html: String) { command("insertHTML", SignatureHTML.sanitizeBody(html) ?? "") }
    func setEditingEnabled(_ enabled: Bool) { editingEnabled = enabled; commandScript("document.getElementById('editor').contentEditable = \(enabled ? "'true'" : "'false'");") }
    func focus() { webView.window?.makeFirstResponder(webView); commandScript("window.ml.focus();") }
    func command(_ name: String, _ value: String = "") { commandScript("window.ml.command(\(Self.json(name)), \(Self.json(value)));") }
    func toggle(_ trait: NSFontTraitMask) { command(trait == .boldFontMask ? "bold" : "italic") }
    func toggleUnderline() { command("underline") }
    func toggleStrike() { command("strikeThrough") }
    func undo() { command("undo") }; func redo() { command("redo") }
    func setFontFamily(_ name: String) { command("fontName", name) }
    func setFontSize(_ size: CGFloat) { commandScript("window.ml.style('font-size', \(Self.json("\(size)pt")));") }
    private func color(_ value: NSColor) -> String { let c = value.usingColorSpace(.deviceRGB) ?? .black; return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)) }
    func setForeground(_ value: NSColor) { command("foreColor", color(value == .textColor ? .black : value)) }
    func setHighlight(_ value: NSColor?) { command("hiliteColor", value.map(color) ?? "transparent") }
    func setAlignment(_ value: NSTextAlignment) { command(value == .center ? "justifyCenter" : value == .right ? "justifyRight" : value == .justified ? "justifyFull" : "justifyLeft") }
    func insertList(numbered: Bool) { command(numbered ? "insertOrderedList" : "insertUnorderedList") }
    func indent(_ value: CGFloat) { command(value > 0 ? "indent" : "outdent") }
    func setLineSpacing(_ value: CGFloat) { commandScript("window.ml.style('line-height', \(Self.json(String(describing: value))));") }
    func insertLink(_ value: String) { guard let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }; command("createLink", value) }
    func clearFormatting() { command("removeFormat") }
    func insertTable(rows: Int, columns: Int) { insertHTML("<table style=\"border-collapse:collapse\"><tbody>" + (0..<rows).map { _ in "<tr>" + (0..<columns).map { _ in "<td style=\"border:1px solid #777;padding:6px\"><br></td>" }.joined() + "</tr>" }.joined() + "</tbody></table><p><br></p>") }
    /// Targeted browser regression hook executes in the same isolated world as production.
    func inspectDOM(_ script: String) async -> Any? { await tail?.value; return await evaluate(script) }

    private static let shell = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data: mlimage:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><style>html,body{background:white;color:#000;color-scheme:light;margin:0}#editor{min-height:260px;padding:14px;font:12pt Verdana,Arial,sans-serif;outline:none;overflow-wrap:anywhere}img{max-width:100%}</style></head><body><div id="editor" contenteditable="true" role="textbox" aria-label="邮件 HTML 正文" aria-multiline="true"></div></body></html>
    """
    private static let script = #"""
    (() => {
      const root=document.getElementById('editor'); let owner=null, revoked=false, bookmark=null, remote=false, signatureImages=true;
      const imageSource='data-ml-image-source', pasteRanges=new Map();
      function capturePaste(token){remember();if(pasteRanges.size>=16)pasteRanges.delete(pasteRanges.keys().next().value);pasteRanges.set(token,bookmark?bookmark.cloneRange():null)}
      // A real empty line, never an invisible zero-height div, precedes managed content.
      // Only inspect top-level leading body nodes; signature and quote contents are opaque.
      function ensureBody(){
        const boundary=[...root.children].find(n=>n.hasAttribute('data-ml-signature')||n.hasAttribute('data-ml-quote'))||null;
        const leading=[];for(let n=root.firstChild;n&&n!==boundary;n=n.nextSibling)leading.push(n);
        const substantive=n=>(n.textContent||'').replace(/[\s\u200b]/g,'').length>0||(n.nodeType===1&&(n.matches('img,table,hr')||n.querySelector('img,table,hr')));
        if(leading.some(substantive))return;
        let body=leading.find(n=>n.nodeType===1&&/^(DIV|P)$/.test(n.tagName));
        if(!body){body=document.createElement('div');root.insertBefore(body,leading[0]||boundary);}
        if(!body.querySelector('br'))body.append(document.createElement('br'));
        if(!body.style.font&&!body.style.fontFamily&&!body.style.fontSize)body.style.font='12pt Verdana,Arial,sans-serif';
        if(!body.style.color)body.style.color='#000';
        if(!body.style.minHeight)body.style.minHeight='1.4em';
      }
      function safe(raw, trusted=false) {
        const t=document.createElement('template'); t.innerHTML=raw;
        t.content.querySelectorAll('script,style,iframe,frame,object,embed,link,meta,base,form,input,button,textarea,select,svg,math,audio,video,source').forEach(n=>n.remove());
        t.content.querySelectorAll('*').forEach(n=>{
          [...n.attributes].forEach(a=>{
            const k=a.name.toLowerCase(),v=a.value;
            if(k.startsWith('on')||k==='srcdoc'||k==='contenteditable'||k==='id'||(k.startsWith('data-ml-')&&(!trusted||!['data-ml-signature','data-ml-quote'].includes(k)))||k==='srcset'||k==='background') n.removeAttribute(a.name);
            if(k==='style' && /url\s*\(|expression\s*\(|@import|behavior\s*:|-moz-binding/i.test(v)) n.removeAttribute(a.name);
            if(k==='href'&&!/^(https?:|mailto:)/i.test(v))n.removeAttribute(a.name);
          });
          if(n.tagName==='IMG') {
            const src=n.getAttribute('src')||'';
            if(!/^https:\/\//i.test(src)&&!(/^data:image\/(png|jpeg|gif|webp);base64,/i.test(src)&&src.length<=\#(((MailBodyPolicy.maximumImageBytes + 2) / 3) * 4 + 64)))n.removeAttribute('src');
            n.setAttribute('referrerpolicy','no-referrer');
          }
        }); return t.innerHTML;
      }
      function authored(node, internal=true) {
        const copy=node.cloneNode(true);
        copy.querySelectorAll('img['+imageSource+']').forEach(n=>{n.setAttribute('src',n.getAttribute(imageSource));n.removeAttribute(imageSource)});
        if(!internal)copy.querySelectorAll('*').forEach(n=>[...n.attributes].forEach(a=>{if(a.name.startsWith('data-ml-'))n.removeAttribute(a.name)}));
        copy.querySelectorAll('*').forEach(n=>{const attrs=[...n.attributes].map(a=>[a.name,a.value]).sort((a,b)=>a[0].localeCompare(b[0]));[...n.attributes].forEach(a=>n.removeAttribute(a.name));attrs.forEach(a=>n.setAttribute(a[0],a[1]))});
        return copy.innerHTML;
      }
      function imageDisplay(){root.querySelectorAll('img').forEach(n=>{
        let src=n.getAttribute(imageSource)||n.getAttribute('src')||'';
        if(/^https:\/\//i.test(src)){n.setAttribute(imageSource,src);if(remote||(signatureImages&&n.closest('[data-ml-signature]')))n.setAttribute('src','mlimage://fetch?'+encodeURIComponent(src));else n.removeAttribute('src');}
      })}
      function remember(){const s=getSelection();if(s.rangeCount&&root.contains(s.anchorNode)){bookmark=s.getRangeAt(0).cloneRange();const e=s.anchorNode.nodeType===1?s.anchorNode:s.anchorNode.parentElement,c=getComputedStyle(e);webkit.messageHandlers.changed.postMessage({font:c.fontFamily.split(',')[0].replace(/["']/g,''),size:parseFloat(c.fontSize)*0.75})}}
      function restore(){root.focus();if(bookmark&&root.contains(bookmark.commonAncestorContainer)){const s=getSelection();s.removeAllRanges();s.addRange(bookmark)}}
      function changed(){remember();webkit.messageHandlers.changed.postMessage('input')}
      root.addEventListener('input',changed);document.addEventListener('selectionchange',remember);
      root.addEventListener('click',e=>{if(e.target.closest('a'))e.preventDefault()});
      root.addEventListener('drop',e=>{e.preventDefault()});
      root.addEventListener('paste',e=>{e.preventDefault();if(!root.isContentEditable)return;const d=e.clipboardData;if(!d)return;
        if(e.isTrusted||[...d.items].some(i=>i.kind==='file'||/^image\//i.test(i.type))||[...d.types].some(t=>/file|image\//i.test(t))){const token='dom-'+Date.now()+'-'+Math.random();capturePaste(token);webkit.messageHandlers.changed.postMessage({pasteRaster:token});return}
        window.ml.command('insertHTML',safe(d.getData('text/html')||d.getData('text/plain').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/\n/g,'<br>')))});
      function verified(){if(!owner)return null;const nodes=[...root.querySelectorAll('[data-ml-signature]')].filter(n=>n.getAttribute('data-ml-signature')===owner.key);return nodes.length===1&&authored(nodes[0])===owner.baseline?nodes[0]:null}
      window.ml={
        capturePaste,
        pasteImage(html,token,limit){const range=pasteRanges.get(token);pasteRanges.delete(token);if(!root.isContentEditable)return 'disabled';
          if(!range||!root.contains(range.commonAncestorContainer))return 'selection';
          const clean=safe(html),fragment=document.createElement('template');fragment.innerHTML=clean;
          if(new TextEncoder().encode(authored(root)).length+new TextEncoder().encode(clean).length>limit)return 'size';
          bookmark=range;window.ml.command('insertHTML',clean);return 'inserted';},
        load(html,state,trusted){root.innerHTML=safe(html,trusted);owner=null;revoked=false;bookmark=null;pasteRanges.clear();
          if(state){owner=state;if(!verified()){owner=null;revoked=true;root.querySelectorAll('[data-ml-signature]').forEach(n=>n.removeAttribute('data-ml-signature'))}}
          else root.querySelectorAll('[data-ml-signature]').forEach(n=>n.removeAttribute('data-ml-signature'));
          ensureBody();imageDisplay();},
        images(value,signatures){remote=value;signatureImages=signatures;imageDisplay()},
        focus(){ensureBody();root.focus();const r=document.createRange(),body=[...root.children].find(n=>!n.hasAttribute('data-ml-signature')&&!n.hasAttribute('data-ml-quote'));if(body){const first=body.firstChild;r.setStart(first&&first.nodeType===Node.TEXT_NODE?first:body,0)}else r.setStart(root,0);r.collapse(true);const s=getSelection();s.removeAllRanges();s.addRange(r);remember()},
        snapshot(){if(owner&&!verified())revoked=true;return {html:authored(root),outgoingHTML:'<div style="font:12pt Verdana,Arial,sans-serif;color:#000">'+authored(root,false)+'</div>',text:root.innerText,signature:!revoked?owner:null}},
        signature(html,key,identity,reference,beforeQuote,allowInsert){
          let node=owner?verified():null;if((owner&&!node)||revoked){revoked=true;return 'protected'};
          const quote=root.querySelector('[data-ml-quote]');if(beforeQuote&&!quote)return 'protected';
          if(!node&&(!html||!allowInsert))return 'unchanged';
          ensureBody();
          if(node&&owner.identity===identity&&owner.reference===reference&&html!==null){const t=document.createElement('div');t.innerHTML=safe(html);if(authored(t)===owner.baseline)return 'unchanged'}
          remember();const selection=bookmark?bookmark.cloneRange():null;
          if(html===null){if(node)node.remove();owner=null;revoked=false;changed();return 'changed'}
          const replacement=document.createElement('div');replacement.setAttribute('data-ml-signature',key);replacement.innerHTML=safe(html);
          if(node)node.replaceWith(replacement);else root.insertBefore(replacement,beforeQuote?quote:null);
          owner={key,identity,reference,baseline:authored(replacement)};imageDisplay();
          if(selection&&root.contains(selection.commonAncestorContainer)){const s=getSelection();s.removeAllRanges();s.addRange(selection);bookmark=selection}
          changed();return 'changed';
        },
        command(name,value){if(!root.isContentEditable)return;if(name==='undo'||name==='redo'){root.focus();document.execCommand(name,false,null);imageDisplay();changed();return}restore();if(name!=='insertHTML')document.execCommand('styleWithCSS',false,true);document.execCommand(name,false,name==='insertHTML'?safe(value):value);imageDisplay();changed()},
        style(name,value){restore();const s=getSelection();if(!s.rangeCount)return;const range=s.getRangeAt(0),span=document.createElement('span');span.style.setProperty(name,value);span.append(range.extractContents());if(!span.firstChild)span.append(document.createTextNode('\u200b'));range.insertNode(span);range.selectNodeContents(span);s.removeAllRanges();s.addRange(range);changed()}
      };
    })();
    """#
}

struct WebHTMLComposer: NSViewRepresentable {
    let handle: WebHTMLComposerHandle
    let onChange: () -> Void
    func makeNSView(context: Context) -> WKWebView { handle.onChange = onChange; return handle.webView }
    func updateNSView(_ view: WKWebView, context: Context) { handle.onChange = onChange }
}
