import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class MailIPLocationStore: ObservableObject {
    static let shared = MailIPLocationStore()
    static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mail Lite/Native/ip-location/QQWry.Dat")
    }
    @Published private(set) var database: MailIPDatabase?
    @Published private(set) var busy = false
    @Published private(set) var status = "未导入归属地数据库；仍可查看来源 IP。"
    init() { reload() }

    private func reload() {
        let url = Self.databaseURL
        busy = true
        Task {
            let value = await Task.detached(priority: .utility) {
                (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap { try? MailIPDatabase(data: $0) }
            }.value
            database = value; busy = false
            status = value.map { "本地数据库已启用 · \($0.count.formatted()) 个 IPv4 地址段" }
                ?? "未导入有效的归属地数据库；仍可查看来源 IP。"
        }
    }

    func importDatabase() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 QQWry.Dat 归属地数据库"
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        let destination = Self.databaseURL
        Task {
            let success = await Task.detached(priority: .utility) { () -> Bool in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 64 * 1024 * 1024 else { return false }
                    let data = try Data(contentsOf: url)
                    _ = try MailIPDatabase(data: data)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
                    return true
                } catch { return false }
            }.value
            if success { reload() }
            else { busy = false; status = "导入失败：请选择有效的经典 QQWry.Dat 文件。原数据库已保留。" }
        }
    }
}

struct MailSourceIPBadge: View {
    let source: MailSourceIP?
    @ObservedObject private var locations = MailIPLocationStore.shared
    @State private var expanded = false
    private var title: String {
        guard let candidate = source?.primary else { return source == nil ? "来源 IP 待读取" : "来源 IP 未提供" }
        return candidate.address + (locations.database?.location(candidate.address).map { " · " + $0 } ?? "")
    }
    var body: some View {
        Button { expanded.toggle() } label: {
            Label(title, systemImage: "network")
                .font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.045)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reader.sourceIP")
        .accessibilityLabel("邮件来源：" + title)
        .help("邮件头记录的网络来源；可能是邮件服务器，不代表发件人所在地。点击查看依据。")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("邮件来源 IP").font(.headline)
                Text("根据邮件头中的地址推测网络来源，可能是中转服务器。邮件头可以伪造，不能据此判断发件人的真实位置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let source, !source.candidates.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(source.candidates.enumerated()), id: \.offset) { index, item in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.address).font(.system(size: 12, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                                        if index == 0 { Text("优先显示").font(.caption).foregroundStyle(.secondary) }
                                        Spacer()
                                        Button("复制") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(item.address, forType: .string)
                                        }.buttonStyle(.plain)
                                    }
                                    Text(locations.database?.location(item.address) ?? (item.address.contains(":") ? "当前数据库不支持 IPv6 归属地" : "归属地暂无数据"))
                                        .font(.system(size: 11))
                                    Text(item.field + ": " + item.evidence)
                                        .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if index + 1 < source.candidates.count { Divider() }
                            }
                        }
                    }.frame(maxHeight: 280)
                    Text("优先使用明确的来源 IP 字段；否则使用最早可见的公网 from 记录。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text(source == nil ? "旧缓存尚无来源信息，请联网后重新打开邮件。" : "邮件头未提供可用的公网来源 IP。")
                        .font(.system(size: 12))
                }
                Text(locations.status).font(.system(size: 10)).foregroundStyle(.secondary)
                Text("归属地使用本地数据库查询，不会向查询服务提交邮件或 IP。数据库内容可能过时。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(16).frame(width: 430)
        }
    }
}

struct MailIPLocationSettingsView: View {
    @ObservedObject private var locations = MailIPLocationStore.shared
    var body: some View {
        SettingsCard(title: "邮件来源 IP") {
            VStack(alignment: .leading, spacing: 8) {
                Text("在发件人信息下显示邮件头中的公网 IP；导入 QQWry.Dat 后，可离线显示国家、地区和网络公司。")
                    .font(.system(size: 12))
                Text(locations.status).font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                HStack {
                    Button(locations.database == nil ? "导入归属地数据库…" : "更换归属地数据库…") { locations.importDatabase() }
                        .buttonStyle(GhostButtonStyle()).disabled(locations.busy)
                    if locations.busy { ProgressView().controlSize(.small) }
                }
                Text("仅识别邮件网络来源，不代表客户实际位置。经典 QQWry 数据库仅支持 IPv4，请使用有权使用且及时更新的数据文件。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
            }
        }
    }
}
