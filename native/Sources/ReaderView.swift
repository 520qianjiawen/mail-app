import SwiftUI
import AppKit
import WebKit
import PDFKit
import Quartz
import UniformTypeIdentifiers

struct ReaderPane: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var showRecipients = false
    @State private var showRemoteImages = false
    @State private var plainText = false
    @State private var bodyHeight: CGFloat = 60
    @State private var bodyWebView: WKWebView?
    @State private var paperBody = false
    @State private var showAllThreads = false
    @State private var dismissExternalBanner = false
    @State private var expandedThreadKeys: Set<String> = []
    @State private var imageDiagnosticReport: String?
    @State private var imageDiagnosticBusy = false
    @State private var expandQuotedHistory = false

    @State private var memoKey: String = ""
    @State private var memoProjection: MailHistoryProjection.Result = .init(html: "", folded: false)
    @State private var memoRenderedHTML: String = ""
    @State private var memoSessionSources: [String] = []
    @State private var memoHasRemote: Bool = false
    @State private var memoPlainText: String = ""

    private func bodyRenderKey(_ detail: MailDetail) -> String {
        "\(detail.message.key):\(expandQuotedHistory):\(showRemoteImages):\(state.preferences.value.loadRemoteImages):\(isDark):\(paperBody)"
    }

    private var message: MailMessage? {
        guard let key = state.activeKey else { return nil }
        return state.messageStore[key] ?? state.rows.first { $0.key == key }
    }

    private var currentIndex: Int? {
        state.activeConversationIndex()
    }
    private var hasPrevious: Bool {
        guard let idx = currentIndex else { return false }
        return idx > 0
    }
    private var hasNext: Bool {
        guard let idx = currentIndex else { return false }
        return idx < state.rows.count - 1
    }
    private func selectPrevious() {
        guard let idx = currentIndex, idx > 0 else { return }
        state.open(state.rows[idx - 1], preferLatest: true)
    }
    private func selectNext() {
        guard let idx = currentIndex, idx < state.rows.count - 1 else { return }
        state.open(state.rows[idx + 1], preferLatest: true)
    }

    var body: some View {
        ZStack {
            Palette.elevated
            if let inlineModel = currentInlineReplyModel {
                ComposeView(model: inlineModel,
                            isInline: true,
                            onPopOut: { state.popOutInlineReply() },
                            onDismiss: { state.closeInlineReply(save: true) })
                    .id(inlineModel.draft.id)
            } else if let message {
                reader(message)
                    .id(message.key)
            } else {
                EmptyState(symbol: "envelope.open", title: "选择一封邮件",
                           message: "列表中的邮件会在这里直接展开。回复、标签、延迟与附件都在同一处完成。")
            }
        }
        .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 0.5) }
        .onExitCommand {
            if state.inlineReplyModel != nil {
                state.closeInlineReply(save: true)
            } else {
                state.closeReader()
            }
        }
        .alert("图片诊断", isPresented: Binding(get: { imageDiagnosticReport != nil }, set: { if !$0 { imageDiagnosticReport = nil } })) {
            Button("复制诊断") {
                if let report = imageDiagnosticReport {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
            }
            Button("关闭", role: .cancel) { imageDiagnosticReport = nil }
        } message: { Text(imageDiagnosticReport ?? "") }
        .onChange(of: state.activeKey) { _, _ in
            expandQuotedHistory = false
            bodyHeight = 60
            bodyWebView = nil
            showRemoteImages = false
            showRecipients = false
            expandedThreadKeys = []
            dismissExternalBanner = false
        }
    }

    private var currentInlineReplyModel: ComposeModel? {
        guard let model = state.inlineReplyModel else { return nil }
        guard let sourceMessage = model.draft.source?.message else { return nil }
        return state.isActiveConversation(sourceMessage) ? model : nil
    }

    @ViewBuilder private func reader(_ message: MailMessage) -> some View {
        let detail = state.detail?.message.key == message.key ? state.detail : nil
        VStack(spacing: 0) {
            actionBar(message, detail: detail)
            composePreparationFeedback
            DividerLine()
            readerScrollView(message, detail: detail)
        }
        .task(id: detail.map(bodyRenderKey) ?? "") {
            guard let detail else { return }
            let key = bodyRenderKey(detail)
            let shouldExpand = expandQuotedHistory
            let images = showRemoteImages || state.preferences.value.loadRemoteImages
            let dark = isDark && !paperBody
            let paper = isDark && paperBody
            let worker = Task.detached(priority: .userInitiated) { () -> (MailHistoryProjection.Result, String, [String], Bool, String) in
                let projection = MailHistoryProjection.summary(detail.html)
                let displayed = shouldExpand ? detail.html : projection.html
                let rendered = MailHTML.document(displayed, inline: detail.inline,
                                                 images: images, dark: dark, paper: paper)
                let sources = MailImageDiagnostics.providerSessionSources(detail)
                let remote = detail.html.range(of: "(?:src|background)\\s*=\\s*['\"]?https?://",
                                               options: [.regularExpression, .caseInsensitive]) != nil
                let plain = MailHTML.plainText(displayed)
                return (projection, rendered, sources, remote, plain)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            memoKey = key
            memoProjection = result.0
            memoRenderedHTML = result.1
            memoSessionSources = result.2
            memoHasRemote = result.3
            memoPlainText = result.4
        }
    }

    private func readerScrollView(_ message: MailMessage, detail: MailDetail?) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if let error = state.readingError {
                    HStack {
                        Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber)
                        Spacer()
                        Button("重试") { state.retryReading() }.buttonStyle(.plain)
                    }
                }
                subjectBlock(message, detail: detail)
                VStack(alignment: .leading, spacing: 12) {
                    header(message, detail: detail)
                    MailSentStatusBanner(state: state, message: message)
                    MailTrackingReaderStatus(controller: state.tracking, message: message)
                    if showRecipients, let detail {
                        recipientCard(detail, message: message)
                    }
                    if !labels(for: message).isEmpty { labelRow(message) }
                    snoozedBanner(message)
                    if isExternalSender(detail?.from ?? message.sender, accountID: message.accountID) && !dismissExternalBanner {
                        externalBanner(detail?.from ?? message.sender)
                    }
                    if let detail, !detail.visibleAttachments.isEmpty {
                        MailAttachmentSection(files: detail.visibleAttachments, message: message, state: state)
                            .id(message.key)
                    }
                    if let detail {
                        let ready = memoKey == bodyRenderKey(detail)
                        if ready && memoHasRemote && !showRemoteImages && !state.preferences.value.loadRemoteImages {
                            remoteBanner
                        }
                        if ready {
                            VStack(alignment: .leading, spacing: 0) {
                                if plainText {
                                    Text(memoPlainText)
                                        .font(.system(size: 13.5))
                                        .lineSpacing(5)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 4)
                                } else {
                                    MailBodyView(html: memoRenderedHTML,
                                                 inline: detail.inline, message: message, state: state,
                                                 detailHTML: detail.html,
                                                 allowRemote: showRemoteImages || state.preferences.value.loadRemoteImages,
                                                 dark: isDark && !paperBody,
                                                 paper: isDark && paperBody,
                                                 sessionImageSources: memoSessionSources,
                                                 height: $bodyHeight, webView: $bodyWebView)
                                        .frame(height: max(60, bodyHeight))
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("reader.messageBody")
                        } else {
                                ProgressView("正在整理邮件正文…")
                                    .font(.system(size: 11))
                                    .frame(maxWidth: .infinity, minHeight: 80)
                        }
                        if ready && memoProjection.folded {
                                Button {
                                    expandQuotedHistory.toggle()
                                } label: {
                                    Label(expandQuotedHistory ? "收起引用原文" : "展开引用原文", systemImage: expandQuotedHistory ? "chevron.up" : "ellipsis.bubble")
                                }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.accent).padding(.vertical, 5)
                                .accessibilityIdentifier("reader.quotedHistory")
                        }
                    } else {
                        bodySkeleton
                    }
                }
                .padding(16)
                .modifier(ConversationCardSurface(outgoing: conversationIsOutgoing(message, detail: detail, state: state)))
                if state.threadRows.count > 1 { threadSection(message) }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: Action bar

    @ViewBuilder private var composePreparationFeedback: some View {
        if !state.composeSourcePending.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在准备邮件原文与图片…").font(.system(size: 11))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .accessibilityIdentifier("reader.composeProgress")
        } else if let error = state.composePreparationFailure {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.amber)
                Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("重试") { state.composePreparationRetry?() }.buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                Button {
                    state.composePreparationFailure = nil; state.composePreparationRetry = nil
                } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("关闭回复提示")
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Palette.amber.opacity(0.08))
            .accessibilityIdentifier("reader.composeError")
        }
    }

    private func actionBar(_ message: MailMessage, detail: MailDetail?) -> some View {
        ViewThatFits(in: .horizontal) {
            primaryActions(message, detail: detail, showsNavigation: true)
            primaryActions(message, detail: detail, showsNavigation: false)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Palette.elevated)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.primaryActions")
    }

    private func primaryActions(_ message: MailMessage, detail: MailDetail?, showsNavigation: Bool) -> some View {
        HStack(spacing: 5) {
            Button { if let detail { state.composeReply(detail, mode: .reply) } } label: {
                Label("回复", systemImage: "arrowshape.turn.up.left.fill")
            }
            .buttonStyle(GhostButtonStyle(tint: MailFolderPalette.inbox))
            .disabled(detail == nil || state.composeSourcePending.contains(message.key))
            .help("回复发件人 (⌘R)")
            IconAction(symbol: "arrowshape.turn.up.left.2", help: "回复全部 (⇧⌘R)") {
                if let detail { state.composeReply(detail, mode: .replyAll) }
            }
            .accessibilityLabel("回复全部")
            .disabled(detail == nil || state.composeSourcePending.contains(message.key))
            IconAction(symbol: "arrowshape.turn.up.right", help: "转发") {
                if let detail { state.composeReply(detail, mode: .forward) }
            }
            .accessibilityLabel("转发")
            .disabled(detail == nil || state.composeSourcePending.contains(message.key))
            Spacer(minLength: 12)
            IconAction(symbol: message.hasFlag ? "star.fill" : "star",
                       help: message.hasFlag ? "取消星标" : "标记星标",
                       tint: message.hasFlag ? MailFolderPalette.starred : Palette.secondaryText) {
                state.toggleFlag(message)
            }
            .accessibilityLabel(message.hasFlag ? "取消星标" : "标记星标")
            IconAction(symbol: "archivebox", help: message.archived == true ? "取消归档" : "归档 (⌃⌘A)") {
                state.perform(message.archived == true ? .unarchive : .archive, on: targetMessages(message))
            }
            .accessibilityLabel(message.archived == true ? "取消归档" : "归档")
            IconAction(symbol: "trash", help: "删除 (⌘⌫)") {
                state.perform(.trash, on: targetMessages(message))
            }
            .accessibilityLabel("删除")
            moreMenu(message, detail: detail)
            if showsNavigation {
                Spacer().frame(width: 8)
                IconAction(symbol: "chevron.up", help: "上一封 (K)") { selectPrevious() }
                    .accessibilityLabel("上一封")
                    .disabled(!hasPrevious)
                IconAction(symbol: "chevron.down", help: "下一封 (J)") { selectNext() }
                    .accessibilityLabel("下一封")
                    .disabled(!hasNext)
            }
        }
    }

    private func labelsMenu(_ message: MailMessage) -> some View {
        Menu {
            let labels = state.labelsByAccount[message.accountID] ?? []
            if labels.isEmpty {
                Text("没有可用标签")
            } else {
                ForEach(labels) { label in
                    Button {
                        state.toggleLabel(message, label: label)
                    } label: {
                        Label(label.name, systemImage: (message.labels ?? []).contains(label.id) ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
        } label: {
            Label("标签", systemImage: "tag")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("标签")
    }

    private func moveMenu(_ message: MailMessage) -> some View {
        Menu {
            ForEach(state.folders(message.accountID).filter { $0.systemName != "Templates" }) { folder in
                Button(folder.title) { state.perform(.move(folder.id), on: targetMessages(message)) }
            }
        } label: {
            Label("移动到文件夹", systemImage: "folder")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("移动到文件夹")
    }

    private func snoozeMenu(_ message: MailMessage) -> some View {
        Menu {
            Button("1 小时后") { state.snooze(message, until: Date().addingTimeInterval(3600)) }
            Button("3 小时后") { state.snooze(message, until: Date().addingTimeInterval(3 * 3600)) }
            Button("明天上午 9:00") {
                let calendar = Calendar.current
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                state.snooze(message, until: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
            }
            Button("下周同一时间") { state.snooze(message, until: Date().addingTimeInterval(7 * 86400)) }
            if message.snoozedUntil != nil {
                Divider()
                Button("取消延迟") { state.unsnooze(message) }
            }
        } label: {
            Label("延迟提醒", systemImage: "clock")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("延迟")
    }

    private func moreMenu(_ message: MailMessage, detail: MailDetail?) -> some View {
        Menu {
            Menu {
                ForEach([("important", "重要"), ("info", "通知"), ("followup", "跟进")], id: \.0) { flag in
                    Button(flag.1) { state.perform(.flag(flag.0), on: [message]) }
                }
                Divider()
                Button("清除标记") { state.perform(.flag("flag_not_set"), on: [message]) }
            } label: {
                Label("标记", systemImage: message.hasFlag ? "flag.fill" : "flag")
            }
            Button(message.pinned == true ? "取消置顶" : "置顶") { state.togglePin(message) }
            labelsMenu(message)
            moveMenu(message)
            snoozeMenu(message)
            scrubMenu(message)
            Divider()
            Button("标为未读") { state.perform(.unread, on: [message]) }
            Button(state.isOfflineSaved(message) ? "取消离线保存" : "离线保存") { state.toggleOffline(message) }
            Button(plainText ? "显示富文本" : "显示纯文本") { plainText.toggle() }
            Button(imageDiagnosticBusy ? "正在检查图片…" : "图片诊断…") {
                guard let detail, !imageDiagnosticBusy else { return }
                imageDiagnosticBusy = true
                let key = message.key
                Task { @MainActor in
                    let report = await state.imageDiagnostics(detail, remoteAllowed: showRemoteImages || state.preferences.value.loadRemoteImages, webView: bodyWebView)
                    imageDiagnosticBusy = false
                    guard state.activeKey == key else { return }
                    imageDiagnosticReport = report
                }
            }
            .disabled(detail == nil || imageDiagnosticBusy)
            if isDark {
                Button(paperBody ? "智能深色正文" : "原始配色（浅色正文）") { paperBody.toggle() }
            }
            if state.threadRows.count > 1 {
                Button("将会话标为已读") { state.perform(.read, on: state.threadRows) }
            }
            Button("打印…") { printMessage() }
            if state.isDraft(message) { Button("继续编辑草稿") { if let detail { state.editServerDraft(detail) } } }
            if detail != nil { Button("另存为新邮件") { if let detail { state.saveAsNew(detail) } } }
            Button("移至垃圾邮件") { state.perform(.spam, on: [message]) }
            Divider()
            if let email = detail?.replyAddress ?? MailAddresses.extract(message.sender).first {
                Button("阻止发件人") { state.blockSender(email, accountID: message.accountID) }
                Button("取消阻止") { state.unblockSender(email, accountID: message.accountID) }
                Button("报告网络钓鱼") { state.reportPhishing(message) }
            }
            if let detail { Button("取消订阅") { state.unsubscribe(detail) } }
            Divider()
            Button("标为未读并关闭") {
                state.perform(.unread, on: [message]); state.closeReader()
            }
            Divider()
            Button("上一封 (K)") { selectPrevious() }.disabled(!hasPrevious)
            Button("下一封 (J)") { selectNext() }.disabled(!hasNext)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("更多操作")
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("reader.moreActions")
    }

    private func targetMessages(_ message: MailMessage) -> [MailMessage] {
        state.selectedKeys.contains(message.key) ? state.selectedMessages() : [message]
    }

    // MARK: Subject and header

    private func subjectBlock(_ message: MailMessage, detail: MailDetail?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.subject.isEmpty ? "（无主题）" : message.subject)
                .font(.system(size: 21, weight: .bold))
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reader.subject")
            HStack(spacing: 6) {
                if let account = state.accounts.first(where: { $0.id == message.accountID }) {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.fill").font(.system(size: 9)).foregroundStyle(MailFolderPalette.inbox)
                        Text(state.email(for: account.id))
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.primary.opacity(0.04)))
                    .foregroundStyle(Palette.secondaryText)
                }
                if message.pinned == true {
                    Chip(text: "已置顶", tint: Palette.amber)
                }
                if message.threadID != nil, state.threadRows.count > 1 {
                    Chip(text: "\(state.threadRows.count) 封往来邮件", tint: Palette.accent)
                }
                if message.snoozedUntil != nil {
                    Chip(text: "已延迟", tint: Palette.sky)
                }
                Spacer()
            }
        }
    }

    private func header(_ message: MailMessage, detail: MailDetail?) -> some View {
        let sender = detail?.from ?? message.sender
        return HStack(alignment: .top, spacing: 10) {
            Avatar(text: sender, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Menu {
                    Text(sender)
                    Button("写信给发件人") { state.composeNew(accountID: message.accountID, to: address(sender)) }
                    Button("复制地址") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address(sender), forType: .string)
                    }
                    Button("查找此发件人的邮件") { state.searchContextMessage(message, field: .sender) }
                } label: {
                    HStack(spacing: 6) {
                        Text(displayName(sender))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1).layoutPriority(1)
                        if displayName(sender) != address(sender) {
                            Text(address(sender))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help(sender)
                .accessibilityLabel("发件人：\(sender)")
                if let detail { MailSourceIPBadge(source: detail.sourceIP) }
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showRecipients.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(compactRecipientSummary(detail))
                            .font(.system(size: 11))
                            .lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(showRecipients ? 180 : 0))
                    }
                    .foregroundStyle(Palette.secondaryText)
                }
                .buttonStyle(.plain)
                .help("展开详细收件人与安全信息")
                .accessibilityLabel("收件人详细信息")
                .accessibilityValue(showRecipients ? "已展开" : "已收起")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 72)
        }
        .accessibilityElement(children: .contain)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if message.replied {
                    HStack(spacing: 3) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 8.5))
                        Text("已回复")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Palette.accent.opacity(0.12)))
                }
                if message.forwarded {
                    HStack(spacing: 3) {
                        Image(systemName: "arrowshape.turn.up.right.fill")
                            .font(.system(size: 8.5))
                        Text("已转发")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Text(message.date.mailRelative).font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText)
                    .padding(.leading, 4).help(message.date.mailFull)
                    .accessibilityLabel(message.date.mailFull)
            }
        }
        .accessibilityIdentifier("reader.header")
    }

    private func labelRow(_ message: MailMessage) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(labels(for: message)) { label in
                HStack(spacing: 3) {
                    Circle().fill(Palette.label(label.color)).frame(width: 5, height: 5)
                    Text(label.name).font(.system(size: 10, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .leading)
                }
                .foregroundStyle(Palette.label(label.color))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Palette.label(label.color).opacity(0.1)))
            }
        }
    }

    private var remoteBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark").font(.system(size: 12)).foregroundStyle(Palette.amber)
            Text("已阻止外部图片，保护隐私。").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
            Spacer()
            Button("加载图片") { showRemoteImages = true }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.amber.opacity(0.08)))
    }

    private var bodySkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 12)
                    .frame(maxWidth: index == 3 ? 240 : .infinity, alignment: .leading)
            }
            if state.detailLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在读取正文…").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func threadSection(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DividerLine()
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accent)
                    Text("会话往来")
                        .font(.system(size: 11.5, weight: .semibold))
                    Chip(text: "\(state.threadRows.count) 封", tint: Palette.accent)
                }
                Spacer()
                Button(expandedThreadKeys.count >= max(1, state.threadRows.count - 1) ? "全部收起" : "展开往来正文 (\(state.threadRows.count) 封)") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedThreadKeys.count >= max(1, state.threadRows.count - 1) {
                            expandedThreadKeys.removeAll()
                        } else {
                            for m in state.threadRows {
                                expandedThreadKeys.insert(m.key)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.accent)
            }
            .padding(.top, 4)

            VStack(spacing: 12) {
                ForEach(state.threadRows, id: \.key) { member in
                    ThreadMessageCard(
                        member: member,
                        isCurrent: member.key == message.key,
                        state: state,
                        isExpanded: member.key == message.key ? false : expandedThreadKeys.contains(member.key),
                        onToggleExpand: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if member.key == message.key {
                                    // if current, clicking collapses/expands
                                } else {
                                    if expandedThreadKeys.contains(member.key) {
                                        expandedThreadKeys.remove(member.key)
                                    } else {
                                        expandedThreadKeys.insert(member.key)
                                    }
                                }
                            }
                        },
                        onSwitchActive: {
                            state.open(member, preferLatest: false)
                        }
                    )
                }
            }
        }
    }

    // MARK: Helpers

    private func compactRecipientSummary(_ detail: MailDetail?) -> String {
        guard let detail else { return "收件人信息加载中…" }
        let toList = MailAddresses.extract(detail.to)
        if toList.isEmpty { return "发送给 我" }
        if toList.count == 1 {
            return "发送给 \(toList[0])"
        }
        return "发送给 \(toList[0]) 等 \(toList.count) 人"
    }

    private func recipientCard(_ detail: MailDetail, message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let toAddresses = MailAddresses.extract(detail.to)
            if !toAddresses.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("收件人")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.tertiaryText)
                        .frame(width: 44, alignment: .trailing)
                        .padding(.top, 3)
                    FlowLayout(spacing: 4) {
                        ForEach(toAddresses, id: \.self) { addr in
                            AddressChip(rawAddress: addr) {
                                state.composeNew(accountID: message.accountID, to: addr)
                            }
                        }
                    }
                }
            }
            let ccAddresses = MailAddresses.extract(detail.cc)
            if !ccAddresses.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("抄送")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.tertiaryText)
                        .frame(width: 44, alignment: .trailing)
                        .padding(.top, 3)
                    FlowLayout(spacing: 4) {
                        ForEach(ccAddresses, id: \.self) { addr in
                            AddressChip(rawAddress: addr) {
                                state.composeNew(accountID: message.accountID, to: addr)
                            }
                        }
                    }
                }
            }
            if let bcc = detail.bcc, !bcc.isEmpty {
                let bccAddresses = MailAddresses.extract(bcc)
                if !bccAddresses.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Text("密送")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.tertiaryText)
                            .frame(width: 44, alignment: .trailing)
                            .padding(.top, 3)
                        FlowLayout(spacing: 4) {
                            ForEach(bccAddresses, id: \.self) { addr in
                                AddressChip(rawAddress: addr) {
                                    state.composeNew(accountID: message.accountID, to: addr)
                                }
                            }
                        }
                    }
                }
            }
            if !detail.replyTo.isEmpty && detail.replyTo.lowercased() != detail.from.lowercased() {
                HStack(alignment: .top, spacing: 8) {
                    Text("回复至")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.tertiaryText)
                        .frame(width: 44, alignment: .trailing)
                        .padding(.top, 3)
                    AddressChip(rawAddress: detail.replyTo) {
                        state.composeNew(accountID: message.accountID, to: detail.replyTo)
                    }
                }
            }
            DividerLine().padding(.vertical, 2)
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.mint)
                Text("安全传输 (TLS/SSL) · 域名验证通过")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiaryText)
            }
            .padding(.leading, 52)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }

    private func isExternalSender(_ sender: String, accountID: String) -> Bool {
        guard let account = state.accounts.first(where: { $0.id == accountID }) else { return false }
        let ownEmail = state.email(for: account.id)
        guard let ownDomain = ownEmail.split(separator: "@").last?.lowercased(),
              let senderDomain = MailAddresses.extract(sender).first?.split(separator: "@").last?.lowercased() else {
            return false
        }
        return ownDomain != senderDomain
    }

    private func externalBanner(_ sender: String) -> some View {
        let senderEmail = MailAddresses.extract(sender).first ?? sender
        let domain = senderEmail.split(separator: "@").last.map(String.init) ?? senderEmail
        return HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 12))
                .foregroundStyle(Palette.amber)
            Text("外部发件人 · \(domain)，请核对地址与链接。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("信任发件人") {
                withAnimation(.easeOut(duration: 0.16)) { dismissExternalBanner = true }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.accent)
            .fixedSize()
            Button {
                withAnimation(.easeOut(duration: 0.16)) { dismissExternalBanner = true }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("忽略提示")
            .accessibilityLabel("忽略外部发件人提示")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.amber.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.amber.opacity(0.18), lineWidth: 0.5)
        )
        .help("此邮件来自组织外部，请核对发件人真实性，谨慎下载附件或点击邮件中的链接。")
    }

    @ViewBuilder
    private func snoozedBanner(_ message: MailMessage) -> some View {
        if let until = message.snoozedUntil {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.sky)
                Text("已设置延迟提醒：将于 \(until.mailFull) 重新显示在收件箱顶部。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.sky)
                Spacer()
                Button("取消延迟") {
                    state.unsnooze(message)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.sky)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Palette.sky.opacity(0.12)))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.sky.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.sky.opacity(0.2), lineWidth: 0.5))
        }
    }

    private func scrubMenu(_ message: MailMessage) -> some View {
        let senderEmail = MailAddresses.extract(message.sender).first ?? message.sender
        let senderDisplayName = displayName(message.sender)
        let matches = state.rows.filter {
            $0.folderID == message.folderID &&
            (MailAddresses.extract($0.sender).first?.lowercased() == senderEmail.lowercased())
        }
        return Menu {
            Text("发件人净化：\(senderDisplayName)")
            Text("当前文件夹共 \(matches.count) 封相关邮件")
            Divider()
            Button("批量归档该发件人全部邮件 (\(matches.count) 封)") {
                state.perform(.archive, on: matches)
            }
            Button("批量移入废件箱 (\(matches.count) 封)") {
                state.perform(.trash, on: matches)
            }
        } label: {
            Label("邮件净化", systemImage: "sparkles")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("邮件净化 (Scrub)：批量清理当前发件人在此文件夹的所有历史邮件")
    }

    private var isDark: Bool { colorScheme == .dark }

    private func labels(for message: MailMessage) -> [MailLabel] {
        guard let ids = message.labels, !ids.isEmpty else { return [] }
        return (state.labelsByAccount[message.accountID] ?? []).filter { ids.contains($0.id) }
    }

    private func displayName(_ raw: String) -> String {
        guard let range = raw.range(of: "<") else { return raw.trimmed }
        let name = raw[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return name.isEmpty ? raw : name
    }

    private func address(_ raw: String) -> String {
        MailAddresses.extract(raw).first ?? raw
    }

    private func recipientSummary(_ detail: MailDetail?) -> String {
        guard let detail else { return "收件人信息加载中…" }
        let to = MailAddresses.extract(detail.to).joined(separator: ", ")
        let cc = MailAddresses.extract(detail.cc).joined(separator: ", ")
        var value = "发送给 \(to.isEmpty ? "我" : to)"
        if !cc.isEmpty { value += "\n抄送 \(cc)" }
        if let bcc = detail.bcc, !bcc.isEmpty { value += "\n密送 \(bcc)" }
        return value
    }

    private func hasRemoteImages(_ html: String) -> Bool {
        html.range(of: "(?:src|background)\\s*=\\s*['\"]?https?://", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func printMessage() {
        guard let webView = bodyWebView else { state.status = "正文尚未就绪"; return }
        webView.createPDF { result in
            if case .success(let data) = result, let document = PDFDocument(data: data) {
                let info = NSPrintInfo.shared
                let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true)
                operation?.showsPrintPanel = true
                operation?.run()
            }
        }
    }
}

// MARK: - Body web view

enum MailBodyLayout {
    // document/body scrollHeight is at least the current viewport height. Using
    // it to resize that same viewport prevents shrinking and creates feedback.
    // This owned flow-root has an intrinsic height independent of the viewport.
    static let heightJavaScript = """
    (() => {
        const content = document.getElementById('mail-lite-content');
        if (!content || content.getBoundingClientRect().width <= 0) return null;
        return Math.ceil(Math.max(content.getBoundingClientRect().height, content.scrollHeight));
    })()
    """

    static func fittedHeight(_ value: NSNumber) -> CGFloat? {
        let measured = value.doubleValue
        guard measured.isFinite, measured >= 0 else { return nil }
        return max(40, CGFloat(ceil(measured)))
    }
}

final class EmailBodyWKWebView: WKWebView {
    var onContentWidthChanged: ((WKWebView) -> Void)?
    private var lastContentWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let width = bounds.width
        if width > 0, abs(width - lastContentWidth) > 0.5 {
            lastContentWidth = width
            onContentWidthChanged?(self)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward wheel event directly to enclosing parent responder (SwiftUI ScrollView)
        // This ensures the outer page always scrolls smoothly, eliminating scroll freezing!
        nextResponder?.scrollWheel(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disableInternalScrollers(in: self)
    }

    func disableInternalScrollers(in view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.verticalScroller?.isHidden = true
            scroll.horizontalScroller?.isHidden = true
            scroll.autohidesScrollers = true
        }
        for sub in view.subviews {
            disableInternalScrollers(in: sub)
        }
    }
}

struct MailBodyView: NSViewRepresentable {
    let html: String
    let inline: [MailAttachment]
    let message: MailMessage
    let state: AppState
    let detailHTML: String
    let allowRemote: Bool
    let dark: Bool
    let paper: Bool
    let sessionImageSources: [String]
    var sessionImageKey: String { message.key }
    @Binding var height: CGFloat
    @Binding var webView: WKWebView?

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler {
        var parent: MailBodyView
        var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        var lastHTML = ""
        var measureWork: DispatchWorkItem?
        var sessionImageWork: Task<Void, Never>?
        var invalidated = false
        private var documentRevision = 0
        private var measurementTicket = 0
        private var documentReady = false
        private var activeNavigation: WKNavigation?
        private var sessionOriginals: [String] = []
        var sessionFetched: [String: String] = [:]
        var sessionCurrentKey = ""
        private var sessionFetchTicket = 0

        init(_ parent: MailBodyView) { self.parent = parent }

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let key = ObjectIdentifier(task)
            let revision = documentRevision
            tasks[key] = Task { @MainActor [weak self, weak webView] in
                defer { self?.tasks.removeValue(forKey: key) }
                guard let self, !self.invalidated, !Task.isCancelled,
                      self.tasks[key] != nil, self.documentRevision == revision else { return }
                guard let id = task.request.url?.lastPathComponent,
                      let file = self.parent.inline.first(where: { $0.id == id }) else {
                    task.didFailWithError(NSError(domain: "MailLite", code: 1)); return
                }
                do {
                    let data = try await self.parent.state.attachmentData(file, message: self.parent.message)
                    guard !self.invalidated, !Task.isCancelled, self.tasks[key] != nil,
                          self.documentRevision == revision else { return }
                    guard let type = MailRasterImage.mimeType(for: data) else { throw MailFailure.response }
                    task.didReceive(URLResponse(url: task.request.url!, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
                    task.didReceive(data); task.didFinish()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak webView] in
                        guard let self, let webView, !self.invalidated,
                              self.documentRevision == revision else { return }
                        self.measure(webView)
                    }
                } catch {
                    guard !self.invalidated, !Task.isCancelled, self.tasks[key] != nil,
                          self.documentRevision == revision else { return }
                    task.didFailWithError(NSError(domain: "MailLite", code: 2))
                }
            }
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
            tasks.removeValue(forKey: ObjectIdentifier(task))?.cancel()
        }

        func load(_ html: String, into view: WKWebView) {
            documentRevision += 1
            measurementTicket += 1
            documentReady = false
            measureWork?.cancel()
            let displayHTML = MailTrackingHTML.withoutOwnedPixels(html, records: parent.state.tracking.records)
            activeNavigation = view.loadHTMLString(displayHTML, baseURL: nil)
        }

        /// Fills trusted provider-hosted images that need the account web session.
        /// The session view itself stays cookie-free; only decoded raster bytes that
        /// already passed byte validation enter the document as data URLs.
        func loadSessionImages(_ originals: [String], into view: WKWebView) {
            guard !invalidated, !originals.isEmpty else { return }
            sessionOriginals = originals
            if !sessionFetched.isEmpty {
                // A theme/paper toggle re-renders; already verified images stay inline.
                reloadWithSessionImages(sessionFetched, into: view)
            }
            sessionFetchTicket += 1
            let ticket = sessionFetchTicket
            sessionImageWork?.cancel()
            sessionImageWork = Task { @MainActor [weak self, weak view] in
                guard let self else { return }
                var updated = false
                for raw in originals.prefix(8) {
                    guard !Task.isCancelled, !self.invalidated, self.sessionFetchTicket == ticket else { break }
                    if self.sessionFetched[raw] != nil { continue }
                    do {
                        let data = try await self.parent.state.sessionImageData(raw, message: self.parent.message)
                        guard !Task.isCancelled, !self.invalidated, self.sessionFetchTicket == ticket else { break }
                        self.sessionFetched[raw] = data.base64EncodedString()
                        updated = true
                    } catch { continue }
                }
                guard !Task.isCancelled, !self.invalidated, self.sessionFetchTicket == ticket, updated else { return }
                self.reloadWithSessionImages(self.sessionFetched, into: view)
            }
        }

        private func reloadWithSessionImages(_ fetched: [String: String], into view: WKWebView?) {
            guard let view, !invalidated else { return }
            let expanded = MailHTML.document(self.parent.detailHTML, inline: self.parent.inline,
                                              images: self.parent.allowRemote, dark: self.parent.dark,
                                              paper: self.parent.paper, sessionImages: fetched)
            load(expanded, into: view)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard !invalidated, navigation === activeNavigation else { return }
            documentReady = true
            if let emailView = webView as? EmailBodyWKWebView {
                emailView.disableInternalScrollers(in: emailView)
            }
            let revision = documentRevision
            // Measure as soon as HTML DOM commits without waiting for slow/hanging external images
            for delay in [0.03, 0.1, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self, let webView, !self.invalidated,
                          self.documentRevision == revision else { return }
                    self.measure(webView)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !invalidated, navigation === activeNavigation else { return }
            documentReady = true
            if let emailView = webView as? EmailBodyWKWebView {
                emailView.disableInternalScrollers(in: emailView)
            }
            measure(webView)
            let revision = documentRevision
            // Recheck after layout settles. Revision checks prevent a previous
            // email or theme's delayed measurement from resizing the new body.
            for delay in [0.1, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self, let webView, !self.invalidated,
                          self.documentRevision == revision else { return }
                    self.measure(webView)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !invalidated, navigation === activeNavigation else { return }
            documentReady = true
            measure(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !invalidated, navigation === activeNavigation else { return }
            documentReady = true
            measure(webView)
        }

        func measure(_ webView: WKWebView) {
            guard documentReady, !invalidated else { return }
            measureWork?.cancel()
            measurementTicket += 1
            let ticket = measurementTicket
            let revision = documentRevision
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView, !self.invalidated,
                      self.measurementTicket == ticket, self.documentRevision == revision else { return }
                webView.evaluateJavaScript(MailBodyLayout.heightJavaScript) { [weak self] value, _ in
                    guard let number = value as? NSNumber,
                          let fitted = MailBodyLayout.fittedHeight(number) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, !self.invalidated, self.documentReady,
                              self.documentRevision == revision else { return }
                        if abs(fitted - self.parent.height) > 0.5 {
                            self.parent.height = fitted
                        }
                    }
                }
            }
            measureWork = work
            DispatchQueue.main.async(execute: work)
        }

        func invalidate() {
            invalidated = true
            documentReady = false
            documentRevision += 1
            measurementTicket += 1
            measureWork?.cancel()
            measureWork = nil
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            sessionFetchTicket += 1
            sessionImageWork?.cancel()
            sessionImageWork = nil
            activeNavigation = nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  url.absoluteString != "about:blank",
                  !url.absoluteString.isEmpty else {
                decisionHandler(.allow); return
            }
            if Trust.outside(url) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, Trust.outside(url) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "mail-inline")
        let view = EmailBodyWKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityLabel("邮件正文")
        view.disableInternalScrollers(in: view)
        let coordinator = context.coordinator
        view.onContentWidthChanged = { [weak coordinator] view in coordinator?.measure(view) }
        DispatchQueue.main.async { [weak coordinator, weak view] in
            guard let coordinator, let view, !coordinator.invalidated else { return }
            coordinator.parent.webView = view
        }
        return view
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        (view as? EmailBodyWKWebView)?.onContentWidthChanged = nil
        view.uiDelegate = nil
        view.navigationDelegate = nil
        view.stopLoading()
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if let emailView = view as? EmailBodyWKWebView {
            emailView.disableInternalScrollers(in: emailView)
        }
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            context.coordinator.load(html, into: view)
        } else if height <= 60 {
            context.coordinator.measure(view)
        }
        if context.coordinator.sessionCurrentKey != sessionImageKey {
            context.coordinator.sessionCurrentKey = sessionImageKey
            context.coordinator.sessionFetched = [:]
            context.coordinator.loadSessionImages(sessionImageSources, into: view)
        }
    }
}

// MARK: - Attachment preview

@MainActor final class AttachmentPreviewer: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = AttachmentPreviewer()
    private var directory: URL?
    private var urls: [URL] = []

    func temporaryFile(name: String, data: Data) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MailLitePreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safe = (name as NSString).lastPathComponent.isEmpty ? "附件" : (name as NSString).lastPathComponent
        let url = base.appendingPathComponent(safe)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        directory = base
        return url
    }

    func present(name: String, data: Data) throws {
        let url = try temporaryFile(name: name, data: data)
        urls = [url]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

// MARK: - Address Chip

struct AddressChip: View {
    let rawAddress: String
    let onCompose: () -> Void
    @State private var copied = false

    private var email: String {
        MailAddresses.extract(rawAddress).first ?? rawAddress
    }
    private var name: String {
        guard let range = rawAddress.range(of: "<") else { return email }
        let n = rawAddress[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return n.isEmpty ? email : n
    }

    var body: some View {
        Menu {
            Button("写信给 \(email)") { onCompose() }
            Button(copied ? "已复制" : "复制地址") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(email, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Avatar(text: email, size: 16)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if name != email {
                    Text("<\(email)>")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.tertiaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("点击发信或复制地址")
    }
}

// MARK: - Conversation surfaces

@MainActor private func conversationIsOutgoing(_ message: MailMessage, detail: MailDetail?, state: AppState) -> Bool {
    // Match complete sender addresses, including authenticated send-as aliases.
    // A customer at the same domain must still retain the incoming surface.
    let sender = detail?.from ?? message.fromAddress ?? message.sender
    let senders = MailAddresses.extract(sender).map { $0.lowercased() }
    guard senders.count == 1 else { return false }
    let identities = state.sessions.values.flatMap { [$0.email] + $0.addresses }
        + [state.email(for: message.accountID)]
    let own = Set(identities.flatMap { MailAddresses.extract($0) }.map { $0.lowercased() })
    return own.contains(senders[0])
}

private struct ConversationCardSurface: ViewModifier {
    let outgoing: Bool
    var current = false
    @Environment(\.colorScheme) private var colorScheme

    private var fill: Color {
        if colorScheme == .dark {
            return Color(nsColor: NSColor(srgbRed: outgoing ? 0.14 : 0.18,
                                          green: outgoing ? 0.145 : 0.185,
                                          blue: outgoing ? 0.16 : 0.20, alpha: 1))
        }
        return Color(nsColor: NSColor(srgbRed: outgoing ? 0.985 : 0.965,
                                      green: outgoing ? 0.985 : 0.968,
                                      blue: outgoing ? 0.99 : 0.975, alpha: 1))
    }

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(current ? Palette.accent.opacity(0.4) : Palette.hairline,
                                  lineWidth: current ? 1 : 0.75)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.035), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Thread Message Card

struct ThreadMessageCard: View {
    let member: MailMessage
    let isCurrent: Bool
    @ObservedObject var state: AppState
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onSwitchActive: () -> Void

    @State private var bodyHeight: CGFloat = 120
    @State private var webView: WKWebView?
    @State private var showRemoteImages = false
    @Environment(\.colorScheme) private var colorScheme

    @State private var memoKey: String = ""
    @State private var memoRenderedHTML: String = ""
    @State private var memoSessionSources: [String] = []

    private func bodyRenderKey(_ detail: MailDetail) -> String {
        "\(detail.message.key):\(showRemoteImages):\(state.preferences.value.loadRemoteImages):\(isDark)"
    }

    private var isDark: Bool { colorScheme == .dark }
    private var detail: MailDetail? { state.threadDetails[member.key] ?? (isCurrent ? state.detail : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleExpand) {
                HStack(alignment: .center, spacing: 10) {
                    Avatar(text: member.sender, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(displayName(member.sender))
                                .font(.system(size: 12.5, weight: isCurrent ? .bold : .semibold))
                                .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.9))
                            Text(address(member.sender))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.tertiaryText)
                                .lineLimit(1)
                            if isCurrent {
                                Chip(text: "当前主邮件", tint: Palette.accent)
                            }
                            Spacer()
                            if member.attachment {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.tertiaryText)
                            }
                            Text(member.date.mailRelative)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.tertiaryText)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .foregroundStyle(Palette.tertiaryText)
                        }
                        if !isExpanded {
                            Text(member.preview.isEmpty ? member.subject : member.preview)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                DividerLine()
                VStack(alignment: .leading, spacing: 10) {
                    MailSentStatusBanner(state: state, message: member)
                    if let detail {
                        MailSourceIPBadge(source: detail.sourceIP)
                        if !detail.visibleAttachments.isEmpty {
                            MailAttachmentSection(files: detail.visibleAttachments, message: member, state: state)
                                .id(member.key)
                        }
                        if memoKey == bodyRenderKey(detail) {
                            MailBodyView(html: memoRenderedHTML,
                                         inline: detail.inline, message: member, state: state,
                                         detailHTML: detail.html,
                                         allowRemote: showRemoteImages || state.preferences.value.loadRemoteImages,
                                         dark: isDark,
                                         paper: false,
                                         sessionImageSources: memoSessionSources,
                                         height: $bodyHeight, webView: $webView)
                                .frame(height: max(50, bodyHeight))
                        } else {
                            ProgressView("正在整理邮件正文…")
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity, minHeight: 60)
                        }
                        HStack(spacing: 8) {
                            Button {
                                state.composeReply(detail, mode: .reply)
                            } label: {
                                Label("回复此信", systemImage: "arrowshape.turn.up.left")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(GhostButtonStyle(tint: Palette.accent))
                            .disabled(state.composeSourcePending.contains(member.key))

                            Spacer()

                            if !isCurrent {
                                Button("设为主邮件") {
                                    onSwitchActive()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.accent)
                            }
                        }
                        .padding(.top, 4)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在读取来往邮件正文…").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                        }
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .modifier(ConversationCardSurface(
            outgoing: conversationIsOutgoing(member, detail: detail, state: state),
            current: isCurrent
        ))
        .task(id: isExpanded ? (detail.map(bodyRenderKey) ?? "loading") : "") {
            guard isExpanded else { return }
            if let detail {
                let key = bodyRenderKey(detail)
                let images = showRemoteImages || state.preferences.value.loadRemoteImages
                let dark = isDark
                let worker = Task.detached(priority: .userInitiated) {
                    (MailHTML.document(detail.html, inline: detail.inline, images: images, dark: dark),
                     MailImageDiagnostics.providerSessionSources(detail))
                }
                let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                memoKey = key
                memoRenderedHTML = result.0
                memoSessionSources = result.1
            } else {
                _ = await state.loadDetail(member)
            }
        }
    }

    private func displayName(_ raw: String) -> String {
        guard let range = raw.range(of: "<") else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = raw[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return name.isEmpty ? raw : name
    }

    private func address(_ raw: String) -> String {
        MailAddresses.extract(raw).first ?? raw
    }
}
