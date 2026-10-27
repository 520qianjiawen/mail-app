import Foundation

struct MailUploadFailure: Error {
    let code: Int
    init(_ error: URLError) { code = error.code.rawValue }
    var label: String {
        let reason: String
        switch code {
        case URLError.timedOut.rawValue: reason = "上传超时，请检查网络后重试"
        case URLError.notConnectedToInternet.rawValue: reason = "网络未连接，附件尚未上传"
        case URLError.networkConnectionLost.rawValue: reason = "上传连接中断，附件尚未完成"
        case URLError.cancelled.rawValue: reason = "附件上传已中止"
        default: reason = "附件上传连接失败"
        }
        return reason + "（网络代码 \(code)）"
    }
}
