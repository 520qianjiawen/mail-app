import SwiftUI

enum MailSentStatus {
    /// Exact-message evidence only: never infer sending from subject, sender,
    /// replied/forwarded flags or a different member of the same conversation.
    static func date(for message: MailMessage, session: MailboxSession?, receipts: [OutboxItem]) -> Date? {
        guard Trust.mail(message.origin), Trust.numericID(message.id) != nil else { return nil }
        if let session, session.accountID == message.accountID,
           session.remoteID == message.remoteID, session.origin == message.origin,
           session.sent?.id == message.folderID, valid(message.date) {
            return message.date
        }
        return receipts.compactMap { item -> Date? in
            guard item.state == "sent", item.accountID == message.accountID,
                  item.sentRemoteID == message.remoteID, item.sentOrigin == message.origin,
                  item.sentMessageID == message.id, let date = item.sentAt, valid(date) else { return nil }
            return date
        }.max()
    }

    private static func valid(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 > 0
    }
}

struct MailSentStatusBanner: View {
    @ObservedObject var state: AppState
    let message: MailMessage

    var body: some View {
        if let date = MailSentStatus.date(for: message, session: state.sessions[message.accountID],
                                         receipts: state.outboxStore.all()) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.mint)
                    .accessibilityHidden(true)
                Text("本邮件已于 [\(date.mailFull)] 成功发送")
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
            }
            .font(.system(size: 11.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.mint.opacity(0.07)))
            .accessibilityIdentifier("reader.sentStatus")
            .help("服务器已接收发送，或邮件已同步至服务器的已发送文件夹；不代表对方已收到或阅读。")
        }
    }
}
