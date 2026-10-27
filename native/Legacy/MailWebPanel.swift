import AppKit
import WebKit
import Darwin

@MainActor final class WeakEdits: NSObject, WKScriptMessageHandler {
    weak var panel: MailWebPanel?
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        if message.name == "edits", message.body as? Bool == true, let panel, Trust.mail(panel.webView.url), Region.all.contains(where:{message.frameInfo.securityOrigin.host == "mail.\($0.domain)"}) { panel.dirty = true }
    }
}
@MainActor final class MailWebPanel: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSWindowDelegate {
    weak var owner: MailWindow?
    var account: MailAccount
    let webView: WKWebView
    var dirty = false, popupWindow: NSWindow?, lastUsed = Date()
    struct DownloadJob { let download:WKDownload, temporary:URL, destination:URL }
    var downloads:[ObjectIdentifier:DownloadJob] = [:]
    init(owner:MailWindow,account:MailAccount,configuration supplied:WKWebViewConfiguration? = nil) {
        self.owner = owner; self.account = account
        let configuration = supplied ?? WKWebViewConfiguration()
        configuration.websiteDataStore = owner.dataStore(account)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController = WKUserContentController()
        let edits = WeakEdits()
        configuration.userContentController.add(edits,contentWorld:.defaultClient,name:"edits")
        configuration.userContentController.addUserScript(WKUserScript(source:"document.addEventListener('input', e => { if(e.isTrusted) window.webkit.messageHandlers.edits.postMessage(true); }, true);",injectionTime:.atDocumentEnd,forMainFrameOnly:false,in:.defaultClient))
        webView = WKWebView(frame:.zero,configuration:configuration)
        super.init(); edits.panel = self
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityLabel("Zoho 邮件面板 · \(account.name)")
    }
    func loadFixture(message:MailMessage) {
        webView.loadHTMLString("<!doctype html><meta charset='utf-8'><style>body{font:16px -apple-system;padding:32px;color:#243847}button{font:inherit;padding:8px 18px;margin-right:10px}textarea{display:block;width:90%;height:120px;margin-top:20px}</style><h2>测试邮件面板</h2><p>来源：\(account.id)</p><p>邮件：\(message.id)</p><button onclick=\"document.querySelector('textarea').hidden=false\">测试回复</button><textarea aria-label='测试回复正文' hidden></textarea>",baseURL:nil)
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload, Trust.mail(url) { decisionHandler(.download); return }
        if Trust.inside(url) { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, Trust.outside(url) { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationResponse:WKNavigationResponse,decisionHandler:@escaping(WKNavigationResponsePolicy)->Void) {
        if let http = navigationResponse.response as? HTTPURLResponse, http.value(forHTTPHeaderField:"Content-Disposition")?.lowercased().contains("attachment") == true {
            decisionHandler(Trust.mail(http.url) ? .download : .cancel)
        } else if navigationResponse.canShowMIMEType { decisionHandler(.allow) }
        else { decisionHandler(Trust.mail(navigationResponse.response.url) ? .download : .cancel) }
    }
    func webView(_ webView:WKWebView,didStartProvisionalNavigation navigation:WKNavigation!) {
        guard owner?.activePanel === self else { return }; owner?.status.stringValue = "正在连接 Zoho 邮件…"
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        guard let owner else { return }
        if let url = webView.url, Trust.mail(url), let host = url.host { owner.origins[account.id] = URL(string:"https://\(host)") }
        if owner.activePanel === self {
            owner.status.stringValue = owner.fixture ? "测试面板 · \(account.name)" : Trust.mail(webView.url) ? "Zoho 邮件 · \(account.name)" : "正在登录或验证 · \(account.name)"
            owner.refresh.isEnabled = owner.fixture || Trust.mail(webView.url)
        }
        if owner.authAccount == account.id, Trust.mail(webView.url) {
            Task { @MainActor [weak owner] in await owner?.readAccount(self.account,more:false); owner?.loginCompleted(self.account) }
        }
    }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { failed(error) }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { failed(error) }
    func failed(_ error:Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        if owner?.activePanel === self { owner?.status.stringValue = "邮件面板连接失败，请刷新重试或返回所有收件箱。"; owner?.refresh.isEnabled = true }
    }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {
        if owner?.activePanel === self { owner?.status.stringValue = "邮件面板意外停止，请刷新重试。" }
    }
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for navigationAction:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView? {
        guard let owner, let url = navigationAction.request.url else { return nil }
        guard Trust.inside(url) else { if Trust.outside(url) { NSWorkspace.shared.open(url) }; return nil }
        let panel = MailWebPanel(owner:owner,account:account,configuration:configuration)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:760),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Zoho 邮件 · \(account.name)"; window.contentView = panel.webView; window.delegate = panel; window.isReleasedWhenClosed = false
        panel.popupWindow = window; owner.popupPanels.append(panel); window.center(); window.makeKeyAndOrderFront(nil)
        return panel.webView
    }
    func webViewDidClose(_ webView:WKWebView) { popupWindow?.performClose(nil) }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        if downloads.isEmpty && !dirty { return true }
        let alert = NSAlert(); alert.messageText = downloads.isEmpty ? "确认关闭此邮件窗口？" : "附件下载中，请稍后关闭。"
        alert.informativeText = downloads.isEmpty ? "请先确认编辑已保存为草稿。" : ""
        alert.addButton(withTitle:"继续使用"); if downloads.isEmpty { alert.addButton(withTitle:"关闭") }
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification:Notification) { owner?.popupPanels.removeAll{$0 === self}; popupWindow = nil }
    func webView(_ webView:WKWebView,runJavaScriptAlertPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping()->Void) {
        let alert = NSAlert(); alert.messageText = "Zoho 邮件"; alert.informativeText = Trust.text(message,limit:1500); alert.runModal(); completionHandler()
    }
    func webView(_ webView:WKWebView,runJavaScriptConfirmPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(Bool)->Void) {
        let alert = NSAlert(); alert.messageText = "Zoho 邮件"; alert.informativeText = Trust.text(message,limit:1500); alert.addButton(withTitle:"确定"); alert.addButton(withTitle:"取消"); completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView:WKWebView,runJavaScriptTextInputPanelWithPrompt prompt:String,defaultText:String?,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(String?)->Void) {
        let alert = NSAlert(); alert.messageText = Trust.text(prompt); let field = NSTextField(string:defaultText ?? ""); field.frame = NSRect(x:0,y:0,width:320,height:25); alert.accessoryView = field; alert.addButton(withTitle:"确定"); alert.addButton(withTitle:"取消"); completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
    func webView(_ webView:WKWebView,requestMediaCapturePermissionFor origin:WKSecurityOrigin,initiatedByFrame frame:WKFrameInfo,type:WKMediaCaptureType,decisionHandler:@escaping(WKPermissionDecision)->Void) { decisionHandler(.deny) }
    func webView(_ webView:WKWebView,navigationAction:WKNavigationAction,didBecome download:WKDownload) { download.delegate = self }
    func webView(_ webView:WKWebView,navigationResponse:WKNavigationResponse,didBecome download:WKDownload) { download.delegate = self }
    func download(_ download:WKDownload,decideDestinationUsing response:URLResponse,suggestedFilename:String,completionHandler:@escaping(URL?)->Void) {
        guard let window = popupWindow ?? owner?.window else { completionHandler(nil); return }
        let save = NSSavePanel(); save.nameFieldStringValue = (suggestedFilename as NSString).lastPathComponent; save.canCreateDirectories = true
        save.beginSheetModal(for:window) { [weak self] result in
            guard let self, result == .OK, let url = save.url else { completionHandler(nil); return }
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".mail-lite-\(UUID().uuidString).part")
            self.downloads[ObjectIdentifier(download)] = .init(download:download,temporary:temporary,destination:url)
            self.owner?.busyDownloads += 1; completionHandler(temporary)
        }
    }
    func download(_ download:WKDownload,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,decisionHandler:@escaping(WKDownload.RedirectPolicy)->Void) { decisionHandler(Trust.mail(request.url) ? .allow : .cancel) }
    func downloadDidFinish(_ download:WKDownload) {
        guard let job = downloads.removeValue(forKey:ObjectIdentifier(download)) else { return }; owner?.busyDownloads -= 1
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:job.temporary.path)
        if rename(job.temporary.path,job.destination.path) != 0 {
            try? FileManager.default.removeItem(at:job.temporary); owner?.status.stringValue = "附件未能保存，请重试。"; return
        }
        let quarantine = "0001;\(String(Int(Date().timeIntervalSince1970),radix:16));Mail Lite;\(UUID().uuidString)"
        let result = quarantine.withCString { setxattr(job.destination.path,"com.apple.quarantine",$0,strlen($0),0,0) }
        owner?.status.stringValue = result == 0 ? "附件已保存" : "附件已保存，下载来源标记未写入。"
    }
    func download(_ download:WKDownload,didFailWithError error:Error,resumeData:Data?) {
        if let job = downloads.removeValue(forKey:ObjectIdentifier(download)) { try? FileManager.default.removeItem(at:job.temporary); owner?.busyDownloads -= 1 }
        owner?.status.stringValue = "附件下载未完成，请重试。"
    }
}
