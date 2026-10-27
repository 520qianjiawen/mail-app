import AppKit
import SwiftUI
import WebKit
import UserNotifications

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    var state: AppState!
    var window: NSWindow!
    private var preparingTermination = false
    let fixture = CommandLine.arguments.contains("--fixture")
    var snapshotPath: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier, !fixture,
           !CommandLine.arguments.contains("--allow-multiple"),
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            running.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        state = AppState(fixture: fixture)
        state.applySavedAppearance()
        // Existing screenshot/debug flag is an ephemeral override, never saved.
        if CommandLine.arguments.contains("--light") { MailApplicationAppearance.apply(.light) }
        let root = RootView(state: state)
        let host = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(1080, state.preferences.value.width),
                                             height: max(680, state.preferences.value.height)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Mail Lite"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 960, height: 620)
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        if !fixture, Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--no-mark-read") {
            state.preferences.value.markReadOnOpen = false
        }
        if CommandLine.arguments.contains("--probe-session") {
            Task { @MainActor in
                for account in state.accounts {
                    let session = state.webSession(account)
                    do {
                        try await session.ready()
                        let cookies = await session.store.httpCookieStore.allCookies()
                        let names = cookies.map { $0.name }.sorted().joined(separator: ",")
                        print("ACCOUNT \(account.name) url=\(session.webView.url?.absoluteString ?? "-") cookies=\(names)")
                        let context = try await state.api.discover(account: account, store: session.store,
                                                                   origin: session.origin, browser: session.webView)
                        print("DISCOVER OK \(context.email) remote=\(context.remoteID) folders=\(context.folders.count)")
                    } catch {
                        print("FAIL \(account.name) error=\(error) url=\(session.webView.url?.absoluteString ?? "-")")
                    }
                }
                NSApp.terminate(nil)
            }
        } else {
            state.start()
        }
        if fixture, CommandLine.arguments.contains("--upload-progress-preview"), let account = state.accounts.first {
            var item = OutboxItem(accountID: account.id, from: "design@northwind.studio", to: "recipient@example.test",
                                  subject: "附件上传预览")
            item.state = "sending"
            _ = state.outboxStore.enqueue(item); state.reloadOutbox(); state.showOutbox()
            state.uploadProgress[item.id] = MailUploadProgress(fileName: "product-brochure.pdf", fileIndex: 2,
                fileCount: 3, completedBytes: 4_000_000, fileBytes: 12_000_000,
                uploadedBytes: 8_000_000, totalBytes: 20_000_000)
        }
        if CommandLine.arguments.contains("--open-first") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let first = self.state.rows.first else { return }
                self.state.selectedKeys = [first.key]
                self.state.open(first, preferLatest: true)
            }
        }
        if CommandLine.arguments.contains("--login-test") {
            let account = MailAccount(id: "login-window-test", name: "登录窗口测试", region: "global")
            let session = AccountSession(account: account)
            session.state = state
            state.accountSessions[account.id] = session
            Task { @MainActor in _ = await session.authenticate(presenting: nil) }
        }
        if fixture, CommandLine.arguments.contains("--signature-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let account = self.state.accounts.first else { return }
                if let signature = try? self.state.saveLocalSignature(accountID: account.id, name: "工作签名", html: "<p><strong>Alex Chen</strong><br>Northwind Studio · Product Design</p><p><a href='mailto:alex@example.test'>alex@example.test</a><br><span style='color:#777'>本机演示签名 · 未连接真实邮箱</span></p>") {
                    self.state.setSignatureChoice(accountID: account.id, alias: nil, reply: false, choice: "local:" + signature.id)
                    self.state.setSignatureChoice(accountID: account.id, alias: nil, reply: true, choice: "none")
                }
                self.state.settingsController = SettingsWindowController(state: self.state, section: 7)
                self.state.settingsController?.window.setContentSize(NSSize(width: 760, height: 800))
                self.state.settingsController?.show()
            }
        } else if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.state.showSettings() }
        }
        if CommandLine.arguments.contains("--compose") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.state.composeNew() }
        }
        if fixture, CommandLine.arguments.contains("--reply-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let message = self.state.rows.first else { return }
                let source = MailDetail(message: message, from: "Customer <client@example.test>",
                    to: self.state.email(for: message.accountID), cc: "", replyTo: "client@example.test",
                    html: "<h3>Product enquiry</h3><p>Hello, could you send a quotation and delivery details?</p><table border='1' cellpadding='8'><tr><td>Name</td><td>Example Customer</td></tr><tr><td>Subject</td><td>Desktop Shredder</td></tr></table>", attachments: [], inline: [])
                self.state.composeReply(source, mode: .reply)
                if let model = self.state.composeControllers.last?.model {
                    let signature = MailSignature(id: "preview", name: "演示签名", html: "<table cellpadding='8'><tr><td><strong style='color:#007aff;font-size:24px'>Northwind.</strong></td><td><strong>Alex</strong><br>Technical Sales Engineer</td></tr></table><p><b style='color:#007aff'>Email:</b> design@northwind.studio<br><b style='color:#007aff'>Web:</b> www.example.test</p><hr><p style='color:#777;font-size:10px'>Demonstration signature — local fixture only.</p>")
                    model.signatureOptions = [signature]
                    Task { @MainActor in
                        await model.waitForSignatures()
                        _ = await model.editor.replaceManagedSignatureHTML(signature.html, reference: signature.id, identity: SignaturePolicy.identity(account: model.draft.accountID, from: model.draft.from), beforeQuote: true, allowInsert: true)
                    }
                }
            }
        }

        if let path = snapshotPath {
            let delayIndex = CommandLine.arguments.firstIndex(of: "--delay")
            let delay = delayIndex.flatMap { CommandLine.arguments.count > $0 + 1 ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 2.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.capture(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    private func capture(to path: String) {
        let extra = NSApp.windows.last { $0.isVisible && $0 !== window && $0.title != "Mail Lite" }
        guard let view = (extra ?? NSApp.keyWindow ?? window)?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        guard !preparingTermination else { return .terminateLater }
        // Browser editing must be read before the synchronous shutdown snapshot.
        if state.composeControllers.isEmpty || state.composeControllers.contains(where: { $0.busy }) {
            return state.shutdown() ? .terminateNow : .terminateCancel
        }
        preparingTermination = true
        let composers = Array(state.composeControllers)
        for controller in composers { controller.model.editor.setEditingEnabled(false) }
        Task { @MainActor in
            for controller in composers {
                guard await controller.persistDraftFlushed() else {
                    for pending in composers { pending.model.editor.setEditingEnabled(true) }
                    preparingTermination = false
                    sender.reply(toApplicationShouldTerminate: false)
                    let alert = NSAlert()
                    alert.messageText = "草稿尚未保存，已取消退出。"
                    alert.informativeText = "请检查撰写窗口中的提示，保存后再退出。"
                    alert.runModal()
                    return
                }
            }
            preparingTermination = false
            sender.reply(toApplicationShouldTerminate: state.shutdown())
        }
        return .terminateLater
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let reminder = notification.request.content.userInfo[MailReminderPolicy.userInfoKey] != nil
        completionHandler(reminder ? [.banner, .sound] : [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let key = response.notification.request.content.userInfo[MailReminderPolicy.userInfoKey] as? String else {
            completionHandler(); return
        }
        Task { @MainActor [weak self] in
            if let self, self.state?.openMessageReminder(key) == true {
                self.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            completionHandler()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.preferences.value.width = window.frame.width
        state?.preferences.value.height = window.frame.height
        state?.preferences.save()
    }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ mask: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        item.target = self
        return item
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Mail Lite", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("设置…", #selector(openSettings), ",", [.command]))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Mail Lite", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Mail Lite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "文件")
        file.addItem(item("新建邮件", #selector(newMessage), "n"))
        file.addItem(item("本机草稿", #selector(openDrafts), "d", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("关闭窗口", #selector(NSWindow.performClose(_:)), "w"))
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let mailItem = NSMenuItem()
        let mail = NSMenu(title: "邮件")
        mail.addItem(item("所有收件箱", #selector(allInbox), "i", [.command, .shift]))
        mail.addItem(item("所有已发送", #selector(allSent), "s", [.command, .shift]))
        mail.addItem(item("未读", #selector(showUnread), "u", [.command, .shift]))
        mail.addItem(item("发件箱", #selector(openOutbox), "o", [.command, .shift]))
        mail.addItem(.separator())
        mail.addItem(item("回复", #selector(reply), "r"))
        mail.addItem(item("回复全部", #selector(replyAll), "r", [.command, .shift]))
        mail.addItem(item("转发", #selector(forward), "f", [.command, .shift]))
        mail.addItem(.separator())
        mail.addItem(item("归档", #selector(archive), "a", [.control, .command]))
        mail.addItem(item("删除", #selector(deleteMail), "\u{8}", [.command]))
        mail.addItem(item("标记为未读", #selector(markUnread), "u", [.command, .shift]))
        mail.addItem(item("标记重要/清除", #selector(toggleFlag), "l", [.command, .shift]))
        mail.addItem(.separator())
        mail.addItem(item("刷新", #selector(refreshMail), "r", [.command, .option]))
        mail.addItem(item("搜索", #selector(focusSearch), "f"))
        mailItem.submenu = mail
        main.addItem(mailItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "显示")
        view.addItem(item("下一条", #selector(nextMail), "]"))
        view.addItem(item("上一条", #selector(previousMail), "["))
        view.addItem(item("全选邮件", #selector(selectAllMail), "a", [.command, .option]))
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("关闭阅读器", #selector(closeReader), "\u{1b}", []))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let state else { return false }
        switch menuItem.action {
        case #selector(reply), #selector(replyAll), #selector(forward), #selector(archive),
             #selector(deleteMail), #selector(markUnread), #selector(toggleFlag):
            return !state.selectedMessages().isEmpty || state.activeMessage() != nil
        case #selector(closeReader): return state.activeKey != nil
        case #selector(nextMail), #selector(previousMail): return !state.rows.isEmpty
        default: return true
        }
    }

    @objc private func newMessage() { state.composeNew() }
    @objc private func openDrafts() { state.showDraftsWindow() }
    @objc private func openSettings() { state.showSettings() }
    @objc private func allInbox() { state.showAllInbox() }
    @objc private func allSent() { state.showAllSent() }
    @objc private func showUnread() { state.select(Scope(kind: .unread)) }
    @objc private func openOutbox() { state.showOutbox() }
    @objc private func reply() { state.replyActive() }
    @objc private func replyAll() {
        guard let message = state.activeMessage() else { return }
        state.open(message)
        Task { @MainActor in
            for _ in 0..<40 {
                if let detail = state.detail, detail.message.key == message.key {
                    state.composeReply(detail, mode: .replyAll); return
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }
    @objc private func forward() { state.forwardActive() }
    @objc private func archive() { state.archiveSelection() }
    @objc private func deleteMail() { state.deleteSelection() }
    @objc private func markUnread() { state.markReadSelection(true) }
    @objc private func toggleFlag() { state.flagSelection() }
    @objc private func refreshMail() { state.refresh() }
    @objc private func focusSearch() { state.searchFocusToken += 1 }
    @objc private func nextMail() { state.nextMessage(1) }
    @objc private func previousMail() { state.nextMessage(-1) }
    @objc private func selectAllMail() { state.selectAllRows() }
    @objc private func closeReader() { state.closeReader() }
}

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--send-repair-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("FAIL: send repair checks timed out"); fflush(stdout); exit(1) }
        Task { @MainActor in
            var checks = 0, failures = 0
            await runMailSendRepairTests { condition, label in
                checks += 1
                if !condition { failures += 1; print("FAIL [send-repair]: \(label)") }
            }
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) isolated send repair checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--body-capacity-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { print("FAIL: body capacity checks timed out"); fflush(stdout); exit(1) }
        Task { @MainActor in
            var checks = 0, failures = 0
            await runMailBodyCapacityTests { condition, label in
                checks += 1
                if !condition { failures += 1; print("FAIL [body-capacity]: \(label)") }
            }
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) isolated body capacity checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--workflow-repair-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("FAIL: workflow repair checks timed out"); fflush(stdout); exit(1) }
        Task { @MainActor in
            var checks = 0, failures = 0
            await runMailWorkflowRepairTests { condition, label in
                checks += 1
                if !condition { failures += 1; print("FAIL [workflow-repair]: \(label)") }
            }
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) isolated workflow repair checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--self-test") {
        runSelfTests()
    } else if CommandLine.arguments.contains("--image-diagnostics-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            print("FAIL: real image transport and diagnostic checks exceeded 90 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [image-diagnostics]: \(label)") }
            }
            await runMailRasterImageTests(require)
            await runMailImageDiagnosticsTests(require)
            await runMailInlineImageReferenceTests(require)
            await runMailSessionImageTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused production image transport and diagnostic checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--quote-separator-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            print("FAIL: quote separator checks exceeded 180 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [quote-separator]: \(label)") }
            }
            await runMailQuoteSeparatorTests(require)
            await runMailInlineImageReferenceTests(require)
            await runMailPresentationTests(require)
            await runMailComposerTextPasteTests(require)
            await runMailComposerBodyPlaceholderTests(require)
            await runMailComposerPasteTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused quote separator and image/composer layout regression checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--inline-image-reference-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("FAIL: inline image reference checks exceeded 60 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [inline-image-reference]: \(label)") }
            }
            await runMailInlineImageReferenceTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused inline image reference checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--presentation-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) {
            print("FAIL: presentation checks exceeded 150 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [presentation]: \(label)") }
            }
            await runMailPresentationTests(require)
            await runMailComposerTextPasteTests(require)
            await runMailComposerBodyPlaceholderTests(require)
            await runMailComposerPasteTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused presentation and composer interaction checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--appearance-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("FAIL: application appearance checks exceeded 60 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [appearance]: \(label)") }
            }
            await runMailAppearanceTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused application appearance checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--composer-text-paste-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            print("FAIL: native composer text paste checks exceeded 120 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [composer-text-paste]: \(label)") }
            }
            await runMailComposerTextPasteTests(require)
            await runMailComposerBodyPlaceholderTests(require)
            await runMailComposerPasteTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused native text, body and image paste checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--composer-body-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            print("FAIL: composer body placeholder checks exceeded 90 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [composer-body]: \(label)") }
            }
            await runMailComposerBodyPlaceholderTests(require)
            await runMailComposerPasteTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused body placeholder and clipboard regression checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--composer-paste-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            print("FAIL: composer image paste checks exceeded 90 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [composer-paste]: \(label)") }
            }
            runMailComposerSenderLabelTests(require)
            await runMailInlineImageSendTests(require)
            await runMailComposerPasteTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused composer image paste and sender label checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--primary-sender-sync-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("FAIL: primary sender cloud sync checks exceeded 60 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [primary-sender-sync]: \(label)") }
            }
            await runMailPrimarySenderSyncTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused primary sender cloud sync checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--sender-identity-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("FAIL: sender identity checks exceeded 60 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [sender-identity]: \(label)") }
            }
            runSenderIdentityDiscoveryTests(require)
            await runMailSenderIdentityTests(require)
            await runMailSenderWireTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused sender identity checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--conversation-opening-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("FAIL: conversation opening checks exceeded 60 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [conversation-opening]: \(label)") }
            }
            await runMailConversationOpeningTests(require)
            await runMailReadingLifecycleTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused conversation opening and reading lifecycle checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--context-menu-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("FAIL: message context menu and reminders exceeded 60 seconds")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            var checks = 0, failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [mail-context]: \(label)") }
            }
            await runMailContextMenuTests(require)
            await runMailReminderTests(require)
            await runMailReminderRoutingTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused mail context menu and reminder checks (\(failures) failures).")
            fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--signature-html-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("FAIL: signature HTML and typography suite exceeded 60 seconds")
            fflush(stdout)
            exit(1)
        }
        Task { @MainActor in
            var checks = 0
            var failures = 0
            func require(_ passed: Bool, _ label: String) {
                checks += 1
                if !passed { failures += 1; print("FAIL [signature-html]: \(label)") }
            }
            runSignatureHTMLSanitizerTests(require)
            await runMailSignatureHTMLTests(require)
            await runComposeTypographyTests(require)
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) focused signature HTML and typography checks (\(failures) failures).")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--signature-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            print("FAIL: account signature regression suite exceeded 30 seconds")
            fflush(stdout)
            exit(1)
        }
        Task { @MainActor in
            var checks = 0
            var failures = 0
            await runMailAccountSignatureTests { passed, label in
                checks += 1
                if !passed { failures += 1; print("FAIL [account-signature]: \(label)") }
            }
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) isolated account signature checks (\(failures) failures).")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--sync-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            print("FAIL: mailbox synchronization regression suite exceeded 30 seconds")
            fflush(stdout)
            exit(1)
        }
        Task { @MainActor in
            var checks = 0
            var failures = 0
            await runMailSyncReconciliationTests { passed, label in
                checks += 1
                if !passed { failures += 1; print("FAIL [mail-sync]: \(label)") }
            }
            await runMailViewSyncTests { passed, label in
                checks += 1
                if !passed { failures += 1; print("FAIL [mail-view-sync]: \(label)") }
            }
            await runMailConversationReadTests { passed, label in
                checks += 1
                if !passed { failures += 1; print("FAIL [conversation-read]: \(label)") }
            }
            await runMailMutationOrderTests { passed, label in
                checks += 1
                if !passed { failures += 1; print("FAIL [mutation-order]: \(label)") }
            }
            await runMailReadingLifecycleTests { passed, label in
                checks += 1
                if !passed { failures += 1; print("FAIL [reading-lifecycle]: \(label)") }
            }
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) isolated mailbox synchronization checks (\(failures) failures).")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    } else if CommandLine.arguments.contains("--body-layout-test") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let passed = await runMailBodyLayoutTests()
            fflush(stdout)
            exit(passed ? 0 : 1)
        }
        app.run()
    } else {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
