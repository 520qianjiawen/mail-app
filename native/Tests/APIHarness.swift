import Foundation
import WebKit
import CryptoKit

final class FixtureProtocol:URLProtocol,@unchecked Sendable {
    static var observed:[URLRequest] = []
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.observed.append(request)
        let path = request.url!.path
        let code = path == "/unauthorized" ? 401 : path == "/rate" ? 429 : 200
        let data:Data
        if path == "/reauth" { data = Data("{\"status\":{\"code\":400},\"data\":{\"reauthUrl\":\"https://accounts.zoho.com/private\"}}".utf8) }
        else if path == "/invalid" { data = Data("{\"status\":{\"code\":200},\"data\":{\"unexpected\":true}}".utf8) }
        else { data = Data("{\"status\":{\"code\":200},\"data\":[{\"messageId\":\"900719925474099303\"}]}".utf8) }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct APIHarness {
    @MainActor static func main() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let api = MailAPI(configuration:config), origin = Region.find("global")!.origin
        let first = HTTPCookie(properties:[.domain:"mail.zoho.com",.path:"/",.name:"session",.value:"first",.secure:"TRUE"])!
        let second = HTTPCookie(properties:[.domain:"mail.zoho.com",.path:"/",.name:"session",.value:"second",.secure:"TRUE"])!
        do {
            let rows = try await api.get(origin.appendingPathComponent("api/accounts"),cookies:[first],csrf:"csrf-first")
            precondition(rows.first?["messageId"] as? String == "900719925474099303")
            _ = try await api.get(origin.appendingPathComponent("api/accounts"),cookies:[second],csrf:"csrf-second")
            precondition(FixtureProtocol.observed[0].value(forHTTPHeaderField:"Cookie") == "session=first")
            precondition(FixtureProtocol.observed[1].value(forHTTPHeaderField:"Cookie") == "session=second")
            precondition(FixtureProtocol.observed[0].value(forHTTPHeaderField:"X-ZCSRF-TOKEN") == "zmrcsr=csrf-first")
            for (path,expected) in [("unauthorized",MailFailure.auth),("rate",.rate),("reauth",.auth),("invalid",.response)] {
                do { _ = try await api.get(origin.appendingPathComponent(path),cookies:[first],csrf:"csrf"); fatalError("Expected failure") }
                catch let failure as MailFailure { precondition(failure.label == expected.label) }
            }
            let count = FixtureProtocol.observed.count
            do { _ = try await api.get(URL(string:"https://evil.example/api/accounts")!,cookies:[first],csrf:"csrf"); fatalError("Host accepted") }
            catch is MailFailure { precondition(FixtureProtocol.observed.count == count) }
            print("PASS: native URLSession transport, source cookies, CSRF, large IDs, auth/rate/shape failures and rejected external hosts.")
            if let raw = ProcessInfo.processInfo.environment["MAIL_LITE_OFFICIAL_LOOPBACK_URL"] {
                guard let base = URL(string: raw), base.scheme == "http", base.host == "127.0.0.1" else { fatalError("Loopback host required") }
                let bytes = Data((0..<(8 * 1024 * 1024)).map { UInt8($0 % 251) })
                let form = try MailOfficialProtocol.multipart(fields: ["text": "<p>中文 fixture &amp; body</p>", "mailFormat": "2"], file: ("fixture.bin", bytes))
                var request = URLRequest(url: base.appendingPathComponent("upload")); request.httpMethod = "POST"
                request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
                var counts: [Int64] = []
                let (reply, response) = try await MailNativeUpload.perform(request, data: form.body) { loaded, total in
                    precondition(total == form.body.count); counts.append(loaded)
                }
                precondition((response as? HTTPURLResponse)?.statusCode == 200)
                let result = try api.officialResponse(reply, http: 200)
                let receipt = try MailOfficialProtocol.Receipt.parse(result)
                precondition(receipt.messageID == "900719925474099303")
                precondition(counts.first == 0 && counts.last == Int64(form.body.count) && zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 })
                precondition(counts.contains { $0 > 0 && $0 < form.body.count })
                request.url = base.appendingPathComponent("redirect")
                let (_, redirect) = try await MailNativeUpload.perform(request, data: form.body) { _, _ in }
                precondition((redirect as? HTTPURLResponse)?.statusCode == 307)
                request.url = base.appendingPathComponent("server-error")
                let (failed, failure) = try await MailNativeUpload.perform(request, data: form.body) { _, _ in }
                do { _ = try api.officialResponse(failed, http: (failure as! HTTPURLResponse).statusCode); fatalError("Expected 500") }
                catch let error as MailServerRejection { precondition(!error.definitelyRejected) }
                print("PASS: official multipart 8 MiB byte-exact loopback, native progress, strict receipt, redirect refusal and uncertain HTTP 500.")
            }
        } catch { print("FAIL: native API transport"); exit(1) }
    }
}
