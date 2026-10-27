import AppKit
import WebKit

/// Real native reply-editor Paste regression tests; the unique board is the only clipboard read.
/// Keep these separate from image fixtures so Cmd-V text regressions cannot hide behind DOM paste events.
@MainActor func runMailComposerTextPasteTests(_ require: (Bool, String) -> Void) async {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let editor = WebHTMLComposerHandle()
    defer { editor.dispose() }
    guard let view = editor.webView as? ComposerPasteWebView else {
        require(false, "text paste uses the production native composer responder"); return
    }
    var clipboardReads = 0
    view.pasteboardProvider = { clipboardReads += 1; return board }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 430))
    view.frame = NSRect(x: 0, y: 40, width: 700, height: 390)
    let otherField = NSTextField(frame: NSRect(x: 10, y: 5, width: 300, height: 24))
    container.addSubview(view); container.addSubview(otherField)
    window.contentView = container
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    let pasteSelector = #selector(ComposerPasteWebView.paste(_:))
    let menuItem = NSMenuItem(title: "Paste", action: pasteSelector, keyEquivalent: "v")
    menuItem.keyEquivalentModifierMask = .command
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                characters: "v", charactersIgnoringModifiers: "v",
                                isARepeat: false, keyCode: 9)!
    var changes = 0
    var errors: [String] = []
    editor.onChange = { changes += 1 }
    editor.onPasteError = { errors.append($0) }

    func place(text: String? = nil, html: String? = nil) {
        board.clearContents()
        if let text { board.setString(text, forType: .string) }
        if let html { board.setString(html, forType: .html) }
    }
    func reset(_ body: String = "<div><br></div>", offset: Int? = nil) async -> WebHTMLSnapshot {
        editor.loadReplyHTML(body: body, quote: "<blockquote>Original reply quote</blockquote>")
        _ = await editor.replaceManagedSignatureHTML("<div>Managed reply signature</div>",
                reference: "text-paste", identity: "fixture:text-paste", beforeQuote: true, allowInsert: true)
        editor.focus()
        _ = await editor.flush()
        _ = window.makeFirstResponder(view)
        let position = offset.map { "r.setStart(p.firstChild,\($0));" } ?? "r.setStart(p,0);"
        _ = await editor.inspectDOM("const root=document.getElementById('editor'),p=root.firstElementChild,r=document.createRange();root.focus();\(position)r.collapse(true);const s=getSelection();s.removeAllRanges();s.addRange(r);document.dispatchEvent(new Event('selectionchange'));return true;")
        return await editor.flush()
    }
    func bodyText() async -> String? {
        await editor.inspectDOM("return document.getElementById('editor').firstElementChild.textContent;") as? String
    }

    let initial = await reset()
    place(text: "Reply pasted with ⌘V")
    require(view.performKeyEquivalent(with: event), "native Cmd-V consumes plain text in an empty reply editor")
    let keyboard = await editor.flush() // Intentionally no sleep or polling before Save/Send.
    require(keyboard.text.contains("Reply pasted with ⌘V") && changes > 0,
            "immediate flush includes native Cmd-V text and edit notification")
    require(keyboard.signature == initial.signature && keyboard.outgoingHTML.contains("Original reply quote") && keyboard.outgoingHTML.contains("Managed reply signature"),
            "plain-text reply paste preserves managed signature ownership and quote")
    let order = await editor.inspectDOM("const r=document.getElementById('editor');return r.textContent.indexOf('Reply pasted with ⌘V')<r.textContent.indexOf('Managed reply signature')&&r.textContent.indexOf('Managed reply signature')<r.textContent.indexOf('Original reply quote');") as? Bool
    require(order == true, "reply text lands before the managed signature and quoted message")

    _ = await reset("<div>AB</div>", offset: 1)
    let unicode = "你好 👩🏽‍💻 café <tag> & value\nsecond line\n第三行"
    place(text: unicode)
    require(view.paste(from: board), "production paste(from:) handles Unicode multiline plain text")
    let multiline = await editor.flush()
    require(multiline.text.contains("你好 👩🏽‍💻 café <tag> & value") && multiline.text.contains("second line") && multiline.text.contains("第三行"),
            "Unicode, angle brackets, ampersands and multiline clipboard content survive native Paste")
    let escaped = await editor.inspectDOM("const root=document.getElementById('editor'),sig=root.querySelector('[data-ml-signature]'),range=document.createRange();range.setStart(root,0);range.setEndBefore(sig);const p=document.createElement('div');p.append(range.cloneContents());return !p.querySelector('tag')&&p.textContent.startsWith('A你好')&&p.textContent.trimEnd().endsWith('第三行B')&&(p.innerHTML.includes('<br')||p.querySelectorAll('div,p').length>0);") as? Bool
    require(escaped == true && multiline.text.contains("A" + unicode + "B") && multiline.outgoingHTML.contains("&lt;tag&gt;") && multiline.outgoingHTML.contains("&amp;"),
            "text is escaped rather than interpreted as markup and preserves the middle caret and line breaks")

    _ = await reset("<div>AB</div>", offset: 1)
    place(text: "MENU")
    require(NSApp.sendAction(pasteSelector, to: view, from: menuItem), "AppKit Paste menu action targets the production view")
    _ = await editor.flush()
    require(await bodyText() == "AMENUB", "actual menu action inserts plain text at the saved caret")

    _ = await reset("<div>AB</div>", offset: 1)
    place(text: "DIRECT")
    let readsBeforeMenu = clipboardReads
    view.paste(nil)
    _ = await editor.flush()
    require(await bodyText() == "ADIRECTB" && clipboardReads == readsBeforeMenu + 1,
            "view.paste(nil) reads the injected board through the production clipboard hook")

    _ = await reset("<div>AB</div>", offset: 1)
    place(text: "WINDOW")
    // An app menu is not installed by every offline runner. Exercise NSWindow's actual
    // key-equivalent route, then explicitly exercise the override if AppKit did not route it.
    let routed = window.performKeyEquivalent(with: event)
    let windowSnapshot = await editor.flush()
    if routed {
        require(windowSnapshot.text.contains("AWINDOWB"), "NSWindow Cmd-V routing inserts clipboard text")
    } else {
        require(!windowSnapshot.text.contains("WINDOW"), "absent app-menu routing does not mutate reply body")
        require(view.performKeyEquivalent(with: event), "explicit native key-equivalent override handles Cmd-V without app menu")
        _ = await editor.flush()
        require(await bodyText() == "AWINDOWB", "native override works when the offline runner has no main menu")
    }

    _ = await reset("<div>AB</div>", offset: 1)
    place(html: "<b>Rich only</b>")
    require(view.paste(from: board), "HTML-only native clipboard is consumed")
    let richOnly = await editor.flush()
    let boldOnly = await editor.inspectDOM("return [...document.getElementById('editor').querySelectorAll('b,strong')].some(n=>n.textContent==='Rich only');") as? Bool
    require(boldOnly == true && richOnly.text.contains("ARich onlyB"), "HTML-only native Paste retains bold formatting at the caret")

    _ = await reset("<div>AB</div>", offset: 1)
    place(text: "PLAIN FALLBACK MUST NOT WIN", html: "<b>Preferred rich</b><script>window.__pasteExecuted=true</script><i> retained</i>")
    view.paste(nil)
    let rich = await editor.flush()
    let richShape = await editor.inspectDOM("const r=document.getElementById('editor');return [...r.querySelectorAll('b,strong')].some(n=>n.textContent==='Preferred rich')&&[...r.querySelectorAll('i,em')].some(n=>n.textContent.trim()==='retained')&&!r.querySelector('script')&&window.__pasteExecuted!==true;") as? Bool
    require(richShape == true && rich.text.contains("APreferred rich retainedB") && !rich.text.contains("PLAIN FALLBACK") && !rich.html.contains("__pasteExecuted"),
            "HTML wins over text while script removal preserves valid rich content rather than degrading to fallback")

    _ = await reset("<div>AB</div>", offset: 1)
    place(text: "1")
    require(view.paste(from: board), "first rapid text paste is handled")
    place(text: "2")
    require(view.paste(from: board), "second rapid text paste is handled")
    let rapid = await editor.flush()
    let rapidText = await bodyText()
    require(rapidText?.filter { $0 == "1" }.count == 1 && rapidText?.filter { $0 == "2" }.count == 1 && rapid.text.contains("Original reply quote"),
            "rapid pastes snapshot both clipboard values once without losing content on immediate flush")

    let beforeDisabled = await editor.flush()
    editor.setEditingEnabled(false); _ = await editor.flush()
    place(text: "BLOCKED", html: "<b>BLOCKED HTML</b>")
    _ = view.paste(from: board)
    view.paste(nil)
    let disabled = await editor.flush()
    require(disabled.html == beforeDisabled.html, "disabled reply editor blocks both direct and menu text/HTML paste")
    editor.setEditingEnabled(true); _ = await editor.flush()

    _ = await reset("<div>AB</div>", offset: 1)
    let beforeEmpty = await editor.flush()
    place()
    _ = view.paste(from: board)
    let empty = await editor.flush()
    require(empty.html == beforeEmpty.html && editor.failure == nil, "empty unique clipboard leaves reply body intact")

    place(text: String(repeating: "x", count: 1024 * 1024 + 1))
    let errorCount = errors.count
    require(view.paste(from: board), "oversized plain-text clipboard is consumed rather than forwarded")
    let oversized = await editor.flush()
    require(errors.count == errorCount + 1 && oversized.html == empty.html && editor.failure == nil,
            "text above 1MiB reports a visible recoverable error without mutation or sticky failure")
    place(text: "RECOVERED")
    _ = view.paste(from: board)
    _ = await editor.flush()
    require(await bodyText() == "ARECOVEREDB", "valid text can be pasted immediately after an oversized clipboard error")

    _ = await reset("<div>AB</div>", offset: 1)
    let beforeForeignFocus = await editor.flush()
    place(text: "MUST STAY OUT")
    otherField.stringValue = "Other native input"
    require(window.makeFirstResponder(otherField), "fixture focuses a separate native text field")
    let readsBeforeForeignFocus = clipboardReads
    require(!view.performKeyEquivalent(with: event), "composer key-equivalent override declines Cmd-V while another native field owns focus")
    let foreignFocus = await editor.flush()
    require(foreignFocus.html == beforeForeignFocus.html && clipboardReads == readsBeforeForeignFocus && otherField.stringValue == "Other native input",
            "foreign native-field focus neither reads composer clipboard nor inserts into the reply; system Paste is never invoked")
    require(editor.failure == nil, "native reply text/HTML Paste suite finishes without browser bridge failure")
}
