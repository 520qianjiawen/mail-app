import Foundation

/// Pure synthetic fixtures only. Also callable from the app's focused test runner.
func runSignatureHTMLSanitizerTests(_ require: (Bool, String) -> Void) {
    let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII="
    let company = """
    <!doctype html><html><head><style>
    .company { font-family: 'Helvetica Neue', Arial; font-size:12pt; color:#273244; }
    .company .name { text-transform:uppercase; letter-spacing:2px; border-bottom:1px solid #adc; }
    table.company > tbody > tr > td.logo { padding-right:18px; width:88px; }
    .company .footer { border-top:1px solid #ddd; padding-top:12px; }
    </style></head><body><table class="company" style="border-collapse:collapse;width:520px">
    <tbody><tr><td class="logo"><img src="\(png)" width="72" alt="Synthetic logo"></td>
    <td style="border-left:3px solid #2b6688;padding-left:18px;margin:0 0 10px">
    <div class="name" style="font-size:16pt">Alex Example</div><p>Example Company</p>
    <img src="https://assets.example.test/logo.png" width="48"></td></tr>
    <tr><td colspan="2" class="footer"><table width="100%"><tr><td>Left footer</td><td>Right footer</td></tr></table></td></tr>
    </tbody></table></body></html>
    """
    let clean = SignatureHTML.sanitize(company) ?? ""
    for token in ["border-left:3px solid", "border-bottom:1px solid", "text-transform:uppercase", "letter-spacing:2px", "padding-left:18px", "padding-right:18px", "font-size:12pt", "font-size:16pt", "https://assets.example.test/logo.png", png, "<table", "colspan=\"2\""] {
        require(clean.contains(token), "signature preserves company layout: \(token.prefix(60))")
    }
    require(!clean.contains("<style"), "stylesheet rules become local inline styles")
    require(SignatureHTML.sanitize(clean) == clean, "sanitizer is stable across preferences normalization")
    let active = """
    <style>@import 'https://bad.example/style'; .x {background:url(https://bad.example/track)}</style>
    <div class="x" data-ml-signature="forged" onclick="evil()" style="border-left:2px solid red;background:u/**/rl(https://bad.example/a);font-size:12px;behavior:evil;--load:url(x)">
    Name<script>alert(1)</script><iframe src="https://bad.example"></iframe><form><input value="secret"></form><object>bad</object>
    <svg><image href="https://bad.example/vector"/></svg>
    <a href="java&#x73;cript:alert(1)">bad link</a><a href="file:///tmp/x">file</a>
    <img src="data:image/svg+xml;base64,PHN2Zz4=" onerror="evil()"><img src="javascript:evil()"><img src="file:///tmp/x">
    </div>
    """
    let inert = SignatureHTML.sanitize(active) ?? ""
    require(inert.contains("Name") && inert.contains("border-left:2px solid red") && inert.contains("font-size:12px"), "active input retains inert author content and safe declarations")
    for token in ["<script", "onclick", "onerror", "<iframe", "<form", "<object", "<svg", "javascript:", "file:", "data:image/svg", "https://bad.example", "data-ml-", "@import", "url(", "behavior:"] {
        require(!inert.contains(token), "signature removes active content: \(token)")
    }
    require(SignatureHTML.sanitize("<img src='https://assets.example.test/logo.png'>") != nil, "image-only signature remains valid")
    require(SignatureHTML.sanitize("<img src='http://assets.example.test/logo.png'>") == nil, "non-HTTPS image rejected")
    require(SignatureHTML.sanitize("<script>x</script>") == nil, "active-only content fails closed")
    require(SignatureHTML.sanitize(String(repeating: "x", count: 256 * 1024 + 1)) == nil, "oversized signature fails closed")
    require(SignatureHTML.sanitize("<!DOCTYPE html SYSTEM 'file:///tmp/entity'><div>x</div>") == nil, "external DTD rejected before parse")
    require(SignatureHTML.sanitize("<img src='data:image/png;base64,bm90IGFuIGltYWdl'>") == nil, "invalid raster data fails closed")
    require(SignatureHTML.sanitize("<div style='background:u\\72l(https://bad.example);font-family:Arial'>X</div>")?.contains("style=") == false, "escaped CSS drops complete declaration set")
    let specificity = SignatureHTML.sanitize("<style>.name{color:red}div{color:blue}</style><div class='name' style='color:green'>X</div>") ?? ""
    require(specificity.contains("color:blue;color:red;color:green"), "stylesheet specificity and explicit inline order preserved")
    require(SignatureHTML.sanitize("<div>" + String(repeating: "<span>x</span>", count: 4097) + "</div>") == nil, "node count limit fails closed")
    require(SignatureHTML.sanitize(String(repeating: "<div>", count: 70) + "x" + String(repeating: "</div>", count: 70)) == nil, "depth limit fails closed")
    let escaped = SignatureHTML.sanitize("<div style='font-family:&quot;Arial&quot;;border-bottom:1px solid #fff' data-ml-quote='x' id='keep' class='brand'><a href='https://example.test/a?x=1&amp;y=2'>A&amp;B</a></div>") ?? ""
    require(escaped.contains("id=\"keep\"") && escaped.contains("class=\"brand\"") && !escaped.contains("data-ml"), "class/id retained but all composer metadata removed")
    require(SignatureHTML.sanitize(escaped) == escaped, "escaped attributes and entities normalize idempotently")
    let origin = URL(string: "https://mail.example.test/")!
    let relative = "<base href='https://untrusted.example.test/'><img src='/assets/logo.png'><img src='images/logo.png'><img src='//cdn.example.test/logo.png'><a href='/contact'>Contact</a>"
    let resolved = SignatureHTML.sanitize(relative, baseURL: origin) ?? ""
    require(resolved.contains("https://mail.example.test/assets/logo.png") && resolved.contains("https://mail.example.test/images/logo.png") && resolved.contains("https://cdn.example.test/logo.png") && resolved.contains("href=\"https://mail.example.test/contact\"") && !resolved.contains("untrusted.example.test"), "explicit trusted origin resolves relative/CDN resources and ignores HTML base")
    let unresolved = SignatureHTML.sanitize(relative) ?? ""
    require(!unresolved.contains("src=") && !unresolved.contains("href="), "default sanitizer still strips relative and protocol-relative resource URLs")
    let badResources = SignatureHTML.sanitize("<p>X</p><img src='//user:pass@cdn.example.test/logo.png'><img src='file:///tmp/logo.png'><img src='javascript:evil()'><a href='https://user:pass@example.test/path'>X</a>", baseURL: origin) ?? ""
    require(!badResources.contains("src=") && !badResources.contains("href="), "trusted base does not permit credential-bearing or active resource URLs")
    require(SignatureHTML.sanitize("<img src='/logo.png'>", baseURL: URL(string: "file:///tmp/")) == nil, "non-HTTPS base cannot resolve resources")
    let inherited = SignatureHTML.sanitize("<html><head><style>body{font-size:13pt}</style></head><body style='color:#123'>Text</body></html>") ?? ""
    require(inherited.contains("font-size:13pt;color:#123"), "body typography transfers to inert fragment wrapper")
    let divider = SignatureHTML.sanitize("<hr style='border:none;border-top:1.5px solid rgb(0, 122, 255);background:linear-gradient(to right, rgb(0, 122, 255), transparent);height:1.5px;margin:6px 0 10px 0;width:480px'><span>Signature</span>") ?? ""
    require(divider.contains("linear-gradient(to right, rgb(0, 122, 255), transparent)") && divider.contains("border-top:1.5px solid rgb(0, 122, 255)") && divider.contains("<hr"), "gradient divider line and hr tag are preserved")
}
