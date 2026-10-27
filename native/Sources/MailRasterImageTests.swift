import AppKit
import SwiftUI
import WebKit
import ImageIO
import UniformTypeIdentifiers

/// Synthetic bytes + the shipping Coordinator, never a replacement URL scheme handler.
@MainActor func runMailRasterImageTests(_ require: (Bool, String) -> Void) async {
    func encoded(_ type: UTType) -> Data? {
        guard let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                      bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage() else { return nil }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? bytes as Data : nil
    }
    guard let png = encoded(.png) else {
        require(false, "native opaque PNG fixture generated"); return
    }
    for (type, mime) in [(UTType.png, "image/png"), (.jpeg, "image/jpeg"), (.gif, "image/gif"),
                         (.tiff, "image/tiff"), (.bmp, "image/bmp")] {
        require(encoded(type).flatMap { MailRasterImage.mimeType(for: $0) } == mime,
                "byte inspection recognizes native \(mime)")
    }
    let webp = Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")!
    require(MailRasterImage.mimeType(for: webp) == "image/webp", "byte inspection recognizes WebP")
    let invalid: [Data] = [Data(), Data("not an image".utf8),
        Data("<html><img src=x></html>".utf8), Data("<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'/>".utf8),
        Data("%PDF-1.7\n%%EOF".utf8), Data(png.prefix(24)), Data(repeating: 0, count: 25 * 1024 * 1024 + 1)]
    for (index, bytes) in invalid.enumerated() {
        require(MailRasterImage.mimeType(for: bytes) == nil, "raster gate rejects non-raster/truncated/oversized bytes \(index)")
    }
    // A complete PNG with altered IHDR dimensions exercises metadata limits without allocating a bitmap.
    func withDimensions(_ width: UInt32, _ height: UInt32) -> Data {
        var bytes = png
        for (offset, value) in [(16, width), (20, height)] {
            for shift in 0..<4 { bytes[offset + shift] = UInt8(truncatingIfNeeded: value >> UInt32(24 - shift * 8)) }
        }
        var crc: UInt32 = 0xffffffff
        for byte in bytes[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        crc ^= 0xffffffff
        for shift in 0..<4 { bytes[29 + shift] = UInt8(truncatingIfNeeded: crc >> UInt32(24 - shift * 8)) }
        return bytes
    }
    require(MailRasterImage.mimeType(for: withDimensions(10_001, 10_000)) == nil,
            "raster gate rejects above 100 million source pixels without decoding")
    require(MailRasterImage.mimeType(for: withDimensions(UInt32.max, UInt32.max)) == nil,
            "hostile dimension product cannot overflow the pixel fence")
    require(MailRasterImage.mimeType(for: withDimensions(0, 2)) == nil, "zero source dimensions rejected")

    let state = AppState(fixture: true)
    state.start()
    defer { state.shutdown() }
    guard let message = state.rows.first else { require(false, "isolated fixture message exists"); return }
    let files = [MailAttachment(id: "701", name: "opaque.bin", size: png.count, cid: "logo@fixture"),
                 MailAttachment(id: "702", name: "wrong.jpg", size: png.count, cid: "jpeg@fixture"),
                 MailAttachment(id: "703", name: "name.html", size: png.count, cid: "html@fixture"),
                 MailAttachment(id: "704", name: "bad.png", size: 10, cid: "bad@fixture")]
    var reads: [String: Int] = [:]
    state.inlineImageDataHook = { file, _ in
        reads[file.id, default: 0] += 1
        return file.id == "704" ? Data("<html>bad</html>".utf8) : png
    }
    let source = files.map { "<img src='cid:\($0.cid)'>" }.joined()
    let document = MailHTML.document(source, inline: files)
    let parent = MailBodyView(html: document, inline: files, message: message, state: state,
                              detailHTML: source, allowRemote: false, dark: false, paper: false,
                              sessionImageSources: [],
                              height: .constant(100), webView: .constant(nil))
    let coordinator = parent.makeCoordinator()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.setURLSchemeHandler(coordinator, forURLScheme: "mail-inline")
    let view = EmailBodyWKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 100), configuration: configuration)
    view.navigationDelegate = coordinator
    defer { MailBodyView.dismantleNSView(view, coordinator: coordinator) }

    // Inspect the real production handler's emitted URLResponse, not an extension-based test duplicate.
    for file in files {
        let task = RasterSchemeTask(URL(string: "mail-inline://attachment/\(file.id)")!)
        coordinator.webView(view, start: task)
        let deadline = Date().addingTimeInterval(3)
        while !task.finished, task.error == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        if file.id == "704" {
            require(task.error != nil && task.response == nil && task.bytes.isEmpty,
                    "production Coordinator rejects HTML bytes named PNG before response delivery")
        } else {
            require(task.finished && task.response?.mimeType == "image/png" && task.bytes == png,
                    "production Coordinator emits byte-derived PNG for \(file.name)")
        }
        coordinator.webView(view, stop: task)
    }
    require(files.allSatisfy { reads[$0.id] == 1 }, "production scheme handler reads each attachment through fixture AppState hook")
    reads.removeAll()
    coordinator.load(document, into: view)
    var dimensions: [Int] = []
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
        let result = try? await view.evaluateJavaScript("Array.from(document.images).map(i => i.complete ? i.naturalWidth : -1)")
        dimensions = (result as? [NSNumber])?.map { $0.intValue } ?? []
        if dimensions == [2, 2, 2, 0], files.allSatisfy({ reads[$0.id] == 1 }) { break }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
    require(dimensions == [2, 2, 2, 0],
            "real WKWebView + production Coordinator renders unknown/mismatched/HTML filenames and rejects bad bytes (\(dimensions))")
    require(files.allSatisfy { reads[$0.id] == 1 }, "real browser traverses production AppState attachment transport once per image")
}

@MainActor private final class RasterSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: URLResponse?
    var bytes = Data()
    var finished = false
    var error: Error?
    init(_ url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { bytes.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}
