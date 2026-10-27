import Foundation

/// A read-only policy over the original DOM. Rendering owns the generated attribute/CSS;
/// neither the email nor an author's existing horizontal rules are rewritten here.
enum MailQuoteSeparator {
    static func isHistoryBoundary(_ element: XMLElement) -> Bool {
        tag(element) == "blockquote" || isProviderWrapper(element) || isHeader(element)
    }

    static func shouldDecorate(_ element: XMLElement) -> Bool {
        let quote = tag(element) == "blockquote"
        let wrapper = isProviderWrapper(element)
        let header = isHeader(element)
        guard quote || wrapper || header else { return false }
        let previous = previousMeaningful(element)
        if let previous = previous as? XMLElement, tag(previous) == "hr" { return false }

        if let parent = element.parent as? XMLElement {
            // Provider containers already own their direct header/quote boundary.
            // Descendant historical quotes remain independent boundaries.
            if isProviderWrapper(parent), header || quote { return false }
            if header, (tag(parent) == "blockquote" || isHeader(parent)), firstMeaningful(parent) === element { return false }
        }
        if quote || wrapper, let previous = previous as? XMLElement, isHeader(previous) { return false }
        return true
    }

    private static func tag(_ element: XMLElement) -> String { (element.name ?? "").lowercased() }

    private static func isProviderWrapper(_ element: XMLElement) -> Bool {
        guard ["div", "blockquote"].contains(tag(element)) else { return false }
        if element.attribute(forName: "id")?.stringValue?.lowercased() == "divrplyfwdmsg" { return true }
        let classes = Set((element.attribute(forName: "class")?.stringValue ?? "")
            .lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
        return !classes.isDisjoint(with: ["gmail_quote", "yahoo_quoted", "protonmail_quote"])
    }

    private static func meaningful(_ node: XMLNode) -> Bool {
        if node.kind == .comment { return false }
        if node.kind == .text { return !(node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // An empty line is not a separate historical boundary.
        if let element = node as? XMLElement, tag(element) == "br" { return false }
        return node.kind == .element
    }
    private static func previousMeaningful(_ node: XMLNode) -> XMLNode? {
        var previous = node.previousSibling
        while let current = previous {
            if meaningful(current) { return current }
            previous = current.previousSibling
        }
        return nil
    }
    private static func firstMeaningful(_ element: XMLElement) -> XMLNode? {
        (element.children ?? []).first(where: meaningful)
    }

    private static func isHeader(_ element: XMLElement) -> Bool {
        guard ["p", "div"].contains(tag(element)) else { return false }
        // Inspect only a small inline-only header, never flattened body containers,
        // signature tables, logos, or contact blocks.
        let inline: Set<String> = ["span", "b", "strong", "i", "em", "a", "font", "br", "u"]
        var descendants: [XMLElement] = []
        func collect(_ parent: XMLElement) -> Bool {
            for child in parent.children ?? [] {
                if let child = child as? XMLElement {
                    guard inline.contains(tag(child)) else { return false }
                    descendants.append(child)
                    guard collect(child) else { return false }
                }
            }
            return true
        }
        // The app's source-header group is bounded explicitly: marker paragraph
        // plus metadata-only divs. Never generalize this to arbitrary block text.
        let blocks = (element.children ?? []).filter(meaningful)
        if tag(element) == "div", (4...5).contains(blocks.count),
           let first = blocks.first as? XMLElement, tag(first) == "p",
           (first.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "---- 原始邮件 ----",
           collect(first) {
            let fields = blocks.dropFirst().compactMap { $0 as? XMLElement }
            let prefixes = fields.map { ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let expected = fields.count == 3 ? ["发件人：", "收件人：", "主题："] : ["发件人：", "收件人：", "日期：", "主题："]
            if fields.count == blocks.count - 1,
               zip(prefixes, expected).allSatisfy({ pair in pair.0.hasPrefix(pair.1) }),
               fields.allSatisfy({ tag($0) == "div" && collect($0) }),
               (element.stringValue ?? "").count <= 1800 { return true }
        }
        descendants.removeAll()
        guard collect(element) else { return false }
        let raw = element.stringValue ?? ""
        guard raw.count <= 700 else { return false }
        let text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return false }
        let patterns = [
            "^-{2,}\\s*原始邮件\\s*-{2,}$",
            "^-{2,}\\s*Original Message\\s*-{2,}$",
            "^(?:-{2,}\\s*)?On\\s+.{3,}?\\s+wrote\\s*:?\\s*(?:-{2,})?$"
        ]
        if patterns.contains(where: { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return true
        }
        // Outlook's compact structured header needs all four explicitly bold
        // labels and line breaks. A sentence beginning “From” is not evidence.
        let labels = descendants.filter { ["b", "strong"].contains(tag($0)) }
            .map { ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let expected = ["from:", "sent:", "to:", "subject:"]
        guard labels == expected,
              descendants.filter({ tag($0) == "br" }).count >= 3 else { return false }
        return text.lowercased().hasPrefix("from:")
    }
}
