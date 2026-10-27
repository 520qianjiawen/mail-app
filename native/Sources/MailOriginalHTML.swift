import Foundation

/// Bounded, read-only extraction of the message body, never an HTML attachment.
/// The returned HTML still goes through MailHTML's allowlist and image policy.
enum MailOriginalHTML {
    static let limit = 40 * 1024 * 1024
    static func imageCounts(_ html: String) -> (missing: Int, available: Int) {
        guard let root = MailHTML.parsed(html)?.rootElement() else { return (0, 0) }
        var pending: [XMLNode] = [root], missing = 0, available = 0
        while let node = pending.popLast() {
            if let element = node as? XMLElement {
                let tag = element.name?.lowercased() ?? ""
                if ["head", "script", "style", "object", "iframe"].contains(tag) { continue }
                if tag == "img" {
                    if (MailInlineImageReference.imageSource(from: element) ?? "").isEmpty { missing += 1 }
                    else { available += 1 }
                }
            }
            pending.append(contentsOf: node.children ?? [])
        }
        return (missing, available)
    }
    static func needsRecovery(_ html: String) -> Bool { imageCounts(html).missing > 0 }
    static func improves(_ original: String, over current: String) -> Bool {
        let before = imageCounts(current), after = imageCounts(original)
        return after.available > 0 && (after.available > before.available ||
            (after.missing < before.missing && after.available >= before.available))
    }
    static func html(_ raw: String) -> String? {
        guard raw.utf8.count <= limit else { return nil }
        var budget = 128
        return part(raw.replacingOccurrences(of: "\r\n", with: "\n"), depth: 0, budget: &budget)
    }
    private static func parameter(_ name: String, in value: String) -> String? {
        let pattern = "(?:^|;)\\s*" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(?:\"([^\"]*)\"|([^;\\s]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        for index in [1, 2] { if let range = Range(match.range(at: index), in: value) { return String(value[range]) } }
        return nil
    }
    private static func part(_ raw: String, depth: Int, budget: inout Int) -> String? {
        guard depth < 12, budget > 0, let separator = raw.range(of: "\n\n") else { return nil }
        budget -= 1
        let header = String(raw[..<separator.lowerBound])
        guard header.utf8.count <= 65536 else { return nil }
        var fields: [String: String] = [:], last = ""
        for line in header.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if !last.isEmpty { fields[last, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }
            } else if let colon = line.firstIndex(of: ":") {
                last = line[..<colon].lowercased()
                fields[last] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let contentType = fields["content-type"] ?? "text/plain"
        let type = contentType.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        let disposition = fields["content-disposition"] ?? ""
        guard !disposition.lowercased().hasPrefix("attachment"), parameter("filename", in: disposition) == nil,
              parameter("name", in: contentType) == nil else { return nil }
        let body = String(raw[separator.upperBound...])
        if type.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: contentType), !boundary.isEmpty, boundary.utf8.count <= 200 else { return nil }
            var parts: [String] = [], lines: [String] = [], collecting = false
            for line in body.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "--" + boundary || trimmed == "--" + boundary + "--" {
                    if collecting { parts.append(lines.joined(separator: "\n")); lines = [] }
                    if trimmed == "--" + boundary + "--" { collecting = false; break }
                    collecting = true
                } else if collecting { lines.append(line) }
            }
            if collecting { return nil } // Truncated multipart: do not guess.
            if type == "multipart/related", let start = parameter("start", in: contentType) {
                let wanted = start.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                let matches = parts.filter { child in
                    guard let headerEnd = child.range(of: "\n\n") else { return false }
                    return child[..<headerEnd.lowerBound].components(separatedBy: "\n").contains { line in
                        guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "content-id" else { return false }
                        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) == wanted
                    }
                }
                guard matches.count == 1, let root = matches.first else { return nil }
                return part(root, depth: depth + 1, budget: &budget)
            }
            if type == "multipart/related" || type == "multipart/mixed" {
                guard let first = parts.first else { return nil }
                return part(first, depth: depth + 1, budget: &budget)
            }
            guard type == "multipart/alternative" else { return nil }
            for child in parts.reversed() {
                if let html = part(child, depth: depth + 1, budget: &budget) { return html }
            }
            return nil
        }
        guard type == "text/html" else { return nil }
        let encoding = (fields["content-transfer-encoding"] ?? "7bit").lowercased()
        let bytes: Data
        if encoding == "base64" {
            let text = body.filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: text), decoded.count <= limit else { return nil }; bytes = decoded
        } else if encoding == "quoted-printable" {
            guard let decoded = quotedPrintable(body) else { return nil }; bytes = decoded
        } else if ["7bit", "8bit", "binary"].contains(encoding) { return body }
        else { return nil }
        switch (parameter("charset", in: contentType) ?? "utf-8").lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii": return String(data: bytes, encoding: .utf8)
        case "iso-8859-1", "latin1": return String(data: bytes, encoding: .isoLatin1)
        case "windows-1252", "cp1252": return String(data: bytes, encoding: .windowsCP1252)
        default: return nil
        }
    }
    private static func quotedPrintable(_ body: String) -> Data? {
        let bytes = Array(body.utf8); var out = Data(), index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte { case 48...57: return byte - 48; case 65...70: return byte - 55; case 97...102: return byte - 87; default: return nil }
        }
        while index < bytes.count {
            if bytes[index] == 61 {
                if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
                guard index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) else { return nil }
                out.append(high * 16 + low); index += 3
            } else { out.append(bytes[index]); index += 1 }
        }
        return out
    }
}
