import Foundation

func runMailOriginalHTMLTests(_ require: (Bool, String) -> Void) {
    let html = "<p>中文 café</p><img src='https://images.example.test/signature.png'>"
    let plain = "Content-Type: text/html; charset=UTF-8\r\n\r\n" + html
    require(MailOriginalHTML.html(plain) == html, "original MIME keeps Unicode HTML")
    let encoded = "Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: base64\n\n" + Data(html.utf8).base64EncodedString()
    require(MailOriginalHTML.html(encoded) == html, "original MIME decodes base64 body")
    let qp = "Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\n<p>caf=C3=A9</p>=\n<img src=3D'https://images.example.test/s.png'>"
    require(MailOriginalHTML.html(qp) == "<p>café</p><img src='https://images.example.test/s.png'>", "original MIME decodes quoted printable and soft breaks")
    let multi = "Content-Type: multipart/alternative;\n boundary=\"example\"\n\n--example\nContent-Type: text/plain\n\nplain\n--example\n" + plain.replacingOccurrences(of: "\r\n", with: "\n") + "\n--example--\n"
    require(MailOriginalHTML.html(multi)?.contains(html) == true, "multipart chooses HTML alternative")
    let nested = "Content-Type: multipart/related; boundary=outer\n\n--outer\n" + multi + "\n--outer\nContent-Type: image/png\nContent-Transfer-Encoding: base64\n\nAAAA\n--outer--"
    require(MailOriginalHTML.html(nested)?.contains(html) == true, "related body recursively selects main alternative")
    require(MailOriginalHTML.html("Content-Type: text/html\nContent-Disposition: attachment; filename=\"page.html\"\n\n" + html) == nil, "never renders attached HTML as mail body")
    require(MailOriginalHTML.html("Content-Type: multipart/mixed; boundary=empty\n\n--empty\nContent-Type: text/plain\n\nmain\n--empty\n" + plain + "\n--empty--") == nil, "never substitutes later HTML attachment for plain main part")
    require(MailOriginalHTML.html(String(multi.dropLast(14))) == nil, "truncated multipart is rejected")
    require(MailOriginalHTML.html("Content-Type: text/html\nContent-Transfer-Encoding: base64\n\n!invalid!") == nil, "invalid transfer encoding fails closed")
    require(MailOriginalHTML.needsRecovery("<p>Text</p><img alt='photo' src=''>"), "empty image reference requests original body")
    require(!MailOriginalHTML.needsRecovery(html) && !MailOriginalHTML.needsRecovery("<img src='cid:photo'>"), "existing sources do not request original body")
    require(!MailOriginalHTML.needsRecovery("<img data-src='https://images.example.test/a.png'>"), "recognized lazy source does not request original body")
    let rendered = MailHTML.document(html + "<script>bad()</script>", images: false)
    require(!rendered.contains("https://images.example.test") && !rendered.contains("<script"), "recovered HTML still respects external image and script policy")
}
