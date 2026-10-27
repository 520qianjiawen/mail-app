import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Byte-derived raster metadata only: filenames and server-provided MIME are not trusted.
/// Inspection does not decode a full bitmap or accept active/vector document formats.
enum MailRasterImage {
    static func mimeType(for data: Data) -> String? {
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let identifier = CGImageSourceGetType(source),
              let mime = UTType(identifier as String)?.preferredMIMEType?.lowercased() else { return nil }
        let canonical: String
        switch mime {
        case "image/png", "image/jpeg", "image/gif", "image/webp", "image/tiff",
             "image/bmp", "image/heic", "image/heif": canonical = mime
        case "image/x-ms-bmp": canonical = "image/bmp"
        default: return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        // Cap before conversion; division avoids multiplication overflow even with hostile dimensions.
        func pixels(_ value: NSNumber) -> UInt64? {
            let number = value.doubleValue
            guard number.isFinite, number >= 1, number <= 100_000_000,
                  number.rounded(.towardZero) == number else { return nil }
            return UInt64(number)
        }
        guard let w = pixels(width), let h = pixels(height), w <= 100_000_000 / h else { return nil }
        return canonical
    }
}
