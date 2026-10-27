import SwiftUI

/// Embedded directly in the parent's account section, not another settings tab.
struct AccountSenderIdentitySettingsView: View {
    @ObservedObject var state: AppState
    let accountID: String

    private var identities: [MailSenderIdentity] { state.availableSenderIdentities(accountID: accountID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发件人名称").font(.system(size: 13, weight: .semibold))
            Text("主邮箱与别名分别设置，保存在本机；不修改账号标签或 Zoho 服务器设置。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondaryText).fixedSize(horizontal: false, vertical: true)
            Text("新发送邮件会提交所选名称；Zoho 是否保留该名称及收件端显示效果，请用测试邮件核对。")
                .font(.system(size: 10)).foregroundStyle(Palette.tertiaryText).fixedSize(horizontal: false, vertical: true)
            if identities.isEmpty {
                Text("尚未加载可用发件地址。请刷新此账号后再设置。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
            } else {
                ForEach(identities, id: \.address) { identity in
                    SenderIdentitySettingsRow(state: state, accountID: accountID, identity: identity)
                        .id(accountID + ":" + identity.address)
                }
            }
        }
    }
}

private struct SenderIdentitySettingsSnapshot: Equatable {
    let local: String?
    let server: String?
}

private struct SenderIdentitySettingsRow: View {
    @ObservedObject var state: AppState
    let accountID: String
    let identity: MailSenderIdentity
    @State private var editing = false
    @State private var name = ""
    @State private var notice = ""

    private var local: String? { state.senderDisplayNameOverride(accountID: accountID, from: identity.address) }
    private var effective: String? { state.effectiveSenderDisplayName(accountID: accountID, from: identity.address) }
    private var snapshot: SenderIdentitySettingsSnapshot { .init(local: local, server: identity.displayName) }
    private var currentText: String {
        guard let effective else { return "Zoho 名称未知（跟随服务器）" }
        return effective.isEmpty ? "不附加自定义名称" : effective
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(identity.address).font(.system(size: 11, weight: .medium)).textSelection(.enabled)
                Spacer()
                Text(local == nil ? "使用 Zoho 名称" : "本机设置").font(.system(size: 10)).foregroundStyle(Palette.secondaryText)
            }
            if editing {
                TextField("发件人名称", text: $name).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(identity.address + " 发件人名称")
                Text("留空不附加自定义名称，Zoho 可能使用默认名称；最多 120 个字符。")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondaryText)
                HStack {
                    Button("保存") { save() }.buttonStyle(PrimaryButtonStyle())
                    Button("取消") { editing = false; notice = "" }.buttonStyle(GhostButtonStyle())
                }
            } else {
                HStack {
                    Text(currentText).font(.system(size: 11)).textSelection(.enabled)
                    Spacer()
                    Button("编辑") { name = effective ?? ""; editing = true; notice = "" }.buttonStyle(GhostButtonStyle())
                    if local != nil {
                        Button("使用 Zoho 名称") { restore() }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
            if !notice.isEmpty { Text(notice).font(.system(size: 10)).foregroundStyle(Palette.secondaryText).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(10)
        .background(Palette.hairline.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: snapshot) { _, _ in
            // A save elsewhere or refreshed server metadata invalidates the edit
            // buffer, rather than silently overwriting newer identity settings.
            if editing { editing = false; name = effective ?? ""; notice = "设置已更新，请重新编辑。" }
        }
    }

    private func save() {
        do {
            try state.saveSenderDisplayName(accountID: accountID, from: identity.address, name: name)
            editing = false; notice = "已保存到本机。"
        } catch { notice = error.localizedDescription }
    }
    private func restore() {
        do {
            try state.removeSenderDisplayNameOverride(accountID: accountID, from: identity.address)
            editing = false
            notice = identity.displayName == nil ? "已移除本机覆盖；Zoho 名称尚未知晓。" : "已移除本机覆盖，使用 Zoho 名称。"
        } catch { notice = error.localizedDescription }
    }
}
