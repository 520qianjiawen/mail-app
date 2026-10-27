import Foundation

/// Bounded provider diagnostics, without retaining response bodies, mail text,
/// recipient addresses, cookies, tokens or reauthentication URLs.
struct MailServerRejection: Error, Equatable, Codable {
    let http: Int
    let statusCode: Int?
    let errorCode: String?
    let parameter: String?
    let reason: String?
    let responseFields: [String: String]?

    init(http: Int, body: [String: Any]) {
        self.http = http
        let status = body["status"] as? [String: Any] ?? [:]
        let data = body["data"] as? [String: Any] ?? [:]
        let error = body["error"] as? [String: Any] ?? [:]
        // Record only known schema field types, including the documented
        // moreInfo field that older clients discarded. Values stay private.
        func shape(_ value: Any) -> String {
            if value is NSNull { return "null" }
            if value is String { return "string" }
            if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number" }
            if value is [String: Any] { return "object" }
            if value is [Any] { return "array" }
            return "other"
        }
        var fields: [String: String] = [:]
        for (prefix, row) in [("root", body), ("status", status), ("data", data), ("error", error)] {
            for key in ["status", "data", "error", "code", "description", "errorCode", "moreInfo", "errorMessage", "message", "parameter", "paramName"] {
                if let value = row[key] { fields[prefix + "." + key] = shape(value) }
            }
        }
        responseFields = fields.isEmpty ? nil : fields
        statusCode = status["code"] as? Int
        func token(_ value: Any?) -> String? {
            guard let value else { return nil }
            let text = String(describing: value)
            guard !text.isEmpty, text.count <= 80,
                  text.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil else { return nil }
            return text
        }
        errorCode = token(data["errorCode"] ?? error["errorCode"] ?? error["code"] ?? body["errorCode"])
        let field = token(data["parameter"] ?? data["paramName"] ?? error["parameter"])
        parameter = field.flatMap { ["content", "fromAddress", "toAddress", "ccAddress", "bccAddress", "subject", "attachments", "mailFormat", "encoding", "action", "fileName", "isInline", "text", "plainText", "accountId", "attachName", "filePath", "storeName", "attEntObj", "inReplyTo", "refHeader", "mode", "sendImm", "mymid", "dmailid", "frm", "accId", "newFlow"].contains($0) ? $0 : nil }
        // Only recognized categories are persisted. Arbitrary server prose can
        // contain a reflected request body or credentials and is not a log.
        let moreInfo = data["moreInfo"] as? [String: Any] ?? [:]
        let description = [status["description"], data["errorMessage"], data["message"], data["moreInfo"],
                           moreInfo["message"], moreInfo["errorMessage"], error["message"], body["message"], errorCode]
            .compactMap { ($0 as? String).map { String($0.prefix(4096)) } }.joined(separator: " ").lowercased()
        if http == 413 || description.range(of: "too.{0,12}(large|long)|maximum.{0,24}(length|size)|size.{0,12}exceed|length.{0,12}exceed", options: .regularExpression) != nil { reason = "size" }
        else if description.contains("invalid input") || description.contains("invalid_input") || description.contains("invalid value") || description.contains("input passed is invalid") { reason = "input" }
        else if description.contains("blocked") || description.contains("not allowed") || description.contains("permission") { reason = "policy" }
        else if (500..<600).contains(http) || (500..<600).contains(statusCode ?? 0) { reason = "server" }
        else { reason = nil }
    }

    /// A 5xx response after the send POST may follow a successful delivery.
    /// Never turn it into a one-click blind retry just because JSON was returned.
    var definitelyRejected: Bool {
        ((400..<500).contains(http) && http != 408) ||
        (http == 200 && (400..<500).contains(statusCode ?? 0) && statusCode != 408)
    }

    var label: String {
        let explanation: String
        switch reason {
        case "size": explanation = "Zoho 拒绝了内容大小，请检查正文、引用图片或附件"
        case "input": explanation = "Zoho 拒绝了请求参数"
        case "policy": explanation = "Zoho 限制了此操作，请检查账号发送权限"
        case "server": explanation = "Zoho 服务器处理出错，发送结果尚未确认"
        default: explanation = "Zoho 未接受此操作"
        }
        var codes = ["HTTP \(http)"]
        if let statusCode, statusCode != http { codes.append("状态 \(statusCode)") }
        if let errorCode { codes.append(errorCode) }
        if let parameter { codes.append("参数 \(parameter)") }
        return explanation + "（" + codes.joined(separator: " · ") + "）"
    }
}
