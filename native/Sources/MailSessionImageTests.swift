import Foundation

/// Trust table, document rewrite and session transport for provider-hosted images.
/// Fixture-only hooks; no network is touched.
@MainActor func runMailSessionImageTests(_ require: (Bool, String) -> Void) async {
    let origin = URL(string: "https://mail.zoho.com")!
    // Trust table: absolute, protocol-relative and root-relative trusted forms pass;
    // third-party, insecure, credentialed, non-/zm/ and cid: forms never do.
    let accepted: [(String, URL?)] = [
        ("https://us4-zmud.zoho.com/zm/ImageDisplay?na=1&mode=inline&cid=a@b", origin),
        ("https://mail.zoho.com/zm/ImageDisplay?mode=inline&cid=a@b", origin),
        ("//us4-zmud.zoho.com/zm/ImageDisplay?mode=inline", origin),
        ("/zm/ImageDisplay?na=1", origin),
        ("https://us4-zmud.zoho.com/zm/ImageDisplay?mode=inline&cid=a@b", nil),
    ]
    for (raw, base) in accepted {
        require(MailInlineImageReference.sessionImageURL(raw, origin: base) != nil, "session image trust accepts \(raw.hasPrefix("/") ? "relative" : "absolute") trusted form")
    }
    let rejected: [(String, URL?)] = [
        ("https://tracker.example.test/zm/ImageDisplay?a=1", origin),
        ("https://us4-zmud.zoho.com/attach/download?id=1", origin),
        ("http://us4-zmud.zoho.com/zm/ImageDisplay", origin),
        ("https://user:pass@us4-zmud.zoho.com/zm/ImageDisplay", origin),
        ("https://us4-zmud.zoho.com:8443/zm/ImageDisplay", origin),
        ("cid:inline@example.test", origin),
        ("zm/ImageDisplay?na=1", origin),
        ("", origin),
        ("/zm/ImageDisplay?na=1", nil),
        ("/zm/ImageDisplay?na=1", URL(string: "https://mail.example.test")!),
    ]
    for (raw, base) in rejected {
        require(MailInlineImageReference.sessionImageURL(raw, origin: base) == nil, "session image trust rejects untrusted form")
    }
    require(MailInlineImageReference.isProviderDisplayURL("https://us4-zmud.zoho.com/zm/ImageDisplay?mode=inline&cid=a@b"), "provider display classification is unchanged")

    // Document rewrite: with remote images allowed, the trusted reference stays a
    // direct https source (the reader stays cookie-free); the report still counts it.
    let state0 = AppState(fixture: true)
    defer { _ = state0.shutdown() }
    let message = MailMessage(accountID: state0.accounts[0].id, remoteID: "100", folderID: "200", id: "300", origin: origin,
                              subject: "s", sender: "from@example.test", preview: "", date: Date(), attachment: false, unread: false)
    let html = "<img src='https://us4-zmud.zoho.com/zm/ImageDisplay?mode=inline&amp;cid=a@b'><img src='https://us4-zmud.zoho.com/zm/ImageDisplay?na=9'><img src='https://private.example.test/p.png'>"
    let files = [MailAttachment(id: "801", name: "pic.png", size: 68, cid: "a@b")]
    let withRemote = MailHTML.document(html, inline: files, images: true)
    require(!withRemote.contains("https://us4-zmud.zoho.com/zm/ImageDisplay?na=9"), "session-only display URLs never fall back to anonymous direct https")
    require(withRemote.contains("https://private.example.test/p.png"), "allowed remote render keeps ordinary third-party https source")
    require(!MailHTML.document(html, inline: files, images: false).contains("us4-zmud"), "blocked render strips provider display sources")
    let detailForSources = MailDetail(message: message, from: "", to: "", cc: "", replyTo: "", html: html, attachments: [], inline: files)
    let collected = MailImageDiagnostics.providerSessionSources(detailForSources)
    require(collected.count == 1, "provider session sources collect unique trusted references")

    // Session transport: fixture hook serves a real PNG and a failing URL.
    let state = state0
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    state.sessionImageDataHook = { raw in raw.contains("bad") ? Data("<html>x</html>".utf8) : png }
    // Bad fixture URL below uses the hook with non-raster bytes; the transport must
    // reject them at the raster-validation layer, not pass them through.
    let detail = MailDetail(message: message, from: "", to: "", cc: "", replyTo: "", html: html, attachments: [], inline: files)
    do {
        let data = try await state.sessionImageData("https://us4-zmud.zoho.com/zm/ImageDisplay?a=1", message: message)
        require(MailRasterImage.mimeType(for: data) == "image/png", "session transport returns raster bytes in fixture mode")
    } catch { require(false, "session transport fixture success path threw \(error)") }
    do {
        _ = try await state.sessionImageData("https://us4-zmud.zoho.com/zm/ImageDisplay?bad=1", message: message)
        require(false, "session transport rejects non-raster bytes")
    } catch { require(String(describing: error).contains("response"), "session transport rejects non-raster bytes (threw \(error))") }
    do {
        _ = try await state.sessionImageData("https://tracker.example.test/zm/ImageDisplay", message: message)
        require(false, "session transport rejects untrusted hosts")
    } catch { require(true, "session transport rejects untrusted hosts") }

    // Report integration: live probe lines appear and stay redacted.
    state.sessionImageDataHook = { _ in png }
    let report = await state.imageDiagnostics(detail, remoteAllowed: true)
    require(report.contains("Zoho图片实测（最多2项）：成功 1"), "report includes session image live probe result (report: \(report.contains("成功 1")))")
    require(!report.contains("us4-zmud") && !report.contains("example.test") && !report.contains("a@b"), "session probe report stays redacted")
}
