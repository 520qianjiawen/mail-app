import AppKit

@MainActor final class DraftShelf:NSObject,NSWindowDelegate {
    weak var owner:MailWindow?
    let window:NSWindow,rows=NSStackView()
    var drafts:[MailDraft]=[]
    init(owner:MailWindow) {
        self.owner=owner;window=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:460),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init();window.title="待完成草稿";window.isReleasedWhenClosed=false;window.delegate=self
        let scroll=NSScrollView(),document=MailDocumentView();scroll.hasVerticalScroller=true;scroll.documentView=document;window.contentView=scroll
        rows.orientation = .vertical;rows.alignment = .leading;rows.spacing=12;document.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints=false;document.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),rows.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:20),rows.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-20),rows.topAnchor.constraint(equalTo:document.topAnchor,constant:20),rows.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-20)])
        reload();window.center();window.makeKeyAndOrderFront(nil)
    }
    func reload() {
        for view in rows.arrangedSubviews {rows.removeArrangedSubview(view);view.removeFromSuperview()}
        guard let owner else{return};drafts=owner.draftStore.all(accounts:Set(owner.preferences.value.accounts.map{$0.id}))
        if drafts.isEmpty {rows.addArrangedSubview(NSTextField(labelWithString:"没有待完成草稿"));return}
        for (index,draft) in drafts.enumerated() {
            let title=NSTextField(labelWithString:draft.subject.isEmpty ? "（无主题）" : Trust.text(draft.subject,limit:180));title.font = .systemFont(ofSize:14,weight:.medium);title.lineBreakMode = .byTruncatingTail
            let date=DateFormatter();date.dateStyle = .short;date.timeStyle = .short
            let detail=NSTextField(labelWithString:"\(owner.accountName(draft.accountID)) · \(date.string(from:draft.updated))\(draft.state == "sent" ? " · 已发送，草稿清理待核对" : draft.state == "editing" ? "" : " · 发送结果待核对")");detail.font = .systemFont(ofSize:11);detail.textColor = .secondaryLabelColor
            let labels=NSStackView(views:[title,detail]);labels.orientation = .vertical;labels.alignment = .leading
            let edit=NSButton(title:"继续编辑",target:self,action:#selector(editDraft));edit.tag=index;edit.bezelStyle = .rounded
            let remove=NSButton(title:"丢弃",target:self,action:#selector(removeDraft));remove.tag=index;remove.bezelStyle = .recessed
            let row=NSStackView(views:[labels,NSView(),edit,remove]);row.spacing=12;rows.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:rows.widthAnchor).isActive=true
        }
    }
    @objc func editDraft(_ sender:NSButton) {guard drafts.indices.contains(sender.tag) else{return};owner?.resumeDraft(drafts[sender.tag])}
    @objc func removeDraft(_ sender:NSButton) {
        guard drafts.indices.contains(sender.tag),let owner else{return};let draft=drafts[sender.tag]
        if let composer=owner.composers.first(where:{$0.draft.id==draft.id}) {composer.window.makeKeyAndOrderFront(nil);composer.status.stringValue="请先关闭编辑窗口，再丢弃本机草稿";return}
        let alert=NSAlert();alert.messageText="丢弃这封本机草稿？";alert.informativeText=draft.subject+"\n本机副本移到废纸篓，云端草稿保留。";alert.addButton(withTitle:"丢弃");alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for:window){[weak self] response in guard response == .alertFirstButtonReturn else{return};do{try FileManager.default.trashItem(at:owner.draftStore.folder(draft.id),resultingItemURL:nil);self?.reload()}catch{owner.status.stringValue="草稿未能移除，请重试"}}
    }
    func windowWillClose(_ notification:Notification) {owner?.draftShelf=nil}
}
