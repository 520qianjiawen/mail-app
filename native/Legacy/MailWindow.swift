import AppKit
import WebKit

final class MailDocumentView:NSView {override var isFlipped:Bool {true}}

@MainActor final class MailWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let preferences: PreferenceFile, api = MailAPI()
    let cache:MailCache, draftStore:DraftStore
    let window: NSWindow, fixture: Bool
    let table = NSTableView(), search = NSSearchField(), filter = NSSegmentedControl(labels: ["全部", "未读", "包含附件", "标记", "含归档"], trackingMode: .selectOne, target: nil, action: nil)
    let status = NSTextField(labelWithString: ""), heading = NSTextField(labelWithString: "所有收件箱"), source = NSTextField(labelWithString: "")
    let accountsStack = NSStackView(), content = NSView(), list = NSView(), listScroll = NSScrollView()
    let back = NSButton(title: "所有收件箱", target: nil, action: nil), refresh = NSButton(title: "刷新", target: nil, action: nil)
    let more = NSButton(title: "加载更多", target: nil, action: nil)
    var stores: [String: WKWebsiteDataStore] = [:], origins: [String: URL] = [:]
    var pages: [String: InboxPage] = [:], allMessages: [String: MailMessage] = [:], visible: [MailMessage] = []
    var accountErrors: [String: String] = [:], loadingAccounts = Set<String>()
    var panels: [String: MailWebPanel] = [:], activePanel: MailWebPanel?, activeMessage: MailMessage?
    var visibleLimit = 100, refreshing = false, generation = 0, refreshTask: Task<Void, Never>?, timer: Timer?
    var selectedMessageKey: String?, lastListOrigin: NSPoint = .zero
    var busyDownloads = 0, popupPanels: [MailWebPanel] = []
    var authPoll: Timer?, authAccount: String?
    var activeReader:MailReader?, detailTask:Task<Void,Never>?, composers:[MailCompose] = []
    var selectedAccountID:String?
    var selectedFolderID:String?
    var contexts:[String:MailboxSession]=[:],folderPages:[String:InboxPage]=[:],searchPages:[String:InboxPage]=[:]
    var filteredMessages:[String:MailMessage]=[:],filteredPages:[String:InboxPage]=[:]
    var searchResults:[String:MailMessage]=[:],submittedQuery="",searchTask:Task<Void,Never>?,viewGeneration=0
    var actionBusy=false,selectionMode=false
    let foldersStack=NSStackView(),operation=NSPopUpButton(frame:.zero,pullsDown:true),newMail=NSButton(title:"写邮件",target:nil,action:nil),select=NSButton(title:"选择",target:nil,action:nil)
    var folderButtons:[MailFolder]=[],draftShelf:DraftShelf?,activeConversation:MailConversation?
    var previewWindows:[AttachmentPreview]=[]

    init(fixture: Bool = false) {
        self.fixture = fixture
        if fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-native-\(UUID().uuidString)")
            preferences = PreferenceFile(directory: directory)
            preferences.value.accounts = [.init(id: "fixture-first", name: "工作邮箱 · 测试", region: "global"), .init(id: "fixture-second", name: "个人邮箱 · 测试", region: "global")]
        } else { preferences = PreferenceFile() }
        cache = MailCache(directory:preferences.directory)
        draftStore = DraftStore(directory:preferences.directory)
        if !fixture {for item in cache.contexts(accounts:Set(preferences.value.accounts.map{$0.id})) {contexts[item.accountID]=item}}
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:preferences.value.width,height:preferences.value.height), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing:.buffered, defer:false)
        super.init()
        window.title = "Mail Lite"; window.subtitle = "所有收件箱"; window.minSize = NSSize(width:960,height:640)
        window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false; window.delegate = self
        setup(); buildAccounts(); preferences.save()
        if !fixture { for message in cache.messages(accounts:Set(preferences.value.accounts.map{$0.id})) {allMessages[message.key]=message};renderList() }
        timer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in
            Task { @MainActor in if let self, self.activePanel == nil, self.activeConversation == nil, self.window.isVisible, !self.window.isMiniaturized { self.refreshScope() } }
        }
    }
    func show() { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); refreshAll() }
    func setup() {
        let root = NSView(); window.contentView = root
        let sidebar = NSVisualEffectView(); sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow
        root.addSubview(sidebar)
        let title = label("邮件", size:13, weight:.semibold); title.textColor = .secondaryLabelColor
        let all = NSButton(title:"所有收件箱", image:NSImage(systemSymbolName:"tray.full", accessibilityDescription:nil)!, target:self, action:#selector(showInbox))
        all.bezelStyle = .recessed; all.alignment = .left; all.font = .systemFont(ofSize:14, weight:.semibold)
        let accountsTitle = label("账号", size:11, weight:.semibold); accountsTitle.textColor = .secondaryLabelColor
        let add = NSButton(title:"添加账号", image:NSImage(systemSymbolName:"plus", accessibilityDescription:nil)!, target:self, action:#selector(addAccount))
        add.bezelStyle = .recessed; add.alignment = .left
        accountsStack.orientation = .vertical; accountsStack.alignment = .leading; accountsStack.spacing = 10
        let drafts = NSButton(title:"待完成草稿",image:NSImage(systemSymbolName:"square.and.pencil",accessibilityDescription:nil)!,target:self,action:#selector(showDrafts));drafts.bezelStyle = .recessed;drafts.alignment = .left
        foldersStack.orientation = .vertical;foldersStack.alignment = .leading;foldersStack.spacing=3
        let folderTitle=label("文件夹",size:11,weight:.semibold);folderTitle.textColor = .secondaryLabelColor
        let sideStack = NSStackView(views:[title,all,drafts,accountsTitle,accountsStack,add,folderTitle,foldersStack]);sideStack.orientation = .vertical;sideStack.alignment = .leading;sideStack.spacing=14
        let sideScroll=NSScrollView(),sideDocument=MailDocumentView();sideScroll.drawsBackground=false;sideScroll.hasVerticalScroller=true;sideScroll.autohidesScrollers=true;sideScroll.documentView=sideDocument;sidebar.addSubview(sideScroll);sideDocument.addSubview(sideStack)
        sideScroll.translatesAutoresizingMaskIntoConstraints=false;sideDocument.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([sideScroll.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor),sideScroll.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor),sideScroll.topAnchor.constraint(equalTo:root.safeAreaLayoutGuide.topAnchor,constant:8),sideScroll.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor),sideDocument.widthAnchor.constraint(equalTo:sideScroll.contentView.widthAnchor),sideStack.bottomAnchor.constraint(equalTo:sideDocument.bottomAnchor,constant:-20)])
        let bar = NSView(); back.target = self; back.action = #selector(backToList); back.bezelStyle = .texturedRounded
        back.image = NSImage(systemSymbolName:"chevron.left", accessibilityDescription:nil)
        back.imagePosition = .imageLeading
        refresh.target = self; refresh.action = #selector(refreshAction); refresh.bezelStyle = .texturedRounded
        refresh.image = NSImage(systemSymbolName:"arrow.clockwise", accessibilityDescription:nil)
        source.font = .systemFont(ofSize:12); source.textColor = .secondaryLabelColor; source.lineBreakMode = .byTruncatingMiddle
        newMail.target=self;newMail.action=#selector(newMessage);newMail.bezelStyle = .texturedRounded;newMail.image=NSImage(systemSymbolName:"square.and.pencil",accessibilityDescription:nil)
        newMail.imagePosition = .imageLeading
        select.target=self;select.action=#selector(toggleSelection);select.bezelStyle = .texturedRounded
        setupOperations()
        let barStack = NSStackView(views:[back,source,NSView(),newMail,select,operation,refresh]); barStack.orientation = .horizontal; barStack.spacing = 14
        bar.addSubview(barStack)
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        root.addSubview(bar); root.addSubview(content); root.addSubview(status)
        for view in [sidebar,bar,content,status,sideStack,barStack] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo:root.leadingAnchor), sidebar.widthAnchor.constraint(equalToConstant:210), sidebar.topAnchor.constraint(equalTo:root.topAnchor), sidebar.bottomAnchor.constraint(equalTo:root.bottomAnchor),
            sideStack.leadingAnchor.constraint(equalTo:sideDocument.leadingAnchor,constant:18),sideStack.trailingAnchor.constraint(equalTo:sideDocument.trailingAnchor,constant:-16),sideStack.topAnchor.constraint(equalTo:sideDocument.topAnchor,constant:18),
            foldersStack.widthAnchor.constraint(equalTo:sideStack.widthAnchor),accountsStack.widthAnchor.constraint(equalTo:sideStack.widthAnchor),
            bar.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor), bar.trailingAnchor.constraint(equalTo:root.trailingAnchor), bar.topAnchor.constraint(equalTo:root.safeAreaLayoutGuide.topAnchor), bar.heightAnchor.constraint(equalToConstant:46),
            barStack.leadingAnchor.constraint(equalTo:bar.leadingAnchor,constant:22), barStack.trailingAnchor.constraint(equalTo:bar.trailingAnchor,constant:-22), barStack.centerYAnchor.constraint(equalTo:bar.centerYAnchor),
            content.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor), content.trailingAnchor.constraint(equalTo:root.trailingAnchor), content.topAnchor.constraint(equalTo:bar.bottomAnchor), content.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-8),
            status.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:22), status.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20), status.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-10), status.heightAnchor.constraint(equalToConstant:16)
        ])
        content.addSubview(list); pin(list, to:content)
        heading.font = .systemFont(ofSize:27,weight:.bold)
        search.placeholderString = "搜索邮件，按回车查询";search.delegate=self;search.sendsSearchStringImmediately=false;search.sendsWholeSearchString=true;search.target=self;search.action=#selector(submitSearch);search.setAccessibilityLabel("搜索邮件")
        filter.selectedSegment = 0; filter.target = self; filter.action = #selector(filterChanged)
        let tools = NSStackView(views:[search,filter]); tools.orientation = .horizontal; tools.spacing = 16
        list.addSubview(heading); list.addSubview(tools); list.addSubview(listScroll); list.addSubview(more)
        for view in [heading,tools,listScroll,more] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo:list.leadingAnchor,constant:24), heading.topAnchor.constraint(equalTo:list.topAnchor,constant:20),
            tools.leadingAnchor.constraint(equalTo:heading.leadingAnchor), tools.trailingAnchor.constraint(equalTo:list.trailingAnchor,constant:-24), tools.topAnchor.constraint(equalTo:heading.bottomAnchor,constant:20), tools.heightAnchor.constraint(equalToConstant:30), search.widthAnchor.constraint(greaterThanOrEqualToConstant:220),
            listScroll.leadingAnchor.constraint(equalTo:list.leadingAnchor), listScroll.trailingAnchor.constraint(equalTo:list.trailingAnchor), listScroll.topAnchor.constraint(equalTo:tools.bottomAnchor,constant:20), listScroll.bottomAnchor.constraint(equalTo:more.topAnchor,constant:-12),
            more.centerXAnchor.constraint(equalTo:list.centerXAnchor), more.bottomAnchor.constraint(equalTo:list.bottomAnchor,constant:-12)
        ])
        listScroll.documentView = table; listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false
        table.headerView = nil; table.rowHeight = 72; table.intercellSpacing = NSSize(width:18,height:0); table.style = .fullWidth
        table.backgroundColor = .controlBackgroundColor; table.selectionHighlightStyle = .regular;table.allowsMultipleSelection=true
        for (id,width) in [("mail",530.0),("source",160.0)] {
            let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id)); column.width = width; column.minWidth = id == "mail" ? 280 : 110
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle; table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(openSelected); table.setAccessibilityLabel("所有账号的邮件")
        more.target = self; more.action = #selector(loadMore); more.bezelStyle = .rounded; more.isHidden = true
        back.isHidden = true
    }
    func label(_ text:String, size:CGFloat, weight:NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString:text); field.font = .systemFont(ofSize:size,weight:weight); return field
    }
    func pin(_ view:NSView, to parent:NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:parent.leadingAnchor),view.trailingAnchor.constraint(equalTo:parent.trailingAnchor),view.topAnchor.constraint(equalTo:parent.topAnchor),view.bottomAnchor.constraint(equalTo:parent.bottomAnchor)])
    }
    func dataStore(_ account:MailAccount) -> WKWebsiteDataStore {
        if let store = stores[account.id] { return store }
        let store = fixture ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier:account.dataIdentifier)
        stores[account.id] = store; return store
    }
    func buildAccounts() {
        for view in accountsStack.arrangedSubviews { accountsStack.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index,account) in preferences.value.accounts.enumerated() {
            let connected = pages[account.id] != nil && accountErrors[account.id] == nil
            let button = NSButton(title:account.name, target:self, action:#selector(accountClicked(_:))); button.tag = index
            button.bezelStyle = .recessed; button.alignment = .left; button.font = .systemFont(ofSize:12)
            button.image = NSImage(systemSymbolName:connected ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark",accessibilityDescription:nil)
            button.imagePosition = .imageLeading; button.contentTintColor = connected ? .secondaryLabelColor : .systemOrange
            button.toolTip = accountErrors[account.id] ?? "查看收件箱"; button.lineBreakMode = .byTruncatingMiddle
            button.widthAnchor.constraint(lessThanOrEqualToConstant:174).isActive = true
            accountsStack.addArrangedSubview(button)
        }
    }
    var sortedMessages:[MailMessage] { allMessages.values.sorted { $0.date == $1.date ? $0.key < $1.key : $0.date > $1.date } }
    func renderList() {
        let oldVisible=visible
        let query = search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let pool = !submittedQuery.isEmpty ? searchResults.values.sorted{$0.date>$1.date} : filter.selectedSegment>0 ? filteredMessages.values.sorted{$0.date>$1.date} : sortedMessages
        let matching=pool.filter { message in
            let inScope:Bool
            if !submittedQuery.isEmpty {inScope=true}
            else if let account=selectedAccountID {
                inScope=message.accountID==account && message.folderID==(selectedFolderID ?? contexts[account]?.inbox?.id ?? pages[account]?.folderID ?? "")
            } else {inScope=message.folderID==(contexts[message.accountID]?.inbox?.id ?? pages[message.accountID]?.folderID ?? message.folderID)}
            return inScope && (filter.selectedSegment != 1 || message.unread) && (filter.selectedSegment != 2 || message.attachment) && (submittedQuery.isEmpty || filter.selectedSegment != 3 || !["0","flag_not_set",""].contains(message.flag ?? "")) && (filter.selectedSegment == 4 || message.archived != true) &&
                (!submittedQuery.isEmpty || query.isEmpty || [message.subject,message.sender,message.preview,accountName(message.accountID)].joined(separator:" ").localizedCaseInsensitiveContains(query))
        }
        let grouped=MailMessage.conversations(matching);visible=Array(grouped.prefix(visibleLimit))
        let selected=Set(table.selectedRowIndexes.compactMap{oldVisible.indices.contains($0) ? oldVisible[$0].key : nil})
        table.reloadData()
        table.selectRowIndexes(IndexSet(visible.indices.filter{selected.contains(visible[$0].key)}),byExtendingSelection:false)
        more.isHidden = !(grouped.count > visibleLimit || currentPages.contains{$0.more});more.isEnabled = !refreshing
        let ready = preferences.value.accounts.filter { pages[$0.id] != nil && accountErrors[$0.id] == nil }.count
        if activePanel == nil && activeReader == nil {
            if fixture { status.stringValue = "测试数据 · \(ready) 个账号 · \(visible.count) 封邮件" }
            else if refreshing { status.stringValue = "正在汇总 \(preferences.value.accounts.count) 个账号…" }
            else if preferences.value.accounts.isEmpty { status.stringValue = "点击左侧添加账号，登录后自动汇总邮件。" }
            else { status.stringValue = "\(ready) / \(preferences.value.accounts.count) 个账号已连接 · \(visible.count) 封邮件" + (ready < preferences.value.accounts.count ? " · 点击左侧橙色账号登录" : " · 每分钟自动刷新") }
        }
        buildAccounts();buildFolders();updateOperationState()
    }
    func numberOfRows(in tableView:NSTableView) -> Int { visible.count }
    func tableView(_ tableView:NSTableView, viewFor tableColumn:NSTableColumn?, row:Int) -> NSView? {
        guard visible.indices.contains(row) else { return nil }; let message = visible[row]
        let container = NSView()
        let primary = label(tableColumn?.identifier.rawValue == "source" ? accountName(message.accountID) : "\(message.unread ? "●  " : "")\(message.sender)",size:13,weight:message.unread ? .semibold : .regular)
        let dateFormat = DateFormatter(); dateFormat.locale = Locale(identifier:"zh_CN"); dateFormat.timeZone = TimeZone(identifier:"America/New_York"); dateFormat.dateFormat = Calendar.current.isDateInToday(message.date) ? "HH:mm" : "M月d日 HH:mm"
        let secondary = label(tableColumn?.identifier.rawValue == "source" ? dateFormat.string(from:message.date) : "\(message.attachment ? "⌁  " : "")\(message.subject)\((message.threadCount ?? 0)>1 ? "  · \(message.threadCount!) 封" : "")",size:12)
        primary.lineBreakMode = .byTruncatingTail; secondary.lineBreakMode = .byTruncatingTail
        secondary.textColor = .secondaryLabelColor
        let stack = NSStackView(views:[primary,secondary]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        container.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:16), stack.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-12), stack.centerYAnchor.constraint(equalTo:container.centerYAnchor)])
        return container
    }
    func accountName(_ id:String) -> String { preferences.value.accounts.first{$0.id == id}?.name ?? "邮箱" }
    func controlTextDidChange(_ obj:Notification) { renderList() }
    @objc func filterChanged() {filteredMessages=[:];filteredPages=[:];renderList();refreshScope()}
    @objc func refreshAction() {
        if let reader=activeReader {loadDetail(reader,force:true);activeConversation?.loadThread();return}
        if let conversation=activeConversation {conversation.loadThread();return}
        if let panel = activePanel { if Trust.mail(panel.webView.url) { panel.webView.reload() } }
        else { refreshScope() }
    }
    @objc func showInbox() {
        selectedAccountID=nil;selectedFolderID=nil;resetSearch();backToList();refreshScope()
    }
    @objc func backToList() {
        detailTask?.cancel();detailTask=nil;activeReader?.view.removeFromSuperview();activeReader=nil;activeConversation?.task?.cancel();activeConversation?.view.removeFromSuperview();activeConversation=nil
        activePanel?.webView.removeFromSuperview(); activePanel = nil; activeMessage = nil
        authPoll?.invalidate(); authPoll = nil; authAccount = nil
        list.isHidden = false; back.isHidden = true; source.stringValue = selectedAccountID.map(accountName) ?? ""; refresh.isEnabled = true
        heading.stringValue=currentFolderTitle
        window.subtitle = heading.stringValue; renderList()
        if let row=visible.firstIndex(where:{$0.key == selectedMessageKey}) {table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}
        listScroll.contentView.scroll(to:lastListOrigin); listScroll.reflectScrolledClipView(listScroll.contentView)
    }
    @objc func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard !selectionMode,table.selectedRowIndexes.count<=1,visible.indices.contains(row) else{return};open(visible[row])
    }
    func open(_ message:MailMessage) {
        guard preferences.value.accounts.contains(where:{$0.id == message.accountID}) else{return}
        if activeReader == nil && activePanel == nil {lastListOrigin=listScroll.contentView.bounds.origin}
        detailTask?.cancel();activePanel?.webView.removeFromSuperview();activePanel=nil
        activeReader?.view.removeFromSuperview();authPoll?.invalidate();authPoll=nil;authAccount=nil
        selectedMessageKey=message.key;activeMessage=message
        activeConversation?.task?.cancel();activeConversation?.view.removeFromSuperview()
        let conversation=MailConversation(owner:self,message:message);activeConversation=conversation
        let reader=conversation.initialReader;activeReader=reader
        list.isHidden=true;back.isHidden=false;back.title=currentFolderTitle;refresh.isEnabled=true
        source.stringValue=accountName(message.accountID);window.subtitle=message.subject
        content.addSubview(conversation.view);pin(conversation.view,to:content);status.stringValue="正在读取邮件…"
        loadDetail(reader);conversation.loadThread();updateOperationState()
    }
    func loadDetail(_ reader:MailReader,force:Bool = false) {
        detailTask?.cancel()
        if !force,let saved=cache.detail(reader.message) {reader.show(saved);markOpenedRead(reader.message);status.stringValue="\(accountName(reader.message.accountID)) · \(folderName(reader.message))";return}
        detailTask=Task { @MainActor [weak self,weak reader] in
            guard let self,let reader else{return}
            do {
                let detail:MailDetail
                if self.fixture {
                    detail = .init(message:reader.message,from:"sender@example.test",to:"fixture@example.test",cc:"",replyTo:"",html:"<p>测试邮件正文</p><p>来源：\(reader.message.accountID)</p><p>邮件：\(reader.message.id)</p>",attachments:[],inline:[])
                } else {
                    guard let account=self.preferences.value.accounts.first(where:{$0.id == reader.message.accountID}) else{throw MailFailure.auth}
                    let panel=try await self.sessionPanel(account)
                    detail=try await self.api.detail(reader.message,store:self.dataStore(account),browser:panel.webView)
                }
                try Task.checkCancellation();self.cache.store(detail)
                guard self.activeReader === reader else{return};reader.show(detail);self.markOpenedRead(reader.message)
                self.status.stringValue="\(self.accountName(reader.message.accountID)) · \(self.folderName(reader.message))"
            } catch {
                if Task.isCancelled{return};guard self.activeReader === reader else{return};reader.failed();self.status.stringValue="邮件未能读取，请刷新重试。"
            }
        }
    }
    func attachmentData(_ file:MailAttachment,message:MailMessage) async throws -> Data {
        guard let account=preferences.value.accounts.first(where:{$0.id == message.accountID}) else{throw MailFailure.auth}
        let panel=try await sessionPanel(account)
        return try await api.attachment(file,message:message,store:dataStore(account),browser:panel.webView)
    }
    func compose(_ detail:MailDetail,mode:ComposeMode) {composers.append(MailCompose(owner:self,detail:detail,mode:mode))}
    func display(_ panel:MailWebPanel) {
        detailTask?.cancel();activeReader?.view.removeFromSuperview();activeReader=nil;activeConversation?.view.removeFromSuperview();activeConversation=nil;activeMessage=nil
        if activePanel == nil { lastListOrigin = listScroll.contentView.bounds.origin }
        activePanel?.webView.removeFromSuperview(); activePanel = panel; panel.lastUsed = Date(); list.isHidden = true; back.isHidden = false
        source.stringValue = panel.account.name; window.subtitle = "\(panel.account.name) · Zoho 邮件"
        content.addSubview(panel.webView); pin(panel.webView,to:content)
        status.stringValue = "正在打开 Zoho 邮件面板…"; refresh.isEnabled = true
    }
    @objc func accountClicked(_ sender:NSButton) {
        guard preferences.value.accounts.indices.contains(sender.tag) else { return }
        let account=preferences.value.accounts[sender.tag]
        if pages[account.id] != nil && accountErrors[account.id] == nil {selectedAccountID=account.id;selectedFolderID=nil;resetSearch();backToList();refreshScope()}
        else {login(account)}
    }
    func login(_ account:MailAccount) {
        authPoll?.invalidate(); authAccount = account.id
        let key = "login:\(account.id)", panel = panels["login:\(account.id)"] ?? MailWebPanel(owner:self,account:account)
        panels[key] = panel; display(panel)
        if panel.webView.url == nil { panel.webView.load(URLRequest(url:URL(string:"/zm/",relativeTo:Region.find(account.region)!.origin)!.absoluteURL)) }
        authPoll = Timer.scheduledTimer(withTimeInterval:5,repeats:true) { [weak self] _ in
            Task { @MainActor in guard let self, self.authAccount == account.id, Trust.mail(panel.webView.url), !self.loadingAccounts.contains(account.id) else { return }; await self.readAccount(account,more:false); self.loginCompleted(account) }
        }
    }
    func loginCompleted(_ account:MailAccount) {
        if authAccount == account.id && accountErrors[account.id] == nil && pages[account.id] != nil { showInbox() }
    }
    @objc func addAccount() {
        let alert = NSAlert(); alert.messageText = "添加邮箱账号"; alert.informativeText = "登录后自动加入所有收件箱。每个账号使用独立会话。"
        alert.addButton(withTitle:"添加并登录"); alert.addButton(withTitle:"取消")
        let name = NSTextField(string:""); name.placeholderString = "账号名称或邮箱"
        let region = NSPopUpButton(); Region.all.forEach { region.addItem(withTitle:"\($0.name) · \($0.domain)") }
        let stack = NSStackView(views:[name,region]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.frame = NSRect(x:0,y:0,width:340,height:74)
        name.widthAnchor.constraint(equalToConstant:340).isActive = true; alert.accessoryView = stack
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let account = MailAccount(id:UUID().uuidString.lowercased(),name:Trust.text(name.stringValue,limit:80).isEmpty ? "账号 \(self.preferences.value.accounts.count + 1)" : Trust.text(name.stringValue,limit:80),region:Region.all[max(0,region.indexOfSelectedItem)].id)
            self.preferences.value.accounts.append(account); self.preferences.save(); self.buildAccounts(); self.login(account)
        }
    }
    @objc func loadMore() {if !submittedQuery.isEmpty {runSearch(more:true)} else{refreshScope(more:true)}}
    func sessionPanel(_ account:MailAccount) async throws -> MailWebPanel {
        let key = "login:\(account.id)"
        let panel = panels[key] ?? MailWebPanel(owner:self,account:account)
        panels[key] = panel
        if panel.webView.url == nil {
            panel.webView.frame = NSRect(x:0,y:0,width:1100,height:750)
            panel.webView.load(URLRequest(url:Region.find(account.region)!.origin.appendingPathComponent("zm/")))
        }
        for _ in 0..<150 {
            try Task.checkCancellation()
            if panel.webView.url != nil && !panel.webView.isLoading { return panel }
            try await Task.sleep(nanoseconds:200_000_000)
        }
        throw MailFailure.network
    }
    func refreshAll(more:Bool = false) {
        if refreshing {return}
        refreshing = true; generation += 1; let current = generation
        if more { visibleLimit += 100 } else { visibleLimit = 100 }
        renderList()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Batches keep request concurrency bounded while allowing any number of accounts.
            for account in self.preferences.value.accounts {
                if Task.isCancelled || current != self.generation { break }
                if more, let page = self.filter.selectedSegment>0 ? self.filteredPages[account.id] : self.pages[account.id], !page.more { continue }
                await self.readAccount(account,more:more)
            }
            guard current == self.generation else { return }; self.refreshing = false; self.renderList()
        }
    }
    func readAccount(_ account:MailAccount,more:Bool) async {
        guard !loadingAccounts.contains(account.id) else { return }
        let requestedFilter=filter.selectedSegment
        loadingAccounts.insert(account.id); defer { loadingAccounts.remove(account.id) }
        do {
            let page:InboxPage
            if fixture {
                let start = more ? (pages[account.id]?.next ?? 1) : 1
                let base = account.id == "fixture-first" ? 10000 : 20000
                let messages = (0..<(start == 1 ? 100 : 5)).compactMap { i in MailMessage.parse(["messageId":String(base+start+i),"folderId":"500","receivedTime":String(Date().timeIntervalSince1970*1000 - Double(start+i)*60000 - Double(base)),"subject":"测试邮件 \(start+i)","sender":account.id == "fixture-first" ? "工作联系人" : "个人联系人","status":i%2,"hasAttachment":i%3 == 0],accountID:account.id,remoteID:"101",folderID:"500",origin:Region.find(account.region)!.origin) }
                let folders=[MailFolder(id:"500",name:"Inbox",path:"/Inbox",type:"Inbox"),MailFolder(id:"501",name:"Drafts",path:"/Drafts",type:"Drafts"),MailFolder(id:"502",name:"Sent",path:"/Sent",type:"Sent"),MailFolder(id:"503",name:"Trash",path:"/Trash",type:"Trash")]
                let context=MailboxSession(accountID:account.id,remoteID:"101",email:"\(account.id)@example.test",origin:Region.find(account.region)!.origin,folders:folders,addresses:["\(account.id)@example.test"])
                page = .init(messages:messages,remoteID:"101",folderID:"500",next:start+messages.count,more:start == 1,mailbox:context)
            } else {
                let panel = try await sessionPanel(account)
                page = try await api.inbox(account:account,store:dataStore(account),origin:origins[account.id] ?? Region.find(account.region)!.origin,previous:more ? (requestedFilter>0 ? filteredPages[account.id] : pages[account.id]) : nil,browser:panel.webView,filter:requestedFilter)
            }
            guard !Task.isCancelled else { return }
            if let context=page.mailbox {contexts[account.id]=context;if !fixture {cache.store(context)}}
            if requestedFilter>0 {
                if !more {filteredMessages=filteredMessages.filter{$0.value.accountID != account.id}}
                for message in page.messages {filteredMessages[message.key]=message}
                filteredPages[account.id]=page
            } else {
                if !more { allMessages = allMessages.filter{!($0.value.accountID == account.id && $0.value.folderID == page.folderID)} }
                for message in page.messages { allMessages[message.key] = message }
                if !fixture {cache.store(page.messages,account:account.id,replace:!more,folderID:page.folderID)}
                pages[account.id]=page
            };accountErrors[account.id] = nil
            if !page.email.isEmpty, let index = preferences.value.accounts.firstIndex(where:{$0.id == account.id}), preferences.value.accounts[index].name != page.email {
                preferences.value.accounts[index].name = page.email; preferences.save()
                for panel in panels.values where panel.account.id == account.id {
                    panel.account.name = page.email
                    panel.webView.setAccessibilityLabel("Zoho 邮件面板 · \(page.email)")
                    if activePanel === panel { source.stringValue = page.email; window.subtitle = "\(page.email) · Zoho 邮件" }
                }
            }
        } catch {
            if Task.isCancelled { return }; accountErrors[account.id] = (error as? MailFailure)?.label ?? MailFailure.network.label
        }
        renderList()
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { confirmQuit() }
    func windowWillClose(_ notification:Notification) { preferences.value.width = window.frame.width; preferences.value.height = window.frame.height; preferences.save() }
    func confirmQuit() -> Bool {
        if busyDownloads > 0 || composers.contains(where:{$0.sending || $0.syncing}) { let alert = NSAlert(); alert.messageText = "邮件操作正在进行，请完成后再退出。"; alert.runModal(); return false }
        for composer in composers {if !composer.persistDraft(){return false}}
        guard panels.values.contains(where:{$0.dirty}) || popupPanels.contains(where:{$0.dirty}) else { return true }
        let alert = NSAlert(); alert.messageText = "邮件面板可能有尚未完成的编辑"; alert.informativeText = "请确认回复已保存为草稿或发送后再退出。"; alert.addButton(withTitle:"继续编辑"); alert.addButton(withTitle:"退出")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
