import SwiftUI

struct MailTrackingSettingsView: View {
    @ObservedObject var controller: MailTrackingController
    @State private var serviceURL = "https://track.neutemu.com"
    @State private var accessKey = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("邮件追踪").font(.system(size: 15, weight: .semibold))
            SettingsCard(title: "独立追踪服务", detail: "图片访问和打开记录保存在自己的服务器，不依赖第三方追踪账号。") {
                HStack {
                    Label(controller.connected ? "已连接" : "未连接", systemImage: controller.connected ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(controller.connected ? Palette.mint : Palette.secondaryText)
                    Spacer()
                    if controller.connected {
                        Button("刷新") { controller.refresh() }.disabled(controller.refreshing)
                        Button("断开连接") { controller.disconnect() }
                    } else {
                        Button(controller.connecting ? "连接中…" : "连接") {
                            Task { await controller.connect(.init(serverURL: serviceURL, apiKey: accessKey)); if controller.connected { accessKey = "" } }
                        }.disabled(controller.connecting)
                    }
                }
                if !controller.connected {
                    TextField("追踪服务地址", text: $serviceURL).textFieldStyle(.roundedBorder)
                    SecureField("访问密钥", text: $accessKey).textFieldStyle(.roundedBorder)
                    Text("服务地址需为公网 HTTPS。访问密钥仅保存在 macOS 钥匙串；不会发送给收件人。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("新邮件默认开启追踪", isOn: Binding(get: { controller.defaultEnabled }, set: { controller.setDefaultEnabled($0) }))
                    .disabled(!controller.connected)
                Text("每封邮件也可在撰写窗口单独开启。多人收件时显示整封邮件的次数，无法确定是哪位收件人打开；图片被屏蔽时可能没有记录。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if let error = controller.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.rose).textSelection(.enabled)
            }
            SettingsCard(title: "追踪记录", detail: "只统计开启追踪后发送的邮件；没有记录时显示“追踪中”，不判断为未读。") {
                if let updated = controller.lastRefresh {
                    Text("最近刷新：" + updated.mailFull).font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText)
                }
                let records = controller.records.filter { $0.sentAt != nil }.sorted { ($0.sentAt ?? $0.createdAt) > ($1.sentAt ?? $1.createdAt) }
                if records.isEmpty {
                    Text("暂无已发送的追踪邮件").font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                }
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(record.subject.isEmpty ? "（无主题）" : record.subject).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            trackingLabel(record)
                        }
                        Text("至：" + record.recipient).font(.system(size: 11)).foregroundStyle(Palette.secondaryText).lineLimit(1)
                        if let date = record.latest {
                            Text("最近打开：" + date.mailFull).font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText)
                        }
                        if record.count > 0 {
                            DisclosureGroup("打开记录") {
                                ForEach(record.opens.sorted { $0.date > $1.date }) { event in
                                    HStack {
                                        Text(event.date.mailFull)
                                        Spacer()
                                        Text(event.platform)
                                        if !event.country.isEmpty && event.country != "??" { Text(event.country) }
                                    }.font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText)
                                }
                            }.font(.system(size: 11))
                        }
                    }.padding(.vertical, 7)
                    Divider()
                }
            }
        }
    }
    private func trackingLabel(_ record: MailTrackingRecord) -> some View {
        Label(record.label, systemImage: record.count > 0 ? "eye.fill" : "eye")
            .font(.system(size: 11)).foregroundStyle(record.count > 0 ? Palette.mint : Palette.secondaryText)
    }
}

struct MailTrackingReaderStatus: View {
    @ObservedObject var controller: MailTrackingController
    let message: MailMessage
    var body: some View {
        if let record = controller.record(for: message) {
            HStack(spacing: 8) {
                Image(systemName: record.count > 0 ? "eye.fill" : "eye")
                Text(record.label).fontWeight(.medium)
                if let date = record.latest { Text("最近打开：" + date.mailFull).foregroundStyle(Palette.secondaryText) }
                Spacer()
                if !controller.connected { Text("追踪连接已暂停").foregroundStyle(Palette.secondaryText) }
                Button("刷新") { controller.refresh() }.buttonStyle(.plain).disabled(!controller.connected || controller.refreshing)
            }
            .font(.system(size: 11)).foregroundStyle(record.count > 0 ? Palette.mint : Palette.secondaryText)
            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Palette.mint.opacity(0.07)))
            .accessibilityIdentifier("reader.mailTracking")
            .help("图片加载记录可能受缓存、图片屏蔽或代理影响。")
        }
    }
}

struct MailTrackingMessageBadge: View {
    @EnvironmentObject var state: AppState
    let message: MailMessage
    var body: some View { MailTrackingRowBadge(controller: state.tracking, message: message) }
}
private struct MailTrackingRowBadge: View {
    @ObservedObject var controller: MailTrackingController
    let message: MailMessage
    var body: some View {
        if let record = controller.record(for: message) {
            Label(record.count > 0 ? "\(record.count) 次" : "追踪中", systemImage: record.count > 0 ? "eye.fill" : "eye")
                .font(.system(size: 9.5)).foregroundStyle(record.count > 0 ? Palette.mint : Palette.secondaryText)
                .help(record.label + (record.latest.map { " · " + $0.mailFull } ?? ""))
                .accessibilityLabel("邮件追踪，" + record.label)
        }
    }
}

extension AppState {
    func showTrackingSettings() {
        // Retain an existing settings window; replace only its root selection.
        if let existing = settingsController {
            existing.window.contentView = NSHostingView(rootView: SettingsView(state: self, initialSection: 9))
            existing.show(); return
        }
        let controller = SettingsWindowController(state: self, section: 9)
        settingsController = controller; controller.show()
    }
}
