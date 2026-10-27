import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    SectionLabel(text: "邮箱")
                    smartRows
                    ForEach(state.accounts) { account in
                        accountSection(account)
                    }
                    if !state.outbox.isEmpty {
                        SectionLabel(text: "发送队列")
                        SidebarRow(icon: "paperplane", title: "发件箱", count: state.outbox.filter { $0.state != "sent" }.count,
                                   selected: state.scope.kind == .outbox, tint: Palette.amber) {
                            state.showOutbox()
                        }
                    }
                    labelSections
                    Spacer(minLength: 12)
                }
                .padding(.bottom, 8)
            }
            footer
        }
        .background(ColumnBackground(material: .sidebar))
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.hairline).frame(width: 0.5) }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.accentGradient)
                    Image(systemName: "envelope.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
                Text("Mail Lite").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { state.showSettings() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("偏好设置 (⌘,)")
            }
            .padding(.top, 34)
            .padding(.horizontal, 14)

            // Prominent Flectar-style Compose button
            Button { state.composeNew() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil").font(.system(size: 12, weight: .semibold))
                    Text("新建邮件").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("⌘N").font(.system(size: 10.5, weight: .medium)).opacity(0.65)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.accentGradient))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .help("写新邮件 (⌘N)")
        }
        .padding(.bottom, 6)
        .background(.ultraThinMaterial.opacity(0.001))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
    }

    private var smartRows: some View {
        VStack(spacing: 1) {
            SidebarRow(icon: "tray.fill", title: "所有收件箱", count: state.unreadTotal,
                       selected: state.scope.kind == .all, tint: MailFolderPalette.inbox) { state.showAllInbox() }
            SidebarRow(icon: "paperplane.fill", title: "所有已发送",
                       selected: state.scope.kind == .sent, tint: MailFolderPalette.sent) { state.showAllSent() }
            SidebarRow(icon: "circle.inset.filled", title: "未读",
                       selected: state.scope.kind == .unread, tint: MailFolderPalette.inbox) { state.select(Scope(kind: .unread)) }
            SidebarRow(icon: "star.fill", title: "星标邮件",
                       selected: state.scope.kind == .flagged, tint: MailFolderPalette.starred) { state.select(Scope(kind: .flagged)) }
            SidebarRow(icon: "paperclip", title: "附件",
                       selected: state.scope.kind == .attachments, tint: MailFolderPalette.attachments) { state.select(Scope(kind: .attachments)) }
            if !state.preferences.value.offlineSaved.isEmpty {
                SidebarRow(icon: "arrow.down.circle.fill", title: "离线保存", count: state.preferences.value.offlineSaved.count,
                           selected: state.scope.kind == .offline, tint: Palette.mint) { state.select(Scope(kind: .offline)) }
            }
        }
    }

    @ViewBuilder private func accountSection(_ account: MailAccount) -> some View {
        let expanded = state.expandedAccounts.contains(account.id)
        let error = state.accountErrors[account.id]
        VStack(spacing: 1) {
            HStack(spacing: 7) {
                Button {
                    if expanded { state.expandedAccounts.remove(account.id) } else { state.expandedAccounts.insert(account.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.tertiaryText)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                Avatar(text: account.name, size: 20)
                Text(account.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let error {
                    Button {
                        if error.contains("登录") { state.relogin(account) }
                        else { state.refresh() }
                    } label: {
                        Text(error.contains("登录") ? "重新验证" : "重试")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Palette.rose)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(Palette.rose.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help(error)
                } else {
                    Circle()
                        .fill(Palette.mint)
                        .frame(width: 6, height: 6)
                        .help("已连接")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Rectangle())
            .help(state.email(for: account.id))
            .onTapGesture { openInbox(account) }
            .contextMenu {
                Button("打开收件箱") { openInbox(account) }
                Button("重新登录…") { state.relogin(account) }
                Button("重命名…") { rename(account) }
                Divider()
                Button("新建文件夹…") { newFolder(account) }
                if let trash = state.systemFolder(account.id, "Trash") {
                    Button("清空回收站…") { confirmEmptyTrash(account, trash) }
                }
                Divider()
                Button("移除账号…", role: .destructive) { confirmRemove(account) }
            }

            if expanded {
                ForEach(orderedFolders(account)) { folder in
                    SidebarRow(icon: icon(for: folder), title: folder.title,
                               count: folderCount(account, folder),
                               selected: state.scope.kind == .folder && state.scope.folderID == folder.id,
                               tint: tint(for: folder),
                               indent: 24) {
                        state.select(Scope(kind: .folder, accountID: account.id, folderID: folder.id))
                    }
                    .contextMenu {
                        Button("打开") { state.select(Scope(kind: .folder, accountID: account.id, folderID: folder.id)) }
                        if folder.systemName == nil {
                            Button("重命名…") { renameFolder(account, folder) }
                            Button("删除文件夹…", role: .destructive) { confirmDeleteFolder(account, folder) }
                        }
                        if ["Trash", "Spam"].contains(folder.systemName) {
                            Divider()
                            Button("清空\(folder.title)…", role: .destructive) { confirmEmptyTrash(account, folder) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var labelSections: some View {
        if state.accounts.contains(where: { !(state.labelsByAccount[$0.id] ?? []).isEmpty }) {
            SectionLabel(text: "标签")
        }
        ForEach(state.accounts) { account in
            let labels = state.labelsByAccount[account.id] ?? []
            if !labels.isEmpty {
                Text(account.name.split(separator: "@").first.map(String.init) ?? account.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.tertiaryText.opacity(0.85))
                    .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 2)
                ForEach(labels) { label in
                    Button {
                        state.select(Scope(kind: .label, accountID: account.id, label: label))
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Palette.label(label.color)).frame(width: 7, height: 7)
                            Text(label.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .padding(.leading, 18)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(state.scope.kind == .label && state.scope.label?.id == label.id ? Palette.accent.opacity(0.14) : .clear))
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("查看标签邮件") { state.select(Scope(kind: .label, accountID: account.id, label: label)) }
                        Button("删除标签…", role: .destructive) { state.deleteLabel(accountID: account.id, label: label) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            DividerLine()
            HStack(spacing: 8) {
                Circle()
                    .fill(state.readyAccounts == state.totalAccounts && !state.accounts.isEmpty ? Palette.mint : Palette.orange)
                    .frame(width: 6, height: 6)
                Text(state.accounts.isEmpty ? "未添加账号" : "\(state.readyAccounts)/\(state.totalAccounts) 个账号")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondaryText)
                Spacer()
                IconAction(symbol: "plus", help: "添加账号") { addAccount() }
                IconAction(symbol: "gearshape", help: "设置 (⌘,)") { state.showSettings() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func openInbox(_ account: MailAccount) {
        if let inbox = state.systemFolder(account.id, "Inbox") {
            state.select(Scope(kind: .folder, accountID: account.id, folderID: inbox.id))
        } else {
            state.select(Scope(kind: .all, accountID: account.id))
        }
    }

    private func orderedFolders(_ account: MailAccount) -> [MailFolder] {
        let order = ["Inbox", "Drafts", "Sent", "Snoozed", "Outbox", "Spam", "Trash", "Templates"]
        let all = state.folders(account.id).filter {
            !["Notification", "Newsletter", "Templates"].contains($0.systemName ?? "") &&
            !["Notification", "Newsletter", "Templates"].contains($0.name)
        }
        let system = all.filter { $0.systemName != nil }.sorted {
            (order.firstIndex(of: $0.systemName ?? "") ?? 99) < (order.firstIndex(of: $1.systemName ?? "") ?? 99)
        }
        let custom = all.filter { $0.systemName == nil }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        return system + custom
    }

    private func icon(for folder: MailFolder) -> String {
        switch folder.systemName {
        case "Inbox": return "tray.fill"
        case "Drafts": return "doc.text.fill"
        case "Sent": return "paperplane.fill"
        case "Snoozed": return "clock.fill"
        case "Outbox": return "tray.and.arrow.up.fill"
        case "Spam": return "exclamationmark.shield.fill"
        case "Trash": return "trash.fill"
        case "Templates": return "doc.on.doc.fill"
        case "Archive": return "archivebox.fill"
        default: return "folder.fill"
        }
    }

    private func tint(for folder: MailFolder) -> Color {
        switch folder.systemName {
        case "Inbox": return MailFolderPalette.inbox
        case "Sent": return MailFolderPalette.sent
        case "Drafts": return MailFolderPalette.drafts
        case "Snoozed": return Palette.sky
        case "Outbox": return MailFolderPalette.outbox
        case "Spam": return MailFolderPalette.spam
        case "Trash": return MailFolderPalette.trash
        case "Archive": return MailFolderPalette.archive
        case "Templates": return Palette.amber
        default: return Palette.secondaryText.opacity(0.8)
        }
    }

    private func folderCount(_ account: MailAccount, _ folder: MailFolder) -> Int {
        if folder.systemName == "Inbox" { return state.folderUnread(account.id, folder) }
        if folder.systemName == "Drafts" { return state.folders(account.id).isEmpty ? 0 : 0 }
        return 0
    }

    private func addAccount() {
        let alert = NSAlert()
        alert.messageText = "添加邮箱账号"
        alert.informativeText = "每个账号使用独立会话；登录页在独立窗口打开。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        let name = NSTextField(string: "")
        name.placeholderString = "账号名称或邮箱"
        let region = NSPopUpButton()
        Region.all.forEach { region.addItem(withTitle: "\($0.name) · \($0.domain)") }
        let stack = NSStackView(views: [name, region])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 64)
        name.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.addAccount(name: name.stringValue, region: Region.all[max(0, region.indexOfSelectedItem)])
    }

    private func rename(_ account: MailAccount) {
        let alert = NSAlert()
        alert.messageText = "重命名账号"
        alert.informativeText = "只修改本机显示名称，不改变登录身份。"
        let field = NSTextField(string: account.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { state.renameAccount(account, to: field.stringValue) }
    }

    private func newFolder(_ account: MailAccount) {
        let alert = NSAlert()
        alert.messageText = "新建文件夹"
        alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: "")
        field.placeholderString = "文件夹名称"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn { state.createFolder(accountID: account.id, name: field.stringValue, parent: nil) }
    }

    private func renameFolder(_ account: MailAccount, _ folder: MailFolder) {
        let alert = NSAlert()
        alert.messageText = "重命名文件夹"
        let field = NSTextField(string: folder.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { state.renameFolder(accountID: account.id, folder: folder, name: field.stringValue) }
    }

    private func confirmDeleteFolder(_ account: MailAccount, _ folder: MailFolder) {
        let alert = NSAlert()
        alert.messageText = "删除文件夹“\(folder.name)”？"
        alert.informativeText = "文件夹中的邮件会保留在服务器上的原位置或按 Zoho 规则处理，本客户端不猜测结果。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { state.deleteFolder(accountID: account.id, folder: folder) }
    }

    private func confirmEmptyTrash(_ account: MailAccount, _ folder: MailFolder) {
        let alert = NSAlert()
        alert.messageText = "清空\(folder.title)？"
        alert.informativeText = "这是服务器上的永久删除操作，无法撤销。"
        alert.addButton(withTitle: "清空"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if folder.systemName == "Trash" { state.emptyTrash(account) } else { state.emptyFolder(account, folder) }
    }

    private func confirmRemove(_ account: MailAccount) {
        let alert = NSAlert()
        alert.messageText = "移除账号 \(account.name)？"
        alert.informativeText = "将清除本机保存的登录状态、缓存和草稿索引；服务器上的邮件不受影响。"
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { state.removeAccount(account) }
    }
}

struct SidebarRow: View {
    let icon: String
    let title: String
    var count: Int = 0
    var selected: Bool = false
    var tint: Color = Palette.secondaryText
    var indent: CGFloat = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(selected ? Palette.accent : tint)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.accent : Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Badge(count: count, tint: selected ? Palette.accent : Palette.secondaryText.opacity(0.6))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .padding(.leading, indent)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.accent.opacity(0.12) : hovering ? Color.primary.opacity(0.04) : .clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Palette.accent)
                        .frame(width: 3, height: 16)
                        .padding(.leading, max(2, indent - 6))
                }
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}
