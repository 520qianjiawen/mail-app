import Foundation

@MainActor func runMailInlineImageSendTests(_ require: (Bool, String) -> Void) async {
    let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
    func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); require(false, label) }
        catch { require(error is MailInlineImageSend.Failure, label) }
    }
    do {
        let original = "<p style=\"color: #334455\">Before &amp; after</p><img src=\"\(png)\" alt=\"pasted\" width=\"1\"><div class=\"signature\"><img src=\"https://example.test/signature.png\"><b>署名</b></div>"
        let prepared = try MailInlineImageSend.prepare(original)
        require(prepared.html == original && prepared.imageCount == 1 && prepared.imageBytes > 0,
                "send production preflight retains entire data-URI body and HTTPS signature byte-for-byte")
        let retried = try MailInlineImageSend.prepare(prepared.html)
        require(retried.html == original && retried.imageBytes == prepared.imageBytes,
                "retry reruns pure preflight without rewriting durable data-URI body")
        let payload = try JSONSerialization.data(withJSONObject: ["content": prepared.html, "mailFormat": "html"])
        let decoded = try JSONSerialization.jsonObject(with: payload) as! [String: String]
        require(decoded["content"] == original && decoded["content"]!.contains(png),
                "JSON content preserves actual base64 and signature; no guessed CID/wire fields")
        let ordinary = "<p>plain body</p><img src='https://example.test/signature.png'>"
        require(try MailInlineImageSend.prepare(ordinary).html == ordinary,
                "ordinary HTML/signature path remains unchanged")
        let upper = "<IMG SRC='\(png)' data-other='data:bogus'>"
        require(try MailInlineImageSend.prepare(upper).imageCount == 1,
                "actual uppercase image tag and single-quoted src parsed inertly")
        let unquoted = "<img src=\(png)>"
        require(try MailInlineImageSend.prepare(unquoted).imageCount == 1,
                "actual unquoted data-URI src is recognized")
        let unrelated = "<!-- <img src='data:image/png;base64,invalid'> --><style>.x { background: url(data:invalid); }</style><p data-src='data:invalid'>data:invalid</p><img data-src='data:invalid' src='https://example.test/image'>"
        let unchanged = try MailInlineImageSend.prepare(unrelated)
        require(unchanged.html == unrelated && unchanged.imageCount == 0,
                "comments CSS text data-src and remote image are not extracted or rewritten")
        let two = "<img src='\(png)'><img src='\(png)'>"
        require(try MailInlineImageSend.prepare(two).imageCount == 2,
                "duplicate image nodes counted independently without mutation")
        let eight = String(repeating: "<img src='\(png)'>", count: 8)
        require(try MailInlineImageSend.prepare(eight).imageCount == 8, "eight pasted image nodes accepted")
        require(try MailInlineImageSend.prepare(eight + "<img src='\(png)'>").imageCount == 9,
                "ninth image is accepted without an arbitrary image-count cap")
        require(try MailInlineImageSend.prepare(String(repeating: "<img src='\(png)'>", count: 500)).imageCount == 500,
                "500 inline references are checked by total body size rather than a fixed image count")
        for source in ["data:image/png;base64,%%%%", "data:image/png;base64,", "data:image/png;base64,SGVsbG8=", "data:image/svg+xml;base64,PHN2Zz4=", "data:text/html;base64,PGgxPg==", "data:image/png,raw"] {
            rejects("malformed/unsupported image src rejected before send") {
                _ = try MailInlineImageSend.prepare("<img src='\(source)'>")
            }
        }
        var boundary = Data([137,80,78,71,13,10,26,10])
        boundary.append(Data(repeating: 0, count: MailInlineImageSend.maximumImageBytes - boundary.count))
        let exact = "data:image/png;base64," + boundary.base64EncodedString()
        require(try MailInlineImageSend.decodeImage(exact).count == MailInlineImageSend.maximumImageBytes,
                "exact resource-size boundary accepted by production decoder")
        boundary.append(0)
        rejects("decoded image over resource-size boundary rejected") {
            _ = try MailInlineImageSend.decodeImage("data:image/png;base64," + boundary.base64EncodedString())
        }
        rejects("body over allocation guard rejected without parsing huge input") {
            _ = try MailInlineImageSend.prepare(String(repeating: "x", count: MailInlineImageSend.maximumBodyBytes + 1))
        }
        rejects("HTML entity declaration never loaded") {
            _ = try MailInlineImageSend.prepare("<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///not-read'>]><img src='\(png)'>")
        }
        let expected = MailboxSession(accountID: "A", remoteID: "100", email: "a@example.test", origin: URL(string: "https://mail.zoho.com")!, folders: [], addresses: ["a@example.test"])
        require(MailInlineImageSend.sameContext(expected, expected: expected), "send fence accepts unchanged mailbox context")
        require(!MailInlineImageSend.sameContext(nil, expected: expected), "send fence rejects removed mailbox context")
        func changed(account: String = "A", remote: String = "100", origin: String = "https://mail.zoho.com") -> MailboxSession {
            .init(accountID: account, remoteID: remote, email: expected.email, origin: URL(string: origin)!, folders: [], addresses: expected.addresses)
        }
        require(!MailInlineImageSend.sameContext(changed(account: "B"), expected: expected), "send fence rejects account switch")
        require(!MailInlineImageSend.sameContext(changed(remote: "200"), expected: expected), "send fence rejects remote account switch")
        require(!MailInlineImageSend.sameContext(changed(origin: "https://mail.zoho.eu"), expected: expected), "send fence rejects origin switch")
    } catch { require(false, "inline-image pure send setup: \(error)") }
}
