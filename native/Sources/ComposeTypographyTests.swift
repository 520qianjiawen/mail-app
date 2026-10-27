import AppKit

/// Check the actual browser commands used by the compose toolbar, not legacy AppKit formatting.
@MainActor func runComposeTypographyTests(_ require: (Bool, String) -> Void) async {
    let editor = WebHTMLComposerHandle()
    defer { editor.dispose() }
    editor.loadReplyHTML(body: "<div>Typed reply body</div>", quote: "<blockquote style='font-family:Georgia;font-size:20pt;color:#654321'>Original quote</blockquote>")
    let signature = "<div><span style='font-family:Georgia;font-size:18pt;color:#123456'>Independent signature</span></div>"
    _ = await editor.replaceManagedSignatureHTML(signature, reference: "typography", identity: "fixture:typography", beforeQuote: true, allowInsert: true)
    var reportedFont: String?, reportedSize: CGFloat?
    editor.onSelection = { reportedFont = $0; reportedSize = $1 }
    _ = await editor.inspectDOM("const p=document.getElementById('editor').firstElementChild,r=document.createRange();r.selectNodeContents(p);const s=getSelection();s.removeAllRanges();s.addRange(r);document.dispatchEvent(new Event('selectionchange'));return true;")
    editor.setFontFamily("Arial")
    editor.setFontSize(15)
    editor.toggle(.boldFontMask)
    editor.toggle(.italicFontMask)
    editor.toggleUnderline()
    editor.toggleStrike()
    editor.setForeground(.red)
    editor.setHighlight(.yellow)
    let formatted = await editor.flush()
    let actual = await editor.inspectDOM("""
        const body=document.getElementById('editor').firstElementChild;
        const walker=document.createTreeWalker(body,NodeFilter.SHOW_TEXT);let text;
        while(text=walker.nextNode())if(text.textContent.includes('Typed reply body'))break;
        if(!text)return null;
        const leaf=text.parentElement,c=getComputedStyle(leaf);let decorations=[];
        for(let p=leaf;p&&p!==document.getElementById('editor');p=p.parentElement)decorations.push(getComputedStyle(p).textDecorationLine);
        const sig=getComputedStyle(document.querySelector('[data-ml-signature] span'));
        const quote=getComputedStyle(document.querySelector('blockquote'));
        return {font:c.fontFamily,size:parseFloat(c.fontSize),weight:c.fontWeight,italic:c.fontStyle,color:c.color,highlight:c.backgroundColor,decorations:decorations.join(' '),signatureSize:sig.fontSize,signatureColor:sig.color,quoteSize:quote.fontSize,quoteColor:quote.color};
        """) as? [String: Any]
    require(actual?["font"] as? String == "Arial" && abs((actual?["size"] as? Double ?? 0) - 20) < 0.001,
            "reply font controls render Arial 15pt as actual 20px")
    require(actual?["weight"] as? String == "700" && actual?["italic"] as? String == "italic",
            "browser bold and italic toolbar commands affect the selected reply text")
    let decorations = actual?["decorations"] as? String ?? ""
    require(decorations.contains("underline") && decorations.contains("line-through"),
            "browser underline and strikethrough commands retain painted decorations")
    require(actual?["color"] as? String == "rgb(255, 0, 0)" && actual?["highlight"] as? String == "rgb(255, 255, 0)",
            "browser text and highlight color commands apply selected colors")
    require(actual?["signatureSize"] as? String == "24px" && actual?["signatureColor"] as? String == "rgb(18, 52, 86)" && actual?["quoteColor"] as? String == "rgb(101, 67, 33)",
            "formatting reply body leaves signature and quote colors and signature 18pt size intact")
    let quoteSize = Double((actual?["quoteSize"] as? String ?? "").replacingOccurrences(of: "px", with: "")) ?? 0
    require(abs(quoteSize - 26.6667) < 0.01, "reply quote preserves its independent 20pt size after toolbar changes")
    require(reportedFont == "Arial" && abs((reportedSize ?? 0) - 15) < 0.01,
            "selection feedback reports actual font and point size for toolbar display")
    require(formatted.outgoingHTML.contains("Typed reply body") && formatted.outgoingHTML.contains("Independent signature") && formatted.outgoingHTML.contains("Original quote") && !formatted.outgoingHTML.contains("data-ml-"),
            "formatted reply export preserves all three regions without private metadata")
    let restored = WebHTMLComposerHandle()
    defer { restored.dispose() }
    restored.restoreHTML(formatted.html, signature: formatted.signature)
    let saved = await restored.flush()
    require(saved.outgoingHTML == formatted.outgoingHTML && saved.signature == formatted.signature,
            "HTML draft restore preserves authored typography and managed signature exactly")
    require(editor.failure == nil && restored.failure == nil, "typography checks complete without browser bridge errors")
}
