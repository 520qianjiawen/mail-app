import Foundation

/// Request structure only. Never retain addresses, names, subject, HTML,
/// attachment identifiers, filenames, URLs or authentication material.
struct MailSendDiagnostic: Codable, Equatable, Sendable {
    let version: Int
    let operation: String
    let requestBytes: Int
    let bodyBytes: Int
    let inlineImages: Int
    let ordinaryAttachments: Int
    let uploadedBytes: Int64
    let attachmentDescriptors: Int
    let composeDescriptors: Int
    let mailDescriptors: Int
    let otherDescriptors: Int
    let descriptorFieldsValid: Bool
    let contentContainsDataImages: Bool
    var protocolKind: String? = nil

    init(body: [String: Any], reply: Bool, inlineImages: Int, ordinaryAttachments: Int, uploadedBytes: Int64) throws {
        version = 1
        operation = reply ? "reply" : "send"
        requestBytes = try JSONSerialization.data(withJSONObject: body).count
        let html = body["content"] as? String ?? ""
        bodyBytes = html.utf8.count
        self.inlineImages = inlineImages
        self.ordinaryAttachments = ordinaryAttachments
        self.uploadedBytes = uploadedBytes
        let attachments = body["attachments"] as? [[String: String]] ?? []
        attachmentDescriptors = attachments.count
        composeDescriptors = attachments.filter { $0["attachmentPath"]?.hasPrefix("/compose/") == true }.count
        mailDescriptors = attachments.filter { $0["attachmentPath"]?.hasPrefix("/Mail/") == true }.count
        otherDescriptors = attachments.count - composeDescriptors - mailDescriptors
        descriptorFieldsValid = attachments.allSatisfy {
            Set($0.keys) == Set(["storeName", "attachmentPath", "attachmentName"]) && $0.values.allSatisfy { !$0.isEmpty }
        }
        contentContainsDataImages = html.range(of: "data:image/", options: .caseInsensitive) != nil
    }

    init(officialFields: [String: String], requestBytes: Int, reply: Bool, inlineImages: Int,
         files: [MailOfficialProtocol.UploadedFile], uploadedBytes: Int64) {
        version = 2; protocolKind = "zoho-mail-send-api"
        operation = reply ? "reply" : "send"
        self.requestBytes = requestBytes
        let html = officialFields["text"] ?? ""
        bodyBytes = html.utf8.count
        self.inlineImages = inlineImages; ordinaryAttachments = files.count
        self.uploadedBytes = uploadedBytes; attachmentDescriptors = files.count
        composeDescriptors = files.filter { $0.path.hasPrefix("/compose/") }.count
        mailDescriptors = files.filter { $0.path.hasPrefix("/Mail/") }.count
        otherDescriptors = files.count - composeDescriptors - mailDescriptors
        descriptorFieldsValid = files.allSatisfy { !$0.name.isEmpty && !$0.path.isEmpty && !$0.store.isEmpty }
        contentContainsDataImages = html.range(of: "data:image/", options: .caseInsensitive) != nil
    }
}
