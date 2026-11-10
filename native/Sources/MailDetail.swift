import Foundation

struct MailAttachment: Codable, Sendable {
    let id: String, name: String, size: Int, cid: String
    static func parse(_ row:[String:Any]) -> MailAttachment? {
        guard let id = Trust.numericID(row["attachmentId"]) else { return nil }
        let name = (Trust.text(row["attachmentName"],limit:240) as NSString).lastPathComponent
        return .init(id:id,name:name.isEmpty ? "附件" : name,size:max(0,Int(String(describing:row["attachmentSize"] ?? "0")) ?? 0),cid:Trust.text(row["cid"],limit:500))
    }
}
struct MailDetail: Codable, Sendable {
    var message:MailMessage
    let from:String, to:String, cc:String, replyTo:String, html:String
    let attachments:[MailAttachment], inline:[MailAttachment]
    var bcc:String?=nil
    // Optional for backwards-compatible decoding of old body caches/drafts.
    var replyHeadersChecked:Bool?=nil
    var imageSourceRecovery:String?=nil
    var rfcMessageID:String?=nil
    var rfcReferences:String?=nil
    var rfcInReplyTo:String?=nil
    var sourceIP:MailSourceIP?=nil
    var visibleAttachments: [MailAttachment]
    var replyAddress:String {
        let reply = MailAddresses.extract(replyTo)
        return (reply.isEmpty ? MailAddresses.extract(from) : reply).joined(separator:", ")
    }

    enum CodingKeys: String, CodingKey {
        case message, from, to, cc, replyTo, html, attachments, inline, bcc,
             replyHeadersChecked, imageSourceRecovery, rfcMessageID, rfcReferences,
             rfcInReplyTo, sourceIP, visibleAttachments
    }

    init(message: MailMessage, from: String, to: String, cc: String, replyTo: String, html: String,
         attachments: [MailAttachment], inline: [MailAttachment], bcc: String? = nil,
         replyHeadersChecked: Bool? = nil, imageSourceRecovery: String? = nil,
         rfcMessageID: String? = nil, rfcReferences: String? = nil, rfcInReplyTo: String? = nil,
         sourceIP: MailSourceIP? = nil, visibleAttachments: [MailAttachment]? = nil) {
        self.message = message
        self.from = from
        self.to = to
        self.cc = cc
        self.replyTo = replyTo
        self.html = html
        self.attachments = attachments
        self.inline = inline
        self.bcc = bcc
        self.replyHeadersChecked = replyHeadersChecked
        self.imageSourceRecovery = imageSourceRecovery
        self.rfcMessageID = rfcMessageID
        self.rfcReferences = rfcReferences
        self.rfcInReplyTo = rfcInReplyTo
        self.sourceIP = sourceIP
        self.visibleAttachments = visibleAttachments ?? Self.computeVisibleAttachments(attachments: attachments, inline: inline, html: html)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(MailMessage.self, forKey: .message)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        cc = try container.decode(String.self, forKey: .cc)
        replyTo = try container.decode(String.self, forKey: .replyTo)
        html = try container.decode(String.self, forKey: .html)
        attachments = try container.decode([MailAttachment].self, forKey: .attachments)
        inline = try container.decode([MailAttachment].self, forKey: .inline)
        bcc = try container.decodeIfPresent(String.self, forKey: .bcc)
        replyHeadersChecked = try container.decodeIfPresent(Bool.self, forKey: .replyHeadersChecked)
        imageSourceRecovery = try container.decodeIfPresent(String.self, forKey: .imageSourceRecovery)
        rfcMessageID = try container.decodeIfPresent(String.self, forKey: .rfcMessageID)
        rfcReferences = try container.decodeIfPresent(String.self, forKey: .rfcReferences)
        rfcInReplyTo = try container.decodeIfPresent(String.self, forKey: .rfcInReplyTo)
        sourceIP = try container.decodeIfPresent(MailSourceIP.self, forKey: .sourceIP)
        if let stored = try container.decodeIfPresent([MailAttachment].self, forKey: .visibleAttachments) {
            visibleAttachments = stored
        } else {
            visibleAttachments = Self.computeVisibleAttachments(attachments: attachments, inline: inline, html: html)
        }
    }

    /// Returns normal attachments plus any inline attachments that are not
    /// referenced in the HTML body, so orphaned signature/inline images are not lost.
    static func computeVisibleAttachments(attachments: [MailAttachment], inline: [MailAttachment], html: String) -> [MailAttachment] {
        guard !inline.isEmpty else { return attachments }
        var list = attachments
        var referenced = Set<String>()
        if let root = MailHTML.parsed(html)?.rootElement() {
            var pending: [XMLNode] = [root]
            while let node = pending.popLast() {
                if let element = node as? XMLElement {
                    if element.name?.lowercased() == "img", let raw = MailInlineImageReference.imageSource(from: element),
                       let file = MailInlineImageReference.attachment(for: raw, alt: element.attribute(forName: "alt")?.stringValue, inline: inline) {
                        referenced.insert(file.id)
                    }
                    for raw in [element.attribute(forName: "background")?.stringValue,
                                element.attribute(forName: "style").flatMap { MailInlineImageReference.extractURLFromStyle($0.stringValue ?? "") }].compactMap({ $0 }) {
                        if let file = MailInlineImageReference.attachment(for: raw, inline: inline) { referenced.insert(file.id) }
                    }
                }
                pending.append(contentsOf: node.children ?? [])
            }
        }
        let unreferencedInline = inline.filter { !referenced.contains($0.id) }
        for file in unreferencedInline {
            if !list.contains(where: { $0.id == file.id }) {
                list.append(file)
            }
        }
        return list
    }
}
enum MailAddresses {
    static func safeHeaderValue(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 16384 else { return nil }
        let value = raw.replacingOccurrences(of: "\r?\n[ \t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    static func validated(_ text:String)->[String]? {
        guard !text.contains("\n"),!text.contains("\r") else{return nil}
        let values=text.split(whereSeparator:{$0=="," || $0==";"}).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        var result:[String]=[]
        for value in values {
            let addresses=extract(value);guard addresses.count==1 else{return nil}
            let address=addresses[0]
            if value != address {
                guard let start=value.firstIndex(of:"<"),value.last==">",String(value[value.index(after:start)..<value.index(before:value.endIndex)])==address,!value[..<start].contains("@"),!value[..<start].contains(">") else{return nil}
            }
            if !result.contains(where:{$0.lowercased()==address.lowercased()}) {result.append(address)}
        };return result
    }
    static func extract(_ text:String) -> [String] {
        let pattern = "[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+"
        guard let regex = try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else { return [] }
        var seen = Set<String>()
        return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { match in
            guard let range = Range(match.range,in:text) else { return nil }; let address = String(text[range])
            return seen.insert(address.lowercased()).inserted ? address : nil
        }
    }
    static func headerAddress(_ name:String, in headers:[String:Any]) -> String {
        let values = headers.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }
            .flatMap { entry -> [String] in
                if let text = entry.value as? String { return [text] }
                return entry.value as? [String] ?? []
            }
        return extract(values.joined(separator:", ")).joined(separator:", ")
    }
    static func reply(_ detail:MailDetail, own:[String], all:Bool = false) -> (to:String,cc:String) {
        let identities = Set(own.flatMap { extract($0) }.map { $0.lowercased() })
        let from = extract(detail.from)
        let externalReply = extract(detail.replyTo).filter { !identities.contains($0.lowercased()) }
        // Form notifications can also be sent From our own mailbox. Their
        // explicit customer Reply-To still takes precedence over sent-mail rules.
        let sentBySelf = externalReply.isEmpty && !from.isEmpty && from.allSatisfy { identities.contains($0.lowercased()) }
        let preferred = !externalReply.isEmpty ? externalReply : (sentBySelf ? extract(detail.to) : extract(detail.replyAddress))
        let to = preferred.filter { !identities.contains($0.lowercased()) }
        let excluded = identities.union(to.map { $0.lowercased() })
        let candidates = sentBySelf ? detail.cc : detail.to + "," + detail.cc
        let cc = all ? extract(candidates).filter { !excluded.contains($0.lowercased()) } : []
        return (to.joined(separator:", "),cc.joined(separator:", "))
    }
    static func replyAll(_ detail:MailDetail, own:String) -> (to:String,cc:String) {
        reply(detail, own:[own], all:true)
    }
}

// The authenticated account WebKit view never receives message HTML. A separate,
// cookie-free, script-disabled view renders this allowlisted fragment only.
enum MailHTML {
    static func sanitizeAnchorsForParser(_ html: String) -> String {
        guard !html.isEmpty else { return html }
        let utf8 = Array(html.utf8)
        let count = utf8.count
        guard count >= 3 else { return html }

        let b_less: UInt8 = 60 // '<'
        let b_slash: UInt8 = 47 // '/'
        let b_greater: UInt8 = 62 // '>'

        // Fast presence check
        var hasA = false
        var hasDivOrP = false
        var hasCenter = false

        var idx = 0
        while idx < count - 2 {
            if utf8[idx] == b_less {
                let c1 = utf8[idx + 1] | 0x20
                if c1 == 97 { // 'a'
                    let c2 = utf8[idx + 2]
                    if c2 == 32 || c2 == 62 || c2 == 47 || c2 == 9 || c2 == 10 || c2 == 13 {
                        hasA = true
                    }
                } else if c1 == 99 && idx + 6 < count { // 'c' -> 'center'
                    if (utf8[idx + 2] | 0x20) == 101 && (utf8[idx + 3] | 0x20) == 110 &&
                       (utf8[idx + 4] | 0x20) == 116 && (utf8[idx + 5] | 0x20) == 101 &&
                       (utf8[idx + 6] | 0x20) == 114 {
                        hasCenter = true
                    }
                } else if (c1 == 100 && (utf8[idx + 2] | 0x20) == 105) || c1 == 112 { // 'di' or 'p'
                    hasDivOrP = true
                }
            }
            if hasCenter && hasA && hasDivOrP { break }
            idx += 1
        }

        if !hasCenter && (!hasA || !hasDivOrP) {
            return html
        }

        var result = [UInt8]()
        result.reserveCapacity(count + 512)

        func isTagDelim(_ b: UInt8) -> Bool {
            b == 32 || b == 62 || b == 47 || b == 9 || b == 10 || b == 13
        }

        var i = 0
        var anchorDepth = 0

        while i < count {
            if utf8[i] == b_less && i + 1 < count {
                let next = utf8[i + 1]
                let c1 = next | 0x20

                // Check <center> / <center ...>
                if c1 == 99 && i + 6 < count &&
                   (utf8[i + 2] | 0x20) == 101 && (utf8[i + 3] | 0x20) == 110 &&
                   (utf8[i + 4] | 0x20) == 116 && (utf8[i + 5] | 0x20) == 101 &&
                   (utf8[i + 6] | 0x20) == 114 {
                    let delim = i + 7 < count ? utf8[i + 7] : 0
                    if delim == 62 { // "<center>"
                        result.append(contentsOf: "<span style=\"display:block;text-align:center\">".utf8)
                        i += 8
                        continue
                    } else if isTagDelim(delim) { // "<center "
                        result.append(contentsOf: "<span style=\"display:block;text-align:center\" ".utf8)
                        i += 8
                        continue
                    }
                }

                // Check </center>
                if next == b_slash && i + 7 < count &&
                   (utf8[i + 2] | 0x20) == 99 && (utf8[i + 3] | 0x20) == 101 &&
                   (utf8[i + 4] | 0x20) == 110 && (utf8[i + 5] | 0x20) == 116 &&
                   (utf8[i + 6] | 0x20) == 101 && (utf8[i + 7] | 0x20) == 114 {
                    var k = i + 8
                    while k < count && utf8[k] != b_greater { k += 1 }
                    if k < count {
                        result.append(contentsOf: "</span>".utf8)
                        i = k + 1
                        continue
                    }
                }

                // Check <a ...
                if c1 == 97 && i + 2 < count && isTagDelim(utf8[i + 2]) {
                    anchorDepth += 1
                    result.append(utf8[i])
                    i += 1
                    continue
                }

                // Check </a ...
                if next == b_slash && i + 2 < count && (utf8[i + 2] | 0x20) == 97 {
                    let delim = i + 3 < count ? utf8[i + 3] : 0
                    if delim == 62 || isTagDelim(delim) {
                        anchorDepth = max(0, anchorDepth - 1)
                        result.append(utf8[i])
                        i += 1
                        continue
                    }
                }

                if anchorDepth > 0 {
                    // Inside anchor: check <div ...
                    if c1 == 100 && i + 3 < count && (utf8[i + 2] | 0x20) == 105 && (utf8[i + 3] | 0x20) == 118 {
                        let delim = i + 4 < count ? utf8[i + 4] : 0
                        if delim == 62 || isTagDelim(delim) {
                            result.append(contentsOf: "<span style=\"display:block\"".utf8)
                            i += 4 // skips "<div"
                            continue
                        }
                    }

                    // Inside anchor: check </div ...
                    if next == b_slash && i + 4 < count &&
                       (utf8[i + 2] | 0x20) == 100 && (utf8[i + 3] | 0x20) == 105 && (utf8[i + 4] | 0x20) == 118 {
                        var k = i + 5
                        while k < count && utf8[k] != b_greater { k += 1 }
                        if k < count {
                            result.append(contentsOf: "</span>".utf8)
                            i = k + 1
                            continue
                        }
                    }

                    // Inside anchor: check <p ...
                    if c1 == 112 {
                        let delim = i + 2 < count ? utf8[i + 2] : 0
                        if delim == 62 || isTagDelim(delim) {
                            result.append(contentsOf: "<span style=\"display:block;margin:1em 0\"".utf8)
                            i += 2 // skips "<p"
                            continue
                        }
                    }

                    // Inside anchor: check </p ...
                    if next == b_slash && i + 2 < count && (utf8[i + 2] | 0x20) == 112 {
                        var k = i + 3
                        while k < count && utf8[k] != b_greater { k += 1 }
                        if k < count {
                            result.append(contentsOf: "</span>".utf8)
                            i = k + 1
                            continue
                        }
                    }
                }
            }

            result.append(utf8[i])
            i += 1
        }

        return String(decoding: result, as: UTF8.self)
    }

    static func parsed(_ html:String)->XMLDocument? {
        let sanitized = sanitizeAnchorsForParser(html)
        var unicode = sanitized
        if unicode.contains("<?xml") || unicode.range(of: "<meta", options: .caseInsensitive) != nil {
            unicode = unicode.replacingOccurrences(of:"<\\?xml[^>]*\\?>|<meta\\b[^>]*(?:charset\\s*=|http-equiv\\s*=)[^>]*>",with:"",options:[.regularExpression,.caseInsensitive])
        }
        if unicode.range(of: "imagedata", options: .caseInsensitive) != nil {
            unicode = unicode
                .replacingOccurrences(of:"<v:imagedata",with:"<img data-vml=\"true\"",options:.caseInsensitive)
                .replacingOccurrences(of:"<imagedata",with:"<img data-vml=\"true\"",options:.caseInsensitive)
        }
        return try? XMLDocument(data:Data(("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">"+unicode).utf8),options:[.documentTidyHTML,.nodeLoadExternalEntitiesNever])
    }
    static func escape(_ text:String) -> String { text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&#39;") }
    static func document(_ html:String, inline:[MailAttachment] = [], images:Bool = false, dark:Bool = false, paper:Bool = false, sessionImages:[String:String] = [:]) -> String {
        let fragment:String
        if let document = parsed(html), let root = document.rootElement() {
            fragment = clean(root,inline:inline,images:images,dark:dark,sessionImages:sessionImages)
        } else { fragment = "<pre>\(escape(html.replacingOccurrences(of:"<[^>]*>",with:"",options:.regularExpression)))</pre>" }
        let imageSources = images ? "data: mail-inline: https:" : "data: mail-inline:"
        let quoteLineColor = dark && !paper ? "#44474f" : "#dfe1e6"
        let palette = paper
            ? "color-scheme:light}body{color:#1c1d21;background:#ffffff}blockquote{border-left:2px solid #dfe1e6;color:#5f6368}a{color:#3556d8}"
            : dark
            ? "color-scheme:dark}body{color:#e6e7ea;background:transparent}blockquote{border-left:2px solid #5a5d66;color:#a9adb7}a{color:#7aa2ff}"
            : "color-scheme:light}body{color:#1c1d21;background:transparent}blockquote{border-left:2px solid #dfe1e6;color:#5f6368}a{color:#3556d8}"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; img-src \(imageSources); style-src 'unsafe-inline'"><meta name="viewport" content="width=device-width, initial-scale=1"><style>:root{\(palette)}html,body{overflow:hidden !important;overflow-x:hidden !important;overflow-y:hidden !important;height:auto !important;min-height:0 !important;margin:0;padding:0;font:15px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.4;overflow-wrap:anywhere}#mail-lite-content{display:flow-root;box-sizing:border-box;width:100%;height:auto;min-height:0;margin:0;padding:2px 0 8px}::-webkit-scrollbar{display:none !important;width:0px !important;height:0px !important;background:transparent !important}img{max-width:100% !important;height:auto !important;border-radius:4px;display:inline-block;vertical-align:middle}table{font:inherit;max-width:100% !important;table-layout:auto;word-wrap:break-word;overflow-wrap:anywhere;border-collapse:collapse}td,th{word-break:break-word;overflow-wrap:anywhere;vertical-align:top}div,p{word-wrap:break-word;overflow-wrap:anywhere;max-width:100%}p{margin:0 0 0.45em}a{overflow-wrap:break-all;word-break:break-word;text-underline-offset:2px}pre{white-space:pre-wrap;word-break:break-word;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;background:rgba(128,128,128,0.08);padding:8px 12px;border-radius:6px}code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;background:rgba(128,128,128,0.08);padding:1px 4px;border-radius:3px}blockquote{margin:8px 0;padding:4px 0 4px 12px;border-radius:0}[data-mail-quote-separator="true"]{border-top:1px solid \(quoteLineColor) !important;margin-top:20px !important;padding-top:16px !important}</style></head><body><div id="mail-lite-content">\(fragment)</div></body></html>
        """
    }
    static func clean(_ node:XMLNode, inline:[MailAttachment], images:Bool, dark:Bool = false, sessionImages:[String:String] = [:]) -> String {
        if node.kind == .text { return escape(node.stringValue ?? "") }
        guard let element = node as? XMLElement else { return "" }
        let tag = (element.name ?? "").lowercased()
        if ["script","style","iframe","frame","frameset","object","embed","form","input","textarea","button","select","link","meta","base","svg","math","head"].contains(tag) { return "" }
        let children = (element.children ?? []).map{clean($0,inline:inline,images:images,dark:dark,sessionImages:sessionImages)}.joined()
        let allowed:Set<String> = ["div","span","p","br","hr","b","strong","i","em","u","s","del","blockquote","pre","code","ul","ol","li","table","tbody","thead","tfoot","tr","td","th","h1","h2","h3","h4","h5","h6","a","img","font","center","sub","sup","v:imagedata","imagedata"]
        guard allowed.contains(tag) else { return children }
        var attributes = MailQuoteSeparator.shouldDecorate(element) ? " data-mail-quote-separator=\"true\"" : ""
        for attribute in element.attributes ?? [] {
            let name = (attribute.name ?? "").lowercased(), value = attribute.stringValue ?? ""
            if ["title","alt","colspan","rowspan","width","height","align","valign","bgcolor"].contains(name), value.count <= 500 {
                attributes += " \(name)=\"\(escape(value))\""
            } else if tag == "table", ["cellpadding", "cellspacing", "border"].contains(name),
                      let amount = Int(value), (0...100).contains(amount) {
                attributes += " \(name)=\"\(amount)\""
            } else if ["td","th","table","body"].contains(tag), name == "background" {
                if let file = MailInlineImageReference.attachment(for: value, inline: inline) {
                    attributes += " background=\"mail-inline://message/\(file.id)\""
                } else if images, let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil {
                    attributes += " background=\"\(escape(url.absoluteString))\""
                }
            } else if name == "style" {
                let properties:Set<String> = [
                    "color","background-color","background-image","background",
                    "font","font-size","font-family","font-weight","font-style","font-variant",
                    "text-decoration","text-align","line-height","letter-spacing","white-space",
                    "margin","margin-left","margin-right","margin-top","margin-bottom",
                    "padding","padding-left","padding-right","padding-top","padding-bottom",
                    "border","border-color","border-width","border-style","border-collapse","border-radius",
                    "border-top","border-right","border-bottom","border-left",
                    "border-top-color","border-right-color","border-bottom-color","border-left-color",
                    "border-top-width","border-right-width","border-bottom-width","border-left-width",
                    "border-top-style","border-right-style","border-bottom-style","border-left-style",
                    "vertical-align","width","max-width","min-width","height","min-height","max-height",
                    "display"
                ]
                let declarations = value.split(separator:";").compactMap { item -> String? in
                    let pieces = item.split(separator:":",maxSplits:1)
                    guard pieces.count == 2 else { return nil }
                    let property = pieces[0].trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                    let raw = pieces[1].trimmingCharacters(in:.whitespacesAndNewlines)
                    if property == "background-image" {
                        if raw.lowercased().contains("gradient(") && SignatureHTML.safeCSSValue(raw) {
                            return "background-image:" + raw
                        }
                        if let urlStr = MailInlineImageReference.extractURLFromStyle(raw),
                           let file = MailInlineImageReference.attachment(for: urlStr, inline: inline) {
                            return "background-image:url(mail-inline://message/\(file.id))"
                        } else if images, let urlStr = MailInlineImageReference.extractURLFromStyle(raw),
                                  let url = URL(string: urlStr), url.scheme == "https", url.user == nil, url.password == nil {
                            return "background-image:url(\(url.absoluteString))"
                        }
                        return nil
                    }
                    if property == "background" {
                        if raw.lowercased().contains("gradient(") && SignatureHTML.safeCSSValue(raw) {
                            return "background:" + raw
                        }
                        if raw.range(of: "url\\s*\\(", options: [.regularExpression, .caseInsensitive]) != nil {
                            if let urlStr = MailInlineImageReference.extractURLFromStyle(raw),
                               let file = MailInlineImageReference.attachment(for: urlStr, inline: inline) {
                                return "background-image:url(mail-inline://message/\(file.id))"
                            } else if images, let urlStr = MailInlineImageReference.extractURLFromStyle(raw),
                                      let url = URL(string: urlStr), url.scheme == "https", url.user == nil, url.password == nil {
                                return "background-image:url(\(url.absoluteString))"
                            }
                            return nil
                        }
                        guard raw.range(of: "url|expression|@|\\\\|[<>]", options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
                        guard dark else { return "background-color:" + raw }
                        return "background-color:" + (mapDarkBackground(raw) ?? raw)
                    }
                    guard properties.contains(property),
                          raw.range(of:"url|expression|@|\\\\|[<>]",options:[.regularExpression,.caseInsensitive]) == nil else { return nil }
                    if property == "font", !SignatureHTML.safeCSSValue(raw) { return nil }
                    guard dark else { return property + ":" + raw }
                    switch property {
                    case "color":
                        return "color:" + (mapDarkForeground(raw) ?? raw)
                    case "background-color":
                        return "background-color:" + (mapDarkBackground(raw) ?? raw)
                    case "border-color", "border-top-color", "border-right-color", "border-bottom-color", "border-left-color":
                        return property + ":" + (mapDarkBorder(raw) ?? raw)
                    case "border", "border-top", "border-right", "border-bottom", "border-left":
                        return property + ":" + mapDarkShorthand(raw)
                    default:
                        return property + ":" + raw
                    }
                }.joined(separator:";")
                if !declarations.isEmpty { attributes += " style=\"\(escape(declarations))\"" }
            } else if tag == "a", name == "href",
                      let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                      Trust.outside(url) {
                attributes += " href=\"\(escape(url.absoluteString))\" rel=\"noreferrer noopener\""
            }
        }
        if ["img", "v:imagedata", "imagedata"].contains(tag) {
            let alt = element.attributes?.first(where: { $0.name?.lowercased() == "alt" })?.stringValue
            let raw = MailInlineImageReference.imageSource(from: element) ?? ""
            let w = element.attributes?.first(where: { $0.name?.lowercased() == "width" })?.stringValue?.trimmingCharacters(in: .whitespaces)
            let h = element.attributes?.first(where: { $0.name?.lowercased() == "height" })?.stringValue?.trimmingCharacters(in: .whitespaces)
            let isBeacon = (w == "1" && h == "1") || (w == "0" && h == "0")
            var source:String?
            if let file = MailInlineImageReference.attachment(for: raw, alt: alt, inline: inline) { source = "mail-inline://message/\(file.id)" }
            else if raw.range(of:"^data:image/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\\s]+$",options:[.regularExpression,.caseInsensitive]) != nil { source = raw }
            else if let cached = sessionImages[raw] { source = "data:\(MailRasterImage.mimeType(for: Data(base64Encoded:cached) ?? Data()) ?? "image/png");base64,\(cached)" }
            else if images, !isBeacon, !MailInlineImageReference.isProviderDisplayURL(raw), let url = URL(string:raw), url.scheme == "https", url.user == nil, url.password == nil { source = url.absoluteString }
            if let source { attributes += " src=\"\(escape(source))\"" }
        }
        if ["br","hr","img"].contains(tag) { return "<\(tag)\(attributes)>" }
        if ["v:imagedata","imagedata"].contains(tag) { return "<img\(attributes)>" }
        if tag == "a", children.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        return "<\(tag)\(attributes)>\(children)</\(tag)>"
    }
    // MARK: - Dark mode colour mapping

    static func components(_ raw: String) -> (Double, Double, Double)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "transparent" || value == "inherit" || value == "initial" { return nil }
        if value.hasPrefix("#") {
            let hex = String(value.dropFirst())
            if hex.count == 3, let r = UInt8(String(hex[hex.startIndex]) + String(hex[hex.startIndex]), radix: 16),
               let g = UInt8(String(hex[hex.index(hex.startIndex, offsetBy: 1)]) + String(hex[hex.index(hex.startIndex, offsetBy: 1)]), radix: 16),
               let b = UInt8(String(hex[hex.index(hex.startIndex, offsetBy: 2)]) + String(hex[hex.index(hex.startIndex, offsetBy: 2)]), radix: 16) {
                return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
            }
            if (hex.count == 6 || hex.count == 8), let number = UInt32(hex.prefix(6), radix: 16) {
                return (Double((number >> 16) & 0xff) / 255, Double((number >> 8) & 0xff) / 255, Double(number & 0xff) / 255)
            }
        }
        if value.hasPrefix("rgb") {
            let digits = value.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if digits.count >= 3, let r = Double(digits[0]), let g = Double(digits[1]), let b = Double(digits[2]) {
                return (min(1, r / 255), min(1, g / 255), min(1, b / 255))
            }
        }
        let named: [String: (Double, Double, Double)] = [
            "white": (1, 1, 1), "black": (0, 0, 0), "red": (1, 0, 0), "green": (0, 0.5, 0),
            "blue": (0, 0, 1), "gray": (0.5, 0.5, 0.5), "grey": (0.5, 0.5, 0.5),
            "silver": (0.75, 0.75, 0.75), "yellow": (1, 1, 0), "orange": (1, 0.65, 0)
        ]
        return named[value]
    }

    static func luminance(_ color: (Double, Double, Double)) -> Double {
        0.2126 * color.0 + 0.7152 * color.1 + 0.0722 * color.2
    }

    static func hex(_ color: (Double, Double, Double)) -> String {
        let r = Int((min(1, max(0, color.0)) * 255).rounded())
        let g = Int((min(1, max(0, color.1)) * 255).rounded())
        let b = Int((min(1, max(0, color.2)) * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// Use neutral dark surfaces for neutral light email templates. White maps
    /// to the dark page; pale grey maps to a slightly raised field surface.
    /// Keep authored dark surfaces and the hue of coloured light surfaces.
    static func mapDarkBackground(_ raw: String) -> String? {
        guard let color = components(raw), luminance(color) > 0.45 else { return nil }
        let lightness = luminance(color)
        let surface = min(0.19, 0.14 + (1 - lightness) * 0.65)
        let chroma = max(color.0, color.1, color.2) - min(color.0, color.1, color.2)
        if chroma < 0.04 { return hex((surface, surface, surface)) }
        return hex((surface + (color.0 - lightness) * 0.16,
                    surface + (color.1 - lightness) * 0.16,
                    surface + (color.2 - lightness) * 0.16))
    }

    /// Dark text authored for a white page becomes light text; already-light
    /// text (buttons, badges) is preserved.
    static func mapDarkForeground(_ raw: String) -> String? {
        guard let color = components(raw), luminance(color) < 0.55 else { return nil }
        return hex((0.80 + color.0 * 0.20, 0.80 + color.1 * 0.20, 0.80 + color.2 * 0.20))
    }

    static func mapDarkShorthand(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "#[0-9a-fA-F]{3,8}|rgba?\\([^)]*\\)") else { return raw }
        var result = raw
        for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            if let mapped = mapDarkBorder(token) { result.replaceSubrange(range, with: mapped) }
        }
        return result
    }

    static func mapDarkBorder(_ raw: String) -> String? {
        guard let color = components(raw), luminance(color) > 0.45 else { return nil }
        return "#3a3b41"
    }

    static func plainText(_ html:String) -> String {
        let fragment=parsed(html)?.rootElement().map{clean($0,inline:[],images:false)} ?? escape(html)
        let breaks = fragment.replacingOccurrences(of:"<(br|/p|/div|/tr)[^>]*>",with:"\n",options:[.regularExpression,.caseInsensitive])
        guard let document = parsed(breaks) else { return breaks.replacingOccurrences(of:"<[^>]*>",with:"",options:.regularExpression) }
        return document.rootElement()?.stringValue ?? ""
    }

    /// Strips editor signature (data-ml-signature) and quote history (data-ml-quote) elements,
    /// returning only the user-authored plain text (trimmed).
    static func authoredPlainText(from html: String) -> String {
        if let doc = try? XMLDocument(data: Data(("<root>" + html + "</root>").utf8),
                                      options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
           let root = doc.rootElement() {
            func removeMarkedNodes(_ node: XMLNode) {
                if let elem = node as? XMLElement {
                    if elem.attribute(forName: "data-ml-signature") != nil ||
                       elem.attribute(forName: "data-ml-quote") != nil {
                        elem.detach()
                        return
                    }
                }
                for child in (node.children ?? []) {
                    removeMarkedNodes(child)
                }
            }
            removeMarkedNodes(root)
            return (root.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var fallback = html
        for attr in ["data-ml-signature", "data-ml-quote"] {
            if let range = fallback.range(of: "<[^>]*" + attr, options: .regularExpression) {
                fallback = String(fallback[..<range.lowerBound])
            }
        }
        return fallback.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
