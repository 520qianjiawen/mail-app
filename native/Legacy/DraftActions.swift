import AppKit

@MainActor extension MailWindow {
    func editServerDraft(_ detail:MailDetail) {
        guard contexts[detail.message.accountID]?.folders.first(where:{$0.id==detail.message.folderID})?.systemName=="Drafts" else{return}
        if let existing=composers.first(where:{$0.draft.cloudID==detail.message.id && $0.draft.accountID==detail.message.accountID}) {existing.window.makeKeyAndOrderFront(nil);return}
        if let local=draftStore.all(accounts:[detail.message.accountID]).first(where:{$0.cloudID==detail.message.id}) {resumeDraft(local);return}
        var draft=MailDraft(accountID:detail.message.accountID,from:contexts[detail.message.accountID]?.email ?? accountName(detail.message.accountID),mode:ComposeMode.edit.rawValue,source:detail)
        if let sender=MailAddresses.extract(detail.from).first,contexts[detail.message.accountID]?.addresses.contains(sender)==true {draft.from=sender}
        draft.to=MailAddresses.extract(detail.to).joined(separator:", ");draft.cc=MailAddresses.extract(detail.cc).joined(separator:", ");draft.bcc=MailAddresses.extract(detail.bcc ?? "").joined(separator:", ");draft.subject=detail.message.subject;draft.cloudID=detail.message.id
        let composer=MailCompose(owner:self,draft:draft);composers.append(composer);composer.insertHTML(detail.html);_=composer.persistDraft()
    }
    func chooseTemplate(for composer:MailCompose) {
        guard !composer.sending,!composer.syncing,let account=preferences.value.accounts.first(where:{$0.id==composer.draft.accountID}) else{return}
        composer.status.stringValue="正在读取模板…"
        Task { @MainActor [weak self,weak composer] in
            guard let self,let composer else{return}
            do {
                let context=try await self.mailbox(account),panel=try await self.sessionPanel(account)
                guard let folder=context.folders.first(where:{$0.systemName=="Templates"}) else{throw MailFailure.folder}
                var rows:[MailMessage]=[],start=1
                while true {
                    let page=try await self.api.messages(context:context,folder:folder,store:self.dataStore(account),browser:panel.webView,start:start)
                    rows+=page.messages;if !page.more {break};start=page.next
                    if start>2000 {throw MailFailure.response}
                }
                guard !composer.sending,!composer.syncing,composer.draft.accountID==account.id else{return}
                if rows.isEmpty {composer.status.stringValue="此账号暂无模板";return}
                let picker=NSPopUpButton();rows.forEach{picker.addItem(withTitle:$0.subject)};picker.frame=NSRect(x:0,y:0,width:400,height:30)
                let alert=NSAlert();alert.messageText="插入模板";alert.accessoryView=picker;alert.addButton(withTitle:"插入");alert.addButton(withTitle:"取消")
                alert.beginSheetModal(for:composer.window){[weak composer] response in
                    guard let composer,response == .alertFirstButtonReturn,rows.indices.contains(picker.indexOfSelectedItem) else{return};let message=rows[picker.indexOfSelectedItem]
                    Task { @MainActor in
                        do {let detail=try await self.api.detail(message,store:self.dataStore(account),browser:panel.webView);guard !composer.sending,!composer.syncing,composer.draft.accountID==account.id else{return};composer.insertHTML(detail.html);if composer.subject.stringValue.isEmpty {composer.subject.stringValue=message.subject};composer.changed()}
                        catch {composer.status.stringValue="模板未能读取，请重试"}
                    }
                }
            } catch {composer.status.stringValue="模板未能读取，请检查账号登录后重试"}
        }
    }
    func syncDraft(_ composer:MailCompose) {
        guard !composer.sending,!composer.syncing,!composer.draft.cloudUncertain,composer.draft.state=="editing" else{return}
        composer.dirty=true;guard composer.persistDraft() else{return}
        if fixture {composer.status.stringValue="测试模式仅保存本机草稿";return}
        composer.syncing=true;composer.setBusy(true);composer.status.stringValue="正在同步草稿…"
        let value=composer.draft,html=composer.html(),localFiles=composer.localFiles,forwarded=composer.forwarded
        Task { @MainActor [weak self,weak composer] in
            guard let self,let composer else{return};var attempted=false
            do {
                guard let account=self.preferences.value.accounts.first(where:{$0.id==value.accountID}) else{throw MailFailure.auth}
                let context=try await self.mailbox(account),panel=try await self.sessionPanel(account)
                guard context.addresses.contains(value.from),let reference=context.messageReference(),context.folders.contains(where:{$0.systemName=="Drafts"}) else{throw MailFailure.auth}
                var body:[String:Any]=["mode":"draft","fromAddress":value.from,"toAddress":value.to,"ccAddress":value.cc,"bccAddress":value.bcc,"subject":value.subject,"content":html,"mailFormat":"html","encoding":"UTF-8","askReceipt":value.receipt ? "yes" : "no"]
                if let source=value.source,[ComposeMode.reply.rawValue,ComposeMode.replyAll.rawValue,ComposeMode.edit.rawValue].contains(value.mode) {
                    let fields=try await self.api.headers(source.message,store:self.dataStore(account),browser:panel.webView)
                    let reply=value.mode==ComposeMode.edit.rawValue ? fields["in-reply-to"] : fields["message-id"]
                    if let reply,!reply.isEmpty,!reply.contains("\r"),!reply.contains("\n") {body["inReplyTo"]=reply}
                    else if value.mode != ComposeMode.edit.rawValue {throw MailFailure.response}
                    if let refs=fields["references"],!refs.isEmpty {body["refHeader"]=refs+(value.mode==ComposeMode.edit.rawValue ? "" : " "+(reply ?? ""))}
                }
                var uploads:[[String:String]]=[]
                for file in forwarded {guard let message=value.source?.message else{throw MailFailure.response};let data=try await self.attachmentData(file,message:message);uploads.append(try await self.api.upload(data,name:file.name,message:reference,store:self.dataStore(account),browser:panel.webView))}
                for file in localFiles {uploads.append(try await self.api.upload(Data(contentsOf:file),name:file.lastPathComponent,message:reference,store:self.dataStore(account),browser:panel.webView))}
                if !uploads.isEmpty {body["attachments"]=uploads}
                composer.draft.cloudUncertain=true
                try self.draftStore.save(composer.draft)
                attempted=true
                let id=try await self.api.saveDraft(body,context:context,store:self.dataStore(account),browser:panel.webView)
                let old=(value.obsoleteCloudIDs ?? [])+(value.cloudID.map{[$0]} ?? [])
                composer.draft.cloudID=id;composer.draft.obsoleteCloudIDs=Array(Set(old.filter{$0 != id}));composer.draft.cloudUncertain=false
                try self.draftStore.save(composer.draft) // Confirm durable ownership of the new copy before deleting any prior version.
                var obsolete:[String]=[]
                for previous in composer.draft.obsoleteCloudIDs ?? [] {
                    do {try await self.api.removeDraftCopy(previous,context:context,store:self.dataStore(account),browser:panel.webView)}catch{obsolete.append(previous)}
                }
                composer.draft.obsoleteCloudIDs=obsolete;try self.draftStore.save(composer.draft)
                composer.syncing=false;composer.setBusy(false);composer.updateFromOptions();composer.status.stringValue=obsolete.isEmpty ? "草稿已同步到 \(context.email)" : "新草稿已同步，旧副本清理未完成，请核对草稿文件夹"
                self.draftShelf?.reload();self.refreshScope()
            } catch {
                let rejected=(error as? MailFailure).map{[MailFailure.auth,.rate,.rejected].contains($0)} ?? false
                composer.draft.cloudUncertain=attempted && !rejected;try? self.draftStore.save(composer.draft)
                composer.syncing=false;composer.setBusy(false);composer.cloud.isEnabled = !composer.draft.cloudUncertain
                composer.status.stringValue=composer.draft.cloudUncertain ? "云端结果未确认，请先核对草稿；本机内容已保留" : "云端未保存，请检查地址及登录；本机草稿已保留"
                composer.reconcile.isHidden = !composer.draft.cloudUncertain
            }
        }
    }
}
