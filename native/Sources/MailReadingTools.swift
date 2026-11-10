import Foundation
import Darwin

/// Derived reading projection only. Stored/sent HTML is never rewritten.
enum MailHistoryProjection {
    struct Result: Sendable { let html: String; let folded: Bool }
    static func summary(_ html: String) -> Result {
        guard html.utf8.count <= 8 * 1024 * 1024, let document = MailHTML.parsed(html),
              let body = try? document.nodes(forXPath: "//body").first else { return Result(html: html, folded: false) }
        var text = 0, count = 0, boundary: XMLElement?
        func visit(_ node: XMLNode) {
            guard boundary == nil, count < 8192 else { return }
            count += 1
            if let element = node as? XMLElement {
                let tag = element.name?.lowercased() ?? ""
                if ["head", "script", "style"].contains(tag) { return }
                if text >= 8, MailQuoteSeparator.isHistoryBoundary(element) { boundary = element; return }
            } else if node.kind == .text { text += (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count }
            for child in node.children ?? [] { visit(child) }
        }
        visit(body)
        guard var node: XMLNode = boundary else { return Result(html: html, folded: false) }
        // Once history begins, its following siblings and ancestor tails belong
        // to the collapsed portion. Work on this parsed copy, never source HTML.
        var removeSelf = true
        while node !== body, let parent = node.parent, let index = parent.children?.firstIndex(where: { $0 === node }) {
            for child in (parent.children ?? []).dropFirst(index + (removeSelf ? 0 : 1)) { child.detach() }
            if parent === body { break }
            node = parent; removeSelf = false
        }
        let value = body.children?.map { $0.xmlString(options: .nodeCompactEmptyElement) }.joined() ?? ""
        return Result(html: value, folded: true)
    }
}

enum MailAttachmentExport {
    /// A directory export never silently overwrites an existing file, including
    /// duplicates within one message. Creation itself is exclusive, not TOCTOU.
    static func save(_ data: Data, name: String, directory: URL) throws -> URL {
        let cleaned = (name as NSString).lastPathComponent
        let safe = cleaned.isEmpty || [".", ".."].contains(cleaned) ? "附件" : cleaned
        let parts = safe as NSString
        for n in 0..<10000 {
            let ext = parts.pathExtension
            let candidate = n == 0 ? safe : parts.deletingPathExtension + " (\(n))" + (ext.isEmpty ? "" : "." + ext)
            let url = directory.appendingPathComponent(candidate)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
                let quarantine = "0001;\(String(Int(Date().timeIntervalSince1970), radix: 16));Mail Lite;\(UUID().uuidString)"
                _ = quarantine.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
                return url
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
        throw MailFailure.response
    }
}
