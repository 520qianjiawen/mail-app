import AppKit

enum ComposeMode:String {case new,reply,replyAll,forward,edit}
@MainActor final class MailCompose:NSObject,NSWindowDelegate,NSTextViewDelegate,NSTextFieldDelegate {
    weak var owner:MailWindow?
    var draft:MailDraft
    let window:NSWindow
    let from=NSPopUpButton(),to=NSTextField(),cc=NSTextField(),bcc=NSTextField(),subject=NSTextField(),text=NSTextView()
    let status=NSTextField(labelWithString:""),files=NSStackView(),send=NSButton(title:"发送",target:nil,action:nil),attach=NSButton(title:"添加附件",target:nil,action:nil),save=NSButton(title:"保存草稿",target:nil,action:nil)
    let cloud=NSButton(title:"同步草稿",target:nil,action:nil),signatures=NSPopUpButton(frame:.zero,pullsDown:true),templates=NSButton(title:"插入模板",target:nil,action:nil),receipt=NSButton(checkboxWithTitle:"请求已读回执",target:nil,action:nil),schedule=NSPopUpButton()
    var localFiles:[URL]=[],dirty=false,sending=false,syncing=false,autosave:Timer?
    var fromOptions:[(String,String)]=[],signatureOptions:[MailSignature]=[]
    let reconcile=NSButton(title:"核对发送及草稿结果…",target:nil,action:nil)
    var mode:ComposeMode {ComposeMode(rawValue:draft.mode) ?? .new}
    var forwarded:[MailAttachment] {[ComposeMode.forward, .edit].contains(mode) ? (draft.source?.attachments ?? []).filter{!(draft.excludedForwardIDs ?? []).contains($0.id)} : []}
    convenience init(owner:MailWindow,detail:MailDetail,mode:ComposeMode) {
        let own=owner.contexts[detail.message.accountID]?.email ?? owner.accountName(detail.message.accountID)
        var value=MailDraft(accountID:detail.message.accountID,from:own,mode:mode.rawValue,source:detail)
        if mode == .replyAll {let addresses=MailAddresses.replyAll(detail,own:own);value.to=addresses.to;value.cc=addresses.cc}
        else if mode == .reply {value.to=detail.replyAddress}
        let prefix=mode == .forward ? "Fwd: " : "Re: "
        value.subject=detail.message.subject.lowercased().hasPrefix(prefix.lowercased()) ? detail.message.subject : prefix+detail.message.subject
        value.body="\n\n———— 原邮件 ————\n发件人：\(detail.from)\n收件人：\(detail.to)\n主题：\(detail.message.subject)\n\n\(MailHTML.plainText(detail.html))"
        self.init(owner:owner,draft:value)
    }
    convenience init(owner:MailWindow,account:MailAccount) {
        self.init(owner:owner,draft:MailDraft(accountID:account.id,from:owner.contexts[account.id]?.email ?? "",mode:ComposeMode.new.rawValue,source:nil))
    }
    init(owner:MailWindow,draft:MailDraft) {
        self.owner=owner;self.draft=draft
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:840,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init();window.title=mode == .new ? "写邮件" : mode == .forward ? "转发邮件" : mode == .edit ? "编辑草稿" : "回复邮件";window.isReleasedWhenClosed=false;window.delegate=self;window.minSize=NSSize(width:700,height:660)
        to.placeholderString="收件人";cc.placeholderString="抄送";bcc.placeholderString="密送";subject.placeholderString="主题"
        to.stringValue=draft.to;cc.stringValue=draft.cc;bcc.stringValue=draft.bcc;subject.stringValue=draft.subject
        for field in [to,cc,bcc,subject] {field.delegate=self}
        text.isRichText=true;text.importsGraphics=false;text.font = .systemFont(ofSize:14);text.isAutomaticQuoteSubstitutionEnabled=false;text.isAutomaticDashSubstitutionEnabled=false;text.textContainerInset=NSSize(width:12,height:14);text.isVerticallyResizable=true;text.isHorizontallyResizable=false;text.autoresizingMask = .width;text.textContainer?.widthTracksTextView=true
        if let rtf=draft.rtf,let value=NSAttributedString(rtf:rtf,documentAttributes:nil) {text.textStorage?.setAttributedString(value)}else{text.string=draft.body}
        if draft.rtf==nil,let source=draft.source,mode != .edit,let root=MailHTML.parsed(source.html)?.rootElement() {
            let header="原邮件<br>发件人：\(MailHTML.escape(source.from))<br>收件人：\(MailHTML.escape(MailAddresses.extract(source.to).joined(separator:", ")))<br>主题：\(MailHTML.escape(source.message.subject))"
            let quote="<html><head><meta charset='utf-8'></head><body><p><br><br></p><p>\(header)</p><blockquote>\(MailHTML.clean(root,inline:[],images:false))</blockquote></body></html>"
            if let value=try? NSAttributedString(data:Data(quote.utf8),options:[.documentType:NSAttributedString.DocumentType.html,.characterEncoding:String.Encoding.utf8.rawValue],documentAttributes:nil) {text.textStorage?.setAttributedString(value)}
        }
        text.delegate=self;localFiles=owner.draftStore.files(draft)
        let scroll=NSScrollView();scroll.documentView=text;scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder
        for (button,selector) in [(send,#selector(sendAction)),(attach,#selector(addAttachments)),(save,#selector(saveAction)),(cloud,#selector(syncAction)),(templates,#selector(templateAction))] {button.target=self;button.action=selector;button.bezelStyle = .rounded}
        from.target=self;from.action=#selector(fromChanged)
        receipt.state=draft.receipt ? .on : .off;receipt.target=self;receipt.action=#selector(optionChanged)
        for name in ["立即发送","一小时后发送","两小时后发送","四小时后发送","明天上午发送","明天下午发送"] {schedule.addItem(withTitle:name)}
        schedule.selectItem(at:draft.scheduleType ?? 0);schedule.target=self;schedule.action=#selector(optionChanged)
        signatures.addItem(withTitle:"插入签名");signatures.target=self;signatures.action=#selector(signatureChanged)
        let bold=NSButton(title:"粗体",target:self,action:#selector(formatAction)),italic=NSButton(title:"斜体",target:self,action:#selector(formatAction)),underline=NSButton(title:"下划线",target:self,action:#selector(formatAction))
        for (index,button) in [bold,italic,underline].enumerated() {button.tag=index;button.bezelStyle = .recessed}
        let format=NSStackView(views:[bold,italic,underline,NSView(),signatures,templates]);format.spacing=8
        let options=NSStackView(views:[receipt,NSView(),schedule]);options.spacing=8
        status.font = .systemFont(ofSize:11);status.textColor = .secondaryLabelColor;status.lineBreakMode = .byTruncatingTail
        reconcile.target=self;reconcile.action=#selector(reconcileAction);reconcile.bezelStyle = .recessed;reconcile.isHidden = draft.state=="editing" && !draft.cloudUncertain || draft.state=="sent"
        let actions=NSStackView(views:[attach,save,cloud,reconcile,NSView(),send]);actions.spacing=8
        files.orientation = .vertical;files.alignment = .leading;files.spacing=3
        let fromRow=NSStackView(views:[NSTextField(labelWithString:"发件人"),from]);fromRow.spacing=10
        let stack=NSStackView(views:[fromRow,to,cc,bcc,subject,format,files,scroll,options,status,actions]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10
        let root=NSView();window.contentView=root;root.addSubview(stack);stack.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:root.topAnchor,constant:18),stack.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-18),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:210)])
        for view in [fromRow,to,cc,bcc,subject,format,files,scroll,options,status,actions] {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        updateFromOptions();updateAttachments();loadSignatures()
        if draft.state != "editing" {send.isEnabled=false;status.stringValue=draft.state=="sent" ? "此邮件已发送" : "上次发送结果未确认，请先核对已发送邮件"}
        if draft.cloudUncertain {cloud.isEnabled=false;send.isEnabled=false;status.stringValue="云端草稿结果未确认，本机内容已保留；请先核对草稿文件夹"}
        window.center();window.makeKeyAndOrderFront(nil);window.makeFirstResponder(mode == .new ? to : text);text.setSelectedRange(NSRange(location:0,length:0))
    }
    func updateFromOptions() {
        guard let owner else{return};fromOptions=[];from.removeAllItems()
        let ids=mode == .new && draft.cloudID==nil ? owner.preferences.value.accounts.map{$0.id} : [draft.accountID]
        for id in ids {
            let addresses=owner.contexts[id]?.addresses ?? (id==draft.accountID && !draft.from.isEmpty ? [draft.from] : [])
            for address in addresses {fromOptions.append((id,address));from.addItem(withTitle:address)}
        }
        if let i=fromOptions.firstIndex(where:{$0.0==draft.accountID && $0.1==draft.from}) {from.selectItem(at:i)}
        else if let i=fromOptions.firstIndex(where:{$0.0==draft.accountID}) {from.selectItem(at:i);draft.from=fromOptions[i].1}
        from.isEnabled = !fromOptions.isEmpty && !sending && !syncing
        if fromOptions.isEmpty {from.addItem(withTitle:owner.accountName(draft.accountID))}
    }
    @objc func fromChanged() {
        guard fromOptions.indices.contains(from.indexOfSelectedItem) else{return}
        let value=fromOptions[from.indexOfSelectedItem];draft.accountID=value.0;draft.from=value.1;changed();loadSignatures()
    }
    func textDidChange(_ notification:Notification) {changed()}
    func controlTextDidChange(_ notification:Notification) {changed()}
    @objc func optionChanged() {changed()}
    func changed() {
        guard !sending,!syncing else{return};dirty=true
        autosave?.invalidate();autosave=Timer.scheduledTimer(withTimeInterval:0.6,repeats:false){[weak self] _ in Task { @MainActor in _=self?.persistDraft() }}
    }
    func snapshot() {
        draft.to=to.stringValue;draft.cc=cc.stringValue;draft.bcc=bcc.stringValue;draft.subject=subject.stringValue;draft.body=text.string
        draft.rtf=try? text.attributedString().data(from:NSRange(location:0,length:text.string.utf16.count),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        draft.files=localFiles.map{$0.path};draft.receipt=receipt.state == .on;draft.scheduleType=schedule.indexOfSelectedItem>0 ? schedule.indexOfSelectedItem : nil;draft.updated=Date()
    }
    @discardableResult func persistDraft()->Bool {
        guard let owner else{return false};if draft.state=="sent" {return true};guard dirty || draft.state != "editing" else{return true};snapshot()
        do {try owner.draftStore.save(draft);dirty=false;status.stringValue="草稿已保存在本机";owner.draftShelf?.reload();return true}
        catch {status.stringValue="草稿保存失败，请保留此窗口后重试";return false}
    }
    @objc func saveAction() {dirty=true;_=persistDraft()}
    func updateAttachments() {
        for view in files.arrangedSubviews {files.removeArrangedSubview(view);view.removeFromSuperview()}
        let names=forwarded.map{$0.name}+localFiles.map{$0.lastPathComponent}
        for (index,name) in names.enumerated() {
            let label=NSTextField(labelWithString:name);label.lineBreakMode = .byTruncatingMiddle
            let remove=NSButton(title:"移除",target:self,action:#selector(removeAttachment));remove.tag=index;remove.bezelStyle = .recessed
            let row=NSStackView(views:[label,NSView(),remove]);row.spacing=8;files.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:files.widthAnchor).isActive=true
        };files.isHidden=names.isEmpty
    }
    @objc func removeAttachment(_ button:NSButton) {
        let count=forwarded.count
        if button.tag<count {draft.excludedForwardIDs=(draft.excludedForwardIDs ?? [])+[forwarded[button.tag].id]}
        else if localFiles.indices.contains(button.tag-count) {localFiles.remove(at:button.tag-count)}
        updateAttachments();changed()
    }
    @objc func addAttachments() {
        let panel=NSOpenPanel();panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
        panel.beginSheetModal(for:window){[weak self] response in
            guard response == .OK,let self,let owner=self.owner else{return}
            do {for file in panel.urls {self.localFiles.append(try owner.draftStore.importFile(file,id:self.draft.id))};self.changed();self.updateAttachments();_=self.persistDraft()}
            catch {self.status.stringValue="附件添加失败，单个文件上限为 25 MB";self.updateAttachments();self.changed()}
        }
    }
    func html()->String {
        let attributed=text.attributedString()
        if let data=try? attributed.data(from:NSRange(location:0,length:attributed.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.html]),let html=String(data:data,encoding:.utf8){return html}
        return "<pre>\(MailHTML.escape(text.string))</pre>"
    }
    @objc func formatAction(_ sender:NSButton) {
        guard !sending,!syncing,let storage=text.textStorage else{return}
        let range=text.selectedRange(),old=NSAttributedString(attributedString:storage)
        func attributes(_ existing:[NSAttributedString.Key:Any])->[NSAttributedString.Key:Any] {
            var value=existing
            if sender.tag==2 {value[.underlineStyle]=(existing[.underlineStyle] as? Int ?? 0)==0 ? NSUnderlineStyle.single.rawValue : 0}
            else {
                let font=existing[.font] as? NSFont ?? NSFont.systemFont(ofSize:14),trait:NSFontTraitMask=sender.tag==0 ? .boldFontMask : .italicFontMask
                value[.font]=NSFontManager.shared.traits(of:font).contains(trait) ? NSFontManager.shared.convert(font,toNotHaveTrait:trait) : NSFontManager.shared.convert(font,toHaveTrait:trait)
            };return value
        }
        if range.length==0 {text.typingAttributes=attributes(text.typingAttributes)}
        else {
            text.undoManager?.registerUndo(withTarget:text){view in view.textStorage?.setAttributedString(old);view.didChangeText()}
            storage.beginEditing();old.enumerateAttributes(in:range){value,subrange,_ in storage.setAttributes(attributes(value),range:subrange)};storage.endEditing();text.didChangeText()
        }
        window.makeFirstResponder(text);changed()
    }
    func insertHTML(_ html:String) {
        let safe=MailHTML.document(html,images:false)
        if let value=try? NSAttributedString(data:Data(safe.utf8),options:[.documentType:NSAttributedString.DocumentType.html],documentAttributes:nil) {text.textStorage?.replaceCharacters(in:text.selectedRange(),with:value)}
        else {text.insertText(MailHTML.plainText(html),replacementRange:text.selectedRange())};changed()
    }
    func loadSignatures() {
        guard let owner,!owner.fixture,let account=owner.preferences.value.accounts.first(where:{$0.id==draft.accountID}) else{return}
        let accountID=draft.accountID
        Task { @MainActor [weak self] in
            guard let self else{return}
            do {
                let context=try await owner.mailbox(account),panel=try await owner.sessionPanel(account)
                guard self.draft.accountID==accountID else{return};self.updateFromOptions()
                let values=try await owner.api.signatures(context:context,store:owner.dataStore(account),browser:panel.webView)
                guard self.draft.accountID==accountID else{return};self.signatureOptions=values;self.signatures.removeAllItems();self.signatures.addItem(withTitle:"插入签名")
                for value in values {self.signatures.addItem(withTitle:value.name.isEmpty ? "签名" : value.name)}
                if !self.dirty,self.draft.body.isEmpty,self.draft.rtf==nil,let id=owner.preferences.value.signatures?[accountID],let signature=values.first(where:{$0.id==id}) {self.insertHTML("<br><br>"+signature.html)}
            } catch {self.signatures.toolTip="签名暂时无法读取，请刷新账号后重试"}
        }
    }
    @objc func signatureChanged() {
        let index=signatures.indexOfSelectedItem-1;guard signatureOptions.indices.contains(index),let owner else{return}
        let value=signatureOptions[index];insertHTML(value.html);var saved=owner.preferences.value.signatures ?? [:];saved[draft.accountID]=value.id;owner.preferences.value.signatures=saved;owner.preferences.save()
    }
    @objc func templateAction() {owner?.chooseTemplate(for:self)}
    func setBusy(_ value:Bool) {
        for field in [to,cc,bcc,subject] {field.isEnabled = !value};text.isEditable = !value
        for button in [send,attach,save,cloud,templates,receipt] {button.isEnabled = !value};from.isEnabled = !value;signatures.isEnabled = !value;schedule.isEnabled = !value
        send.isEnabled = !value && draft.state=="editing" && !draft.cloudUncertain
        cloud.isEnabled = !value && !draft.cloudUncertain && draft.state=="editing"
        from.isEnabled = !value && !fromOptions.isEmpty
    }
    @objc func syncAction() {owner?.syncDraft(self)}
    @objc func reconcileAction() {
        guard !sending,!syncing,draft.state != "sent" else{return}
        let alert=NSAlert();alert.messageText="请先核对服务器上的邮件";alert.informativeText="请检查此账户的已发送、发件箱及草稿。只有确认上次请求没有产生邮件或新草稿时，才恢复编辑；否则可能重复发送或保存。"
        alert.addButton(withTitle:"已确认没有产生邮件，继续编辑");alert.addButton(withTitle:"保持当前状态")
        alert.beginSheetModal(for:window){[weak self] response in
            guard response == .alertFirstButtonReturn,let self,let owner=self.owner else{return}
            self.draft.state="editing";self.draft.cloudUncertain=false
            do {try owner.draftStore.save(self.draft);self.setBusy(false);self.reconcile.isHidden=true;self.status.stringValue="可以继续编辑，发送及同步需要再次点击"}
            catch {self.draft.state="uncertain";self.setBusy(false);self.status.stringValue="恢复状态未保存，请重试"}
        }
    }
    @objc func sendAction() {
        guard !sending,!syncing,draft.state=="editing",!draft.cloudUncertain,let owner else{return}
        guard let addresses=MailAddresses.validated(to.stringValue),!addresses.isEmpty,let copies=MailAddresses.validated(cc.stringValue),let blind=MailAddresses.validated(bcc.stringValue) else{status.stringValue="请检查收件人、抄送和密送地址";return}
        if owner.fixture {status.stringValue="测试模式不会发送邮件";return}
        dirty=true;guard persistDraft() else{return};autosave?.invalidate()
        sending=true;setBusy(true);status.stringValue="正在发送…";draft.state="sending"
        do {try owner.draftStore.save(draft)}catch{sending=false;draft.state="editing";setBusy(false);status.stringValue="草稿未能保存，邮件尚未发送";return}
        let value=draft,content=html(),selectedFiles=localFiles,forwarded=forwarded
        Task { @MainActor [weak self] in
            guard let self else{return};var attempted=false
            do {
                guard let account=owner.preferences.value.accounts.first(where:{$0.id==value.accountID}) else{throw MailFailure.auth}
                let context=try await owner.mailbox(account),panel=try await owner.sessionPanel(account)
                guard context.addresses.contains(value.from),let reference=context.messageReference() else{throw MailFailure.auth}
                var uploads:[[String:String]]=[]
                for file in forwarded {guard let original=value.source?.message else{throw MailFailure.response};let data=try await owner.attachmentData(file,message:original);uploads.append(try await owner.api.upload(data,name:file.name,message:reference,store:owner.dataStore(account),browser:panel.webView))}
                for file in selectedFiles {let data=try Data(contentsOf:file);uploads.append(try await owner.api.upload(data,name:file.lastPathComponent,message:reference,store:owner.dataStore(account),browser:panel.webView))}
                var payload:[String:Any]=["fromAddress":value.from,"toAddress":addresses.joined(separator:","),"ccAddress":copies.joined(separator:","),"bccAddress":blind.joined(separator:","),"subject":Trust.text(value.subject,limit:1000),"content":content,"mailFormat":"html","encoding":"UTF-8","askReceipt":value.receipt ? "yes" : "no"]
                let replying=[ComposeMode.reply.rawValue,ComposeMode.replyAll.rawValue].contains(value.mode)
                if replying {payload["action"]="reply"}
                if value.mode==ComposeMode.edit.rawValue,let source=value.source {
                    let headers=try await owner.api.headers(source.message,store:owner.dataStore(account),browser:panel.webView)
                    for (key,field) in [("in-reply-to","inReplyTo"),("references","refHeader")] {
                        if let header=headers[key],!header.contains("\r"),!header.contains("\n"),!header.isEmpty {payload[field]=header}
                    }
                }
                if let schedule=value.scheduleType {payload["isSchedule"]=true;payload["scheduleType"]=schedule}
                if !uploads.isEmpty {payload["attachments"]=uploads}
                attempted=true
                try await owner.api.send(message:replying ? (value.source?.message ?? reference) : reference,store:owner.dataStore(account),browser:panel.webView,body:payload,reply:replying)
                self.draft.state="sent";try? owner.draftStore.save(self.draft)
                var cleanupFailed=false
                for id in Set((value.obsoleteCloudIDs ?? [])+(value.cloudID.map{[$0]} ?? [])) {
                    do {try await owner.api.removeDraftCopy(id,context:context,store:owner.dataStore(account),browser:panel.webView)}catch{cleanupFailed=true}
                }
                if !cleanupFailed {try? owner.draftStore.remove(value.id)}
                self.dirty=false;self.sending=false;owner.status.stringValue=cleanupFailed ? "邮件已发送，旧草稿清理未完成，请核对草稿文件夹" : (value.scheduleType==nil ? "邮件已发送" : "邮件已安排稍后发送");self.window.close();owner.draftShelf?.reload();owner.refreshScope()
            } catch {
                let rejected=(error as? MailFailure).map{[MailFailure.auth,.rate,.rejected].contains($0)} ?? false
                let uncertain=attempted && !rejected
                self.sending=false;self.draft.state=uncertain ? "uncertain" : "editing";try? owner.draftStore.save(self.draft);self.setBusy(false)
                self.status.stringValue=uncertain ? "发送结果未确认，请先核对已发送邮件；草稿已保留" : "邮件尚未发送，请检查账号登录及附件后重试"
                self.reconcile.isHidden = !uncertain
            }
        }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {if sending || syncing {return false};autosave?.invalidate();return persistDraft()}
    func windowWillClose(_ notification:Notification) {autosave?.invalidate();owner?.composers.removeAll{$0===self};owner?.draftShelf?.reload()}
}
