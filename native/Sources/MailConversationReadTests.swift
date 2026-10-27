import Foundation

/// Aggregate conversation flags are presentation only. Opening a row must not
/// turn its already-read newest member into unread in canonical storage.
@MainActor func runMailConversationReadTests(_ require: (Bool, String) -> Void) async {
    let state = AppState(fixture: true)
    let account = state.accounts[0]
    let origin = URL(string: "https://mail.zoho.com")!
    var newest = MailMessage(accountID: account.id, remoteID: "100", folderID: "500", id: "2", origin: origin,
                             subject: "Conversation", sender: "fixture@example.test", preview: "", date: Date(timeIntervalSince1970: 200), attachment: false, unread: false)
    var older = MailMessage(accountID: account.id, remoteID: "100", folderID: "500", id: "1", origin: origin,
                            subject: "Conversation", sender: "fixture@example.test", preview: "", date: Date(timeIntervalSince1970: 100), attachment: false, unread: true)
    newest.threadID = "300"; older.threadID = "300"
    state.messageStore = [newest.key: newest, older.key: older]
    state.preferences.value.markReadOnOpen = false
    state.rebuildRows()
    guard let row = state.rows.first else {
        require(false, "conversation fixture produces a list row")
        _ = state.shutdown()
        return
    }
    require(row.key == newest.key && row.unread, "conversation presentation aggregates older unread into newest representative")
    require(state.messageStore[newest.key]?.unread == false, "building a conversation row does not alter canonical newest read status")
    state.open(row)
    require(state.messageStore[newest.key]?.unread == false, "opening an aggregate unread row preserves canonical read newest member")
    require(state.messageStore[older.key]?.unread == true, "opening a representative does not silently mark another member read")
    state.preferences.value.markReadOnOpen = true
    state.open(row)
    require(state.messageStore[newest.key]?.unread == false && state.messageStore[older.key]?.unread == true,
            "per-message open preference does not fabricate whole-conversation acknowledgement")
    state.open(older)
    require(state.messageStore[older.key]?.unread == false, "opening actual unread member marks that member read in local fixture path")
    require(state.messageStore[newest.key]?.unread == false, "member read operation does not change another member's canonical state")
    await Task.yield()
    _ = state.shutdown()
}
