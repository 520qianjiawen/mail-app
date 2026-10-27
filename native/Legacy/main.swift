import AppKit
import WebKit

@MainActor final class Application: NSObject, NSApplicationDelegate {
    var controller:MailWindow?
    func applicationDidFinishLaunching(_ notification:Notification) {
        if !CommandLine.arguments.contains("--fixture"), let bundleID = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) {
            running.activate(options:[.activateAllWindows]); NSApp.terminate(nil); return
        }
        let appMenu = NSMenu(), root = NSMenuItem(); root.submenu = appMenu
        appMenu.addItem(withTitle:"关于 Mail Lite",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"隐藏 Mail Lite",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(withTitle:"退出 Mail Lite",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let menu = NSMenu(); menu.addItem(root)
        let mail = NSMenu(), mailRoot = NSMenuItem(title:"邮件",action:nil,keyEquivalent:""); mailRoot.submenu = mail; menu.addItem(mailRoot)
        let controller = MailWindow(fixture:ProcessInfo.processInfo.arguments.contains("--fixture")); self.controller = controller
        let compose=NSMenuItem(title:"写邮件",action:#selector(MailWindow.newMessage),keyEquivalent:"n");compose.target=controller;mail.addItem(compose)
        let drafts=NSMenuItem(title:"待完成草稿",action:#selector(MailWindow.showDrafts),keyEquivalent:"d");drafts.keyEquivalentModifierMask=[.command,.shift];drafts.target=controller;mail.addItem(drafts)
        let inboxItem = NSMenuItem(title:"所有收件箱",action:#selector(MailWindow.showInbox),keyEquivalent:"i"); inboxItem.keyEquivalentModifierMask = [.command,.shift]; inboxItem.target = controller; mail.addItem(inboxItem)
        let refresh = NSMenuItem(title:"刷新",action:#selector(MailWindow.refreshAction),keyEquivalent:"r"); refresh.target = controller; mail.addItem(refresh)
        let add = NSMenuItem(title:"添加账号…",action:#selector(MailWindow.addAccount),keyEquivalent:"n"); add.keyEquivalentModifierMask = [.command,.shift]; add.target = controller; mail.addItem(add)
        let edit = NSMenu(), editRoot = NSMenuItem(title:"编辑",action:nil,keyEquivalent:""); editRoot.submenu = edit; menu.addItem(editRoot)
        for (title,action,key) in [("撤销","undo:","z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] { edit.addItem(withTitle:title,action:Selector(action),keyEquivalent:key) }
        let windows = NSMenu(), windowRoot = NSMenuItem(title:"窗口",action:nil,keyEquivalent:""); windowRoot.submenu = windows; menu.addItem(windowRoot)
        windows.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        windows.addItem(withTitle:"最小化",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m"); NSApp.windowsMenu = windows
        NSApp.mainMenu = menu; controller.show()
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { controller?.confirmQuit() == false ? .terminateCancel : .terminateNow }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { controller?.window.makeKeyAndOrderFront(nil); return true }
}

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--self-test") { runSelfTests() }
    else {
        let app = NSApplication.shared, delegate = Application()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
    }
}
