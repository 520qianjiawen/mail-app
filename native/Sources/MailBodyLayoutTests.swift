import AppKit
import WebKit

private enum MailBodyLayoutTestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

/// Exercises the production height JavaScript against a real, isolated WebKit
/// document. No accounts, cookies, external resources, or application windows
/// are used. Every WebKit callback has a timeout, including navigation failure.
@MainActor private final class MailBodyLayoutTestBrowser: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var navigationTimeout: DispatchWorkItem?
    private let deadline = Date().addingTimeInterval(25)

    private func timeoutInterval(_ requested: TimeInterval) throws -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw MailBodyLayoutTestFailure.failed("body layout suite exceeded its 25 second overall deadline")
        }
        return min(requested, remaining)
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        view = EmailBodyWKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 2500), configuration: configuration)
        super.init()
        (view as? EmailBodyWKWebView)?.disableInternalScrollers(in: view)
        view.navigationDelegate = self
    }

    func close() {
        view.stopLoading()
        view.navigationDelegate = nil
        finishNavigation(.failure(MailBodyLayoutTestFailure.failed("test browser closed")))
    }

    func load(_ fragment: String) async throws {
        let document = MailHTML.document(fragment, images: false)
        guard document.contains("id=\"mail-lite-content\"") else {
            throw MailBodyLayoutTestFailure.failed("production MailHTML.document has no natural-height wrapper")
        }
        let timeoutDelay = try timeoutInterval(3)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            let timeout = DispatchWorkItem { [weak self] in
                self?.view.stopLoading()
                self?.finishNavigation(.failure(MailBodyLayoutTestFailure.failed("WebKit navigation exceeded 3 seconds")))
            }
            navigationTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutDelay, execute: timeout)
            view.loadHTMLString(document, baseURL: nil)
        }
        try await settle()
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        navigationTimeout?.cancel()
        navigationTimeout = nil
        let continuation = navigationContinuation
        navigationContinuation = nil
        continuation?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        (webView as? EmailBodyWKWebView)?.disableInternalScrollers(in: webView)
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(.failure(MailBodyLayoutTestFailure.failed("WebKit content process terminated")))
    }

    func evaluate(_ javaScript: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            // WKWebView need not invoke its callback after a process failure.
            // Resume exactly once regardless of callback / deadline ordering.
            var pending: CheckedContinuation<Any?, Error>? = continuation
            let timeout = DispatchWorkItem {
                let continuation = pending
                pending = nil
                continuation?.resume(throwing: MailBodyLayoutTestFailure.failed("host JavaScript evaluation exceeded 2 seconds"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
            view.evaluateJavaScript(javaScript) { value, error in
                guard let continuation = pending else { return }
                pending = nil
                timeout.cancel()
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    func height() async throws -> Double {
        guard let number = try await evaluate(MailBodyLayout.heightJavaScript) as? NSNumber else {
            throw MailBodyLayoutTestFailure.failed("production height JavaScript did not return a number")
        }
        let height = number.doubleValue
        guard height.isFinite, height > 0, height < 1_000_000 else {
            throw MailBodyLayoutTestFailure.failed("invalid production height: \(height)")
        }
        return height
    }

    func resize(width: CGFloat? = nil, height: CGFloat) async throws {
        view.setFrameSize(NSSize(width: width ?? view.frame.width, height: height))
        view.layoutSubtreeIfNeeded()
        try await settle()
    }

    private func settle() async throws {
        // Let the UI/WebContent processes exchange the changed viewport size.
        // Reading geometry in the next host evaluation also flushes DOM layout.
        try await Task.sleep(nanoseconds: 45_000_000)
    }
}

/// Run through the dedicated --body-layout-test CLI entry, with NSApp.run active.
/// Returns false on assertion, navigation, JavaScript, or timeout failure.
@MainActor func runMailBodyLayoutTests() async -> Bool {
    let browser = MailBodyLayoutTestBrowser()
    defer { browser.close() }
    var checks = 0
    let started = Date()
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw MailBodyLayoutTestFailure.failed(message) }
        checks += 1
        print("PASS [body-layout \(checks)]: \(message)")
    }
    func stable(_ values: [Double], around expected: Double, tolerance: Double = 2) -> Bool {
        values.allSatisfy { abs($0 - expected) <= tolerance }
    }

    do {
        try require(!browser.view.configuration.websiteDataStore.isPersistent &&
                    !browser.view.configuration.defaultWebpagePreferences.allowsContentJavaScript,
                    "renderer uses nonpersistent storage and disabled document JavaScript")
        let short = "<p>Short email body.</p>"
        let unsafe = short + "<script>window.__mailBodyUntrustedScriptRan = true;</script>"
        try await browser.load(unsafe)
        let scriptRan = try await browser.evaluate("window.__mailBodyUntrustedScriptRan === true") as? Bool
        let scriptCount = try await browser.evaluate("document.querySelectorAll('script').length") as? NSNumber
        try require(scriptRan == false && scriptCount?.intValue == 0,
                    "sanitized message scripts are absent and do not execute; host measurement remains available")
        let shortHeight = try await browser.height()
        try require(shortHeight >= 20 && shortHeight < 200,
                    "short body measures its natural height in a 2500px viewport (\(shortHeight)px)")

        let oldHeight = try await browser.evaluate("Math.ceil(Math.max(document.documentElement.scrollHeight, document.body.scrollHeight, document.documentElement.offsetHeight, document.body.offsetHeight)) + 6") as? NSNumber
        try require((oldHeight?.doubleValue ?? 0) >= 2500 && shortHeight < 200,
                    "old viewport-based formula reproduces oversized body (old \(oldHeight?.doubleValue ?? -1)px, fixed \(shortHeight)px)")

        var feedbackHeights: [Double] = []
        for _ in 0..<8 {
            let height = try await browser.height()
            try await browser.resize(height: CGFloat(max(40, height)))
            feedbackHeights.append(try await browser.height())
        }
        try require(stable(feedbackHeights, around: shortHeight),
                    "eight measure/frame-resize cycles stay stable without +6px feedback growth")

        var viewportHeights: [Double] = []
        for viewport: CGFloat in [200, 1200, 80, 3000, 600] {
            try await browser.resize(height: viewport)
            viewportHeights.append(try await browser.height())
        }
        try require(stable(viewportHeights, around: shortHeight),
                    "the same short body height is independent of several old viewport heights")

        let long = (0..<90).map { "<p>Message paragraph \($0): delivery and product details.</p>" }.joined()
        try await browser.resize(height: 2500)
        try await browser.load(long)
        let longHeight = try await browser.height()
        try require(longHeight > 2000, "long body expands beyond the old viewport (\(longHeight)px)")
        try await browser.resize(height: CGFloat(longHeight))
        try await browser.load(short)
        let replacedHeight = try await browser.height()
        try require(replacedHeight < 200 && abs(replacedHeight - shortHeight) <= 2,
                    "loading a short message into the same tall WebKit view shrinks to natural height")

        let wrapping = "<p>" + String(repeating: "A customer asked for product pricing and delivery details. ", count: 22) + "</p>"
        try await browser.resize(width: 900, height: 2500)
        try await browser.load(wrapping)
        let wideHeight = try await browser.height()
        let wideWidth = try await browser.evaluate("document.getElementById('mail-lite-content').getBoundingClientRect().width") as? NSNumber
        try await browser.resize(width: 260, height: 2500)
        let narrowHeight = try await browser.height()
        let actualWidth = try await browser.evaluate("document.getElementById('mail-lite-content').getBoundingClientRect().width") as? NSNumber
        // Offscreen macOS WebKit may reserve a 16px native scrollbar gutter.
        // Verify the requested width delta rather than assuming zero gutter.
        let widthDelta = (wideWidth?.doubleValue ?? 0) - (actualWidth?.doubleValue ?? 0)
        try require(abs(widthDelta - 640) < 2 && narrowHeight > wideHeight * 1.5,
                    "narrower width recomputes text wrapping (wide \(wideHeight)px, narrow \(narrowHeight)px, root width \(actualWidth?.doubleValue ?? -1)px, requested \(browser.view.frame.width)px)")
        try await browser.resize(width: 900, height: 2500)
        try require(abs((try await browser.height()) - wideHeight) <= 2,
                    "widening the same message shrinks back to its prior natural height")

        try await browser.resize(width: 640, height: 2500)
        try await browser.load(short)
        let beforeLateContent = try await browser.height()
        _ = try await browser.evaluate("""
        (() => {
          const node = document.createElement('div');
          node.id = 'mail-layout-test-late';
          node.style.height = '420px';
          node.textContent = 'Trusted host fixture simulating late image/content dimensions';
          document.getElementById('mail-lite-content').appendChild(node);
          return true;
        })()
        """)
        let afterLateContent = try await browser.height()
        try require(afterLateContent >= beforeLateContent + 400,
                    "host-triggered late content growth is reflected in the next production measurement")
        _ = try await browser.evaluate("document.getElementById('mail-layout-test-late').remove(); true")
        try require(abs((try await browser.height()) - beforeLateContent) <= 2,
                    "removing late content shrinks the height again without reloading WebKit")

        for (name, fragment, selector) in [
            ("paragraph", "<p style='margin:0 0 52px 0'>Trailing paragraph</p>", "p"),
            ("table", "<p style='margin:0'>Before table</p><table style='margin:0 0 48px 0;border:1px solid #777'><tr><td>Trailing table cell</td></tr></table>", "table")
        ] {
            try await browser.load(fragment)
            let measured = try await browser.height()
            guard let metrics = try await browser.evaluate("""
            (() => {
              const root = document.getElementById('mail-lite-content');
              const last = root.querySelector('\(selector)');
              const rootRect = root.getBoundingClientRect();
              const rect = last.getBoundingClientRect();
              return {bottom: rect.bottom - rootRect.top,
                      margin: parseFloat(getComputedStyle(last).marginBottom) || 0,
                      padding: parseFloat(getComputedStyle(root).paddingBottom) || 0};
            })()
            """) as? [String: Any],
                  let bottom = metrics["bottom"] as? NSNumber,
                  let margin = metrics["margin"] as? NSNumber,
                  let padding = metrics["padding"] as? NSNumber else {
                throw MailBodyLayoutTestFailure.failed("could not inspect trailing \(name) geometry")
            }
            let requiredBottom = bottom.doubleValue + margin.doubleValue + padding.doubleValue
            try require(margin.doubleValue >= 40 && measured + 1 >= requiredBottom && measured < 250,
                        "natural wrapper includes trailing \(name) margin and bottom padding without clipping (\(measured)px)")
        }
        try await runMailBodyCoordinatorChecks(require)
        try require(Date().timeIntervalSince(started) < 30, "body layout suite finishes within 30 seconds")
        print("PASS: \(checks) real WebKit mail body layout checks (\(String(format: "%.2f", Date().timeIntervalSince(started)))s).")
        return true
    } catch {
        print("FAIL: real WebKit body layout after \(checks) checks: \(error)")
        return false
    }
}
