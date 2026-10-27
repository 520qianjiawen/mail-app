import AppKit
import WebKit

/// One isolated WebKit session per account. It is a same-origin fetch engine
/// for the Zoho web API and becomes visible only while the user completes a
/// sign-in. The sign-in window behaves like a small browser: Zoho's flow may
/// redirect across zoho.com properties, open a popup, or raise a JavaScript
/// alert, and all of those must work or the button appears to do nothing.
@MainActor final class AccountSession: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let account: MailAccount
    let store: WKWebsiteDataStore
    let webView: WKWebView
    weak var state: AppState?
    var loginWindow: NSWindow?
    var loginContinuation: CheckedContinuation<Bool, Never>?
    var pollTimer: Timer?
    var lastError: String?
    var statusLabel: NSTextField?
    var spinner: NSProgressIndicator?
    var hostLabel: NSTextField?

    var origin: URL { Region.find(account.region)?.origin ?? Region.all[0].origin }

    init(account: MailAccount, fixture: Bool = false) {
        self.account = account
        store = fixture ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: account.dataIdentifier)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = WKUserContentController()
        let diagnostics = """
        window.__mlLogs = [];
        window.addEventListener('error', function (event) {
            try { window.__mlLogs.push('error: ' + event.message + ' @ ' + (event.filename || '') + ':' + event.lineno); } catch (e) {}
        });
        window.addEventListener('unhandledrejection', function (event) {
            try { var reason = event.reason; window.__mlLogs.push('rejection: ' + ((reason && (reason.message || reason)) || 'unknown')); } catch (e) {}
        });
        (function () {
            var original = console.error;
            console.error = function () {
                try { window.__mlLogs.push('console.error: ' + Array.prototype.map.call(arguments, String).join(' ')); } catch (e) {}
                return original.apply(console, arguments);
            };
        })();
        """
        controller.addUserScript(WKUserScript(source: diagnostics, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setAccessibilityLabel("Zoho 登录 · \(account.name)")
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        if #available(macOS 13.3, *) { webView.isInspectable = true }
    }

    func loadIfNeeded() {
        if webView.url == nil {
            webView.load(URLRequest(url: origin.appendingPathComponent("zm/")))
        }
    }

    /// Wait until the session has a settled document on a mail host.
    func ready(timeout: TimeInterval = 20) async throws {
        loadIfNeeded()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !webView.isLoading, let url = webView.url, Trust.mail(url) { return }
            if !webView.isLoading, let url = webView.url {
                // A valid mailbox session lands on mail.<region>. Any settled
                // page on accounts.<region> (signin, relogin, oauth) means the
                // session must be re-authenticated: fail fast instead of
                // blocking every other account behind a 20-second timeout.
                if (url.host ?? "").hasPrefix("accounts.") { throw MailFailure.auth }
                if !Trust.inside(url) { throw MailFailure.auth }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw MailFailure.network
    }

    func verify() async throws -> MailboxSession {
        try await ready()
        guard let state else { throw MailFailure.auth }
        return try await state.api.discover(account: account, store: store, origin: origin, browser: webView)
    }

    // MARK: - Sign-in window

    func authenticate(presenting parent: NSWindow?) async -> Bool {
        if loginWindow != nil { return false }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "登录 \(account.name)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 820, height: 600)

        let bar = NSVisualEffectView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        let back = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "后退")!, target: self, action: #selector(goBack))
        let reload = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")!, target: self, action: #selector(reloadPage))
        let external = NSButton(image: NSImage(systemSymbolName: "safari", accessibilityDescription: "在浏览器打开")!, target: self, action: #selector(openInBrowser))
        let diagnose = NSButton(title: "诊断", target: self, action: #selector(showDiagnostics))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelLogin))
        for button in [back, reload, external] { button.bezelStyle = .accessoryBarAction }
        diagnose.bezelStyle = .accessoryBarAction
        cancel.bezelStyle = .accessoryBarAction
        let host = NSTextField(labelWithString: "")
        host.font = .systemFont(ofSize: 11)
        host.textColor = .secondaryLabelColor
        host.lineBreakMode = .byTruncatingMiddle
        let status = NSTextField(labelWithString: "正在打开 Zoho 登录页…")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [back, reload, external, diagnose, host, spacer, progress, status, cancel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        bar.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(bar)
        container.addSubview(webView)
        bar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 38),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
        window.center()
        loginWindow = window
        statusLabel = status
        hostLabel = host
        spinner = progress
        host.stringValue = origin.host ?? ""
        webView.load(URLRequest(url: origin.appendingPathComponent("zm/")))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        return await withCheckedContinuation { continuation in
            loginContinuation = continuation
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.pollLogin() }
            }
        }
    }

    private func pollLogin() async {
        guard let state, loginWindow != nil else { return }
        guard !webView.isLoading, let url = webView.url, Trust.mail(url) else { return }
        do {
            let context = try await state.api.discover(account: account, store: store,
                                                       origin: origin, browser: webView)
            state.adopt(context, account: account)
            statusLabel?.stringValue = "登录成功，正在返回…"
            finishLogin(true)
        } catch {
            lastError = (error as? MailFailure)?.label
            statusLabel?.stringValue = "已到达邮箱页面，正在确认登录状态…"
        }
    }

    func finishLogin(_ ok: Bool) {
        pollTimer?.invalidate(); pollTimer = nil
        if let window = loginWindow {
            window.delegate = nil
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        loginWindow = nil
        statusLabel = nil
        hostLabel = nil
        spinner = nil
        if webView.superview != nil { webView.removeFromSuperview() }
        let continuation = loginContinuation
        loginContinuation = nil
        continuation?.resume(returning: ok)
    }

    @objc private func goBack() { if webView.canGoBack { webView.goBack() } }
    @objc private func reloadPage() { webView.reload() }
    @objc private func openInBrowser() {
        if let url = webView.url, Trust.outside(url) { NSWorkspace.shared.open(url) }
    }
    @objc private func cancelLogin() { finishLogin(false) }

    /// The user sees exactly what the page and our navigation layer reported.
    /// Useful when a sign-in step does not advance and the cause is client-side
    /// (blocked dialog, rejected promise, cancelled redirect).
    @objc private func showDiagnostics() {
        let script = """
        JSON.stringify({
            url: location.href,
            title: document.title,
            text: (document.body ? document.body.innerText : '').slice(0, 700),
            forms: document.querySelectorAll('form').length,
            buttons: Array.prototype.map.call(document.querySelectorAll('button'), function (b) { return (b.innerText || '').trim(); }).filter(Boolean).slice(0, 12),
            logs: (window.__mlLogs || []).slice(-20)
        })
        """
        webView.evaluateJavaScript(script) { [weak self] value, error in
            Task { @MainActor in
                guard let self else { return }
                let body: String
                if let error {
                    body = "无法读取页面状态：\(error.localizedDescription)"
                } else if let text = value as? String,
                          let data = text.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let pretty = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? text
                    body = pretty
                } else {
                    body = "页面尚未返回状态。"
                }
                let alert = NSAlert()
                alert.messageText = "登录页诊断"
                alert.informativeText = "以下内容只来自当前登录页，不包含密码或验证码。"
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
                let textView = NSTextView(frame: scroll.bounds)
                textView.isEditable = false
                textView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                textView.string = body
                textView.isVerticallyResizable = true
                textView.textContainer?.widthTracksTextView = true
                scroll.documentView = textView
                scroll.hasVerticalScroller = true
                alert.accessoryView = scroll
                alert.addButton(withTitle: "关闭")
                if let window = self.loginWindow { alert.beginSheetModal(for: window) }
                else { alert.runModal() }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === loginWindow else { return }
        finishLogin(false)
    }

    func clearData() async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    // MARK: - Navigation and page dialogs

    /// The sign-in window is a browser for Zoho's authentication flow. Allow
    /// any HTTPS page inside it (accounts/signin/signup/IdP redirects) and send
    /// other schemes to the system browser. Cancelling here silently was what
    /// made an MFA step look like a dead button.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = (url.scheme ?? "").lowercased()
        if ["about", "blob", "data"].contains(scheme) { decisionHandler(.allow); return }
        if scheme == "https" { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, Trust.outside(url) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains((url.scheme ?? "").lowercased()) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        if let window = loginWindow { alert.beginSheetModal(for: window) { _ in completionHandler() } }
        else { alert.runModal(); completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if let window = loginWindow {
            alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn) }
        } else {
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if let window = loginWindow {
            alert.beginSheetModal(for: window) { response in
                completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        } else {
            completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // MARK: - Status

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        spinner?.startAnimation(nil)
        statusLabel?.stringValue = "正在加载…"
        hostLabel?.stringValue = webView.url?.host ?? ""
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hostLabel?.stringValue = webView.url?.host ?? ""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner?.stopAnimation(nil)
        hostLabel?.stringValue = webView.url?.host ?? ""
        let host = webView.url?.host ?? ""
        if host.hasPrefix("accounts.") {
            statusLabel?.stringValue = "请在页面完成验证；成功后会自动返回"
        } else if Trust.mail(webView.url) {
            statusLabel?.stringValue = "已到达邮箱，正在确认登录状态…"
        } else {
            statusLabel?.stringValue = "等待页面完成…"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner?.stopAnimation(nil)
        statusLabel?.stringValue = "页面加载失败：\(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        spinner?.stopAnimation(nil)
        statusLabel?.stringValue = "无法打开：\(error.localizedDescription)"
    }
}
