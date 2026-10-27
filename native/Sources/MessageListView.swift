import SwiftUI
import AppKit

struct MessageListView: View {
    @ObservedObject var state: AppState
    @State private var searchDraft = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            DividerLine()
            content
            footer
        }
        .background(Palette.surface)
        .onChange(of: state.scope) { _, _ in searchDraft = state.scope.kind == .search ? state.scope.query : "" }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.tertiaryText).lineLimit(1)
                Spacer()
                if state.filter != .all {
                    Button {
                        state.setFilter(.all)
                    } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.tertiaryText)
                    .help("清除筛选")
                }
                IconAction(symbol: "arrow.clockwise", help: "刷新 (⌘⌥R)") { state.refresh() }
            }
            searchBar
            filterBar
            if state.selectedKeys.count > 1 { batchBar }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(Palette.tertiaryText)
            TextField("搜索邮件（发件人、主题、正文）", text: $searchDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { state.search(searchDraft) }
                .onChange(of: state.searchFocusToken) { _, _ in searchFocused = true }
            if !searchDraft.isEmpty {
                Button {
                    searchDraft = ""; state.clearSearch()
                } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(Palette.tertiaryText)
            } else {
                Text("⌘F").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Palette.tertiaryText.opacity(0.75))
            }
            Menu {
                if !state.preferences.value.savedSearches.isEmpty {
                    Section("已保存的搜索") {
                        ForEach(state.preferences.value.savedSearches, id: \.id) { saved in
                            Button(saved.name) { searchDraft = saved.query; state.search(saved.query) }
                        }
                    }
                }
                if !state.preferences.value.searchHistory.isEmpty {
                    Section("最近搜索") {
                        ForEach(state.preferences.value.searchHistory, id: \.self) { query in
                            Button(query) { searchDraft = query; state.search(query) }
                        }
                    }
                }
                Divider()
                Button("保存当前搜索…") { saveSearch() }
                    .disabled(searchDraft.trimmed.isEmpty)
                if !state.preferences.value.searchHistory.isEmpty {
                    Button("清除搜索历史") {
                        state.preferences.value.searchHistory = []
                        state.preferences.save()
                    }
                }
                Divider()
                Menu("高级搜索") {
                    Button("来自某人…") { advanced("from:") }
                    Button("主题包含…") { advanced("subject:") }
                    Button("带附件") { searchDraft = "has:attachment"; state.search("has:attachment") }
                    Button("未读") { searchDraft = "is:unread"; state.search("is:unread") }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(Palette.tertiaryText)
            .help("搜索历史与已保存搜索")
        }
        .padding(.horizontal, 9).padding(.vertical, 5.5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }

    private var batchBar: some View {
        HStack(spacing: 6) {
            Text("已选择 \(state.selectedKeys.count) 封").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
            Spacer()
            Button("归档") { state.perform(.archive, on: state.selectedMessages()) }.buttonStyle(GhostButtonStyle())
            Button("已读") { state.perform(.read, on: state.selectedMessages()) }.buttonStyle(GhostButtonStyle())
            Button("未读") { state.perform(.unread, on: state.selectedMessages()) }.buttonStyle(GhostButtonStyle())
            Button("删除") { state.perform(.trash, on: state.selectedMessages()) }.buttonStyle(GhostButtonStyle(tint: Palette.rose))
            Button { state.selectedKeys = [] } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Palette.tertiaryText)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.accent.opacity(0.07)))
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(ListFilter.allCases) { item in
                FilterChip(title: item.title,
                           symbol: item.symbol,
                           active: state.filter == item) {
                    state.setFilter(item)
                }
            }
            Spacer()
            if state.loading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if state.scope.kind == .outbox {
            outboxList
        } else if state.rows.isEmpty {
            if state.loading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在同步邮件…").font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    EmptyState(symbol: emptySymbol, title: emptyTitle, message: emptyMessage)
                    if let account = state.accounts.first(where: { state.accountErrors[$0.id] != nil }) {
                        Button("重新登录 \(account.name)") { state.relogin(account) }
                            .buttonStyle(PrimaryButtonStyle())
                            .padding(.bottom, 40)
                    }
                }
            }
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(state.rows.enumerated()), id: \.element.key) { index, message in
                        if index == 0 || (message.pinned == true) != (state.rows[index - 1].pinned == true) ||
                            (message.pinned != true && !Calendar.current.isDate(message.date, inSameDayAs: state.rows[index - 1].date)) {
                            Text(message.pinned == true ? "置顶" : dayLabel(message.date))
                                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, index == 0 ? 3 : 12).padding(.bottom, 4)
                        }
                        MessageRow(message: message,
                                   account: state.accounts.first { $0.id == message.accountID },
                                   labels: labels(for: message),
                                   selected: state.selectedKeys.contains(message.key) || state.isActiveConversation(message),
                                   compact: state.preferences.value.compactRows,
                                   previewLines: state.preferences.value.previewLines,
                                   accountEmail: state.email(for: message.accountID),
                                   showAccount: state.showsAccountBadge)
                            .onTapGesture { select(message) }
                            .contextMenu { menu(for: message) }
                            .padding(.horizontal, 6)
                    }
                    if state.loadingMore {
                        ProgressView().controlSize(.small).padding(.vertical, 12)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var outboxList: some View {
        Group {
            if state.outbox.isEmpty {
                EmptyState(symbol: "paperplane", title: "发件箱为空", message: "离线发送与定时发送的邮件会先进入这里。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.outbox) { item in
                            OutboxRow(item: item, account: state.accounts.first { $0.id == item.accountID }, progress: state.uploadProgress[item.id]) {
                                state.sendNow(item.id)
                            } cancel: {
                                state.cancelOutbox(item.id)
                            } retry: {
                                state.retryOutbox(item.id)
                            } confirmSent: {
                                state.confirmOutboxSent(item.id)
                            }
                            .padding(.horizontal, 8)
                        }
                    }.padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if state.scope.kind != .outbox, !state.uploadProgress.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(state.outbox.filter { state.uploadProgress[$0.id] != nil }) { item in
                    if let progress = state.uploadProgress[item.id] {
                        Button { state.showOutbox() } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                ProgressView(value: progress.fraction).tint(Palette.accent)
                                Text(progress.label).font(.system(size: 10)).lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain).help("查看发件箱上传进度")
                        .accessibilityLabel(progress.label)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Palette.surface)
            .overlay(alignment: .top) { DividerLine() }
        }
        if !state.rows.isEmpty {
            HStack(spacing: 8) {
                Text("\(state.rows.count) 个会话").font(.system(size: 10.5)).foregroundStyle(Palette.tertiaryText)
                Spacer()
                if canLoadMore {
                    Button("加载更多") { state.loadMore() }
                        .buttonStyle(GhostButtonStyle())
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Palette.surface)
            .overlay(alignment: .top) { DividerLine() }
        }
    }

    private var canLoadMore: Bool { state.canLoadMoreResults }

    // MARK: Helpers

    private func select(_ message: MailMessage) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) || flags.contains(.shift) {
            if state.selectedKeys.contains(message.key) { state.selectedKeys.remove(message.key) }
            else { state.selectedKeys.insert(message.key) }
            return
        }
        state.selectedKeys = [message.key]
        state.open(message, preferLatest: true)
    }

    private func labels(for message: MailMessage) -> [MailLabel] {
        guard let ids = message.labels, !ids.isEmpty else { return [] }
        let all = state.labelsByAccount[message.accountID] ?? []
        return all.filter { ids.contains($0.id) }
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    private var title: String {
        switch state.scope.kind {
        case .all: return "所有收件箱"
        case .sent: return "所有已发送"
        case .unread: return "未读"
        case .flagged: return "重要"
        case .attachments: return "附件"
        case .offline: return "离线保存"
        case .outbox: return "发件箱"
        case .search: return "搜索"
        case .label: return state.scope.label?.name ?? "标签"
        case .folder:
            guard let accountID = state.scope.accountID, let folderID = state.scope.folderID,
                  let folder = state.folders(accountID).first(where: { $0.id == folderID }) else { return "邮件" }
            return folder.title
        }
    }

    private var subtitle: String {
        switch state.scope.kind {
        case .search: return "“\(state.scope.query)”"
        case .all, .sent: return state.loading ? "同步中…" : "\(state.accounts.count) 个账号"
        case .folder, .label:
            if let accountID = state.scope.accountID, let account = state.accounts.first(where: { $0.id == accountID }) {
                return account.name
            }
            return ""
        default: return state.loading ? "同步中…" : ""
        }
    }

    private var emptySymbol: String {
        switch state.scope.kind {
        case .search: return "magnifyingglass"
        case .unread: return "checkmark.circle"
        case .attachments: return "paperclip"
        case .flagged: return "flag"
        case .offline: return "arrow.down.circle"
        case .sent: return "paperplane"
        default: return "tray"
        }
    }

    private var emptyTitle: String {
        switch state.scope.kind {
        case .search: return "没有匹配的邮件"
        case .unread: return "没有未读邮件"
        case .attachments: return "没有带附件的邮件"
        case .flagged: return "没有标记的邮件"
        case .offline: return "没有离线保存的邮件"
        case .sent: return "没有已发送邮件"
        default: return state.accounts.isEmpty ? "尚未添加账号" : "收件箱为空"
        }
    }

    private var emptyMessage: String {
        if state.accounts.isEmpty { return "点击左下角的 ＋ 添加账号，登录后自动汇总所有收件箱。" }
        if let error = state.accountErrors.values.first { return error }
        return "新邮件到达时会自动出现在这里。"
    }

    @ViewBuilder private func menu(for message: MailMessage) -> some View {
        let current = state.messageStore[message.key] ?? message
        let reminded = state.messageReminderDate(current) != nil
        ForEach(MailContextCommand.allCases) { command in
            if command == .reply || command == .spam || command == .reminder { Divider() }
            Button(command.title(pinned: current.pinned == true, reminded: reminded),
                   role: command == .delete ? .destructive : nil) {
                runContextCommand(command, message: current)
            }
            if command == .reminder && reminded {
                Button("取消提醒") { state.cancelMessageReminder(current) }
            }
        }
    }

    private func runContextCommand(_ command: MailContextCommand, message: MailMessage) {
        switch command {
        case .sender: state.searchContextMessage(message, field: .sender)
        case .subject: state.searchContextMessage(message, field: .subject)
        case .reply, .replyAll, .forward:
            let mode: ComposeMode = command == .reply ? .reply : (command == .replyAll ? .replyAll : .forward)
            Task { @MainActor in await state.composeContextMessage(message, mode: mode) }
        case .spam: state.perform(.spam, on: [message])
        case .delete: state.perform(.trash, on: [message])
        case .reminder: state.presentMessageReminder(message)
        case .pin: state.togglePin(message)
        }
    }

    private func saveSearch() {
        let value = searchDraft.trimmed
        guard !value.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "保存搜索"
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            state.saveSearch(name: field.stringValue.trimmed.isEmpty ? value : field.stringValue.trimmed, query: value)
        }
    }

    private func advanced(_ prefix: String) {
        let alert = NSAlert()
        alert.messageText = prefix.hasPrefix("from") ? "搜索发件人" : "搜索主题"
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "搜索"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmed.isEmpty {
            let query = prefix + field.stringValue.trimmed
            searchDraft = query
            state.search(query)
        }
    }
}

// MARK: - Message row

struct MessageRow: View {
    let message: MailMessage
    let account: MailAccount?
    let labels: [MailLabel]
    let selected: Bool
    // Keep pointer updates local: crossing rows must not invalidate the inbox.
    @State private var hovered = false
    var compact = false
    var previewLines = 1
    var accountEmail = ""
    var showAccount = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(text: message.sender, size: 34)
                if message.unread {
                    Circle().fill(Palette.accent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Palette.surface, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if message.unread {
                        Circle().fill(MailFolderPalette.inbox)
                            .frame(width: 6.5, height: 6.5)
                    }
                    if message.pinned == true {
                        Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(Palette.amber)
                    }
                    Text(message.sender.isEmpty ? "未知发件人" : message.sender)
                        .font(.system(size: 12.5, weight: message.unread ? .semibold : .medium))
                        .foregroundStyle(selected ? Palette.accent : Color.primary.opacity(message.unread ? 1 : 0.88))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // Both layers reserve the same geometry, avoiding a row
                    // relayout when the date changes to pointer quick actions.
                    ZStack(alignment: .trailing) {
                        Text(message.date.mailRelative)
                            .font(.system(size: 10.5, weight: message.unread ? .semibold : .regular))
                            .foregroundStyle(message.unread ? Palette.accent : Palette.tertiaryText)
                            .monospacedDigit()
                            .opacity(hovered ? 0 : 1)
                            .accessibilityHidden(hovered)
                        RowQuickActions(message: message)
                            .opacity(hovered ? 1 : 0)
                            .allowsHitTesting(hovered)
                            .accessibilityHidden(!hovered)
                    }
                }
                HStack(spacing: 5) {
                    Text(message.subject)
                        .font(.system(size: 12.5, weight: message.unread ? .medium : .regular))
                        .foregroundStyle(message.unread ? Color.primary : Palette.secondaryText)
                        .lineLimit(1)
                    if let count = message.threadCount, count > 1 {
                        Text("\(count)")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    Spacer(minLength: 2)
                    if message.attachment {
                        Image(systemName: "paperclip").font(.system(size: 9.5)).foregroundStyle(Palette.tertiaryText)
                    }
                    if message.hasFlag {
                        Image(systemName: "star.fill").font(.system(size: 9.5)).foregroundStyle(MailFolderPalette.starred)
                    }
                }
                if !message.preview.isEmpty, previewLines > 0 {
                    Text(Trust.entities(message.preview).split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText.opacity(message.unread ? 0.85 : 0.65))
                        .lineLimit(previewLines)
                }
                if !labels.isEmpty || (showAccount && !accountEmail.isEmpty) {
                    HStack(spacing: 4) {
                        ForEach(labels.prefix(3)) { label in
                            HStack(spacing: 3) {
                                Circle().fill(Palette.label(label.color)).frame(width: 5, height: 5)
                                Text(label.name).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                            }
                            .foregroundStyle(Palette.label(label.color))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Palette.label(label.color).opacity(0.1)))
                        }
                        Spacer(minLength: 6)
                        if showAccount, !accountEmail.isEmpty { mailboxBadge }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, compact ? 6 : 9).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
            .fill(selected ? Palette.accent.opacity(0.12) : hovered ? Color.primary.opacity(0.04) : .clear))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Palette.accent)
                    .frame(width: 3, height: 26)
                    .padding(.leading, 1)
            } else if message.unread {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(MailFolderPalette.inbox.opacity(0.85))
                    .frame(width: 3, height: 18)
                    .padding(.leading, 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            guard hovered != inside else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { hovered = inside }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.sender)，\(message.subject)，\(message.date.mailRelative)\(message.unread ? "，未读" : "")")
    }

    private var mailboxBadge: some View {
        let tint = Palette.avatar(for: message.accountID)
        return HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(accountEmail)
                .font(.system(size: 9.2, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill(Color.primary.opacity(0.045)))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
        .help(accountEmail)
    }
}

struct RowQuickActions: View {
    let message: MailMessage
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 2) {
            Button { state.perform(message.archived == true ? .unarchive : .archive, on: [message]) } label: {
                Image(systemName: "archivebox").font(.system(size: 10.5))
            }
            .help("归档")
            Button { state.perform(.trash, on: [message]) } label: {
                Image(systemName: "trash").font(.system(size: 10.5))
            }
            .help("删除")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.secondaryText)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Palette.surface))
    }
}

struct OutboxRow: View {
    let item: OutboxItem
    let account: MailAccount?
    let progress: MailUploadProgress?
    let sendNow: () -> Void
    let cancel: () -> Void
    let retry: () -> Void
    let confirmSent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Palette.amber)
                Text(item.subject.isEmpty ? "（无主题）" : item.subject).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer()
                Text(stateLabel).font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(stateTint)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(stateTint.opacity(0.12)))
            }
            Text("至：\(item.to)").font(.system(size: 11)).foregroundStyle(Palette.secondaryText).lineLimit(1)
            if let progress {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: progress.fraction).tint(Palette.accent)
                    Text(progress.label).font(.system(size: 10)).foregroundStyle(Palette.secondaryText)
                        .lineLimit(2).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(progress.label)
            }
            if let error = item.error {
                Text(error).font(.system(size: 10)).foregroundStyle(Palette.rose)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let scheduled = item.scheduledAt, item.state == "queued" {
                    Text("计划 \(scheduled.mailRelative) \(timeString(scheduled))")
                        .font(.system(size: 10)).foregroundStyle(Palette.tertiaryText)
                }
                Spacer()
                if item.state == "queued" {
                    Button("立即发送", action: sendNow).buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Palette.accent)
                }
                if item.state == "failed" || item.state == "uncertain" {
                    Button("重试", action: retry).buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Palette.accent)
                }
                if item.state == "uncertain" {
                    Button("已核对并确认发送", action: confirmSent).buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Palette.accent)
                }
                if ["queued", "failed"].contains(item.state) {
                    Button("取消并保留草稿", action: cancel).buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Palette.rose)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }

    private var stateLabel: String {
        switch item.state {
        case "queued": return item.scheduledAt == nil ? "待发送" : "已安排"
        case "sending": return "发送中"
        case "sent": return "已发送"
        case "failed": return "失败"
        case "uncertain": return "待核对"
        default: return item.state
        }
    }
    private var stateTint: Color {
        switch item.state {
        case "failed", "uncertain": return Palette.rose
        case "sent": return Palette.mint
        default: return Palette.amber
        }
    }
    private func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
    }
}
