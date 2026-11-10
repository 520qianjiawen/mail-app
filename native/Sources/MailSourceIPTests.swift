import Foundation

func runMailSourceIPTests(_ require: (Bool, String) -> Void) {
    let received = ["from new.example ([8.8.8.8]) by receiving.example ([1.1.1.1]); date",
                    "from old.example ([67.195.1.2]) by new.example; date"]
    let parsed = MailSourceIP.parse(["rEcEiVeD": received])
    require(parsed.primary?.address == "67.195.1.2", "oldest visible from-hop selected")
    require(parsed.candidates.map(\.address) == ["67.195.1.2", "8.8.8.8"], "receiving by-host excluded")
    require(MailSourceIP.parse(["Received": received, "X-Originating-IP": "[9.9.9.9]"]).primary?.address == "9.9.9.9", "explicit originating IP takes priority")
    require(MailSourceIP.parse(["X-Originating-IP": "[10.1.1.1]", "Received": received]).primary?.address == "67.195.1.2", "private originating IP cannot mask public relay")
    require(MailSourceIP.parse(["Received": "from internal [192.168.1.1] by relay [8.8.8.8]"]).primary == nil, "receiver-only public IP is not attributed to source")
    require(MailSourceIP.parse(["X-Received": "by 2002:a17:906:22cd:0:0:0:0; date"]).primary == nil, "by-only X-Received is not guessed")
    require(MailSourceIP.parse(["Subject": "8.8.8.8", "From": "8.8.8.8@example.test"]).candidates.isEmpty, "IP never inferred from sender address or subject")
    require(MailSourceIP.parse([:]).primary == nil, "missing headers yield explicit unknown")
    for address in ["0.0.0.0", "10.0.0.1", "127.0.0.1", "100.64.0.1", "169.254.1.1", "172.16.1.1", "192.168.1.1", "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.1.1.1", "255.255.255.255", "999.1.1.1", "1.2.3", "::1", "fe80::1", "fc00::1", "2001:db8::1", "::ffff:8.8.8.8"] {
        require(MailSourceIP.publicAddress(address) == nil, "non-public/invalid source rejected: " + address)
    }
    require(MailSourceIP.publicAddress("172.32.1.1") == "172.32.1.1", "adjacent public IPv4 range retained")
    require(MailSourceIP.parse(["Received": "from host ([IPv6:2607:F8B0:4005:80A::200E]) by relay"]).primary?.address == "2607:f8b0:4005:80a::200e", "global IPv6 parsed and normalized")
    require(MailSourceIP.parse(["Received": received, "X-Originating-IP": "[8.8.8.8]"]).candidates.count == 2, "duplicate address suppressed")
    require((try? JSONDecoder().decode(MailSourceIP.self, from: JSONEncoder().encode(parsed))) == parsed, "source evidence survives cache roundtrip")

    func fixture(mode: Int = 0) -> Data {
        var data = Data(repeating: 0, count: 15)
        func put(_ value: Int, at offset: Int, bytes: Int) {
            for i in 0..<bytes { data[offset + i] = UInt8((value >> (i * 8)) & 255) }
        }
        put(8, at: 0, bytes: 4); put(8, at: 4, bytes: 4)
        put(0x08080800, at: 8, bytes: 4); put(15, at: 12, bytes: 3)
        data.append(contentsOf: [255, 8, 8, 8]) // range end, little endian
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let country = "美国".data(using: String.Encoding(rawValue: encoding))! + Data([0])
        let area = Data("Example network\0".utf8)
        if mode == 0 { data.append(country); data.append(area) }
        else if mode == 1 { data.append(contentsOf: [1, 23, 0, 0]); data.append(country); data.append(area) }
        else if mode == 2 { data.append(contentsOf: [2, 39, 0, 0]); data.append(area); data.append(country) }
        else { data.append(contentsOf: [1, 19, 0, 0]) } // pointer cycle
        return data
    }
    for mode in 0...2 {
        let database = try? MailIPDatabase(data: fixture(mode: mode))
        require(database?.location("8.8.8.8") == "美国 · Example network", "QQWry direct and redirect mode \(mode)")
        require(database?.location("8.8.8.0") != nil && database?.location("8.8.8.255") != nil, "inclusive IPv4 range bounds")
        require(database?.location("8.8.7.255") == nil && database?.location("8.8.9.0") == nil, "out-of-range IP does not inherit nearest country")
        require(database?.location("2607:f8b0::1") == nil, "IPv6 does not receive a fabricated IPv4 location")
    }
    require((try? MailIPDatabase(data: fixture(mode: 3)))?.location("8.8.8.8") == nil, "cyclic database redirect terminates safely")
    require((try? MailIPDatabase(data: Data([0, 1, 2]))) == nil, "truncated database rejected")
    var invalid = fixture(); invalid[12] = 255
    require((try? MailIPDatabase(data: invalid)) == nil, "out of bounds record pointer rejected")
    var unterminated = fixture(); unterminated[unterminated.count - 1] = 65
    require((try? MailIPDatabase(data: unterminated))?.location("8.8.8.8") == nil, "unterminated area text safely rejected")
}
