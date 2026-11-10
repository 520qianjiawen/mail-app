import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    let state: AppState
    let window: NSWindow
    init(state: AppState, section: Int = 0) {
        self.state = state
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Mail Lite 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(state: state, initialSection: section))
        window.minSize = NSSize(width: 680, height: 520)
    }
    func show() {
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        state.settingsController = nil
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var section = 0
    @State private var signatureAccountID = ""
    @State private var selectedBccAccountID = ""
    init(state: AppState, initialSection: Int = 0) { self.state = state; _section = State(initialValue: initialSection) }

    var body: some View {
        VStack(spacing: 0) {
            header
            DividerLine()
            ScrollView {
                Group {
                    switch section {
                    case 0: accounts
                    case 1: folders
                    case 2: labels
                    case 3: notifications
                    case 4: reading
                    case 5: vacation
                    case 6: storage
                    case 7: AccountSignatureSettingsView(state: state, initialAccountID: signatureAccountID)
                    case 8: shortcutsSection
                    case 9: MailTrackingSettingsView(controller: state.tracking)
                    default: accounts
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            DividerLine()
            footer
        }
        .background(Palette.elevated)
        .frame(minWidth: 680, minHeight: 520)
    }

    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let items: [(String, String)] = [
                    ("账号", "person.crop.circle"),
                    ("文件夹", "folder"),
                    ("标签", "tag"),
                    ("通知", "bell"),
                    ("阅读与编写", "eyeglasses"),
                    ("假期回复", "sun.max"),
                    ("存储", "internaldrive"),
                    ("签名", "signature"),
                    ("快捷键", "command"),
                    ("邮件追踪", "eye")
                ]
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Button {
                        section = index
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.1)
                                .font(.system(size: 11))
                            Text(item.0)
                                .font(.system(size: 12, weight: section == index ? .semibold : .medium))
                        }
                        .foregroundStyle(section == index ? Color.white : Palette.secondaryText)
                        .padding(.horizontal, 10).padding(.vertical, 5.5)
                        .background(Capsule().fill(section == index ? Palette.accent : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.mint).frame(width: 6, height: 6)
            Text(state.status).font(.system(size: 11)).foregroundStyle(Palette.secondaryText).lineLimit(1)
            Spacer()
            Text("Mail Lite \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")").font(.system(size: 10.5)).foregroundStyle(Palette.tertiaryText)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
    }

    // MARK: Accounts

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("账号", detail: "每个账号使用独立的 WebKit 会话；移除账号只清理本机数据。")
            ForEach(state.accounts) { account in
                HStack(spacing: 12) {
                    Avatar(text: account.name, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name).font(.system(size: 13, weight: .semibold))
                        Text("\(Region.find(account.region)?.name ?? account.region) · \(state.sessions[account.id]?.email ?? "未登录")")
                            .font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText)
                    }
                    Spacer()
                    if let error = state.accountErrors[account.id] {
                        Text(error).font(.system(size: 10)).foregroundStyle(Palette.rose).lineLimit(1)
                    } else {
                        Chip(text: "已连接", tint: Palette.mint)
                    }
                    Button("签名") { signatureAccountID = account.id; section = 7 }.buttonStyle(GhostButtonStyle())
                    Button("重新登录") { state.relogin(account) }.buttonStyle(GhostButtonStyle())
                    Button("重命名") { rename(account) }.buttonStyle(GhostButtonStyle())
                    Button("移除") { remove(account) }.buttonStyle(GhostButtonStyle(tint: Palette.rose))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline, lineWidth: 0.5))
                PrimarySenderSyncSettingsView(state: state, accountID: account.id)
                    .id("primary-server-" + account.id)
                AccountSenderIdentitySettingsView(state: state, accountID: account.id)
                    .id(account.id)
            }
            Button {
                addAccount()
            } label: { Label("添加账号…", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Folders

    @State private var folderAccount: String?

    private var folders: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("文件夹", detail: "创建、重命名与删除自定义文件夹；系统文件夹只允许清空回收站/垃圾邮件。")
            Picker("账号", selection: Binding(get: { folderAccount ?? state.accounts.first?.id ?? "" },
                                              set: { folderAccount = $0 })) {
                ForEach(state.accounts) { account in Text(account.name).tag(account.id) }
            }
            .frame(maxWidth: 320)
            if let accountID = folderAccount ?? state.accounts.first?.id {
                let custom = state.folders(accountID).filter { $0.systemName == nil }
                if custom.isEmpty {
                    Text("没有自定义文件夹").font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText)
                }
                ForEach(custom) { folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Palette.accent)
                        Text(folder.name).font(.system(size: 12))
                        Text(folder.path).font(.system(size: 10)).foregroundStyle(Palette.tertiaryText).lineLimit(1)
                        Spacer()
                        Button("重命名") { renameFolder(accountID, folder) }.buttonStyle(GhostButtonStyle())
                        Button("删除") { deleteFolder(accountID, folder) }.buttonStyle(GhostButtonStyle(tint: Palette.rose))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                }
                HStack(spacing: 8) {
                    Button("新建文件夹…") { newFolder(accountID) }.buttonStyle(PrimaryButtonStyle())
                    if let trash = state.systemFolder(accountID, "Trash") {
                        Button("清空回收站…") { state.emptyFolder(state.accounts.first { $0.id == accountID }!, trash) }
                            .buttonStyle(GhostButtonStyle(tint: Palette.rose))
                    }
                }
            }
        }
    }

    // MARK: Labels

    private var labels: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("标签", detail: "标签来自服务器；添加或移除标签会立即同步到当前邮件。")
            ForEach(state.accounts) { account in
                let values = state.labelsByAccount[account.id] ?? []
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(account.name).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("刷新") { Task { await state.loadLabels(account) } }.buttonStyle(GhostButtonStyle())
                        Button("新建标签…") { newLabel(account) }.buttonStyle(GhostButtonStyle())
                    }
                    if values.isEmpty {
                        Text("没有标签，或服务器未返回标签列表。").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                    }
                    ForEach(values) { label in
                        HStack(spacing: 8) {
                            Circle().fill(Palette.label(label.color)).frame(width: 8, height: 8)
                            Text(label.name).font(.system(size: 12))
                            Spacer()
                            Button("删除") { state.deleteLabel(accountID: account.id, label: label) }
                                .buttonStyle(GhostButtonStyle(tint: Palette.rose))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline, lineWidth: 0.5))
            }
        }
    }

    // MARK: Notifications

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("通知", detail: "通知只包含发件人、主题与摘要，不写入任何日志。")
            SettingsCard(title: "系统通知与声音") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("新邮件系统通知", isOn: binding(\.notificationsEnabled))
                    Toggle("未读计数显示在 Dock 图标", isOn: binding(\.badgeEnabled))
                    Toggle("通知播放声音", isOn: binding(\.playSound))
                    if state.preferences.value.notificationsEnabled {
                        Button("请求系统通知权限") {
                            Task { _ = await state.notifier.requestAuthorization() }
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
            Text("macOS 通知由系统“系统设置 -> 通知”管理；关闭后本应用不再投递提醒。稍后发送需要保持应用运行。")
                .font(.system(size: 10.5)).foregroundStyle(Palette.tertiaryText)
        }
    }

    // MARK: Reading

    private var reading: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("阅读与编写偏好", detail: "个性化设置邮件显示、编写与默认密送规则，保存在本机。")
            MailIPLocationSettingsView()
            SettingsCard(title: "外观主题") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("系统模式").font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                        Spacer()
                        Picker("外观", selection: Binding(get: { state.preferences.value.appearanceMode },
                                                           set: { _ = state.setAppearanceMode($0) })) {
                            ForEach(MailAppearanceMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                    }
                    Text("立即生效并保存在本机。写邮件正文仍为白底；阅读正文配色可在邮件内单独切换。")
                        .font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText)
                }
            }
            SettingsCard(title: "阅读与回复偏好") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("打开邮件时标记为已读", isOn: binding(\.markReadOnOpen))
                    Toggle("内联回复（类似 Outlook 就地回复，不单独弹窗）", isOn: binding(\.inlineReply))
                    Toggle("自动加载外部图片", isOn: binding(\.loadRemoteImages))
                    Toggle("紧凑列表行", isOn: binding(\.compactRows))
                    Stepper("预览行数：\(state.preferences.value.previewLines)", value: binding(\.previewLines), in: 0...3)
                }
            }
            SettingsCard(title: "默认密送 (Auto-BCC)") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("发信时自动密送自己", isOn: binding(\.autoBccMyself))
                    Text("写新邮件、回复或转发时，自动将当前发件人地址加入密送；切换发件人时自动同步。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)

                    DividerLine().padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("通用默认密送地址")
                            .font(.system(size: 12, weight: .medium))
                        HStack {
                            TextField("例如 archive@energycle.com（多地址用逗号分隔）", text: binding(\.defaultBccAddress))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            if !state.preferences.value.defaultBccAddress.isEmpty {
                                Button("清空") {
                                    state.preferences.value.defaultBccAddress = ""
                                    state.preferences.save()
                                }
                                .buttonStyle(GhostButtonStyle())
                            }
                        }
                        Text("所有账号写信时均会自动包含该密送地址。")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                    }

                    if state.accounts.count > 1 {
                        DividerLine().padding(.vertical, 2)
                        accountSpecificBccSection
                    }
                }
            }
            SettingsCard(title: "列表布局") {
                HStack {
                    Text("列表宽度").font(.system(size: 12))
                    Slider(value: Binding(get: { state.listWidth }, set: { state.listWidth = $0 }), in: Metrics.listMin...Metrics.listMax)
                        .frame(width: 220)
                    Spacer()
                    Button("保存布局") { state.saveLayout() }.buttonStyle(GhostButtonStyle())
                }
            }
        }
    }

    private var accountSpecificBccSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("按账号单独指定密送（选填）")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                let currentID = state.accounts.contains(where: { $0.id == selectedBccAccountID }) ? selectedBccAccountID : (state.accounts.first?.id ?? "")
                Picker("账号", selection: Binding(get: { currentID }, set: { selectedBccAccountID = $0 })) {
                    ForEach(state.accounts) { acc in
                        Text(acc.name).tag(acc.id)
                    }
                }
                .frame(width: 200)

                TextField("此账号专用密送地址", text: Binding(get: {
                    state.preferences.value.defaultBccByAccount[currentID] ?? ""
                }, set: { val in
                    let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        state.preferences.value.defaultBccByAccount.removeValue(forKey: currentID)
                    } else {
                        state.preferences.value.defaultBccByAccount[currentID] = trimmed
                    }
                    state.preferences.save()
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

                if (state.preferences.value.defaultBccByAccount[currentID] ?? "").isEmpty == false {
                    Button("清除") {
                        state.preferences.value.defaultBccByAccount.removeValue(forKey: currentID)
                        state.preferences.save()
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
            Text("若为此账号配置了专用密送地址，写信时会自动附加该地址。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
        }
    }

    // MARK: Vacation

    @State private var vacationAccount: String?

    private var vacation: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("假期自动回复", detail: "通过账号的服务器设置开启或关闭；服务器未提供接口时会在状态栏说明。")
            if state.accounts.isEmpty { Text("尚未添加账号").foregroundStyle(Palette.secondaryText) }
            ForEach(state.accounts) { account in
                VacationEditor(state: state, account: account)
            }
        }
    }

    // MARK: Storage

    private var storage: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("本机存储", detail: "所有数据位于用户的 Application Support 目录，目录 0700、文件 0600。")
            SettingsCard(title: "数据目录") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(state.preferences.directory.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([state.preferences.directory])
                        }.buttonStyle(GhostButtonStyle())
                    }
                    HStack(spacing: 12) {
                        Text("离线保存的邮件：\(state.preferences.value.offlineSaved.count) 封")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                        Text("本机草稿：\(state.draftStore.all(accounts: Set(state.accounts.map { $0.id })).count) 封")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                    }
                }
            }
            SettingsCard(title: "数据清理与重置") {
                HStack(spacing: 10) {
                    Button("清除正文缓存") { state.clearBodyCache() }.buttonStyle(GhostButtonStyle())
                    Button("清除搜索历史") {
                        state.preferences.value.searchHistory = []
                        state.preferences.value.savedSearches = []
                        state.preferences.save()
                    }.buttonStyle(GhostButtonStyle())
                    Button("重置界面布局") {
                        state.listWidth = 392; state.sidebarWidth = 232; state.saveLayout()
                    }.buttonStyle(GhostButtonStyle())
                }
            }
            Text("清除登录状态请使用各账号的“重新登录/移除”，或在 Finder 中删除 Native 目录。")
                .font(.system(size: 10.5)).foregroundStyle(Palette.tertiaryText)
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("键盘快捷键", detail: "熟练使用键盘快捷键可大幅提升日常邮件处理效率。")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                SettingsCard(title: "邮件撰写与发送") {
                    VStack(spacing: 8) {
                        shortcutRow(key: "⌘ N", label: "新建邮件")
                        shortcutRow(key: "⌘ ↩", label: "发送邮件")
                        shortcutRow(key: "⌘ S", label: "保存草稿至本机")
                        shortcutRow(key: "⇧ ⌘ S", label: "同步草稿至云端")
                        shortcutRow(key: "⇧ ⌘ T", label: "显示/收起格式工具")
                        shortcutRow(key: "Esc", label: "放弃回复 / 取消")
                    }
                }
                SettingsCard(title: "邮件阅读与整理") {
                    VStack(spacing: 8) {
                        shortcutRow(key: "⌘ R", label: "回复发件人")
                        shortcutRow(key: "⇧ ⌘ R", label: "回复全部")
                        shortcutRow(key: "⌘ F", label: "聚焦搜索栏")
                        shortcutRow(key: "J / K", label: "下一封 / 上一封")
                        shortcutRow(key: "⌃ ⌘ A", label: "归档邮件")
                        shortcutRow(key: "⌘ ⌫", label: "移至废纸篓")
                    }
                }
            }
        }
    }

    private func shortcutRow(key: String, label: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.primary)
            Spacer()
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Palette.accent.opacity(0.1)))
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<NativePreferences, T>) -> Binding<T> {
        Binding(get: { state.preferences.value[keyPath: keyPath] },
                set: { state.preferences.value[keyPath: keyPath] = $0; state.preferences.save() })
    }

    private func addAccount() {
        let alert = NSAlert()
        alert.messageText = "添加邮箱账号"
        let name = NSTextField(string: "")
        name.placeholderString = "账号名称或邮箱"
        let region = NSPopUpButton()
        Region.all.forEach { region.addItem(withTitle: "\($0.name) · \($0.domain)") }
        let stack = NSStackView(views: [name, region])
        stack.orientation = .vertical; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 62)
        name.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            state.addAccount(name: name.stringValue, region: Region.all[max(0, region.indexOfSelectedItem)])
        }
    }

    private func rename(_ account: MailAccount) {
        let alert = NSAlert(); alert.messageText = "重命名账号"
        let field = NSTextField(string: account.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { state.renameAccount(account, to: field.stringValue) }
    }

    private func remove(_ account: MailAccount) {
        let alert = NSAlert()
        alert.messageText = "移除 \(account.name)？"
        alert.informativeText = "清除本机登录状态与缓存，服务器邮件不受影响。"
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { state.removeAccount(account) }
    }

    private func newFolder(_ accountID: String) {
        let alert = NSAlert(); alert.messageText = "新建文件夹"
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { state.createFolder(accountID: accountID, name: field.stringValue, parent: nil) }
    }

    private func renameFolder(_ accountID: String, _ folder: MailFolder) {
        let alert = NSAlert(); alert.messageText = "重命名文件夹"
        let field = NSTextField(string: folder.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            state.renameFolder(accountID: accountID, folder: folder, name: field.stringValue)
        }
    }

    private func deleteFolder(_ accountID: String, _ folder: MailFolder) {
        state.deleteFolder(accountID: accountID, folder: folder)
    }

    private func newLabel(_ account: MailAccount) {
        let alert = NSAlert(); alert.messageText = "新建标签"
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { state.createLabel(accountID: account.id, name: field.stringValue) }
    }
}

struct VacationEditor: View {
    let state: AppState
    let account: MailAccount
    @State private var enabled = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Avatar(text: account.name, size: 22)
                Text(account.name).font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("开启", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
            }
            TextEditor(text: $message)
                .font(.system(size: 12))
                .frame(height: 82)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline, lineWidth: 0.5))
            HStack {
                Spacer()
                Button("保存到服务器") {
                    state.setVacation(account, enabled: enabled, message: message)
                }.buttonStyle(GhostButtonStyle(tint: Palette.accent))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
        .onAppear {
            enabled = state.preferences.value.vacationEnabled[account.id] ?? false
            message = state.preferences.value.vacationMessage[account.id] ?? "我正在休假，回来后会尽快回复。"
        }
    }
}

// MARK: - Local drafts window

@MainActor final class DraftsWindowController: NSObject, NSWindowDelegate {
    let state: AppState
    let window: NSWindow
    init(state: AppState) {
        self.state = state
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "本机草稿"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: DraftsView(state: state))
    }
    func show() { window.center(); window.makeKeyAndOrderFront(nil) }
    func windowWillClose(_ notification: Notification) { state.draftsController = nil }
}

struct DraftsView: View {
    @ObservedObject var state: AppState
    @State private var drafts: [MailDraft] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本机草稿").font(.system(size: 14, weight: .semibold))
                Text("\(drafts.count)").foregroundStyle(Palette.tertiaryText).font(.system(size: 11))
                Spacer()
                Button("刷新") { reload() }.buttonStyle(GhostButtonStyle())
            }
            .padding(14)
            DividerLine()
            if drafts.isEmpty {
                EmptyState(symbol: "doc.text", title: "没有本机草稿", message: "撰写中的邮件会自动保存在这里，退出应用也不会丢失。")
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(drafts, id: \.id) { draft in
                            HStack(spacing: 10) {
                                Avatar(text: draft.to.nonEmpty ?? "草稿", size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(draft.subject.nonEmpty ?? "（无主题）").font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text("至 \(draft.to.nonEmpty ?? "未填写") · \(draft.updated.mailRelative)")
                                        .font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText).lineLimit(1)
                                }
                                Spacer()
                                Button("继续编辑") { state.editDraft(draft) }.buttonStyle(GhostButtonStyle(tint: Palette.accent))
                                Button("删除") {
                                    try? state.draftStore.remove(draft.id)
                                    reload()
                                }.buttonStyle(GhostButtonStyle(tint: Palette.rose))
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                        }
                    }.padding(12)
                }
            }
        }
        .background(Palette.elevated)
        .onAppear(perform: reload)
        .onChange(of: state.draftsVersion) { _, _ in reload() }
    }

    private func reload() {
        drafts = state.draftStore.all(accounts: Set(state.accounts.map { $0.id }))
    }
}

// MARK: - Settings Card Component

struct SettingsCard<Content: View>: View {
    let title: String?
    let detail: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.75)
        )
    }
}
