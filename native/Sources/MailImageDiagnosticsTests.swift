import Foundation
import WebKit

@MainActor func runMailImageDiagnosticsTests(_ require: (Bool, String) -> Void) async {
    let state = AppState(fixture: true)
    defer { _ = state.shutdown() }
    let message = MailMessage(accountID: state.accounts[0].id, remoteID: "100", folderID: "200", id: "300", origin: URL(string: "https://mail.zoho.com")!, subject: "PRIVATE SUBJECT", sender: "secret@example.test", preview: "", date: Date(), attachment: false, unread: false)
    let files = (0..<4).map { MailAttachment(id: String(701 + $0), name: "opaque.bin", size: 68, cid: "private-\($0)@example.test") }
    func detail(_ html: String) -> MailDetail {
        MailDetail(message: message, from: message.sender, to: "private-to@example.test", cc: "", replyTo: "", html: html, attachments: [], inline: files)
    }
    let html = "<img src='cid:private-0@example.test'><img src='https://us4-zmud.zoho.com/zm/ImageDisplay?mode=inline&amp;cid=private-1@example.test'><img src='cid:missing@example.test'><img src='https://private.example.test/pixel?token=secret'><img src='data:image/png;base64,AAAA'><img><script>\"<img src='cid:private-3@example.test'>\"</script>"
    let inventory = MailImageDiagnostics.inventory(detail(html))
    require(inventory.images == 6 && inventory.embedded == 3 && inventory.matched == 2 && inventory.unresolved == 1, "diagnostic counts actual source types and unresolved inline references")
    require(inventory.remote == 1 && inventory.dataImages == 1 && inventory.emptySource == 1, "diagnostic keeps remote/data/empty image categories distinct")
    require(inventory.files.count == 2, "diagnostic probes only matched unique attachment members")
    let summary = MailImageDiagnostics.summary(inventory, inlineCount: files.count, remoteAllowed: false)
    for secret in ["PRIVATE SUBJECT", "private-", "example.test", "secret", "token=", "701", "https://"] {
        require(!summary.contains(secret), "shareable diagnostic omits private fixture string \(secret)")
    }
    require(summary.contains("原始HTML特征：含CID(是)；含ImageDisplay(是)"), "summary detects CID and ImageDisplay presence in raw HTML")
    require(summary.contains("当前未允许加载"), "diagnostic explains external image blocking without changing the preference")
    require(MailImageDiagnostics.summary(inventory, inlineCount: 4, remoteAllowed: true).contains("已允许加载"), "diagnostic reports external image enabled state")
    var calls: [String] = []
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    require(MailRasterImage.mimeType(for: png) == "image/png", "diagnostic fixture is an actual readable PNG")
    state.inlineImageDataHook = { file, _ in
        calls.append(file.id)
        if file.id == "701" { return png }
        return Data("<html>not an image</html>".utf8)
    }
    let report = await state.imageDiagnostics(detail(html), remoteAllowed: false)
    require(calls == ["701", "702"] || calls == ["702", "701"], "diagnostic follows the real attachment-data entry for matched references only")
    require(report.contains("有效图片 1，非支持图片 1，读取失败 0"), "diagnostic distinguishes invalid image bytes from transport failures")
    require(report.contains("部分图片未关联"), "diagnostic explains missing current-message CID association")
    require(!report.contains("example.test") && !report.contains("701") && !report.contains("PRIVATE SUBJECT"), "complete download report also stays redacted")
    calls.removeAll()
    state.inlineImageDataHook = { file, _ in calls.append(file.id); throw MailFailure.response }
    let failed = await state.imageDiagnostics(detail("<img src='cid:private-0@example.test'>"), remoteAllowed: false)
    require(failed.contains("读取失败 1") && failed.contains("附件下载未成功"), "actual attachment error produces a useful fixed diagnosis rather than raw server details")
    calls.removeAll()
    state.inlineImageDataHook = { file, _ in calls.append(file.id); return png }
    let many = files.map { "<img src='cid:\($0.cid)'>" }.joined() + "<img src='cid:private-0@example.test'>"
    let bounded = await state.imageDiagnostics(detail(many), remoteAllowed: false)
    require(calls.count == 3 && Set(calls).count == 3, "diagnostic bounds probes to three unique existing attachments")
    require(bounded.contains("有效图片 3"), "successful diagnostics report actual image-byte validation")
    calls.removeAll()
    _ = await state.imageDiagnostics(detail("<p>No images</p>"), remoteAllowed: false)
    require(calls.isEmpty, "no-image diagnostics never create attachment IO")
    require(state.accountSessions.isEmpty, "diagnostic fixtures create no actual account browser sessions")

    // Live WebView render stats verification
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    let testWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), configuration: config)
    testWebView.loadHTMLString("<img src='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='><img src='https://example.invalid/broken.png'>", baseURL: nil)
    let liveDeadline = Date().addingTimeInterval(3)
    while testWebView.isLoading && Date() < liveDeadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    try? await Task.sleep(nanoseconds: 200_000_000)
    if let stats = await MailImageDiagnostics.liveRenderStats(from: testWebView) {
        require(stats.total == 2, "live render stats detects total rendered images")
        require(stats.loaded >= 1, "live render stats measures successfully decoded raster image")
    } else {
        require(false, "live render stats returns non-nil stats from webView")
    }
    let reportWithLive = await state.imageDiagnostics(detail(html), remoteAllowed: true, webView: testWebView)
    require(reportWithLive.contains("页面实测渲染："), "report incorporates live webView render stats when available")
    require(!reportWithLive.contains("example.invalid") && !reportWithLive.contains("broken.png"), "report with live stats stays redacted")

    // Fallback attributes & empty source attributes distribution verification
    let fallbackHTML = "<img src='' data-src='https://assets.example.test/lazy.png'><img data-cid='private-0@example.test'><img style=\"background: url('https://us4-zmud.zoho.com/zm/ImageDisplay?mode=inline&amp;cid=private-1@example.test')\"><img src='' alt='desc' width='10' height='20'>"
    let fallbackInventory = MailImageDiagnostics.inventory(detail(fallbackHTML))
    require(fallbackInventory.images == 4, "fallback inventory counts all 4 images")
    require(fallbackInventory.fallbackSources == 3, "fallback sources count reflects data-src, data-cid, and style background")
    require(fallbackInventory.remote == 1, "fallback data-src counted as remote")
    require(fallbackInventory.embedded == 2 && fallbackInventory.matched == 2, "fallback data-cid and style background counted as matched embedded")
    require(fallbackInventory.emptySource == 1, "unresolved empty src counted as emptySource")
    require(fallbackInventory.emptyAttributes["alt"] == 1 && fallbackInventory.emptyAttributes["width"] == 1, "emptyAttributes records attribute names on empty-source images")

    let fallbackSummary = MailImageDiagnostics.summary(fallbackInventory, inlineCount: 2, remoteAllowed: true)
    require(fallbackSummary.contains("备用属性/样式识别（如data-src/style background）：3"), "summary reports fallback source count")
    require(fallbackSummary.contains("空来源属性分布："), "summary reports empty source attribute distribution")
    require(!fallbackSummary.contains("assets.example.test") && !fallbackSummary.contains("private-0"), "fallback summary remains strictly redacted")

    // Verify MailDetail.clean resolves fallback attributes into standard src
    let cleanedDoc = MailHTML.document(fallbackHTML, inline: files, images: true)
    require(cleanedDoc.contains("src=\"https://assets.example.test/lazy.png\""), "MailDetail.clean promotes data-src to src when remote allowed")
    require(cleanedDoc.contains("src=\"mail-inline://message/701\""), "MailDetail.clean promotes data-cid to mail-inline")
    require(cleanedDoc.contains("src=\"mail-inline://message/702\""), "MailDetail.clean promotes style background url to mail-inline")
}
