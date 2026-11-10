import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Signature-only, inert HTML serializer. Never use the reader's lossy cleaner here.
/// Stylesheets support type/class/id, descendant and child selectors; rules are
/// flattened into inline CSS. At-rules, pseudo selectors and CSS resource loads
/// are intentionally unsupported. Parsing/size/complexity failures return nil.
enum SignatureHTML {
    static let maximumBytes = 256 * 1024
    static let bodyMaximumBytes = MailBodyPolicy.maximumBytes
    static let bodyMaximumImageBytes = MailBodyPolicy.maximumImageBytes
    static let bodyMaximumNodes = MailBodyPolicy.maximumNodes

    static func sanitizeBody(_ input: String) -> String? {
        if input.isEmpty { return "" }
        return sanitize(input, baseURL: nil, maximumBytes: bodyMaximumBytes, maximumImageBytes: bodyMaximumImageBytes, maximumNodes: bodyMaximumNodes, maximumDepth: MailBodyPolicy.maximumDepth, allowEmpty: true)
    }
    /// Replace only actual image src attributes during the existing inert
    /// serialization. Text, links and data-src attributes cannot become uploads.
    static func replacingBodyImages(_ input: String, replacements: [String: String]) -> String? {
        sanitize(input, baseURL: nil, maximumBytes: bodyMaximumBytes,
                 maximumImageBytes: bodyMaximumImageBytes, maximumNodes: bodyMaximumNodes,
                 maximumDepth: MailBodyPolicy.maximumDepth, allowEmpty: true,
                 imageReplacements: replacements)
    }
    private static let tags = Set("a abbr b bdi bdo blockquote br caption center code col colgroup dd del div dl dt em font h1 h2 h3 h4 h5 h6 hr i img ins li ol p pre s small span strong sub sup table tbody td tfoot th thead tr u ul".split(separator: " ").map(String.init))
    private static let discard = Set("script iframe frame frameset form input button textarea select option object embed svg math template noscript link meta base audio video source canvas style".split(separator: " ").map(String.init))
    private static let voids: Set<String> = ["br", "hr", "img", "col"]
    private static let properties = Set("color background background-color background-image font font-family font-size font-style font-weight font-variant font-stretch line-height text-align text-decoration text-decoration-color text-decoration-style text-transform text-indent text-shadow letter-spacing word-spacing white-space word-break overflow-wrap vertical-align border border-top border-right border-bottom border-left border-color border-style border-width border-top-color border-right-color border-bottom-color border-left-color border-top-style border-right-style border-bottom-style border-left-style border-top-width border-right-width border-bottom-width border-left-width border-collapse border-spacing border-radius padding padding-top padding-right padding-bottom padding-left margin margin-top margin-right margin-bottom margin-left width min-width max-width height min-height max-height table-layout display float clear box-sizing list-style-type list-style-position direction unicode-bidi opacity".split(separator: " ").map(String.init))
    private struct Rule { let selector: String; let css: String; let specificity: Int; let order: Int }

    static func sanitize(_ input: String) -> String? { sanitize(input, baseURL: nil) }

    /// Resolve remote signature resources only against caller-supplied trusted
    /// context. An HTML <base> never influences resolution; this performs no IO.
    static func sanitize(_ input: String, baseURL: URL?) -> String? {
        sanitize(input, baseURL: baseURL, maximumBytes: maximumBytes, maximumImageBytes: 144 * 1024)
    }

    private static func sanitize(_ input: String, baseURL: URL?, maximumBytes: Int, maximumImageBytes: Int, maximumNodes: Int = 4096, maximumDepth: Int = 64, allowEmpty: Bool = false, imageReplacements: [String: String] = [:]) -> String? {
        guard input.utf8.count <= maximumBytes else { return nil }
        // Accept the inert HTML5 declaration; all DTD/entity declarations fail closed.
        let html = input.replacingOccurrences(of: "<!doctype html>", with: "", options: .caseInsensitive)
        guard !html.isEmpty, html.utf8.count <= maximumBytes,
              !html.contains("\0"), !html.lowercased().contains("<!entity"), !html.lowercased().contains("<!doctype"),
              let doc = try? XMLDocument(data: Data(("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">" + html).utf8), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement() else { return nil }
        var nodes = 0, styleBytes = 0, invalid = false
        var rules: [Rule] = []
        var pending: [(XMLNode, Int)] = [(root, 0)]
        while let (node, depth) = pending.popLast() {
            nodes += 1
            guard nodes <= maximumNodes, depth <= maximumDepth else { return nil }
            if node.kind == .element, node.name?.lowercased() == "style" {
                let css = node.stringValue ?? ""
                styleBytes += css.utf8.count
                if styleBytes > 32768 { return nil }
                rules += stylesheet(css, startingAt: rules.count)
                if rules.count > 256 { return nil }
            }
            pending.append(contentsOf: (node.children ?? []).reversed().map { ($0, depth + 1) })
        }
        rules.sort { $0.specificity == $1.specificity ? $0.order < $1.order : $0.specificity < $1.specificity }
        var meaningful = false, outputBytes = 0
        var selectorBudget = allowEmpty ? max(200_000, min(16_000_000, nodes * 128)) : 200_000
        var fragments: [String] = []
        func append(_ text: String) {
            outputBytes += text.utf8.count
            if outputBytes > maximumBytes { invalid = true; return }
            fragments.append(text)
        }
        // Append in document order without recursive string concatenation. A
        // deeply quoted thread is linear in output size instead of repeatedly
        // copying the entire remaining history at every ancestor.
        var output: [(XMLNode?, String?)] = [(root, nil)]
        while let (next, closing) = output.popLast() {
            guard !invalid else { return nil }
            if let closing { append(closing); continue }
            guard let node = next else { continue }
            if node.kind == .text {
                let text = node.stringValue ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { meaningful = true }
                append(escape(text)); continue
            }
            guard let element = node as? XMLElement else { continue }
            let sourceTag = (element.name ?? "").lowercased()
            if discard.contains(sourceTag) || sourceTag == "head" { continue }
            let tag = sourceTag == "body" || sourceTag == "html" ? "div" : sourceTag
            func children() { output.append(contentsOf: (element.children ?? []).reversed().map { ($0, nil) }) }
            guard tags.contains(tag) else { children(); continue }
            var attributes: [String] = []
            for attribute in element.attributes ?? [] {
                let name = (attribute.name ?? "").lowercased(), value = attribute.stringValue ?? ""
                guard value.utf8.count <= maximumBytes else { continue }
                switch name {
                case "class", "id", "title", "alt", "lang", "dir":
                    attributes.append("\(name)=\"\(escape(value))\"")
                case "href" where tag == "a":
                    if let url = resourceURL(value, image: false, baseURL: baseURL) { attributes.append("href=\"\(escape(url))\"") }
                case "src" where tag == "img":
                    if let url = resourceURL(imageReplacements[value] ?? value, image: true, baseURL: baseURL, maximumImageBytes: maximumImageBytes) { attributes.append("src=\"\(escape(url))\""); meaningful = true }
                case "width", "height", "cellpadding", "cellspacing", "border", "colspan", "rowspan", "span":
                    if value.count <= 12 && value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "%") }) { attributes.append("\(name)=\"\(escape(value))\"") }
                case "align", "valign", "bgcolor", "color", "face", "size":
                    if value.count <= 200 && !value.contains("<") && !value.contains("\\") { attributes.append("\(name)=\"\(escape(value))\"") }
                default: break
                }
            }
            let matched = rules.filter { matches(element, selector: $0.selector, budget: &selectorBudget) }.map(\.css)
            if selectorBudget <= 0 { return nil }
            let inline = declarations(element.attribute(forName: "style")?.stringValue ?? "")
            let css = (matched + [inline]).filter { !$0.isEmpty }.joined(separator: ";")
            if !css.isEmpty { attributes.append("style=\"\(escape(css))\"") }
            // Tidy synthesizes html/body on every parse; only retain a wrapper
            // when it actually carries author presentation or selector hooks.
            if (sourceTag == "html" || sourceTag == "body") && attributes.isEmpty { children(); continue }
            let opening = "<" + tag + (attributes.isEmpty ? "" : " " + attributes.joined(separator: " ")) + ">"
            append(opening)
            if !voids.contains(tag) { output.append((nil, "</" + tag + ">")); children() }
        }
        let result = fragments.joined()
        guard !invalid, (meaningful || allowEmpty), result.utf8.count <= maximumBytes else { return nil }
        return result
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func resourceURL(_ raw: String, image: Bool, baseURL: URL?, maximumImageBytes: Int = 144 * 1024) -> String? {
        if validURL(raw, image: image, maximumImageBytes: maximumImageBytes) { return raw }
        guard !raw.isEmpty, !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let reference = URLComponents(string: raw), reference.scheme == nil,
              let baseURL, validURL(baseURL.absoluteString, image: true), baseURL.scheme?.lowercased() == "https",
              let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL.absoluteString,
              validURL(resolved, image: image) else { return nil }
        return resolved
    }

    private static func validURL(_ raw: String, image: Bool, maximumImageBytes: Int = 144 * 1024) -> Bool {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if image && raw.lowercased().hasPrefix("data:") {
            guard let comma = raw.firstIndex(of: ",") else { return false }
            let header = raw[..<comma].lowercased()
            guard ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64"].contains(header) else { return false }
            let payload = String(raw[raw.index(after: comma)...])
            guard payload.utf8.count <= ((maximumImageBytes + 2) / 3) * 4, !payload.isEmpty,
                  let data = Data(base64Encoded: payload), data.count <= maximumImageBytes else { return false }
            let bytes = [UInt8](data.prefix(12))
            switch header {
            case "data:image/png;base64": return bytes.starts(with: [137,80,78,71,13,10,26,10])
            case "data:image/jpeg;base64": return bytes.starts(with: [255,216,255])
            case "data:image/gif;base64": return bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8))
            default: return bytes.count == 12 && bytes[0..<4].elementsEqual(Array("RIFF".utf8)) && bytes[8..<12].elementsEqual(Array("WEBP".utf8))
            }
        }
        guard let url = URLComponents(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return url.host?.isEmpty == false && url.user == nil && url.password == nil }
        return !image && ["mailto", "tel"].contains(scheme) && !raw.contains("\\")
    }

    // A deliberately small CSS grammar; unknown syntax is discarded, not passed through.
    private static func withoutComments(_ input: String) -> String? {
        var result = "", index = input.startIndex, quote: Character?
        while index < input.endIndex {
            let c = input[index], next = input.index(after: index)
            if c == "\\" || c == "<" || c == ">" && quote != nil || c == "\0" { return nil }
            if let q = quote { result.append(c); if c == q { quote = nil }; index = next; continue }
            if c == "\"" || c == "'" { quote = c; result.append(c); index = next; continue }
            if c == "/", next < input.endIndex, input[next] == "*" {
                guard let end = input.range(of: "*/", range: input.index(after: next)..<input.endIndex) else { return nil }
                result += " "; index = end.upperBound; continue
            }
            result.append(c); index = next
        }
        return quote == nil ? result : nil
    }
    private static func declarations(_ source: String) -> String {
        guard source.utf8.count <= 32768, let source = withoutComments(source) else { return "" }
        var output: [String] = []
        for declaration in source.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard properties.contains(property), !value.isEmpty, value.count <= 2048, safeCSSValue(value) else { continue }
            output.append(property + ":" + value)
        }
        return output.joined(separator: ";")
    }
    static func safeCSSValue(_ value: String) -> Bool {
        let allowedFunctions: Set<String> = ["rgb", "rgba", "hsl", "hsla", "calc", "min", "max", "clamp", "linear-gradient", "radial-gradient"]
        var quote: Character?, depth = 0, word = ""
        for c in value {
            if c == "\\" || c == "@" || c == "{" || c == "}" || c == "<" || c == ">" || c == ":" || c.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) { return false }
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; word = ""; continue }
            if c == "(" { guard allowedFunctions.contains(word.lowercased()), depth < 8 else { return false }; depth += 1; word = "" }
            else if c == ")" { depth -= 1; if depth < 0 { return false }; word = "" }
            else if c.isLetter || c == "-" { word.append(c) }
            else { word = "" }
        }
        return quote == nil && depth == 0
    }
    private static func stylesheet(_ source: String, startingAt: Int) -> [Rule] {
        guard let source = withoutComments(source), !source.contains("@") else { return [] }
        var rules: [Rule] = [], rest = source[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let selectors = rest[..<open], body = rest[rest.index(after: open)..<close]
            if body.contains("{") { return [] }
            let css = declarations(String(body))
            if !css.isEmpty {
                for raw in selectors.split(separator: ",") {
                    let selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard selector.count <= 256, validSelector(selector) else { continue }
                    let score = selector.filter { $0 == "#" }.count * 1_000_000 + selector.filter { $0 == "." }.count * 1_000 + selector.split(whereSeparator: { $0.isWhitespace || $0 == ">" }).filter { $0.first?.isLetter == true }.count
                    rules.append(Rule(selector: selector, css: css, specificity: score, order: startingAt + rules.count))
                    if rules.count > 256 { return rules }
                }
            }
            rest = rest[rest.index(after: close)...]
        }
        return rules
    }
    private static func validSelector(_ selector: String) -> Bool {
        !selector.isEmpty && selector.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.*#>".contains($0) || $0.isWhitespace) }
    }
    private static func matches(_ element: XMLElement, selector: String, budget: inout Int) -> Bool {
        let tokens = selector.replacingOccurrences(of: ">", with: " > ").split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, tokens.count <= 24 else { return false }
        func simple(_ node: XMLElement, _ token: String) -> Bool {
            var components: [(Character, String)] = [], kind: Character = "t", text = ""
            for c in token {
                if c == "." || c == "#" { if !text.isEmpty { components.append((kind, text)) }; kind = c; text = "" }
                else { text.append(c) }
            }
            if !text.isEmpty { components.append((kind, text)) }
            guard !components.isEmpty else { return false }
            return components.allSatisfy { kind, value in
                switch kind {
                case "#": return node.attribute(forName: "id")?.stringValue == value
                case ".": return (node.attribute(forName: "class")?.stringValue ?? "").split(whereSeparator: \.isWhitespace).contains(Substring(value))
                default: return value == "*" || node.name?.lowercased() == value.lowercased()
                }
            }
        }
        func match(_ node: XMLElement, _ index: Int) -> Bool {
            budget -= 1
            guard budget > 0, index >= 0, tokens[index] != ">", simple(node, tokens[index]) else { return false }
            if index == 0 { return true }
            if tokens[index - 1] == ">" { guard index >= 2, let parent = node.parent as? XMLElement else { return false }; return match(parent, index - 2) }
            var parent = node.parent as? XMLElement
            while let ancestor = parent { if match(ancestor, index - 1) { return true }; parent = ancestor.parent as? XMLElement }
            return false
        }
        return match(element, tokens.count - 1)
    }
}
