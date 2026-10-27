import AppKit
import WebKit
import UniformTypeIdentifiers
import Darwin

@MainActor final class MailInlineImages:NSObject,WKURLSchemeHandler {
    weak var reader:MailReader?
    var tasks:[ObjectIdentifier:Task<Void,Never>] = [:]
    func webView(_ webView:WKWebView,start urlSchemeTask:WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        tasks[key] = Task { @MainActor [weak self] in
            defer{self?.tasks.removeValue(forKey:key)}
            do {
                guard let reader=self?.reader,let detail=reader.detail,let id=urlSchemeTask.request.url?.lastPathComponent,
                      let file=detail.inline.first(where:{$0.id == id}),let owner=reader.owner else { throw MailFailure.response }
                let bytes:Data
                if let old=reader.inlineData[id] { bytes=old }
                else { bytes=try await owner.attachmentData(file,message:detail.message);reader.inlineData[id]=bytes }
                try Task.checkCancellation()
                let type=UTType(filenameExtension:(file.name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                guard type.hasPrefix("image/") else { throw MailFailure.response }
                urlSchemeTask.didReceive(URLResponse(url:urlSchemeTask.request.url!,mimeType:type,expectedContentLength:bytes.count,textEncodingName:nil))
                urlSchemeTask.didReceive(bytes);urlSchemeTask.didFinish()
            } catch { if !Task.isCancelled { urlSchemeTask.didFailWithError(NSError(domain:"MailReader",code:1)) } }
        }
    }
    func webView(_ webView:WKWebView,stop urlSchemeTask:WKURLSchemeTask) { tasks.removeValue(forKey:ObjectIdentifier(urlSchemeTask))?.cancel() }
}

@MainActor final class MailReader:NSObject,WKNavigationDelegate {
    weak var owner:MailWindow?
    let message:MailMessage, view=NSView(), subject=NSTextField(wrappingLabelWithString:""), sender=NSTextField(labelWithString:""), recipients=NSTextField(wrappingLabelWithString:""), date=NSTextField(labelWithString:"")
    let body:WKWebView, files=NSStackView(), hint=NSTextField(labelWithString:"正在读取邮件…"), images=NSButton(title:"显示外部图片",target:nil,action:nil)
    let reply=NSButton(title:"回复",target:nil,action:nil), replyAll=NSButton(title:"回复所有人",target:nil,action:nil), forward=NSButton(title:"转发",target:nil,action:nil)
    let edit=NSButton(title:"编辑草稿",target:nil,action:nil)
    let inlineHandler=MailInlineImages()
    var detail:MailDetail?, inlineData:[String:Data]=[:], showingImages=false
    init(owner:MailWindow,message:MailMessage) {
        self.owner=owner;self.message=message
        let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript=false
        configuration.setURLSchemeHandler(inlineHandler,forURLScheme:"mail-inline")
        body=WKWebView(frame:.zero,configuration:configuration)
        super.init();inlineHandler.reader=self;body.navigationDelegate=self;body.setAccessibilityLabel("邮件正文")
        subject.stringValue=message.subject;subject.font = .systemFont(ofSize:24,weight:.semibold);subject.maximumNumberOfLines=3
        sender.stringValue=message.sender;sender.font = .systemFont(ofSize:14,weight:.medium)
        let format=DateFormatter();format.locale=Locale(identifier:"zh_CN");format.dateStyle = .medium;format.timeStyle = .short
        date.stringValue=format.string(from:message.date);date.textColor = .secondaryLabelColor;date.font = .systemFont(ofSize:12)
        recipients.font = .systemFont(ofSize:12);recipients.textColor = .secondaryLabelColor;recipients.maximumNumberOfLines=3
        for field in [subject,sender,recipients,date] { field.isSelectable=true }
        for (button,selector,symbol) in [(reply,#selector(replyAction),"arrowshape.turn.up.left"),(replyAll,#selector(replyAllAction),"arrowshape.turn.up.left.2"),(forward,#selector(forwardAction),"arrowshape.turn.up.right")] {
            button.target=self;button.action=selector;button.bezelStyle = .texturedRounded;button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);button.isEnabled=false
            button.imagePosition = .imageLeading
        }
        images.target=self;images.action=#selector(showImages);images.bezelStyle = .recessed;images.isHidden=true
        hint.font = .systemFont(ofSize:12);hint.textColor = .secondaryLabelColor
        files.orientation = .vertical;files.alignment = .leading;files.spacing=6
        edit.target=self;edit.action=#selector(editAction);edit.bezelStyle = .rounded;edit.isHidden=owner.folderName(message) != "草稿";edit.isEnabled=false
        let actions=NSStackView(views:[reply,replyAll,forward,edit,NSView(),images]);actions.orientation = .horizontal;actions.spacing=10
        let header=NSStackView(views:[subject,sender,recipients,date,actions,files,hint]);header.orientation = .vertical;header.alignment = .leading;header.spacing=12
        view.addSubview(header);view.addSubview(body);header.translatesAutoresizingMaskIntoConstraints=false;body.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:28),header.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-28),header.topAnchor.constraint(equalTo:view.topAnchor,constant:22),actions.widthAnchor.constraint(equalTo:header.widthAnchor),subject.widthAnchor.constraint(equalTo:header.widthAnchor),recipients.widthAnchor.constraint(equalTo:header.widthAnchor),body.leadingAnchor.constraint(equalTo:view.leadingAnchor),body.trailingAnchor.constraint(equalTo:view.trailingAnchor),body.topAnchor.constraint(equalTo:header.bottomAnchor,constant:12),body.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
    }
    func show(_ detail:MailDetail) {
        guard detail.message.key == message.key else { return };self.detail=detail
        let from=MailAddresses.extract(detail.from).joined(separator:", ")
        sender.stringValue=message.sender + (from.isEmpty || from == message.sender ? "" : " <\(from)>")
        let to=MailAddresses.extract(detail.to).joined(separator:", "), cc=MailAddresses.extract(detail.cc).joined(separator:", ")
        recipients.stringValue="至：\(to)" + (cc.isEmpty ? "" : "\n抄送：\(cc)")
        for old in files.arrangedSubviews { files.removeArrangedSubview(old);old.removeFromSuperview() }
        for (index,file) in detail.attachments.enumerated() {
            let size=ByteCountFormatter.string(fromByteCount:Int64(file.size),countStyle:.file)
            let button=NSButton(title:"\(file.name) · \(size)",target:self,action:#selector(previewAttachment(_:)));button.tag=index;button.bezelStyle = .recessed;button.image=NSImage(systemSymbolName:"paperclip",accessibilityDescription:nil)
            button.imagePosition = .imageLeading;button.toolTip=file.name
            let save=NSButton(title:"保存",target:self,action:#selector(saveAttachment(_:)));save.tag=index;save.bezelStyle = .recessed
            let row=NSStackView(views:[button,save]);row.spacing=8;files.addArrangedSubview(row)
        }
        hint.stringValue="";hint.isHidden=true;reply.isEnabled = !detail.replyAddress.isEmpty;replyAll.isEnabled=reply.isEnabled;forward.isEnabled=true;edit.isEnabled=true
        if !edit.isHidden {reply.isHidden=true;replyAll.isHidden=true;forward.isHidden=true}
        images.isHidden = detail.html.range(of:"(?:src|background)\\s*=\\s*['\"]?https?://",options:[.regularExpression,.caseInsensitive]) == nil
        body.loadHTMLString(MailHTML.document(detail.html,inline:detail.inline,images:showingImages),baseURL:nil)
    }
    func failed() { if detail == nil { hint.isHidden=false;hint.stringValue="邮件未能读取，请点击顶部刷新重试。" } }
    @objc func showImages() { guard let detail else{return};showingImages=true;show(detail);images.isHidden=true }
    @objc func replyAction() { if let detail { owner?.compose(detail,mode:.reply) } }
    @objc func replyAllAction() { if let detail { owner?.compose(detail,mode:.replyAll) } }
    @objc func forwardAction() { if let detail { owner?.compose(detail,mode:.forward) } }
    @objc func editAction() {if let detail {owner?.editServerDraft(detail)}}
    @objc func previewAttachment(_ button:NSButton) {guard let detail,detail.attachments.indices.contains(button.tag) else{return};owner?.previewAttachment(detail.attachments[button.tag],message:message)}
    @objc func saveAttachment(_ button:NSButton) {
        guard let detail,detail.attachments.indices.contains(button.tag),let owner else{return};let file=detail.attachments[button.tag]
        let save=NSSavePanel();save.nameFieldStringValue=file.name;save.canCreateDirectories=true
        save.beginSheetModal(for:owner.window) { [weak owner] result in
            guard result == .OK,let owner,let destination=save.url else{return}
            owner.busyDownloads+=1
            Task { @MainActor in
                defer{owner.busyDownloads-=1}
                do {
                    let data=try await owner.attachmentData(file,message:detail.message)
                    let temporary=destination.deletingLastPathComponent().appendingPathComponent(".mail-lite-\(UUID().uuidString).part")
                    defer{try? FileManager.default.removeItem(at:temporary)}
                    try data.write(to:temporary,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temporary.path)
                    guard rename(temporary.path,destination.path) == 0 else{throw MailFailure.response}
                    let quarantine="0001;\(String(Int(Date().timeIntervalSince1970),radix:16));Mail Lite;\(UUID().uuidString)"
                    _=quarantine.withCString{setxattr(destination.path,"com.apple.quarantine",$0,strlen($0),0,0)}
                    owner.status.stringValue="附件已保存"
                } catch { owner.status.stringValue="附件未能保存，请重试（单个附件上限 25 MB）。" }
            }
        }
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        if navigationAction.request.url?.absoluteString == "about:blank",navigationAction.navigationType == .other {decisionHandler(.allow);return}
        if navigationAction.navigationType == .linkActivated,let url=navigationAction.request.url,Trust.outside(url) { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
}
