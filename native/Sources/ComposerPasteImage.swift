import AppKit
import WebKit
import ImageIO
import UniformTypeIdentifiers

/// Reads only in response to Paste. No account state, network access, or general-board polling.
enum ComposerPasteImage {
    static let maximumInputBytes = 32 * 1024 * 1024
    static let maximumImageBytes = 1024 * 1024
    static let maximumBodyBytes = MailBodyPolicy.maximumBytes
    enum Content { case none, images(String), invalid(String) }

    static func read(from board: NSPasteboard) -> Content {
        let items = board.pasteboardItems ?? []
        var inputs: [Data] = []
        var inputBytes = 0
        for item in items {
            let rasterTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("com.compuserve.gif"), .init("org.webmproject.webp")]
            var data: Data?
            if let type = rasterTypes.first(where: { item.types.contains($0) }) {
                data = item.data(forType: type)
            } else if item.types.contains(.fileURL) {
                guard let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL,
                      ["png", "jpg", "jpeg", "tif", "tiff", "gif", "webp"].contains(url.pathExtension.lowercased()) else {
                    return .invalid("请选择 PNG、JPEG、TIFF、GIF 或 WebP 图片粘贴")
                }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, let size = values.fileSize, size <= maximumInputBytes,
                          size <= maximumInputBytes - inputBytes else { return .invalid("剪贴板图片过大（原始文件合计上限 32 MB）") }
                    // Bounded read even if the file grows after resourceValues.
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    data = try file.read(upToCount: maximumInputBytes - inputBytes + 1)
                } catch { return .invalid("读取剪贴板图片失败，请重新复制图片") }
            } else if item.types.contains(where: { $0.rawValue.lowercased().contains("svg") }) {
                return .invalid("请将 SVG 转为 PNG 或 JPEG 后粘贴")
            }
            guard let data else { continue }
            guard !data.isEmpty, data.count <= maximumInputBytes - inputBytes else { return .invalid("剪贴板图片过大（原始数据合计上限 32 MB）") }
            inputBytes += data.count; inputs.append(data)
        }
        guard !inputs.isEmpty else { return .none }
        var fragments: [String] = []
        var encodedBytes = 0
        for input in inputs {
            guard let image = encode(input) else { return .invalid("图片格式损坏或尺寸过大，请复制较小的 PNG 或 JPEG 图片") }
            let fragment = "<img src=\"data:\(image.mime);base64,\(image.data.base64EncodedString())\" width=\"\(image.width)\" height=\"\(image.height)\" alt=\"粘贴的图片\">"
            encodedBytes += fragment.utf8.count
            guard encodedBytes <= maximumBodyBytes - 4096 else { return .invalid("粘贴图片合计过大，请减少图片数量") }
            fragments.append(fragment)
        }
        return .images(fragments.joined())
    }

    struct Encoded { let data: Data; let mime: String; let width: Int; let height: Int }
    // Pure conversion, also used for oversized images inherited by a reply.
    static func encode(_ data: Data) -> Encoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let sourceType = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier, UTType.gif.identifier, "org.webmproject.webp"].contains(sourceType),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000,
              Int64(width) * Int64(height) <= 100_000_000 else { return nil }
        for dimension in [2048, 1536, 1024, 768] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            if let png = encoded(image, type: UTType.png.identifier, quality: nil), png.count <= maximumImageBytes {
                return Encoded(data: png, mime: "image/png", width: image.width, height: image.height)
            }
            // White background prevents transparent screenshots turning black on JPEG fallback.
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let opaque = context.makeImage() else { return nil }
            if let jpeg = encoded(opaque, type: UTType.jpeg.identifier, quality: 0.78), jpeg.count <= maximumImageBytes {
                return Encoded(data: jpeg, mime: "image/jpeg", width: image.width, height: image.height)
            }
        }
        return nil
    }
    private static func encoded(_ image: CGImage, type: String, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(target, image, options as CFDictionary)
        return CGImageDestinationFinalize(target) ? data as Data : nil
    }
}

/// WebKit's internal responder may consume Edit > Paste; the DOM paste bridge covers that
/// route too. The keyboard interception handles screenshot data absent from clipboardData.
@MainActor final class ComposerPasteWebView: WKWebView {
    var onImagePaste: ((NSPasteboard) -> Bool)?
    var pasteboardProvider: () -> NSPasteboard = { .general }
    private var bodyHasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }
    @objc func paste(_ sender: Any?) {
        guard bodyHasFocus else { return }
        // Text, HTML and raster images share one reliable native clipboard path.
        // Re-dispatching to the current responder can call this method again or
        // do nothing when this WKWebView itself is the first responder.
        _ = onImagePaste?(pasteboardProvider())
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            guard bodyHasFocus else { return false }
            if onImagePaste?(pasteboardProvider()) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
    /// Same production entry without reading or modifying the system clipboard in tests.
    @discardableResult func paste(from board: NSPasteboard) -> Bool { onImagePaste?(board) ?? false }
}
