import Foundation
import WebKit

/// A shareable report contains counts only: no email addresses, subjects, URLs,
/// cookies, message/attachment IDs or CID values.
enum MailImageDiagnostics {
    struct Inventory {
        var images = 0, embedded = 0, matched = 0, unresolved = 0
        var remote = 0, dataImages = 0, unsupported = 0
        var providerSession = 0, relativeOther = 0, emptySource = 0, malformedSource = 0
        var fallbackSources = 0
        var vmlImageTags = 0
        var hasCIDInRawHTML = false
        var hasImageDisplayInRawHTML = false
        var emptyAttributes: [String: Int] = [:]
        var emptyStyleProperties: [String: Int] = [:]
        var files: [MailAttachment] = []
    }
    static func inventory(_ detail: MailDetail) -> Inventory {
        var result = Inventory()
        let lowerHTML = detail.html.lowercased()
        result.hasCIDInRawHTML = lowerHTML.contains("cid:")
        result.hasImageDisplayInRawHTML = lowerHTML.contains("/zm/imagedisplay") || lowerHTML.contains("imagedisplay")
        guard let root = MailHTML.parsed(detail.html)?.rootElement() else { return result }
        var pending: [XMLNode] = [root]
        while let node = pending.popLast() {
            guard let element = node as? XMLElement else { continue }
            let tag = element.name?.lowercased() ?? ""
            if ["script", "head", "style", "iframe", "svg", "object"].contains(tag) { continue }
            if tag == "v:imagedata" || tag == "imagedata" {
                result.vmlImageTags += 1
            }
            if tag == "img" {
                result.images += 1
                let alt = element.attributes?.first(where: { $0.name?.lowercased() == "alt" })?.stringValue
                let raw = MailInlineImageReference.imageSource(from: element) ?? ""
                let primary = element.attributes?.first(where: { $0.name?.lowercased() == "src" })?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if primary.isEmpty && !raw.isEmpty {
                    result.fallbackSources += 1
                }
                if let file = MailInlineImageReference.attachment(for: raw, alt: alt, inline: detail.inline) {
                    result.embedded += 1
                    result.matched += 1
                    if !result.files.contains(where: { $0.id == file.id }) { result.files.append(file) }
                } else if MailInlineImageReference.cid(from: raw) != nil || MailInlineImageReference.isProviderDisplayURL(raw) {
                    result.embedded += 1
                    result.unresolved += 1
                } else if raw.lowercased().hasPrefix("data:image/") { result.dataImages += 1 }
                else if MailInlineImageReference.sessionImageURL(raw, origin: detail.message.origin) != nil { result.providerSession += 1 }
                else if let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { result.remote += 1 }
                else if raw.isEmpty {
                    result.emptySource += 1
                    for attr in element.attributes ?? [] {
                        if let name = attr.name?.lowercased(), !name.isEmpty {
                            result.emptyAttributes[name, default: 0] += 1
                        }
                    }
                    if let style = element.attributes?.first(where: { $0.name?.lowercased() == "style" })?.stringValue {
                        let declarations = style.split(separator: ";")
                        for decl in declarations {
                            let parts = decl.split(separator: ":", maxSplits: 1)
                            if !parts.isEmpty {
                                let prop = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                if !prop.isEmpty {
                                    result.emptyStyleProperties[prop, default: 0] += 1
                                }
                            }
                        }
                    }
                }
                else if raw.hasPrefix("/") || raw.hasPrefix("./") || raw.hasPrefix("../") { result.relativeOther += 1 }
                else { result.malformedSource += 1 }
            }
            pending.append(contentsOf: element.children ?? [])
        }
        return result
    }
    static func summary(_ value: Inventory, inlineCount: Int, remoteAllowed: Bool) -> String {
        var text = """
        Mail Lite 图片诊断
        正文图片：\(value.images)
        内嵌引用：\(value.embedded)；匹配：\(value.matched)；未匹配：\(value.unresolved)
        服务器内嵌附件：\(inlineCount)
        外链：\(value.remote)（\(remoteAllowed ? "已允许加载" : "当前未允许加载")）
        需登录的Zoho图片：\(value.providerSession)
        数据图片：\(value.dataImages)；相对路径：\(value.relativeOther)；空来源：\(value.emptySource)；无法识别：\(value.malformedSource)
        """
        if value.vmlImageTags > 0 {
            text += "\nVML矢量图片标签：\(value.vmlImageTags)"
        }
        if value.fallbackSources > 0 {
            text += "\n备用属性/样式识别（如data-src/style background）：\(value.fallbackSources)"
        }
        if value.emptySource > 0 && !value.emptyAttributes.isEmpty {
            let sortedAttrs = value.emptyAttributes.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value })
                .map { "\($0.key)(\($0.value))" }
                .joined(separator: "，")
            text += "\n空来源属性分布：\(sortedAttrs)"
        }
        if !value.emptyStyleProperties.isEmpty {
            let sortedStyles = value.emptyStyleProperties.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value })
                .map { "\($0.key)(\($0.value))" }
                .joined(separator: "，")
            text += "\n空来源style样式分布：\(sortedStyles)"
        }
        text += "\n原始HTML特征：含CID(\(value.hasCIDInRawHTML ? "是" : "否"))；含ImageDisplay(\(value.hasImageDisplayInRawHTML ? "是" : "否"))"
        return text
    }
    /// Unique trusted provider-session image sources in document order, capped.
    /// Raw values only; nothing is logged or shared.
    static func providerSessionSources(_ detail: MailDetail, limit: Int = 8) -> [String] {
        guard let root = MailHTML.parsed(detail.html)?.rootElement() else { return [] }
        var found: [String] = []
        var pending: [XMLNode] = [root]
        while let node = pending.popLast() {
            guard let element = node as? XMLElement else { continue }
            let tag = element.name?.lowercased() ?? ""
            if ["script", "head", "style", "iframe", "svg", "object"].contains(tag) { continue }
            if tag == "img",
               let raw = MailInlineImageReference.imageSource(from: element),
               !raw.isEmpty,
               MailInlineImageReference.attachment(for: raw, inline: detail.inline) == nil,
               MailInlineImageReference.sessionImageURL(raw, origin: detail.message.origin) != nil,
               !found.contains(raw), found.count < limit { found.append(raw) }
            pending.append(contentsOf: element.children ?? [])
        }
        return found
    }

    struct RenderStats {
        var total = 0, loaded = 0, broken = 0, pending = 0
        var remoteLoaded = 0, remoteBroken = 0, remotePending = 0
    }

    static let liveRenderScript = """
    (() => {
        const imgs = Array.from(document.querySelectorAll('img'));
        let loaded = 0, broken = 0, pending = 0;
        let remoteLoaded = 0, remoteBroken = 0, remotePending = 0;
        for (const img of imgs) {
            const src = img.currentSrc || img.src || '';
            const isRemote = src.startsWith('http://') || src.startsWith('https://');
            if (img.complete) {
                if (img.naturalWidth > 0 && img.naturalHeight > 0) {
                    loaded++;
                    if (isRemote) remoteLoaded++;
                } else {
                    broken++;
                    if (isRemote) remoteBroken++;
                }
            } else {
                pending++;
                if (isRemote) remotePending++;
            }
        }
        return {
            total: imgs.length,
            loaded: loaded,
            broken: broken,
            pending: pending,
            remoteLoaded: remoteLoaded,
            remoteBroken: remoteBroken,
            remotePending: remotePending
        };
    })()
    """

    static func liveRenderStats(from webView: WKWebView) async -> RenderStats? {
        do {
            let res = try await webView.evaluateJavaScript(liveRenderScript)
            guard let dict = res as? [String: Any] else { return nil }
            return RenderStats(
                total: dict["total"] as? Int ?? 0,
                loaded: dict["loaded"] as? Int ?? 0,
                broken: dict["broken"] as? Int ?? 0,
                pending: dict["pending"] as? Int ?? 0,
                remoteLoaded: dict["remoteLoaded"] as? Int ?? 0,
                remoteBroken: dict["remoteBroken"] as? Int ?? 0,
                remotePending: dict["remotePending"] as? Int ?? 0
            )
        } catch {
            return nil
        }
    }
}

@MainActor extension AppState {
    func imageDiagnostics(_ detail: MailDetail, remoteAllowed: Bool, webView: WKWebView? = nil) async -> String {
        let inventory = MailImageDiagnostics.inventory(detail)
        var result = MailImageDiagnostics.summary(inventory, inlineCount: detail.inline.count, remoteAllowed: remoteAllowed)
        if let recovery = detail.imageSourceRecovery {
            switch recovery {
            case "original-mime": result += "\n图片来源：已从本邮件原始 MIME 正文恢复。"
            case "original-partial": result += "\n已从原始 MIME 恢复部分图片，其余来源仍缺失。"
            case "original-too-large": result += "\n原始邮件超过读取上限，未替换正文。"
            case "original-unparseable": result += "\n已读取原始邮件，但无法从其 MIME 结构或编码提取 HTML 正文。"
            case "original-invalid-response": result += "\n原始邮件接口未返回匹配的正文。"
            case "original-read-failed": result += "\n原始邮件读取失败，请刷新或检查账号登录状态。"
            case "original-empty": result += "\n原始 MIME 正文也有空图片来源，未猜测或替换地址。"
            case "unavailable": result += "\n原始 MIME 正文未能读取或解析，暂保留原正文。"
            default: if recovery.hasPrefix("original-read-failed:") { result += "\n原始邮件读取失败：" + String(recovery.dropFirst("original-read-failed:".count)) }
            }
        }
        let files = Array(inventory.files.prefix(3))
        var readable = 0, invalid = 0, failed = 0
        let lifetime = contextActionLifetime()
        for file in files {
            guard !Task.isCancelled, acceptsContextAction(accountID: detail.message.accountID, lifetime: lifetime) else {
                return result + "\n附件检查已停止：账号或应用状态已变化。"
            }
            do {
                let data = try await attachmentData(file, message: detail.message)
                guard !Task.isCancelled, acceptsContextAction(accountID: detail.message.accountID, lifetime: lifetime) else {
                    return result + "\n附件检查已停止：账号或应用状态已变化。"
                }
                if MailRasterImage.mimeType(for: data) != nil { readable += 1 } else { invalid += 1 }
            } catch { failed += 1 }
        }
        result += "\n附件实测（最多3项）：有效图片 \(readable)，非支持图片 \(invalid)，读取失败 \(failed)。"
        let providers = MailImageDiagnostics.providerSessionSources(detail, limit: 2)
        if !providers.isEmpty {
            var ok = 0, auth = 0, bad = 0
            for raw in providers {
                guard !Task.isCancelled, acceptsContextAction(accountID: detail.message.accountID, lifetime: lifetime) else {
                    return result + "\n图片检查已停止：账号或应用状态已变化。"
                }
                do {
                    let data = try await sessionImageData(raw, message: detail.message)
                    guard !Task.isCancelled, acceptsContextAction(accountID: detail.message.accountID, lifetime: lifetime) else {
                        return result + "\n图片检查已停止：账号或应用状态已变化。"
                    }
                    if MailRasterImage.mimeType(for: data) != nil { ok += 1 } else { bad += 1 }
                } catch MailFailure.auth { auth += 1 } catch { bad += 1 }
            }
            result += "\nZoho图片实测（最多2项）：成功 \(ok)，需重新登录 \(auth)，失败 \(bad)。"
            if auth > 0 { result += "\n定位：Zoho图片需要登录会话；请重新登录账号后重试。" }
            if bad > 0 { result += "\n定位：Zoho图片下载或格式校验未通过。" }
            if ok > 0 { result += "\nZoho图片已可经登录会话加载；此邮件重开即显示。" }
        }
        if let webView, let stats = await MailImageDiagnostics.liveRenderStats(from: webView) {
            result += "\n页面实测渲染：成功加载 \(stats.loaded)，空白或失败 \(stats.broken)，加载中 \(stats.pending)。"
            if inventory.remote > 0 {
                result += "\n外链实测渲染：成功加载 \(stats.remoteLoaded)，空白或失败 \(stats.remoteBroken)，加载中 \(stats.remotePending)。"
                if stats.remoteBroken > 0 {
                    result += "\n定位：部分外链图片渲染失败或空白（naturalWidth=0）；可能受防盗链、Cookie会话或网络限制。"
                }
            }
        }
        if inventory.unresolved > 0 { result += "\n定位：部分图片未关联到当前邮件附件；仍需检查服务器引用信息。" }
        if invalid > 0 { result += "\n定位：返回内容不是支持的图片，或尺寸/大小超限。" }
        if failed > 0 { result += "\n定位：附件下载未成功；不是布局留白问题。" }
        if inventory.matched > 0 && readable == files.count && !files.isEmpty { result += "\n已匹配图片下载及格式检查通过；若仍空白，应继续检查显示链路。" }
        result += "\n诊断不包含地址、主题、链接、账号号或CID。"
        return result
    }
}
