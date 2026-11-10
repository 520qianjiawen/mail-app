import AppKit
import WebKit

/// Deliberately exercises the production browser, not NSTextView's legacy importer.
@MainActor func runMailSignatureHTMLTests(_ require: (Bool, String) -> Void) async {
    let pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII="
    let rich = "<table style=\"border-collapse:collapse;border:3px solid #123456\"><tr><td style=\"border:2px solid #654321;padding:7px\"><img width=\"1\" height=\"1\" src=\"\(pixel)\"><span style=\"font-family:Georgia;font-size:18pt;color:#123456;text-transform:uppercase;letter-spacing:3px\">Logo name</span></td></tr></table>"
    let editor = WebHTMLComposerHandle()
    // Give WebKit a real app view hierarchy without presenting or sending mail.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = editor.webView
    defer { window.contentView = nil; window.close() }
    editor.setText("Authored body")
    require(editor.canonicalHTML.contains("Authored body"), "HTML canonical content exists before mounted browser finishes loading")
    let inserted = await editor.replaceManagedSignatureHTML(rich, reference: "a", identity: "account:a", beforeQuote: false, allowInsert: true)
    require(inserted == .changed, "real WK DOM inserts managed rich signature")
    var snapshot = await editor.flush()
    require(snapshot.signature != nil && snapshot.html.contains("data-ml-signature"), "draft snapshot records exact DOM wrapper ownership")
    require(snapshot.outgoingHTML.contains(pixel) && !snapshot.outgoingHTML.contains("data-ml-"), "outgoing HTML keeps logo while stripping all ownership metadata")
    require(snapshot.outgoingHTML.contains("font:12pt Verdana"), "outgoing HTML carries default body typography, not only page CSS")
    let visual = await editor.inspectDOM("const span=document.querySelector('[data-ml-signature] span'),cell=document.querySelector('td'),table=document.querySelector('table');return {transform:getComputedStyle(span).textTransform,spacing:getComputedStyle(span).letterSpacing,color:getComputedStyle(span).color,font:getComputedStyle(span).fontFamily,size:getComputedStyle(span).fontSize,border:getComputedStyle(cell).borderTopWidth,tableBorder:getComputedStyle(table).borderTopWidth,paper:getComputedStyle(document.body).backgroundColor};") as? [String: String]
    require(visual?["transform"] == "uppercase" && visual?["spacing"] == "3px", "WebKit computed text-transform and letter-spacing retain authored CSS")
    require(visual?["border"] == "2px" && visual?["tableBorder"] == "3px", "WebKit computed table and cell borders remain visible")
    require(visual?["font"]?.contains("Georgia") == true && visual?["size"] == "24px", "signature font and 18pt typography are faithfully rendered")
    require(visual?["color"] == "rgb(18, 52, 86)" && visual?["paper"] == "rgb(255, 255, 255)", "authored dark signature colors stay unchanged on default white paper")
    let logo = await editor.inspectDOM("const i=document.querySelector('img'); if(!i.complete)await new Promise(r=>{i.onload=r;i.onerror=r;setTimeout(r,2000)});return i.naturalWidth;") as? Int
    require(logo == 1, "actual WK image decoder renders embedded logo")
    _ = await editor.inspectDOM("const n=document.getElementById('editor').firstElementChild.firstChild;const r=document.createRange();r.setStart(n,4);r.collapse(true);const s=getSelection();s.removeAllRanges();s.addRange(r);return true;")
    let switched = await editor.replaceManagedSignatureHTML(rich.replacingOccurrences(of: "Logo name", with: "Other name"), reference: "b", identity: "account:b", beforeQuote: false, allowInsert: true)
    require(switched == .changed, "unchanged DOM-owned signature switches identity")
    let caret = await editor.inspectDOM("return getSelection().anchorOffset;") as? Int
    require(caret == 4, "signature switching preserves body caret")
    snapshot = await editor.flush()
    require(snapshot.text.contains("Authored body") && snapshot.outgoingHTML.contains("Other name") && snapshot.outgoingHTML.contains("letter-spacing"), "identity switch preserves body, logo and inline CSS")
    let restored = WebHTMLComposerHandle(); restored.restoreHTML(snapshot.html, signature: snapshot.signature)
    let restoredSnapshot = await restored.flush()
    require(restoredSnapshot.signature == snapshot.signature, "HTML draft restores ownership only with exact DOM proof")
    let restoredSwitch = await restored.replaceManagedSignatureHTML(rich, reference: "a", identity: "account:a", beforeQuote: false, allowInsert: true)
    require(restoredSwitch == .changed, "verified HTML draft remains safely replaceable")
    let none = await restored.replaceManagedSignatureHTML(nil, reference: "none", identity: "account:none", beforeQuote: false, allowInsert: true)
    let afterNone = await restored.replaceManagedSignatureHTML(rich, reference: "again", identity: "account:again", beforeQuote: false, allowInsert: true)
    require(none == .changed && afterNone == .changed, "programmatic identity A to none to C remains replaceable")
    _ = await restored.inspectDOM("document.querySelector('[data-ml-signature] span').textContent='User edited signature';document.getElementById('editor').dispatchEvent(new InputEvent('input',{bubbles:true}));return true;")
    let protectedEdit = await restored.replaceManagedSignatureHTML(rich, reference: "c", identity: "account:c", beforeQuote: false, allowInsert: true)
    require(protectedEdit == .protected, "editing signature revokes DOM ownership instead of overwriting user text")
    let edited = await restored.flush()
    require(edited.outgoingHTML.contains("User edited signature") && edited.signature == nil, "edited signature survives export without managed proof")
    let tampered = WebHTMLComposerHandle(); tampered.restoreHTML(snapshot.html.replacingOccurrences(of: "Other name", with: "Tampered"), signature: snapshot.signature)
    let tamperResult = await tampered.replaceManagedSignatureHTML(rich, reference: "d", identity: "account:d", beforeQuote: false, allowInsert: true)
    require(tamperResult == .protected, "modified draft baseline never grants replacement ownership")
    let deleted = WebHTMLComposerHandle(); deleted.restoreHTML(snapshot.html, signature: snapshot.signature)
    _ = await deleted.inspectDOM("document.querySelector('[data-ml-signature]').remove();return true;")
    let deletedResult = await deleted.replaceManagedSignatureHTML(rich, reference: "d", identity: "account:d", beforeQuote: false, allowInsert: true)
    require(deletedResult == .protected, "deleted signature is not silently reinserted")
    let reply = WebHTMLComposerHandle()
    reply.loadReplyHTML(body: "<div>Reply body</div>", quote: "<blockquote style=\"font:20pt Georgia;color:#654321\">Quoted original</blockquote>")
    _ = await reply.replaceManagedSignatureHTML(rich, reference: "a", identity: "account:a", beforeQuote: true, allowInsert: true)
    let order = await reply.inspectDOM("const s=document.querySelector('[data-ml-signature]'),q=document.querySelector('[data-ml-quote]');return Boolean(s.compareDocumentPosition(q)&Node.DOCUMENT_POSITION_FOLLOWING);") as? Bool
    require(order == true, "reply signature uses a structural quote boundary")
    let quoteCSS = await reply.inspectDOM("return getComputedStyle(document.querySelector('blockquote')).fontSize;") as? String
    require(quoteCSS == "26.6667px" || quoteCSS == "26.666666px", "reply quote retains independent original typography")
    let replyMessage = MailMessage(accountID: "fixture", remoteID: "100", folderID: "500", id: "701",
                                   origin: URL(string: "https://mail.zoho.com")!, subject: "Background reply",
                                   sender: "sender@example.test", preview: "", date: Date(), attachment: false,
                                   unread: false)
    let replySource = MailDetail(message: replyMessage, from: replyMessage.sender, to: "reader@example.test",
                                 cc: "", replyTo: "", html: "<blockquote>Original message</blockquote>",
                                 attachments: [], inline: [], replyHeadersChecked: true)
    let backgroundReply = WebHTMLComposerHandle()
    let backgroundWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                                    styleMask: [.titled], backing: .buffered, defer: false)
    backgroundWindow.isReleasedWhenClosed = false
    backgroundWindow.contentView = backgroundReply.webView
    backgroundReply.loadReplyForMessageInBackground(body: "", source: replySource)
    require(backgroundReply.isPreparingReply, "reply preparation exposes a busy state before processing its quote")
    let backgroundSnapshot = await backgroundReply.flush()
    require(!backgroundReply.isPreparingReply && backgroundSnapshot.outgoingHTML.contains("Original message"),
            "background reply preparation completes before flush and preserves the original quote")
    backgroundWindow.contentView = nil
    backgroundWindow.close()
    backgroundReply.dispose()
    let noQuote = WebHTMLComposerHandle(); noQuote.setText(ComposeDocument.quoteMarker)
    let guessed = await noQuote.replaceManagedSignatureHTML(rich, reference: "a", identity: "account:a", beforeQuote: true, allowInsert: true)
    require(guessed == .protected, "quote-like body text is never mistaken for structural quote ownership")
    let plain = WebHTMLComposerHandle(); plain.setText("Plain new body")
    let defaultStyle = await plain.inspectDOM("const e=document.getElementById('editor').firstElementChild;return {font:getComputedStyle(e).fontFamily,size:getComputedStyle(e).fontSize};") as? [String: String]
    require(defaultStyle?["size"] == "16px" && defaultStyle?["font"]?.contains("Verdana") == true, "new compose default 12pt equals actual WebKit 16px")
    plain.focus(); plain.setFontSize(14); plain.toggle(.boldFontMask)
    let commandDOM = await plain.inspectDOM("return document.getElementById('editor').innerHTML;") as? String ?? ""
    require(commandDOM.contains("14pt") || commandDOM.contains("18.6667px"), "font-size toolbar dispatches to browser DOM")
    _ = await plain.inspectDOM("const e=document.getElementById('editor');e.append(document.createTextNode('LAST_KEYSTROKE'));e.dispatchEvent(new InputEvent('input',{bubbles:true}));return true;")
    let last = await plain.flush()
    require(last.text.contains("LAST_KEYSTROKE") && last.outgoingHTML.contains("LAST_KEYSTROKE"), "awaited flush captures the last input event before save/send")
    plain.loadHTML("<script>window.__signatureExecuted=true</script><img src=\"file:///etc/passwd\" onerror=\"window.__signatureExecuted=true\"><a href=\"javascript:alert(1)\">Bad</a><iframe src=\"https://example.invalid\"></iframe><p style=\"color:#123456\">Allowed</p>")
    let sanitized = await plain.flush()
    require(!sanitized.outgoingHTML.contains("onerror") && !sanitized.outgoingHTML.contains("<script") && !sanitized.outgoingHTML.contains("file:") && !sanitized.outgoingHTML.contains("javascript:") && !sanitized.outgoingHTML.contains("iframe"), "imported active content, events, navigation and local-file URLs are removed")
    let executed: Bool? = await withCheckedContinuation { continuation in
        plain.webView.evaluateJavaScript("window.__signatureExecuted === true", completionHandler: { value, error in
            continuation.resume(returning: error == nil ? value as? Bool : nil)
        })
    }
    require(executed == false, "imported executable HTML never runs in the page world (successful explicit page-world query)")
    plain.loadHTML("<img src=\"https://example.invalid/logo.png\"><p>Remote</p>")
    let blocked = await plain.inspectDOM("return document.querySelector('img').hasAttribute('src');") as? Bool
    require(blocked == false, "remote image requests remain off until explicit per-editor consent")
    let remoteOut = await plain.flush()
    require(remoteOut.outgoingHTML.contains("https://example.invalid/logo.png") && !remoteOut.outgoingHTML.contains("mlimage:"), "remote image toggle does not rewrite authored outgoing source URLs")
    // A signature in quoted mail must retain its authored URLs even when the
    // editor does not load remote images. Draft restoration must do the same.
    let quoteURLs = (0..<20).map { "https://example.invalid/signature-\($0).png" }
    let quoteImages = quoteURLs.map { "<img alt='signature' src='\($0)'>" }.joined()
    let quoted = WebHTMLComposerHandle()
    quoted.loadReplyHTML(body: "<p>Reply fixture</p>", quote: "<blockquote>\(quoteImages)</blockquote>")
    let quoteSnapshot = await quoted.flush()
    require(quoteURLs.allSatisfy { quoteSnapshot.outgoingHTML.contains($0) }, "all 20 quoted signature URLs survive reply export while external image loading is off")
    let quoteRestored = WebHTMLComposerHandle()
    quoteRestored.restoreHTML(quoteSnapshot.html, signature: quoteSnapshot.signature)
    let quoteRestoredSnapshot = await quoteRestored.flush()
    require(quoteURLs.allSatisfy { quoteRestoredSnapshot.outgoingHTML.contains($0) }, "all 20 quoted signature URLs survive draft save and restoration")
    for isReply in [false, true] {
        let blank = WebHTMLComposerHandle()
        if isReply { blank.loadReplyHTML(body: "<div><br></div>", quote: "<blockquote style=\"font:26pt Georgia\">Quote</blockquote>") }
        else { blank.setText("") }
        _ = await blank.replaceManagedSignatureHTML(rich, reference: "large", identity: "account:a", beforeQuote: isReply, allowInsert: true)
        let before = await blank.flush().signature
        blank.focus(); blank.command("insertText", "typedbody")
        let typed = await blank.flush()
        let actual = await blank.inspectDOM("const n=document.getElementById('editor').firstElementChild;const c=getComputedStyle(n);return {text:n.innerText,size:c.fontSize,weight:c.fontWeight,font:c.fontFamily};") as? [String: String]
        require(actual?["text"]?.contains("typedbody") == true && actual?["size"] == "16px" && actual?["weight"] == "400" && actual?["font"]?.contains("Verdana") == true, "empty \(isReply ? "reply" : "new") typing uses body 12pt normal, not signature or quote typography")
        require(typed.signature == before && typed.signature != nil, "empty \(isReply ? "reply" : "new") body typing preserves exact signature baseline")
        blank.dispose()
    }
    require(editor.failure == nil && restored.failure == nil && reply.failure == nil && plain.failure == nil, "production isolated-world browser operations complete without JS errors")
    for handle in [editor, restored, tampered, deleted, reply, noQuote, plain] { handle.dispose() }
}
