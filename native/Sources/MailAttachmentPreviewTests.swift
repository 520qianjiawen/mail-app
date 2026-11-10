import AppKit
import PDFKit

@MainActor func runMailAttachmentPreviewTests(_ require: (Bool, String) -> Void) async {
    let image = NSImage(size: NSSize(width: 320, height: 220))
    image.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 320, height: 220).fill()
    ("Attachment fixture" as NSString).draw(at: NSPoint(x: 20, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
    image.unlockFocus()
    let document = PDFDocument(); document.insert(PDFPage(image: image)!, at: 0)
    let pdf = document.dataRepresentation()!
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    do {
        if case .pdf(let value) = try MailAttachmentContent.decode(pdf, name: "report.pdf") {
            require(value.pageCount == 1, "PDF bytes produce a readable inline PDF document")
        } else { require(false, "PDF classified for inline viewing") }
        if case .image(let value) = try MailAttachmentContent.decode(png, name: "image.png") {
            require(value.size.width > 0, "image bytes produce a bounded inline image")
        } else { require(false, "image classified for inline viewing") }
        if case .other = try MailAttachmentContent.decode(Data("fixture".utf8), name: "sheet.xlsx") {
            require(true, "other attachment types preserve system preview option")
        } else { require(false, "office document is not treated as executable web content") }
    } catch { require(false, "valid attachment decode fixtures") }
    require((try? MailAttachmentContent.decode(Data("<html>login</html>".utf8), name: "report.pdf")) == nil, "HTML or login response cannot masquerade as a PDF preview")
    require((try? MailAttachmentContent.decode(Data("bad image".utf8), name: "photo.png")) == nil, "broken raster content produces an explicit failure")

    let origin = URL(string: "https://mail.zoho.com")!
    let message = MailMessage(accountID: "fixture", remoteID: "100", folderID: "200", id: "300", origin: origin,
        subject: "Fixture", sender: "sender@example.test", preview: "", date: Date(), attachment: true, unread: false)
    let file = MailAttachment(id: "11", name: "report.pdf", size: pdf.count, cid: "")
    let other = MailAttachment(id: "12", name: "photo.png", size: png.count, cid: "")
    var calls: [(String, String)] = []
    let model = MailAttachmentPreviewModel(message: message) { selected, owner in
        calls.append((selected.id, owner.key))
        return selected.id == file.id ? pdf : png
    }
    require(calls.isEmpty && model.selected == nil, "attachment content is not fetched until requested")
    model.preview(file, allowed: [file, other]); await model.wait()
    require(calls.count == 1 && calls[0].0 == file.id && calls[0].1 == message.key, "conversation attachment fetch retains its owning member identity")
    require(model.content != nil && !model.loading && model.error == nil && model.bytes == pdf, "successful fetch displays content and retains bytes for saving")
    model.preview(file, allowed: [file, other]); await model.wait()
    require(calls.count == 1, "reopening the loaded attachment does not duplicate download")
    model.preview(other, allowed: [file, other]); await model.wait()
    require(model.selected?.id == other.id && model.bytes == png && calls.count == 2, "switching files replaces content with the selected attachment")
    model.close()
    require(model.content == nil && model.bytes == nil && model.selected == nil && !model.loading, "collapse releases attachment content and selection")
    model.preview(file, allowed: [other]); await model.wait()
    require(calls.count == 2 && model.selected == nil, "attachment outside the member's visible file list cannot be requested")

    var attempts = 0
    let retry = MailAttachmentPreviewModel(message: message) { _, _ in
        attempts += 1
        if attempts == 1 { throw MailFailure.auth }
        return pdf
    }
    retry.preview(file, allowed: [file]); await retry.wait()
    require(retry.error != nil && !retry.loading && retry.content == nil, "failed download displays an actionable local error")
    retry.preview(file, allowed: [file]); await retry.wait()
    require(attempts == 2 && retry.error == nil && retry.content != nil, "failed attachment fetch can be retried successfully")

    var continuation: CheckedContinuation<Data, Never>?
    let slow = MailAttachmentPreviewModel(message: message) { _, _ in
        await withCheckedContinuation { continuation = $0 }
    }
    slow.preview(file, allowed: [file])
    while continuation == nil { await Task.yield() }
    require(slow.loading && slow.selected?.id == file.id, "loading state visible while the attachment is pending")
    slow.close(); continuation?.resume(returning: pdf); await Task.yield(); await Task.yield()
    require(slow.content == nil && slow.bytes == nil && !slow.loading, "late response cannot reopen a collapsed preview")
}
