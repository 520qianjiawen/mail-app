import Foundation

@MainActor func runMailListCountryTests(_ require: (Bool, String) -> Void) async {
    require(MailIPDatabase.countryName("美国 加利福尼亚州") == "美国", "country tag omits province and company")
    require(MailIPDatabase.countryName("塞尔维亚") == "塞尔维亚", "Serbia country label retained")
    require(MailIPDatabase.countryName("印度尼西亚 雅加达") == "印度尼西亚", "longer country name is not mistaken for India")
    require(MailIPDatabase.countryName("江苏省苏州市") == "中国", "mainland province-only database rows normalize to country")
    require(MailIPDatabase.countryName("美国/加拿大") == nil && MailIPDatabase.countryName("未知归属") == nil, "ambiguous or unknown region does not invent a country")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-country-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MailCache(directory: root)
    func fixture(account: String = "one", remote: String = "100", folder: String = "200", origin: String = "https://mail.zoho.com") -> MailMessage {
        MailMessage(accountID: account, remoteID: remote, folderID: folder, id: "300", origin: URL(string: origin)!, subject: "fixture", sender: "fixture@example.test", preview: "", date: Date(), attachment: false, unread: true)
    }
    var message = fixture()
    let source = MailSourceIP.parse(["X-Originating-IP": "[8.8.8.8]"])
    cache.storeSourceIP(source, for: message)
    require(MailCache(directory: root).sourceIP(message) == source, "header-only source cache persists across launches")
    require(cache.detail(message) == nil, "country cache does not require downloading a message body")
    var wrong = fixture(remote: "999")
    require(cache.sourceIP(wrong) == nil, "same local key cannot borrow another remote account source")
    wrong = fixture(origin: "https://mail.zoho.eu")
    require(cache.sourceIP(wrong) == nil, "source cache rejects changed mail origin")
    wrong = fixture(folder: "999")
    require(cache.sourceIP(wrong) == nil, "source cache rejects changed folder identity")
    cache.removeAccount(message.accountID)
    require(cache.sourceIP(message) == nil, "account removal also clears header-only source cache")
    message = fixture(account: "two")
    let empty = MailSourceIP(candidates: [])
    cache.storeSourceIP(empty, for: message)
    require(cache.sourceIP(message) == empty, "missing source is cached without repeated header downloads")
    cache.removeMessage(message.key)
    require(cache.sourceIP(message) == nil, "message removal clears source cache")

    let loader = MailListSourceIPLoader()
    var sources: [String: MailSourceIP] = [:], calls = 0, active = 0, peak = 0
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<6 {
            group.addTask { @MainActor in
                let key = "\(index)"
                _ = await loader.load(key: key, cached: { sources[key] }) {
                    calls += 1; active += 1; peak = max(peak, active)
                    defer { active -= 1 }
                    try await Task.sleep(nanoseconds: 20_000_000)
                    sources[key] = source; return source
                }
            }
        }
    }
    require(calls == 6 && peak <= 2 && active == 0, "visible row source requests are limited to two concurrent headers")
    _ = await loader.load(key: "0", cached: { sources["0"] }) { calls += 1; return source }
    require(calls == 6, "cached country source bypasses network fetch")
    var failures = 0
    for _ in 0..<2 {
        _ = await loader.load(key: "failed", cached: { nil }) { failures += 1; throw MailFailure.auth }
    }
    require(failures == 1, "failed header requests back off instead of repeatedly retrying a row")
    require(message.unread, "country source loading does not alter message read state")
}
