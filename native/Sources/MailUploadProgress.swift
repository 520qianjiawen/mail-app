import Foundation
import WebKit

struct MailUploadProgress {
    var fileName: String
    var fileIndex: Int
    var fileCount: Int
    var completedBytes: Int64
    var fileBytes: Int64
    var uploadedBytes: Int64 = 0
    var totalBytes: Int64
    var awaitingSend = false

    var fraction: Double { totalBytes > 0 ? min(1, max(0, Double(completedBytes + uploadedBytes) / Double(totalBytes))) : 0 }
    var label: String {
        if awaitingSend { return "附件上传完成，正在提交发送…" }
        let size = ByteCountFormatter.string(fromByteCount: min(totalBytes, completedBytes + uploadedBytes), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "上传 \(fileIndex)/\(fileCount)：\(fileName) · \(size) / \(total) · \(Int(fraction * 100))%"
    }
}

/// Receives native URLSession upload-byte callbacks on the main actor. Closing
/// the receiver prevents delayed delegate callbacks from reviving completed UI.
@MainActor final class MailUploadProgressBridge {
    let total: Int64
    let update: (Int64, Int64) -> Void
    private(set) var loaded: Int64 = 0
    private var active = true
    private var lastUpdate = Date.distantPast
    init(total: Int64, update: @escaping (Int64, Int64) -> Void) {
        self.total = total; self.update = update
    }
    static func count(_ body: Any, expected: Int64, previous: Int64) -> Int64? {
        guard let body = body as? [String: Any], let count = body["loaded"] as? NSNumber,
              CFGetTypeID(count) != CFBooleanGetTypeID(), let total = body["total"] as? NSNumber,
              CFGetTypeID(total) != CFBooleanGetTypeID(), total.doubleValue == Double(expected),
              count.doubleValue.isFinite, count.doubleValue.rounded(.towardZero) == count.doubleValue,
              count.doubleValue >= Double(previous), count.doubleValue <= Double(expected) else { return nil }
        return count.int64Value
    }
    func receive(_ value: Int64, expected: Int64) {
        guard active, expected == total, value >= loaded, value >= 0, value <= total else { return }
        loaded = value
        if value == total || Date().timeIntervalSince(lastUpdate) >= 0.1 {
            lastUpdate = Date(); update(value, total)
        }
    }
    func close() { active = false }
}

/// A per-task delegate: redirects are refused before cookies, CSRF or body data
/// can be forwarded to a different endpoint. Foundation supplies actual bytes.
final class MailUploadTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent, totalBytesExpectedToSend)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Shared byte transport; MailAPI validates the trusted account endpoint and
/// scopes account cookies before entering this low-level routine.
enum MailNativeUpload {
    @MainActor static func perform(_ request: URLRequest, data: Data,
                                   onProgress: @escaping (Int64, Int64) -> Void) async throws -> (Data, URLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 180
        let progress = MailUploadProgressBridge(total: Int64(data.count), update: onProgress)
        let delegate = MailUploadTaskDelegate { [weak progress] loaded, total in
            Task { @MainActor [weak progress] in progress?.receive(loaded, expected: total) }
        }
        let transport = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { progress.close(); transport.invalidateAndCancel() }
        onProgress(0, Int64(data.count))
        return try await transport.upload(for: request, from: data)
    }
}
