import AppKit
import WebKit

/// Offline layout/selection regressions. Both browsers stay attached to native windows;
/// no accounts, network resources, mail operations or system clipboard are involved.
@MainActor func runMailComposerBodyPlaceholderTests(_ require: (Bool, String) -> Void) async {
    let editor = WebHTMLComposerHandle()
    let restored = WebHTMLComposerHandle()
    let windows = [editor, restored].map { handle in
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = handle.webView
        window.makeKeyAndOrderFront(nil)
        return window
    }
    defer {
        editor.dispose(); restored.dispose()
        windows.forEach { $0.close() }
    }
    let signatureLiteral = "Sender App Signature"
    var signatureText = ""
    var existingBodyText = ""
    let signatureHTML = "<table style=\"font:18pt Georgia;color:#008000\"><tbody><tr><td>Sender App Signature</td></tr></tbody></table>"
    let quoteText = "Quoted original message"

    // Inspect positions and actual text parents, not implementation-specific body markers.
    func shape(_ handle: WebHTMLComposerHandle) async -> [String: Any] {
        await handle.inspectDOM("""
        const root=document.getElementById('editor'), first=root.firstElementChild;
        const sigs=[...root.querySelectorAll('[data-ml-signature]')], sig=sigs[0];
        const quote=root.querySelector('[data-ml-quote]');
        const bodies=[...root.children].filter(n=>!n.hasAttribute('data-ml-signature')&&!n.hasAttribute('data-ml-quote'));
        const body=first&&!first.hasAttribute('data-ml-signature')&&!first.hasAttribute('data-ml-quote')?first:null;
        const css=body?getComputedStyle(body):null;
        const cell=sig?sig.querySelector('td'):null, sc=cell?getComputedStyle(cell):null;
        let typed=null;
        if(body){const walk=document.createTreeWalker(body,NodeFilter.SHOW_TEXT);let n;
          while(n=walk.nextNode()){if(n.textContent.includes('Typed')){typed=getComputedStyle(n.parentElement);break;}}}
        const before=(a,b)=>!!(a&&b&&(a.compareDocumentPosition(b)&Node.DOCUMENT_POSITION_FOLLOWING));
        return {body:!!body,br:!!body&&!!body.querySelector('br'),height:body?body.getBoundingClientRect().height:0,
          family:css?css.fontFamily:'',size:css?css.fontSize:'',color:css?css.color:'',
          bodyCount:bodies.length,bodyText:bodies.map(n=>n.textContent).join(''),
          sigCount:sigs.length,sigText:sig?sig.textContent:'',sigSize:sc?sc.fontSize:'',sigColor:sc?sc.color:'',
          beforeSig:before(body,sig),beforeQuote:before(body,quote),sigBeforeQuote:before(sig,quote),
          quoteText:quote?quote.textContent:'',typedFamily:typed?typed.fontFamily:'',
          typedSize:typed?typed.fontSize:'',typedColor:typed?typed.color:''};
        """) as? [String: Any] ?? [:]
    }
    func blank(_ value: [String: Any]) -> Bool {
        value["body"] as? Bool == true && value["br"] as? Bool == true &&
        (value["height"] as? Double ?? 0) >= 16 && value["bodyCount"] as? Int == 1 &&
        (value["bodyText"] as? String ?? "!").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func defaultFont(_ value: [String: Any], typed: Bool = false) -> Bool {
        let prefix = typed ? "typed" : ""
        let family = value[typed ? "typedFamily" : "family"] as? String ?? ""
        return family.lowercased().hasPrefix("verdana") &&
            value[prefix.isEmpty ? "size" : "typedSize"] as? String == "16px" &&
            value[prefix.isEmpty ? "color" : "typedColor"] as? String == "rgb(0, 0, 0)"
    }
    func install(_ handle: WebHTMLComposerHandle, identity: String = "fixture:sender", beforeQuote: Bool = false) async {
        _ = await handle.replaceManagedSignatureHTML(signatureHTML, reference: "body-placeholder", identity: identity,
                                                     beforeQuote: beforeQuote, allowInsert: true)
    }

    // New message: no preliminary Enter or click is needed before signature insertion.
    editor.setText("")
    await install(editor)
    let fresh = await editor.flush()
    let initialShape = await shape(editor)
    signatureText = initialShape["sigText"] as? String ?? ""
    require(signatureText.trimmingCharacters(in: .whitespacesAndNewlines) == signatureLiteral,
            "canonical table signature contains exactly the authored sender text apart from Tidy layout whitespace")
    require(blank(initialShape) && initialShape["beforeSig"] as? Bool == true,
            "new message has one visible BR body block before its managed signature")
    require(defaultFont(initialShape), "new empty body computes to Verdana 16px black")
    require(initialShape["sigCount"] as? Int == 1 && initialShape["sigText"] as? String == signatureText &&
            initialShape["sigSize"] as? String == "24px" && initialShape["sigColor"] as? String == "rgb(0, 128, 0)" && fresh.signature != nil,
            "table signature retains exact sender text, 18pt green styling and managed ownership")
    editor.focus(); editor.insertHTML("Typed")
    let typed = await editor.flush()
    let typedShape = await shape(editor)
    require(typedShape["bodyText"] as? String == "Typed" && typedShape["beforeSig"] as? Bool == true && defaultFont(typedShape, typed: true),
            "focus then insert types before signature using the actual text parent's default font")
    require(typed.signature == fresh.signature && typedShape["sigCount"] as? Int == 1 && typedShape["sigText"] as? String == signatureText,
            "typing into fresh body leaves exact signature text, baseline and owner unchanged")

    // Reply bodies arrive in both common empty forms; quote boundary is structural.
    for bodyHTML in ["<div></div>", "<div><br></div>"] {
        editor.loadReplyHTML(body: bodyHTML, quote: "<blockquote>\(quoteText)</blockquote>")
        _ = await editor.flush()
        let beforeReplySignature = await shape(editor)
        let expectedQuote = beforeReplySignature["quoteText"] as? String ?? ""
        require(expectedQuote.trimmingCharacters(in: .whitespacesAndNewlines) == quoteText, "canonical reply quote retains authored text before signature insertion")
        await install(editor, beforeQuote: true)
        let reply = await editor.flush()
        let replyShape = await shape(editor)
        require(blank(replyShape) && defaultFont(replyShape) && replyShape["beforeSig"] as? Bool == true &&
                replyShape["sigBeforeQuote"] as? Bool == true && replyShape["beforeQuote"] as? Bool == true,
                "reply \(bodyHTML) normalizes to visible default body / signature / quote order")
        editor.focus(); editor.insertHTML("Typed")
        let replyTyped = await editor.flush()
        let result = await shape(editor)
        require(result["bodyText"] as? String == "Typed" && defaultFont(result, typed: true) && result["beforeSig"] as? Bool == true,
                "reply \(bodyHTML) immediately accepts default-font typing above signature")
        require(reply.signature != nil && replyTyped.signature == reply.signature && result["sigCount"] as? Int == 1 &&
                result["sigText"] as? String == signatureText && result["quoteText"] as? String == expectedQuote,
                "reply \(bodyHTML) typing preserves signature baseline, exact sender text and original quote")
    }

    editor.loadHTML("<div></div>")
    _ = await editor.flush()
    let emptyLoad = await shape(editor)
    require(blank(emptyLoad) && defaultFont(emptyLoad), "ordinary empty-div load gains one clickable default-font line")
    editor.focus(); editor.insertHTML("Typed")
    _ = await editor.flush()
    let emptyTyped = await shape(editor)
    require(emptyTyped["bodyText"] as? String == "Typed" && defaultFont(emptyTyped, typed: true),
            "normalized empty-div load accepts typing without Enter")

    // Build a genuine old signature-only saved draft by removing only the source body.
    editor.setText(""); await install(editor)
    let source = await editor.flush()
    let removed = await editor.inspectDOM("""
    const root=document.getElementById('editor'), first=root.firstElementChild;
    if(!first||first.hasAttribute('data-ml-signature')||first.hasAttribute('data-ml-quote'))return false;
    first.remove();return true;
    """) as? Bool
    let legacy = await editor.flush()
    require(removed == true && source.signature != nil && legacy.signature == source.signature,
            "signature-only legacy fixture removes body only and retains source ownership metadata")
    restored.restoreHTML(legacy.html, signature: legacy.signature)
    let legacyRestored = await restored.flush()
    let legacyShape = await shape(restored)
    require(blank(legacyShape) && defaultFont(legacyShape) && legacyShape["beforeSig"] as? Bool == true,
            "saved signature-only draft restores a visible default-font body ahead of signature")
    require(legacyRestored.signature == source.signature && legacyShape["sigCount"] as? Int == 1 && legacyShape["sigText"] as? String == signatureText,
            "legacy restore adds body without changing signature baseline, owner, count or exact text")

    restored.restoreHTML("", signature: nil)
    let emptyDraft = await restored.flush()
    let emptyDraftShape = await shape(restored)
    require(restored.failure == nil && emptyDraft.signature == nil && blank(emptyDraftShape) && defaultFont(emptyDraftShape),
            "saved empty-string draft restores successfully with a clickable default body line")
    restored.focus(); restored.insertHTML("Typed")
    _ = await restored.flush()
    let restoredTyped = await shape(restored)
    require(restoredTyped["bodyText"] as? String == "Typed" && defaultFont(restoredTyped, typed: true),
            "empty saved draft accepts immediate typing in its body")

    editor.loadHTML("<div>Existing body</div>")
    _ = await editor.flush()
    let beforeExistingSignature = await shape(editor)
    existingBodyText = beforeExistingSignature["bodyText"] as? String ?? ""
    require(existingBodyText.trimmingCharacters(in: .whitespacesAndNewlines) == "Existing body", "canonical existing body retains authored text before signature changes")
    await install(editor)
    let existing = await shape(editor)
    require(existing["bodyCount"] as? Int == 1 && existing["bodyText"] as? String == existingBodyText && existing["beforeSig"] as? Bool == true,
            "existing typed body receives signature without an extra spacer paragraph")
    await install(editor, identity: "fixture:other-sender")
    _ = await editor.flush()
    let switched = await shape(editor)
    require(switched["bodyCount"] as? Int == 1 && switched["bodyText"] as? String == existingBodyText &&
            switched["sigCount"] as? Int == 1 && switched["sigText"] as? String == signatureText,
            "switching selected identity replaces one signature without duplicating body paragraphs")
    _ = await editor.replaceManagedSignatureHTML(nil, reference: "body-placeholder", identity: "fixture:other-sender", beforeQuote: false, allowInsert: true)
    let withoutSignature = await shape(editor)
    require(withoutSignature["bodyCount"] as? Int == 1 && withoutSignature["sigCount"] as? Int == 0 && withoutSignature["bodyText"] as? String == existingBodyText,
            "signature off preserves existing body without adding empty paragraphs")
    await install(editor)
    let toggled = await shape(editor)
    require(toggled["bodyCount"] as? Int == 1 && toggled["sigCount"] as? Int == 1 && toggled["bodyText"] as? String == existingBodyText,
            "signature on again leaves exactly one existing body and one exact sender signature")

    // A dynamic load may have no initial body at all: insertion still repairs the top line.
    editor.loadHTML("")
    await install(editor)
    _ = await editor.flush()
    let dynamic = await shape(editor)
    require(blank(dynamic) && defaultFont(dynamic) && dynamic["beforeSig"] as? Bool == true && dynamic["sigText"] as? String == signatureText,
            "programmatic signature insertion after blank dynamic load ensures body before signature")
    require(editor.failure == nil && restored.failure == nil && windows.allSatisfy { $0.contentView?.window === $0 },
            "body placeholder fixtures finish without bridge failure and keep both browsers window-attached")
}
