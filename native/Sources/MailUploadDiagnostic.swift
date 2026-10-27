import Foundation

/// Shape and failed predicates only. Never retain response values, mail text,
/// cookie/token material, attachment names, IDs or query parameter values.
struct MailUploadDiagnostic: Codable, Equatable, Sendable {
    var version = 1
    var httpStatus: Int = 200
    var apiStatus: Int = 200
    var stage: String
    var dataShape: String
    var fieldTypes: [String: String]
    var failedChecks: [String]
    var requestBytes: Int?
    var urlPathKind: String?
    var urlQueryKeys: [String]?
    var descriptorPathKind: String?
    var urlUsesHTMLEntities: Bool?
    var protocolKind: String? = nil

    static func kind(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let value = value as? NSNumber { return CFGetTypeID(value) == CFBooleanGetTypeID() ? "boolean" : "number" }
        if value is String { return "string" }
        if let value = value as? [Any] { return "array[\(value.count)]" }
        if value is [String: Any] { return "object" }
        return "other"
    }
    static func safeKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil
    }
    init(data: Any, stage: String, failedChecks: [String], requestBytes: Int? = nil) {
        self.stage = stage; self.failedChecks = failedChecks; self.requestBytes = requestBytes
        dataShape = Self.kind(data)
        let row = (data as? [String: Any]) ?? (data as? [[String: Any]])?.first ?? [:]
        fieldTypes = Dictionary(uniqueKeysWithValues: row.keys.filter(Self.safeKey).sorted().prefix(40).map { ($0, Self.kind(row[$0]!)) })
        if let raw = row["url"] as? String, let url = URLComponents(string: Trust.entities(raw)) {
            urlUsesHTMLEntities = raw.contains("&amp;") || raw.contains("&#")
            urlPathKind = ["/zm/ImageSignature", "/mail/ImageSignature", "/zm/ImageDisplay", "/mail/ImageDisplay"].contains(url.path) ? url.path : "other"
            urlQueryKeys = Array(Set((url.queryItems ?? []).map(\.name).filter(Self.safeKey))).sorted().prefix(30).map { $0 }
        }
        if let path = row["attachmentPath"] as? String {
            descriptorPathKind = path.hasPrefix("/compose/") ? "/compose/" : path.hasPrefix("/Mail/") ? "/Mail/" : "other"
        }
    }
    static func official(_ data: Any, stage: String, failedChecks: [String], requestBytes: Int? = nil) -> MailUploadDiagnostic {
        var diagnostic = MailUploadDiagnostic(data: data, stage: stage, failedChecks: failedChecks, requestBytes: requestBytes)
        diagnostic.protocolKind = "zoho-private-upload"
        if let outer = (data as? [[String: Any]])?.first,
           let inner = (outer["resData"] as? [[String: Any]])?.first {
            let shape = MailUploadDiagnostic(data: inner, stage: stage, failedChecks: failedChecks)
            for key in ["fP", "sN", "url", "name", "errorCode"] {
                if let value = inner[key] { diagnostic.fieldTypes["resData." + key] = Self.kind(value) }
            }
            diagnostic.urlPathKind = shape.urlPathKind; diagnostic.urlQueryKeys = shape.urlQueryKeys
            diagnostic.urlUsesHTMLEntities = shape.urlUsesHTMLEntities
            if let path = inner["fP"] as? String {
                diagnostic.descriptorPathKind = path.hasPrefix("/compose/") ? "/compose/" : path.hasPrefix("/Mail/") ? "/Mail/" : "other"
            }
        }
        return diagnostic
    }
    var label: String {
        let codes = failedChecks.prefix(6).joined(separator: ", ")
        return "上传响应校验失败（\(stage)；\(dataShape)；\(codes)），邮件尚未发送，草稿已保留"
    }
}

struct MailUploadResponseFailure: Error {
    let diagnostic: MailUploadDiagnostic
    var label: String { diagnostic.label }
}
