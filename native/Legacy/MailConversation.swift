import AppKit

@MainActor final class MailConversation:NSObject {
    weak var owner:MailWindow?
    let message:MailMessage,view=NSView(),stack=NSStackView(),scroll=NSScrollView(),more=NSButton(title:"加载更多会话邮件",target:nil,action:nil),hint=NSTextField(labelWithString:"")
    let initialReader:MailReader
    var messages:[MailMessage],readers:[String:MailReader]=[:],expandedKey:String?,page:InboxPage?,task:Task<Void,Never>?
    init(owner:MailWindow,message:MailMessage) {
        self.owner=owner;self.message=message;messages=[message];initialReader=MailReader(owner:owner,message:message);readers[message.key]=initialReader;expandedKey=message.key
        super.init();let document=MailDocumentView();scroll.documentView=document;scroll.hasVerticalScroller=true;scroll.drawsBackground=false;view.addSubview(scroll)
        stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=4;document.addSubview(stack)
        for v in [scroll,document,stack] {v.translatesAutoresizingMaskIntoConstraints=false}
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),scroll.topAnchor.constraint(equalTo:view.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),stack.leadingAnchor.constraint(equalTo:document.leadingAnchor),stack.trailingAnchor.constraint(equalTo:document.trailingAnchor),stack.topAnchor.constraint(equalTo:document.topAnchor),stack.bottomAnchor.constraint(equalTo:document.bottomAnchor)])
        more.target=self;more.action=#selector(loadMore);more.bezelStyle = .rounded;hint.font = .systemFont(ofSize:11);hint.textColor = .secondaryLabelColor
        render()
    }
    deinit {task?.cancel()}
    func render() {
        for child in stack.arrangedSubviews {stack.removeArrangedSubview(child);child.removeFromSuperview()}
        for (index,message) in messages.enumerated() {
            let date=DateFormatter();date.dateStyle = .medium;date.timeStyle = .short
            let header=NSButton(title:"\(expandedKey==message.key ? "⌄" : "›")  \(message.sender) · \(date.string(from:message.date))",target:self,action:#selector(toggle));header.tag=index;header.bezelStyle = .recessed;header.alignment = .left;header.font = .systemFont(ofSize:13,weight:.medium);header.setAccessibilityLabel("展开或收起邮件 \(index+1)")
            stack.addArrangedSubview(header);header.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true;header.heightAnchor.constraint(equalToConstant:42).isActive=true
            if expandedKey==message.key,let reader=readers[message.key] {stack.addArrangedSubview(reader.view);reader.view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true;if reader.view.constraints.first(where:{$0.identifier=="reader-height"})==nil {let height=reader.view.heightAnchor.constraint(equalToConstant:700);height.identifier="reader-height";height.isActive=true}}
        }
        if page?.more==true {stack.addArrangedSubview(more)}
        if !hint.stringValue.isEmpty {stack.addArrangedSubview(hint)}
    }
    @objc func toggle(_ sender:NSButton) {
        guard messages.indices.contains(sender.tag),let owner else{return};let message=messages[sender.tag]
        if expandedKey==message.key {expandedKey=nil;owner.detailTask?.cancel();owner.activeReader=nil;owner.activeMessage=message;render();owner.updateOperationState();return}
        expandedKey=message.key;let reader=readers[message.key] ?? MailReader(owner:owner,message:message);readers[message.key]=reader;owner.activeReader=reader;owner.activeMessage=message;render();view.layoutSubtreeIfNeeded()
        if let header=stack.arrangedSubviews.compactMap({$0 as? NSButton}).first(where:{$0.tag==sender.tag && $0 !== more}) {scroll.contentView.scroll(to:NSPoint(x:0,y:header.frame.minY));scroll.reflectScrolledClipView(scroll.contentView)}
        owner.loadDetail(reader);owner.updateOperationState()
    }
    @objc func loadMore() {loadThread(more:true)}
    func loadThread(more:Bool = false) {
        guard let owner,let thread=message.threadID,thread != "0",!owner.fixture else{return}
        task?.cancel();hint.stringValue="正在读取会话…"
        task=Task { @MainActor [weak self] in
            guard let self else{return}
            do {
                guard let account=owner.preferences.value.accounts.first(where:{$0.id==self.message.accountID}) else{throw MailFailure.auth}
                let context=try await owner.mailbox(account),panel=try await owner.sessionPanel(account)
                let page=try await owner.api.thread(self.message,context:context,store:owner.dataStore(account),browser:panel.webView,start:more ? (self.page?.next ?? 1) : 1)
                try Task.checkCancellation();guard owner.activeConversation===self else{return}
                var values=Dictionary(self.messages.map{($0.key,$0)},uniquingKeysWith:{$1})
                for item in page.messages {values[item.key]=item}
                self.messages=values.values.sorted{$0.date>$1.date};self.page=page;self.hint.stringValue="";self.render()
            } catch {if Task.isCancelled{return};self.hint.stringValue="会话未能全部读取，请刷新重试";self.render()}
        }
    }
}
