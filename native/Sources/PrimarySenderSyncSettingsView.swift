import SwiftUI

@MainActor struct PrimarySenderSyncSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store: PrimarySenderSyncStore
    let accountID: String
    @State private var name = ""
    @State private var confirming = false
    @State private var submittedName = ""
    @State private var submittedContext: MailboxSession?
    init(state: AppState, accountID: String) {
        self.state = state; self.accountID = accountID
        self.store = state.primarySenderSync
    }
    private var primary: String? { state.sessions[accountID]?.email }
    private var status: PrimarySenderSyncState { store.states[accountID] ?? .init() }
    private var busy: Bool { store.busySet.contains(accountID) }
    private func prefillProposedName() {
        guard let primary else { name = ""; return }
        let local = state.senderDisplayNameOverride(accountID: accountID, from: primary)
        let metadata = state.availableSenderIdentities(accountID: accountID).first {
            SenderIdentityPolicy.normalizedAddress($0.address) == SenderIdentityPolicy.normalizedAddress(primary)
        }?.displayName
        name = [local, status.serverName, metadata].compactMap { $0 }.first {
            (try? PrimarySenderSyncPolicy.updateBody(name: $0)) != nil
        } ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zoho 主邮箱账户显示名称").font(.headline)
            Text(primary ?? "请先加载主邮箱账户信息").font(.subheadline).textSelection(.enabled)
            Text("服务器当前名称：" + (status.serverName.map { $0.isEmpty ? "（空名称）" : $0 } ?? "尚未读取"))
                .font(.subheadline).textSelection(.enabled)
            TextField("新的主邮箱账户显示名称", text: $name).textFieldStyle(.roundedBorder)
                .disabled(busy || primary == nil)
            HStack {
                Button("同步到 Zoho") {
                    submittedContext = state.sessions[accountID]
                    submittedName = name
                    confirming = true
                }
                    .disabled(busy || primary == nil || (try? PrimarySenderSyncPolicy.updateBody(name: name)) == nil)
                Button("刷新服务器名称") {
                    guard let primary else { return }
                    Task { await store.refreshPrimaryDisplayName(accountID: accountID, primaryAddress: primary) }
                }.disabled(busy || primary == nil)
                if busy { ProgressView().controlSize(.small) }
            }
            Text(status.message).font(.caption).foregroundStyle(.secondary)
            Text("此操作修改 Zoho 主邮箱的账户级名称，不逐个修改别名，也不会修改本地账号标签。服务器账户名称与别名名称可能不同。")
                .font(.caption).foregroundStyle(.secondary)
            if let primary, state.senderDisplayNameOverride(accountID: accountID, from: primary) != nil {
                Text("此主邮箱还有本地发件名称，会优先显示。同步不会清除它；如需取消，请在下方本地设置单独选择“使用 Zoho 名称”。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 8)
        .onAppear { prefillProposedName() }
        .onChange(of: accountID) { _, _ in prefillProposedName() }
        .confirmationDialog("确认修改 Zoho 主邮箱账户显示名称？", isPresented: $confirming, titleVisibility: .visible) {
            Button("同步到 Zoho") {
                guard let expected = submittedContext else { return }
                let proposed = submittedName
                Task { @MainActor in
                    guard let current = state.sessions[accountID], current.accountID == expected.accountID,
                          current.remoteID == expected.remoteID, current.origin == expected.origin,
                          SenderIdentityPolicy.normalizedAddress(current.email) == SenderIdentityPolicy.normalizedAddress(expected.email) else {
                        state.status = "主邮箱身份已变化，请重新确认名称同步。"
                        return
                    }
                    await store.syncPrimaryDisplayName(accountID: accountID, primaryAddress: expected.email, name: proposed)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("将 \(submittedContext?.email ?? "主邮箱") 的账户名称设为“\(submittedName)”。别名及本地覆盖保持原样。") }
    }
}
