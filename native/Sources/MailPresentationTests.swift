import AppKit
import SwiftUI
import WebKit

/// Native layout fixtures, not a real mailbox or GUI automation of user data.
@MainActor func runMailPresentationTests(_ require: (Bool, String) -> Void) async {
    let original = NSApp.appearance
    defer { NSApp.appearance = original }
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--presentation-output"), args.count > index + 1 else {
        require(false, "presentation screenshot output directory was supplied"); return
    }
    let output = URL(fileURLWithPath: args[index + 1], isDirectory: true)
    let state = AppState(fixture: true)
    defer { _ = state.shutdown() }
    let account = state.accounts[0]
    let origin = URL(string: "https://mail.zoho.com")!
    let message = MailMessage(accountID: account.id, remoteID: "100", folderID: "200", id: "300", origin: origin,
        subject: "Design review — a simpler workspace", sender: "Alex Chen <alex@example.test>",
        preview: "The revised layout keeps the message in focus.", date: Date(timeIntervalSince1970: 1792742400), attachment: false, unread: false)
    let html = """
    <div style="font:15px -apple-system,Arial,sans-serif;line-height:1.65;color:#242424">
    <p>Hello Mira,</p>
    <p>The revised layout keeps the message in focus. Primary actions stay together, while the less frequent options are still available in More.</p>
    <p>Here are the details for our next design review:</p>
    <ul><li>One clear place to reply and forward</li><li>A compact sender header with optional recipient details</li><li>More space for the message, with fewer borders and repeated controls</li></ul>
    <p>The appearance follows your preference, without changing the original email content.</p>
    <p>Best regards,<br>Alex Chen<br><span style="color:#777">Northwind Studio</span></p>
    <div>---- On Friday, Alex Chen wrote ----</div>
    <blockquote><p>Earlier design notes remain readable below a subtle divider.</p></blockquote>
    </div>
    """
    let detail = MailDetail(message: message, from: message.sender, to: "Mira <design@northwind.studio>", cc: "", replyTo: "alex@example.test", html: html, attachments: [], inline: [])
    state.sessions[account.id] = MailboxSession(accountID: account.id, remoteID: "100", email: "design@northwind.studio", origin: origin,
        folders: [.init(id: "200", name: "Inbox", path: "/Inbox", type: "Inbox")], addresses: ["design@northwind.studio"],
        senderIdentities: [.init(address: "design@northwind.studio", displayName: "Mira")])
    state.messageStore[message.key] = message
    state.rows = [message]
    state.activeKey = message.key
    state.detail = detail

    func browserViews(_ node: NSView) -> [WKWebView] {
        (node as? WKWebView).map { [$0] } ?? node.subviews.flatMap(browserViews)
    }
    func top(_ rect: NSRect, in host: NSView) -> CGFloat {
        host.isFlipped ? rect.minY : host.bounds.maxY - rect.maxY
    }
    func settle(_ host: NSView) async {
        // Wait boundedly for actual representable browser creation/navigation; no account IO.
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            let views = browserViews(host)
            if !views.isEmpty && views.allSatisfy({ $0.url != nil && !$0.isLoading }) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<4 { await Task.yield(); host.layoutSubtreeIfNeeded() }
    }
    func capture(_ host: NSView, name: String) async {
        let target = output.appendingPathComponent(name + ".png")
        guard !FileManager.default.fileExists(atPath: target.path),
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            require(false, "fresh native layout screenshot \(name)"); return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // AppKit cacheDisplay omits remote WebKit layers. Composite real WK snapshots
        // at their exact native frames; do not substitute invented HTML mock images.
        for browser in browserViews(host) {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = browser.bounds
            configuration.afterScreenUpdates = true
            let image: NSImage? = await withCheckedContinuation { continuation in
                browser.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
            }
            require(image != nil, "actual WebKit rendered snapshot \(name)")
            if let image, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                var rect = host.convert(browser.bounds, from: browser)
                if host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let transform = context.cgContext.ctm
                context.cgContext.scaleBy(x: (CGFloat(bitmap.pixelsWide) / host.bounds.width) / abs(transform.a),
                                          y: (CGFloat(bitmap.pixelsHigh) / host.bounds.height) / abs(transform.d))
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            require(false, "PNG representation \(name)"); return
        }
        do { try data.write(to: target, options: .atomic); require(true, "native layout screenshot \(name)") }
        catch { require(false, "write native layout screenshot \(name): \(error)") }
        print("VISUAL: \(target.path)")
    }
    for mode in [MailAppearanceMode.light, .dark] {
        MailApplicationAppearance.apply(mode)
        for size in [NSSize(width: 1060, height: 820), NSSize(width: 500, height: 740)] {
            let host = NSHostingView(rootView: ReaderPane(state: state))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            await settle(host)
            let name = "reader-\(mode.rawValue)-\(Int(size.width))"
            let browsers = browserViews(host)
            require(!browsers.isEmpty, "reader \(name) mounts the actual mail body browser")
            if let web = browsers.first {
                let renderedText: String? = await withCheckedContinuation { continuation in
                    web.callAsyncJavaScript("return document.body.innerText;", arguments: [:], in: nil, in: .defaultClient) { result in
                        continuation.resume(returning: (try? result.get()) as? String)
                    }
                }
                require(renderedText?.contains("The revised layout keeps the message in focus") == true, "reader \(name) actually loads the fixture body text")
                let rect = host.convert(web.bounds, from: web)
                let y = top(rect, in: host)
                print("LAYOUT \(name): bodyTop=\(y), bodyWidth=\(rect.width), viewport=\(host.bounds.size)")
                require(y <= 300 && y >= 0, "reader \(name) keeps header/actions compact before the message")
                require(rect.width >= size.width * 0.80, "reader \(name) gives the body most of the available width")
            }
            await capture(host, name: name)
            window.close()
        }
        for (size, expanded) in [(NSSize(width: 1120, height: 820), false), (NSSize(width: 860, height: 700), false), (NSSize(width: 1120, height: 820), true)] {
            var draft = MailDraft(accountID: account.id, from: "design@northwind.studio", mode: ComposeMode.reply.rawValue)
            draft.source = detail; draft.to = "alex@example.test"; draft.subject = "Re: " + message.subject
            draft.body = "Hello Alex,\n\nThank you for the update. The simpler layout looks clear and leaves more room for writing.\n\nBest regards,"
            let model = ComposeModel(state: state, draft: draft)
            let host = NSHostingView(rootView: ComposeView(model: model, formattingInitiallyExpanded: expanded))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            await model.waitForSignatures()
            _ = await model.editor.replaceManagedSignatureHTML("<div style='font:13px Arial;color:#444'><strong>Mira</strong><br>Northwind Studio<br>design@northwind.studio</div>", reference: "layout", identity: "fixture:layout", beforeQuote: true, allowInsert: true)
            _ = await model.editor.flush()
            await settle(host)
            let rect = host.convert(model.editor.webView.bounds, from: model.editor.webView)
            let y = top(rect, in: host)
            let name = "compose-\(mode.rawValue)-\(Int(size.width))\(expanded ? "-formatting" : "")"
            print("LAYOUT \(name): bodyTop=\(y), bodyHeight=\(rect.height), viewport=\(host.bounds.size)")
            require(y <= 240 && y >= 0, "compose \(name) starts the editor near the top")
            require(rect.height >= size.height * 0.60, "compose \(name) reserves the majority of the window for the editor")
            let snapshot = await model.editor.flush()
            require(snapshot.outgoingHTML.contains("Northwind Studio") && snapshot.outgoingHTML.contains("Primary actions"), "compose \(name) retains signature and quoted email content")
            require(model.editor.failure == nil, "compose \(name) has no editor bridge failure")
            await capture(host, name: name)
            model.stopBackgroundWork(); window.close()
        }
    }
    require(state.accountSessions.isEmpty, "presentation fixtures never construct real account browser sessions")
}
