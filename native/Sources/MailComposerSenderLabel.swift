import Foundation

/// Display text only. Wire formatting and bare sender identity remain separate.
enum MailComposerSenderLabel {
    static func format(address: String, name: String?) -> String {
        guard let name, !name.isEmpty else { return address }
        return "\(name) <\(address)>"
    }
}

func runMailComposerSenderLabelTests(_ require: (Bool, String) -> Void) {
    require(MailComposerSenderLabel.format(address: "sales@example.test", name: "Rumtoo") == "Rumtoo <sales@example.test>", "sender label contains name and address only without UUID or repeated account label")
    require(MailComposerSenderLabel.format(address: "sales@example.test", name: nil) == "sales@example.test", "unknown name uses bare address")
    require(MailComposerSenderLabel.format(address: "sales@example.test", name: "") == "sales@example.test", "empty local name uses bare address")
    require(MailComposerSenderLabel.format(address: "sales@example.test", name: "研发 · Sales") == "研发 · Sales <sales@example.test>", "Unicode display name remains readable without wire quoting")
}
