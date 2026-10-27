import AppKit

/// Called only by an explicit editor Paste action; never polls the clipboard.
enum ComposerPasteText {
    static let maximumTextBytes = 1024 * 1024
    static let maximumHTMLBytes = 4 * 1024 * 1024
    enum Content { case none, html(String), invalid(String) }

    static func read(from board: NSPasteboard) -> Content {
        if let raw = board.string(forType: .html), !raw.isEmpty {
            guard raw.utf8.count <= maximumHTMLBytes else { return .invalid("粘贴的富文本过大，请分段粘贴（上限 4 MB）") }
            guard !raw.contains("\0"), let clean = SignatureHTML.sanitizeBody(raw) else {
                return .invalid("读取粘贴的富文本失败，请尝试复制纯文字")
            }
            if !clean.isEmpty { return .html(clean) }
        }
        guard let text = board.string(forType: .string), !text.isEmpty else { return .none }
        guard text.utf8.count <= maximumTextBytes else { return .invalid("粘贴的文字过大，请分段粘贴（上限 1 MB）") }
        guard !text.contains("\0") else { return .invalid("粘贴的文字含无效字符，请重新复制") }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let escaped = MailHTML.escape(lines).replacingOccurrences(of: "\n", with: "<br>")
        return .html("<span style=\"white-space:pre-wrap\">" + escaped + "</span>")
    }
}
