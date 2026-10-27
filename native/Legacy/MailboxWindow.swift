import AppKit
import WebKit

@MainActor extension MailWindow {
    var currentFolderTitle:String {
        if !submittedQuery.isEmpty{return "搜索结果"}
        guard let account=selectedAccountID else{return "所有收件箱"}
        return contexts[account]?.folders.first{$0.id==selectedFolderID}?.title ?? "收件箱"
    }
    var currentPages:[InboxPage] {
        if !submittedQuery.isEmpty{return Array(searchPages.values)}
        if filter.selectedSegment>0 {return filteredPages.filter{selectedAccountID==nil || $0.key==selectedAccountID || $0.key=="\(selectedAccountID!):\(selectedFolderID ?? "")"}.map{$0.value}}
        if let account=selectedAccountID,let folder=selectedFolderID,folder != contexts[account]?.inbox?.id {return folderPages["\(account):\(folder)"].map{[$0]} ?? []}
        return pages.filter{selectedAccountID == nil || $0.key==selectedAccountID}.map{$0.value}
    }
    func folderName(_ message:MailMessage)->String {contexts[message.accountID]?.folders.first{$0.id==message.folderID}?.title ?? "邮件"}
    func buildFolders() {
        for view in foldersStack.arrangedSubviews {foldersStack.removeArrangedSubview(view);view.removeFromSuperview()}
        guard let id=selectedAccountID ?? preferences.value.accounts.first?.id,let context=contexts[id] else{return}
        folderButtons=context.folders.sorted {a,b in
            let order=["Inbox","Drafts","Templates","Snoozed","Sent","Spam","Trash","Outbox"]
            let ia=order.firstIndex(of:a.systemName ?? "") ?? 100,ib=order.firstIndex(of:b.systemName ?? "") ?? 100
            return ia==ib ? a.path.localizedStandardCompare(b.path) == .orderedAscending : ia<ib
        }
        for (index,folder) in folderButtons.enumerated() {
            let button=NSButton(title:folder.title,target:self,action:#selector(folderClicked));button.tag=index;button.bezelStyle = .recessed;button.alignment = .left;button.font = .systemFont(ofSize:12);button.lineBreakMode = .byTruncatingMiddle
            button.image=NSImage(systemSymbolName:folder.systemName=="Drafts" ? "doc" : "folder",accessibilityDescription:nil)
            button.imagePosition = .imageLeading
            button.toolTip="\(context.email) · \(folder.path)";button.widthAnchor.constraint(lessThanOrEqualToConstant:174).isActive=true;foldersStack.addArrangedSubview(button)
        }
    }
    @objc func folderClicked(_ sender:NSButton) {
        guard folderButtons.indices.contains(sender.tag),let id=selectedAccountID ?? preferences.value.accounts.first?.id else{return}
        selectedAccountID=id;selectedFolderID=folderButtons[sender.tag].id;lastListOrigin = .zero;resetSearch();backToList();refreshScope()
    }
    func resetSearch() {searchTask?.cancel();submittedQuery="";search.stringValue="";searchResults=[:];searchPages=[:];viewGeneration+=1}
    @objc func submitSearch() {
        let query=search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        if query.isEmpty {resetSearch();backToList();refreshScope();return}
        submittedQuery=query;visibleLimit=100;searchResults=[:];searchPages=[:];viewGeneration+=1;backToList();runSearch()
    }
    func runSearch(more:Bool = false) {
        searchTask?.cancel();let query=submittedQuery,viewID=viewGeneration,accountID=selectedAccountID
        guard !query.isEmpty else{return}
        if !more {searchResults=[:];searchPages=[:]}
        if more {visibleLimit+=100}
        status.stringValue="正在搜索\(accountID == nil ? "所有账户" : "当前账户")…"
        searchTask=Task { @MainActor [weak self] in
            guard let self else{return};var failed=0
            for account in self.preferences.value.accounts where accountID==nil || account.id==accountID {
                if Task.isCancelled || self.viewGeneration != viewID{return}
                if more,self.searchPages[account.id]?.more==false {continue}
                do {
                    if self.fixture {
                        self.searchResults=self.allMessages.filter{_,m in (accountID==nil || m.accountID==accountID) && [m.subject,m.sender,m.preview].joined(separator:" ").localizedCaseInsensitiveContains(query)}
                    } else {
                        let panel=try await self.sessionPanel(account)
                        let context=try await self.mailbox(account)
                        let page=try await self.api.search(context:context,query:query,store:self.dataStore(account),browser:panel.webView,start:more ? (self.searchPages[account.id]?.next ?? 1) : 1)
                        try Task.checkCancellation();guard self.viewGeneration==viewID else{return}
                        self.searchPages[account.id]=page
                        for message in page.messages {self.searchResults[message.key]=message}
                    }
                } catch {if Task.isCancelled{return};failed+=1}
            }
            guard self.viewGeneration==viewID else{return};self.renderList()
            self.status.stringValue="搜索结果 · \(self.visible.count) 封邮件"+(failed>0 ? " · \(failed) 个账户未完成，请刷新重试" : "")
        }
    }
    func mailbox(_ account:MailAccount) async throws -> MailboxSession {
        if let context=contexts[account.id] {return context}
        let panel=try await sessionPanel(account)
        let context=try await api.discover(account:account,store:dataStore(account),origin:Region.find(account.region)!.origin,browser:panel.webView)
        contexts[account.id]=context;cache.store(context);return context
    }
    func refreshScope(more:Bool = false) {
        if !submittedQuery.isEmpty {runSearch(more:more);return}
        if refreshing {
            let pending=refreshTask;pending?.cancel();generation+=1;let current=generation
            status.stringValue="正在刷新邮件…"
            refreshTask=Task { @MainActor [weak self] in
                await pending?.value
                guard let self,self.generation==current,!Task.isCancelled else{return}
                self.refreshing=false;self.refreshScope(more:more)
            };return
        }
        guard let id=selectedAccountID,let folderID=selectedFolderID,folderID != contexts[id]?.inbox?.id,let account=preferences.value.accounts.first(where:{$0.id==id}),let context=contexts[id],let folder=context.folders.first(where:{$0.id==folderID}) else{refreshAll(more:more);return}
        generation+=1;let current=generation
        if more {visibleLimit+=100}else{visibleLimit=100}
        refreshing=true;status.stringValue="正在读取\(folder.title)…"
        refreshTask=Task { @MainActor [weak self] in
            guard let self else{return}
            do {
                let page:InboxPage
                let key="\(id):\(folder.id)"
                if self.fixture {
                    let rows=(0..<8).compactMap{i in MailMessage.parse(["messageId":"\(800000+i)","folderId":folder.id,"subject":"\(folder.title)测试邮件 \(i+1)","sender":"测试联系人","receivedTime":"\(Int(Date().timeIntervalSince1970*1000)-i*60000)","status":"1"],accountID:id,remoteID:context.remoteID,folderID:folder.id,origin:context.origin)}
                    page = .init(messages:rows,remoteID:context.remoteID,folderID:folder.id,next:9,more:false,email:context.email,mailbox:context)
                } else {
                    let panel=try await self.sessionPanel(account)
                    page=try await self.api.messages(context:context,folder:folder,store:self.dataStore(account),browser:panel.webView,start:more ? ((self.filter.selectedSegment>0 ? self.filteredPages[key] : self.folderPages[key])?.next ?? 1) : 1,filter:self.filter.selectedSegment)
                }
                try Task.checkCancellation();guard self.generation==current else{return}
                if !more,self.filter.selectedSegment==0 {self.allMessages=self.allMessages.filter{!($0.value.accountID==id && $0.value.folderID==folder.id)}}
                if self.filter.selectedSegment>0 {
                    if !more {self.filteredMessages=self.filteredMessages.filter{!($0.value.accountID==id && $0.value.folderID==folder.id)}}
                    for message in page.messages {self.filteredMessages[message.key]=message};self.filteredPages[key]=page
                } else {
                    for message in page.messages {self.allMessages[message.key]=message};self.folderPages[key]=page
                    if !self.fixture {self.cache.store(page.messages,account:id,replace:!more,folderID:folder.id)}
                }
                self.refreshing=false;self.renderList();self.status.stringValue="\(context.email) · \(folder.title) · \(self.visible.count) 封邮件"
            } catch {if Task.isCancelled{return};guard self.generation==current else{return};self.refreshing=false;self.renderList();self.status.stringValue=(error as? MailFailure)?.label ?? "文件夹读取失败，请刷新重试"}
        }
    }
    func setupOperations() {
        operation.bezelStyle = .texturedRounded;operation.addItem(withTitle:"邮件操作")
        let items:[(String,Int)]=[("标记为已读",1),("标记为未读",2),("归档",3),("取消归档",4),("移到回收站",5),("移动到文件夹…",6),("标记重要",7),("标记跟进",8),("标记信息",9),("清除标记",10),("标记为垃圾邮件",11),("不是垃圾邮件",12),("打印邮件…",13)]
        for (title,tag) in items {operation.addItem(withTitle:title);let item=operation.lastItem!;item.tag=tag;item.target=self;item.action=#selector(operationClicked)}
        operation.menu?.autoenablesItems=false;operation.isEnabled=false
    }
    var selectedMessages:[MailMessage] {
        if let message=activeReader?.message {return [allMessages[message.key] ?? searchResults[message.key] ?? message]}
        if activeConversation != nil {return activeMessage.map{[$0]} ?? []}
        let indexes=table.selectedRowIndexes
        return indexes.compactMap{visible.indices.contains($0) ? visible[$0] : nil}
    }
    func updateOperationState() {
        operation.isEnabled = !selectedMessages.isEmpty && !actionBusy && activePanel==nil
        select.isHidden=activeReader != nil || activeConversation != nil || activePanel != nil
        select.title=selectionMode ? "完成选择" : "选择"
        if selectionMode {source.stringValue="已选择 \(table.selectedRowIndexes.count) 封"}
    }
    func tableViewSelectionDidChange(_ notification:Notification) {updateOperationState()}
    @objc func toggleSelection() {selectionMode.toggle();if !selectionMode {table.deselectAll(nil)};updateOperationState()}
    @objc func operationClicked(_ item:NSMenuItem) {
        let messages=selectedMessages;guard !messages.isEmpty,!actionBusy else{return}
        if item.tag==13 {if let reader=activeReader {reader.body.printOperation(with:NSPrintInfo.shared).run()};return}
        if item.tag==6 {chooseMove(messages);return}
        let action:MailAction
        switch item.tag {case 1:action = .read;case 2:action = .unread;case 3:action = .archive;case 4:action = .unarchive;case 5:action = .trash;case 7:action = .flag("important");case 8:action = .flag("followup");case 9:action = .flag("info");case 10:action = .flag("flag_not_set");case 11:action = .spam;case 12:action = .notSpam;default:return}
        apply(action,messages:messages)
    }
    func chooseMove(_ messages:[MailMessage]) {
        guard let first=messages.first,Set(messages.map{$0.accountID}).count==1,let context=contexts[first.accountID] else{status.stringValue="请选取同一账户的邮件后移动";return}
        let folders=context.folders.filter{$0.systemName != "Outbox" && $0.systemName != "Templates" && $0.systemName != "Drafts"}
        let picker=NSPopUpButton();folders.forEach{picker.addItem(withTitle:$0.title)};picker.frame=NSRect(x:0,y:0,width:320,height:28)
        let alert=NSAlert();alert.messageText="移动 \(messages.count) 封邮件";alert.informativeText=context.email;alert.accessoryView=picker;alert.addButton(withTitle:"移动");alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for:window){[weak self] response in guard response == .alertFirstButtonReturn,folders.indices.contains(picker.indexOfSelectedItem) else{return};self?.apply(.move(folders[picker.indexOfSelectedItem].id),messages:messages)}
    }
    func apply(_ action:MailAction,messages:[MailMessage],automatic:Bool = false) {
        guard !messages.isEmpty,!actionBusy else{return}
        actionBusy=true;updateOperationState();if !automatic {status.stringValue="正在处理 \(messages.count) 封邮件…"}
        let groups=Dictionary(grouping:messages,by:{$0.accountID})
        Task { @MainActor [weak self] in
            guard let self else{return};var succeeded=0,failed=0
            for (id,batch) in groups {
                do {
                    if !self.fixture {
                        guard let account=self.preferences.value.accounts.first(where:{$0.id==id}) else{throw MailFailure.auth}
                        let context=try await self.mailbox(account),panel=try await self.sessionPanel(account)
                        try await self.api.perform(action,messages:batch,context:context,store:self.dataStore(account),browser:panel.webView)
                    }
                    for var message in batch {
                        if action == .read || action == .unread {message.unread=action == .unread}
                        if case .flag(let flag)=action {message.flag=flag}
                        let removes:Bool
                        switch action {case .read,.unread,.flag:removes=false;default:removes=true}
                        if removes {self.allMessages.removeValue(forKey:message.key);self.filteredMessages.removeValue(forKey:message.key);self.searchResults.removeValue(forKey:message.key);self.cache.removeMessage(message.key)}
                        else {self.allMessages[message.key]=message;if self.filteredMessages[message.key] != nil{self.filteredMessages[message.key]=message};if self.searchResults[message.key] != nil{self.searchResults[message.key]=message};if !self.fixture{self.cache.store([message],account:id,replace:false)}}
                        succeeded+=1
                    }
                } catch {failed+=batch.count}
            }
            self.actionBusy=false
            if !automatic,failed==0 {
                switch action {case .read,.unread,.flag:break;default:self.backToList()}
            }
            self.renderList();self.updateOperationState()
            if !automatic {self.status.stringValue=failed==0 ? "已处理 \(succeeded) 封邮件" : "已处理 \(succeeded) 封，\(failed) 封结果未确认，请先刷新核对"}
        }
    }
    func markOpenedRead(_ message:MailMessage) {
        if (allMessages[message.key] ?? searchResults[message.key] ?? message).unread {apply(.read,messages:[message],automatic:true)}
    }
    @objc func newMessage() {
        guard let account=preferences.value.accounts.first(where:{$0.id==selectedAccountID}) ?? preferences.value.accounts.first else{addAccount();return}
        composers.append(MailCompose(owner:self,account:account))
    }
    @objc func showDrafts() {
        if let shelf=draftShelf {shelf.reload();shelf.window.makeKeyAndOrderFront(nil)}else{draftShelf=DraftShelf(owner:self)}
    }
    func resumeDraft(_ draft:MailDraft) {
        if let existing=composers.first(where:{$0.draft.id==draft.id}) {existing.window.makeKeyAndOrderFront(nil);return}
        composers.append(MailCompose(owner:self,draft:draft))
    }
}
