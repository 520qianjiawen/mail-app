import Foundation

/// Resolves inline image references only against the current message's attachment manifest.
/// Provider ImageDisplay URLs are never fetched here and never supply account/message IDs.
enum MailInlineImageReference {
    private static func normalizedCID(_ raw: String) -> String? {
        guard raw.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        guard !value.isEmpty, value.utf8.count <= 500,
              value.rangeOfCharacter(from: .controlCharacters.union(.whitespacesAndNewlines)) == nil,
              !value.contains(where: { "<>/\\?#\"".contains($0) }) else { return nil }
        return value
    }

    private static func displayComponents(_ raw: String) -> URLComponents? {
        guard raw.utf8.count <= 8192 else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if value.hasPrefix("//") { candidate = "https:" + value }
        else if value.hasPrefix("/") { candidate = "https://mail.zoho.com" + value }
        else { candidate = value }
        guard let parts = URLComponents(string: candidate), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased(),
              Region.all.contains(where: { region in
                  if host == "mail." + region.domain { return true }
                  guard host.hasSuffix("." + region.domain) else { return false }
                  let prefix = String(host.dropLast(region.domain.count + 1))
                  return prefix.range(of: "^[a-z]{2}[0-9]+-zmud$", options: .regularExpression) != nil
              }),
              ["/zm/imagedisplay", "/mail/imagedisplay"].contains(parts.path.lowercased()) else { return nil }
        return parts
    }

    static func isProviderDisplayURL(_ raw: String) -> Bool { displayComponents(raw) != nil }

    private static func isTrustedMailHost(_ host: String) -> Bool {
        Region.all.contains { region in
            if host == "mail." + region.domain { return true }
            guard host.hasSuffix("." + region.domain) else { return false }
            let prefix = String(host.dropLast(region.domain.count + 1))
            return prefix.range(of: "^[a-z]{2}[0-9]+-zmud$", options: .regularExpression) != nil
        }
    }

    /// Trusted provider image endpoint that requires the account's own web session.
    /// Absolute/protocol-relative forms must already be trusted hosts; a root-relative
    /// path is resolved only against the current message origin. No cid: reference and
    /// no third-party endpoint is ever converted into a session request.
    static func sessionImageURL(_ raw: String, origin: URL?) -> URL? {
        guard raw.utf8.count <= 8192, raw.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.lowercased().hasPrefix("cid:") else { return nil }
        if value.hasPrefix("/") && !value.hasPrefix("//") {
            guard let origin, origin.scheme == "https", let host = origin.host, Trust.mail(origin) else { return nil }
            return URL(string: "https://\(host)\(value)")
        }
        let candidate = value.hasPrefix("//") ? "https:" + value : value
        guard let parts = URLComponents(string: candidate), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased(), isTrustedMailHost(host),
              let url = parts.url, parts.path.lowercased().hasPrefix("/zm/") else { return nil }
        return url
    }

    static func cid(from raw: String) -> String? {
        guard raw.utf8.count <= 8192 else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cid:") {
            guard let decoded = String(value.dropFirst(4)).removingPercentEncoding else { return nil }
            return normalizedCID(decoded)
        }
        guard let parts = displayComponents(value) else { return nil }
        let items = parts.queryItems ?? []
        let modes = items.filter { $0.name.lowercased() == "mode" }
        let cids = items.filter { $0.name.lowercased() == "cid" }
        guard modes.count == 1, modes[0].value?.lowercased() == "inline",
              cids.count == 1, let cid = cids[0].value else { return nil }
        // URLComponents already decoded the query once. Never decode a second time.
        return normalizedCID(cid)
    }

    static func attachment(for raw: String, inline: [MailAttachment]) -> MailAttachment? {
        attachment(for: raw, alt: nil, inline: inline)
    }

    static func attachment(for raw: String, alt: String?, inline: [MailAttachment]) -> MailAttachment? {
        if let cid = cid(from: raw) {
            let matches = inline.filter { normalizedCID($0.cid) == cid }
            if matches.count == 1, let file = matches.first, Trust.numericID(file.id) != nil { return file }
        }
        if let alt = alt?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
            let altNorm = normalizedCID(alt)
            let matches = inline.filter {
                ($0.cid.caseInsensitiveCompare(alt) == .orderedSame) ||
                ($0.name.caseInsensitiveCompare(alt) == .orderedSame) ||
                (altNorm != nil && normalizedCID($0.cid) == altNorm)
            }
            if matches.count == 1, let file = matches.first, Trust.numericID(file.id) != nil {
                return file
            }
        }
        return nil
    }

    static let fallbackSourceAttributeNames: [String] = [
        "data-src", "data-original", "original-src", "data-original-src",
        "data-actualsrc", "data-url", "data-lazy-src", "data-fallback-src",
        "data-inline-src", "zm-src", "data-zm-src", "data-szok", "data-zoho-src",
        "data-cid", "cid"
    ]

    /// Extracts the effective image source from an <img> element, falling back to
    /// common lazy-load and webmail attributes (such as data-src, original-src, data-cid)
    /// when src is missing, empty, or a 1x1 placeholder.
    static func imageSource(from element: XMLElement) -> String? {
        let attrs = element.attributes ?? []
        func attributeValue(_ name: String) -> String? {
            guard let val = attrs.first(where: { $0.name?.lowercased() == name })?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty else { return nil }
            return val
        }

        let primary = attributeValue("src")
        var isPlaceholder = false
        if let primary {
            let lower = primary.lowercased()
            if lower == "about:blank" ||
               lower.hasPrefix("data:image/gif;base64,r0lgodlh") ||
               lower.hasPrefix("data:image/png;base64,ivborw0kggoaaaansuheugaaaa") ||
               (lower.hasPrefix("data:image/svg+xml") && lower.contains("viewbox=\"0 0 1 1\"")) {
                isPlaceholder = true
            }
        }

        if let primary, !isPlaceholder {
            return primary
        }

        for name in fallbackSourceAttributeNames {
            if let val = attributeValue(name) {
                if (name == "data-cid" || name == "cid") && !val.lowercased().hasPrefix("cid:") {
                    return "cid:\(val)"
                }
                return val
            }
        }

        // If no primary or fallback attribute was found, inspect style for background(-image): url(...)
        if let style = attributeValue("style"), let urlFromStyle = extractURLFromStyle(style) {
            return urlFromStyle
        }

        return primary
    }

    /// Extracts a URL reference inside CSS url(...) within an inline style declaration.
    static func extractURLFromStyle(_ style: String) -> String? {
        guard let urlRange = style.range(of: "url(", options: .caseInsensitive) else { return nil }
        var remainder = style[urlRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let endMarker: String
        if remainder.hasPrefix("&quot;") {
            remainder = String(remainder.dropFirst(6))
            endMarker = "&quot;"
        } else if remainder.hasPrefix("&apos;") {
            remainder = String(remainder.dropFirst(6))
            endMarker = "&apos;"
        } else if remainder.hasPrefix("\"") {
            remainder = String(remainder.dropFirst(1))
            endMarker = "\""
        } else if remainder.hasPrefix("'") {
            remainder = String(remainder.dropFirst(1))
            endMarker = "'"
        } else {
            endMarker = ")"
        }
        guard let endRange = remainder.range(of: endMarker) else { return nil }
        let raw = String(remainder[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = raw.replacingOccurrences(of: "&amp;", with: "&")
        guard !decoded.isEmpty else { return nil }
        return decoded
    }

    static func requiresAttachmentInfo(html: String) -> Bool {
        guard let root = MailHTML.parsed(html)?.rootElement() else { return false }
        var pending: [XMLNode] = [root]
        while let node = pending.popLast() {
            if let element = node as? XMLElement {
                let tag = element.name?.lowercased() ?? ""
                if ["script", "style", "head", "iframe", "object", "svg", "math"].contains(tag) { continue }
                if ["img", "v:imagedata", "imagedata", "input"].contains(tag) {
                    if let source = imageSource(from: element), cid(from: source) != nil { return true }
                }
                if let bg = element.attributes?.first(where: { $0.name?.lowercased() == "background" })?.stringValue,
                   cid(from: bg) != nil {
                    return true
                }
                if let style = element.attributes?.first(where: { $0.name?.lowercased() == "style" })?.stringValue,
                   let url = extractURLFromStyle(style), cid(from: url) != nil {
                    return true
                }
            }
            pending.append(contentsOf: node.children ?? [])
        }
        return false
    }

    static func shouldLoadAttachmentInfo(message: MailMessage, metadata: [String: Any], html: String) -> Bool {
        if message.attachment { return true }
        let inlineKeys = ["hasInline", "hasinline", "hasInlineAttachment", "hasInlineImages", "isInline", "hasAttachment", "hasattachment", "attachment", "totalAttachments", "attachmentCount"]
        for key in inlineKeys {
            if let val = metadata[key] {
                let s = String(describing: val).lowercased()
                if s == "true" || s == "1" || (Int(s) ?? 0) > 0 { return true }
            }
        }
        let lower = html.lowercased()
        if lower.contains("cid:") || lower.contains("imagedisplay") || lower.contains("imagesignature") {
            return true
        }
        return requiresAttachmentInfo(html: html)
    }
}
