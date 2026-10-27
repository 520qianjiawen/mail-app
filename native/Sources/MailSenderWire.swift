import Foundation

/// Only the final send payload uses a formatted identity. Matching, drafts,
/// signatures and attachment uploads continue using the bare `item.from`.
enum MailSenderWire {
    static func fromAddress(item: OutboxItem, allowedAddresses: [String]) throws -> String {
        guard let address = SenderIdentityPolicy.normalizedAddress(item.from),
              allowedAddresses.contains(where: { SenderIdentityPolicy.normalizedAddress($0) == address }) else {
            throw MailFailure.rejected
        }
        do {
            return try SenderIdentityPolicy.formattedFrom(address: item.from, name: item.senderDisplayName)
        } catch { throw MailFailure.rejected }
    }

    /// Only an explicit local override changes the submitted From syntax.
    /// Provider metadata labels the UI; default sends leave the server in control.
    @MainActor static func captureConfigured(state: AppState, accountID: String, from: String,
                                            to: String, cc: String, bcc: String, subject: String) -> OutboxItem {
        capture(accountID: accountID, from: from,
                name: state.senderDisplayNameOverride(accountID: accountID, from: from),
                to: to, cc: cc, bcc: bcc, subject: subject)
    }

    /// Shared by new/reply/forward sends; invoke synchronously before HTML flush.
    static func capture(accountID: String, from: String, name: String?,
                        to: String, cc: String, bcc: String, subject: String) -> OutboxItem {
        OutboxItem(accountID: accountID, from: from, senderDisplayName: name,
                   to: to, cc: cc, bcc: bcc, subject: subject)
    }
}
