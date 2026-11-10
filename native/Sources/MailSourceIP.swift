import Foundation
import Darwin

/// Header claims describe transport infrastructure, not a person's location.
struct MailSourceIP: Codable, Sendable, Equatable {
    struct Candidate: Codable, Sendable, Equatable {
        let address: String
        let field: String
        let evidence: String
    }
    let candidates: [Candidate]
    var primary: Candidate? { candidates.first }

    static func parse(_ headers: [String: Any]) -> MailSourceIP {
        func values(_ name: String) -> [String] {
            headers.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }
                .sorted { $0.key < $1.key }.flatMap { item -> [String] in
                    if let value = item.value as? String { return [value] }
                    return item.value as? [String] ?? []
                }.prefix(200).map { String($0.prefix(8192)) }
        }
        var result: [Candidate] = [], seen = Set<String>()
        func add(_ text: String, field: String, fromOnly: Bool) {
            let unfolded = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            var input = unfolded
            if fromOnly {
                // Never mistake the receiving ('by') host or a date for a source.
                guard let start = input.range(of: #"\bfrom\s+"#, options: [.regularExpression, .caseInsensitive]) else { return }
                input = String(input[start.upperBound...])
                if let end = input.range(of: #"\s+(?:by|with|via|id|for)\s+|;"#, options: [.regularExpression, .caseInsensitive]) {
                    input = String(input[..<end.lowerBound])
                }
            }
            input = input.replacingOccurrences(of: "IPv6:", with: "", options: .caseInsensitive)
            let tokens = input.components(separatedBy: CharacterSet(charactersIn: "0123456789abcdefABCDEF:.").inverted)
            for token in tokens {
                guard let address = publicAddress(token), seen.insert(address).inserted else { continue }
                result.append(.init(address: address, field: field, evidence: String(unfolded.prefix(700))))
                if result.count >= 24 { return }
            }
        }
        for name in ["X-Originating-IP", "X-Sender-IP"] {
            for value in values(name) { add(value, field: name, fromOnly: false) }
        }
        // Received is conventionally newest first. Oldest visible public from-hop
        // is a heuristic; headers may be forged, so the UI exposes the evidence.
        for name in ["Received", "X-Received"] {
            for value in values(name).reversed() where result.count < 24 { add(value, field: name, fromOnly: true) }
        }
        return .init(candidates: Array(result.prefix(24)))
    }

    static func publicAddress(_ raw: String) -> String? {
        guard raw.count <= 45, raw.contains(".") || raw.contains(":") else { return nil }
        var ipv4 = in_addr()
        if raw.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let a = value >> 24, b = (value >> 16) & 255, c = (value >> 8) & 255
            guard a != 0, a != 10, a != 127, a < 224,
                  !(a == 100 && (64...127).contains(b)), !(a == 169 && b == 254),
                  !(a == 172 && (16...31).contains(b)), !(a == 192 && b == 168),
                  !(a == 192 && b == 0 && (c == 0 || c == 2)), !(a == 192 && b == 88 && c == 99),
                  !(a == 198 && (b == 18 || b == 19)), !(a == 198 && b == 51 && c == 100),
                  !(a == 203 && b == 0 && c == 113) else { return nil }
            return raw
        }
        var ipv6 = in6_addr()
        guard raw.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        guard bytes[0] & 0xe0 == 0x20,
              !(bytes[0...3].elementsEqual([0x20, 0x01, 0x0d, 0xb8])),
              !(bytes[0...3].elementsEqual([0x20, 0x01, 0x00, 0x00])),
              !(bytes[0] == 0x20 && bytes[1] == 0x02) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }
}

/// Read-only classic QQWry IPv4 ranges. No HTTP requests or header uploads.
struct MailIPDatabase: Sendable {
    let data: Data
    let first: Int, count: Int
    enum Failure: Error { case invalid }
    init(data: Data) throws {
        guard (15...64 * 1024 * 1024).contains(data.count) else { throw Failure.invalid }
        self.data = data
        func number(_ offset: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        first = number(0, 4)
        let last = number(4, 4)
        guard first >= 8, last >= first, last <= data.count - 7, (last - first) % 7 == 0 else { throw Failure.invalid }
        count = (last - first) / 7 + 1
        var previous: Int? = nil
        for index in 0..<count {
            let offset = first + index * 7, start = number(offset, 4), pointer = number(offset + 4, 3)
            guard pointer >= 8, pointer <= data.count - 5, number(pointer, 4) >= start,
                  previous.map({ start > $0 }) ?? true else { throw Failure.invalid }
            previous = start
        }
    }
    private func number(_ offset: Int, _ size: Int) -> Int? {
        guard offset >= 0, offset <= data.count - size else { return nil }
        return (0..<size).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }
    private func text(_ offset: Int, redirects: Int = 0) -> (String, Int)? {
        guard offset >= 8, offset < data.count, redirects < 8 else { return nil }
        if data[offset] == 1 || data[offset] == 2 {
            guard let pointer = number(offset + 1, 3) else { return nil }
            if pointer == 0 { return ("", offset + 4) }
            guard let value = text(pointer, redirects: redirects + 1) else { return nil }
            return (value.0, offset + 4)
        }
        let end = min(data.count, offset + 4096)
        guard let stop = data[offset..<end].firstIndex(of: 0) else { return nil }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard let decoded = String(data: data[offset..<stop], encoding: String.Encoding(rawValue: encoding)) else { return nil }
        let safe = decoded.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return (String(String.UnicodeScalarView(safe)).trimmingCharacters(in: .whitespaces), stop + 1)
    }
    private func record(_ address: String) -> (String, String)? {
        guard MailSourceIP.publicAddress(address) != nil else { return nil }
        var ip = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &ip) }) == 1 else { return nil }
        let target = Int(UInt32(bigEndian: ip.s_addr))
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            guard let start = number(first + mid * 7, 4) else { return nil }
            if start <= target { low = mid + 1 } else { high = mid }
        }
        guard low > 0, let record = number(first + (low - 1) * 7 + 4, 3),
              let end = number(record, 4), target <= end else { return nil }
        var offset = record + 4, redirects = 0
        while offset < data.count, data[offset] == 1 {
            guard redirects < 8, let pointer = number(offset + 1, 3), pointer >= 8, pointer < data.count else { return nil }
            offset = pointer; redirects += 1
        }
        guard let country = text(offset), let area = text(country.1) else { return nil }
        return (country.0, area.0)
    }
    func country(_ address: String) -> String? {
        guard let value = record(address) else { return nil }
        return Self.countryName(value.0)
    }
    static func countryName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("/"), !value.contains("、"), !value.contains("或") else { return nil }
        let mainland = ["中国", "北京市", "天津市", "上海市", "重庆市", "河北省", "河南省", "云南省", "辽宁省", "黑龙江省", "湖南省", "安徽省", "山东省", "江苏省", "浙江省", "江西省", "湖北省", "甘肃省", "山西省", "陕西省", "吉林省", "福建省", "贵州省", "广东省", "青海省", "四川省", "海南省", "台湾省", "内蒙古", "广西", "宁夏", "新疆", "西藏"]
        if mainland.contains(where: { value.hasPrefix($0) }) { return "中国" }
        return countryNames.first { value == $0 || value.hasPrefix($0 + " ") }
    }
    private static let countryNames: [String] = {
        let locale = Locale(identifier: "zh_CN")
        let names = Locale.Region.isoRegions.compactMap { locale.localizedString(forRegionCode: $0.identifier) }
        return Array(Set(names + ["美国", "英国", "俄罗斯", "塞尔维亚", "捷克", "韩国", "朝鲜", "越南", "中国香港", "中国澳门", "香港", "澳门", "台湾"]))
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
    }()
    func location(_ address: String) -> String? {
        guard let (country, area) = record(address) else { return nil }
        let values = [country, area].filter { !$0.isEmpty && $0 != "CZ88.NET" && $0 != "纯真网络" }
        let location = Array(NSOrderedSet(array: values)).compactMap { $0 as? String }.joined(separator: " · ")
        return location.isEmpty ? nil : String(location.prefix(160))
    }
}
