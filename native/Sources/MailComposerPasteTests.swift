import AppKit
import WebKit

/// Focused offline browser tests. Never touches NSPasteboard.general, accounts or mail APIs.
@MainActor func runMailComposerPasteTests(_ require: (Bool, String) -> Void) async {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    func place(_ data: Data, _ type: NSPasteboard.PasteboardType) {
        board.clearContents(); board.setData(data, forType: type)
    }
    func fixture(width: Int, height: Int, noisy: Bool) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        var seed: UInt32 = 0x12345678
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                seed = seed &* 1664525 &+ 1013904223
                bitmap.bitmapData![pixel * 4 + channel] = noisy ? UInt8(truncatingIfNeeded: seed >> 24) : UInt8(80 + channel * 60)
            }
            bitmap.bitmapData![pixel * 4 + 3] = 255
        }
        return bitmap
    }
    let small = fixture(width: 32, height: 20, noisy: false)
    let png = small.representation(using: .png, properties: [:])!
    let editor = WebHTMLComposerHandle()
    defer { editor.dispose() }
    guard let view = editor.webView as? ComposerPasteWebView else { require(false, "composer uses native Paste responder"); return }
    view.pasteboardProvider = { board }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    editor.loadReplyHTML(body: "<div>AB</div>", quote: "<blockquote>Original quote</blockquote>")
    _ = await editor.replaceManagedSignatureHTML("<div>Managed signature</div>", reference: "paste", identity: "fixture:paste", beforeQuote: true, allowInsert: true)
    let initial = await editor.flush()
    func caret(_ offset: Int = 1) async {
        _ = await editor.inspectDOM("const n=document.getElementById('editor').firstElementChild.firstChild,r=document.createRange();r.setStart(n,\(offset));r.collapse(true);const s=getSelection();s.removeAllRanges();s.addRange(r);document.dispatchEvent(new Event('selectionchange'));return true;")
    }
    await caret()
    var changes = 0, errors: [String] = []
    editor.onChange = { changes += 1 }
    editor.onPasteError = { errors.append($0) }
    place(png, .png)
    require(view.responds(to: #selector(ComposerPasteWebView.paste(_:))), "native view exposes the Paste menu action")
    view.paste(nil)
    let pasted = await editor.flush() // No artificial sleep before Save/Send snapshot.
    let shape = await editor.inspectDOM("const p=document.getElementById('editor').firstElementChild;return {images:p.querySelectorAll('img').length,before:p.firstChild.textContent,after:p.lastChild.textContent};") as? [String: Any]
    require(shape?["images"] as? Int == 1 && shape?["before"] as? String == "A" && shape?["after"] as? String == "B", "native Paste inserts exactly one raster at the middle caret")
    require(pasted.html.contains("data:image/png;base64,") && !pasted.outgoingHTML.contains("blob:") && !pasted.outgoingHTML.contains("file:") && !pasted.outgoingHTML.contains("data-ml-"), "image snapshot uses durable raster data and strips internal export metadata")
    require(pasted.signature == initial.signature && pasted.outgoingHTML.contains("Original quote") && changes > 0, "image paste notifies edits and preserves managed signature and quote ownership")
    editor.undo()
    let undone = await editor.flush()
    require(!undone.html.contains("<img") && undone.text.contains("AB"), "single undo removes the pasted image as one edit")
    editor.redo()
    let redone = await editor.flush()
    require(redone.html.contains("data:image/png;base64,"), "redo restores pasted image")
    let restored = WebHTMLComposerHandle()
    defer { restored.dispose() }
    restored.restoreHTML(redone.html, signature: redone.signature)
    let saved = await restored.flush()
    require(saved.outgoingHTML == redone.outgoingHTML && saved.signature == redone.signature, "saved/restored draft retains raster image and signature state")

    // Actual Cmd-V routing without using the system clipboard.
    editor.loadHTML("<div>AB</div>"); _ = await editor.flush(); await caret()
    place(small.tiffRepresentation!, .tiff)
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
    require(view.performKeyEquivalent(with: event), "Cmd-V takes the native screenshot paste path")
    let tiff = await editor.flush()
    require(tiff.html.contains("data:image/png;base64,") && !tiff.html.contains("image/tiff"), "TIFF screenshots transcode to persistent supported PNG")

    // Large noisy image exceeds the old signature-only image/body limit.
    editor.loadHTML("<div>AB</div>"); _ = await editor.flush(); await caret()
    place(fixture(width: 800, height: 600, noisy: true).representation(using: .png, properties: [:])!, .png)
    _ = view.paste(from: board)
    let large = await editor.flush()
    require(large.html.utf8.count > 256 * 1024 && large.html.contains("<img"), "body accepts pasted raster above the former 256KiB signature bound")
    restored.restoreHTML(large.html, signature: nil)
    let largeSaved = await restored.flush()
    require(largeSaved.outgoingHTML == large.outgoingHTML, "large screenshot survives body sanitizer and draft restore")

    let beforeInvalid = await editor.flush()
    place(Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8), .init("public.svg-image"))
    require(view.paste(from: board), "unsupported SVG is consumed rather than pasted as a path")
    place(Data(repeating: 0, count: ComposerPasteImage.maximumInputBytes + 1), .png)
    require(view.paste(from: board), "oversized image is consumed with a recoverable error")
    let afterInvalid = await editor.flush()
    require(errors.count == 2 && afterInvalid.html == beforeInvalid.html && editor.failure == nil, "invalid image errors are visible callbacks without body mutation or sticky editor failure")

    editor.setEditingEnabled(false); _ = await editor.flush()
    place(png, .png); _ = view.paste(from: board)
    let disabled = await editor.flush()
    require(disabled.html == afterInvalid.html, "disabled editor blocks native Paste")
    editor.setEditingEnabled(true); _ = await editor.flush()
    editor.loadHTML("<div>AB</div>"); _ = await editor.flush(); await caret()
    place(Data("plain".utf8), .string)
    require(view.paste(from: board), "text clipboard uses the same reliable native paste path as images")
    let plainPaste = await editor.flush()
    require(plainPaste.text.contains("AplainB"), "native text paste inserts literal text at the body caret")
    editor.loadHTML("<div>AB</div>"); _ = await editor.flush(); await caret()
    _ = await editor.inspectDOM("const d=new DataTransfer();d.setData('text/html','<b>Rich</b><script>bad()</script>');document.getElementById('editor').dispatchEvent(new ClipboardEvent('paste',{clipboardData:d,bubbles:true,cancelable:true}));return true;")
    let rich = await editor.flush()
    let richBold = await editor.inspectDOM("return [...document.getElementById('editor').querySelectorAll('b,strong')].some(n=>n.textContent==='Rich');") as? Bool
    require(richBold == true && !rich.html.contains("script") && rich.text.contains("ARichB"), "existing sanitized rich HTML paste retains bold content and inserts at the caret")
    let tinyImage = "<img src=\"data:image/png;base64,\(png.base64EncodedString())\">"
    editor.loadHTML("<div>AB</div>" + String(repeating: tinyImage, count: 7))
    _ = await editor.flush(); await caret()
    place(png, .png); _ = view.paste(from: board)
    let eightImages = await editor.flush()
    require((try? MailInlineImageSend.prepare(eightImages.outgoingHTML).imageCount) == 8, "eighth body image can be pasted and passes the actual send preflight")
    let oldErrors = errors.count
    _ = view.paste(from: board)
    let ninth = await editor.flush()
    require((try? MailInlineImageSend.prepare(ninth.outgoingHTML).imageCount) == 9 && errors.count == oldErrors,
            "ninth pasted image remains editable and passes the actual send preflight")
    let batch = (0..<12).map { _ -> NSPasteboardItem in
        let item = NSPasteboardItem(); item.setData(png, forType: .png); return item
    }
    board.clearContents(); board.writeObjects(batch)
    _ = view.paste(from: board)
    let batchPasted = await editor.flush()
    require((try? MailInlineImageSend.prepare(batchPasted.outgoingHTML).imageCount) == 21,
            "a 12-image clipboard batch and existing quoted images share the total body budget")
    editor.loadHTML("<div>AB</div>"); _ = await editor.flush(); await caret()
    let beforeBudget = await editor.flush()
    let budgetResult = await editor.inspectDOM("window.ml.capturePaste('budget');return window.ml.pasteImage('<img src=\"data:image/png;base64,\(png.base64EncodedString())\">','budget',1);") as? String
    let afterBudget = await editor.flush()
    require(budgetResult == "size" && beforeBudget.html == afterBudget.html, "production DOM budget gate rejects a paste atomically without inserting partial images")
    restored.restoreHTML("<div><br></div>", signature: nil)
    let emptyDraft = await restored.flush()
    require(restored.failure == nil && !emptyDraft.html.isEmpty && emptyDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "blank saved HTML draft still opens after adding body image validation")
    require(SignatureHTML.maximumBytes == 256 * 1024 && SignatureHTML.sanitize(large.html) == nil, "larger body budget does not widen the signature-specific budget")
    do {
        var draft = MailDraft(accountID: "fixture", from: "owner@example.test", mode: ComposeMode.new.rawValue)
        draft.htmlBody = large.html
        let restoredDraft = try JSONDecoder().decode(MailDraft.self, from: JSONEncoder().encode(draft))
        require(restoredDraft.htmlBody == large.html, "durable draft encoding retains the complete pasted image without truncation")
        var queued = OutboxItem(accountID: "fixture", from: "owner@example.test", to: "to@example.test", cc: "", bcc: "", subject: "Image")
        queued.html = large.outgoingHTML
        let restoredQueue = try JSONDecoder().decode(OutboxItem.self, from: JSONEncoder().encode(queued))
        require(try MailInlineImageSend.prepare(restoredQueue.html).html == large.outgoingHTML, "durable outbox and actual send preflight preserve large pasted screenshot")
    } catch { require(false, "paste persistence fixture: \(error)") }
    require(editor.failure == nil && restored.failure == nil, "paste regression suite finishes without browser bridge failure")
}
