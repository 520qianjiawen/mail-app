import Foundation
import WebKit

@MainActor func runSelfTests() {
    var checks=0
    func require(_ condition:@autoclosure()->Bool,_ label:String) { checks+=1;if !condition() { print("FAIL: \(label)"); exit(1) } }
    let a = MailAccount(id:"one",name:"工作",region:"global"), b = MailAccount(id:"two",name:"个人",region:"global")
    require(a.dataIdentifier != b.dataIdentifier,"account storage isolation")
    require(a.dataIdentifier == MailAccount(id:"one",name:"Renamed",region:"global").dataIdentifier,"rename retains session")
    require(Trust.mail(URL(string:"https://mail.zoho.com/zm/")),"mail host")
    require(!Trust.mail(URL(string:"https://mail.zoho.com.evil.example/")),"lookalike rejected")
    require(!Trust.mail(URL(string:"https://user:password@mail.zoho.com/")),"credential URL rejected")
    require(!Trust.outside(URL(string:"javascript:alert(1)")!),"executable URL rejected")
    require(!Trust.outside(URL(string:"file:///etc/passwd")!),"local URL rejected")
    require(Trust.inside(URL(string:"https://accounts.zoho.com/signin")),"login allowed")
    require(Trust.numericID("900719925474099303") == "900719925474099303","large IDs retained")
    require(Trust.numericID("1/../../") == nil,"path injection rejected")
    require(Trust.numericID(true) == nil,"boolean IDs rejected")
    let origin = Region.find("global")!.origin
    let row:[String:Any] = ["messageId":"900719925474099303","folderId":"500","receivedTime":"10000","subject":"Real subject","sender":"Sender","status":"0"]
    let message = MailMessage.parse(row,accountID:a.id,remoteID:"100",folderID:"500",origin:origin)!
    require(message.unread && (try? MailAPI().messageURL(message,suffix:"content").absoluteString) == "https://mail.zoho.com/api/accounts/100/folders/500/messages/900719925474099303/content","direct body request retains account folder and message identity")
    require(MailMessage.parse(row,accountID:a.id,remoteID:"100",folderID:"501",origin:origin) == nil,"only Inbox included")
    let cookie = HTTPCookie(properties:[.domain:".zoho.com",.path:"/api",.name:"sample",.value:"test",.secure:"TRUE"])!
    require(MailAPI.cookieHeader([cookie],for:origin.appendingPathComponent("api/accounts")) == "sample=test","account cookies used for own host")
    require(MailAPI.cookieHeader([cookie],for:URL(string:"https://evilzoho.com/api/accounts")!).isEmpty,"cookie domain boundary")
    require(MailAPI.cookieHeader([cookie],for:origin.appendingPathComponent("apix" )).isEmpty,"cookie path boundary")
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mail-native-test-\(UUID().uuidString)")
    let prefs = PreferenceFile(directory:temp); prefs.value.accounts = [a,b]; prefs.save()
    require(PreferenceFile(directory:temp).value.accounts.count == 2,"native settings persist")
    let other=MailMessage.parse(row,accountID:b.id,remoteID:"100",folderID:"500",origin:origin)!
    let cached=MailCache(directory:temp)
    cached.store([message],account:a.id,replace:true);cached.store([other],account:b.id,replace:true)
    require(cached.messages(accounts:[a.id,b.id]).count == 2,"identical message IDs in different accounts remain separate")
    require(cached.messages(accounts:[b.id]).first?.accountID == b.id,"cache filters signed-in account identities")
    let detail=MailDetail(message:message,from:"Sender <sender@example.test>",to:"own@example.test, other@example.test",cc:"other@example.test, cc@example.test",replyTo:"reply@example.test",html:"<p>Cached body</p>",attachments:[],inline:[])
    cached.store(detail)
    require(cached.detail(message)?.html == detail.html && cached.detail(other) == nil,"body cache cannot cross account boundary")
    require(MailCache(directory:temp).detail(message)?.message.key == message.key,"body cache persists across reopen")
    cached.store([],account:a.id,replace:true)
    require(cached.messages(accounts:[a.id,b.id]).count == 1,"refresh replaces only the selected account Inbox cache")
    let addresses=MailAddresses.replyAll(detail,own:"own@example.test")
    require(addresses.to == "reply@example.test" && addresses.cc == "other@example.test, cc@example.test","reply-all uses reply-to and excludes own mailbox and duplicate recipients")
    let fragment=MailHTML.document("<html><head><base href='https://evil.test'><script>alert(1)</script></head><body><p onclick='evil()'>Mail</p><iframe src='https://evil.test'></iframe><a href='javascript:alert(1)'>bad</a><img src='https://evil.test/tracker'><img src='file:///etc/passwd'><img src='cid:photo'></body></html>",inline:[.init(id:"123",name:"image.png",size:1,cid:"photo")])
    require(!fragment.contains("<script") && !fragment.contains("onclick=") && !fragment.contains("<iframe") && !fragment.contains("javascript:"),"email HTML drops executable markup")
    require(!fragment.contains("https://evil.test") && !fragment.contains("file:///"),"email HTML blocks automatic external and local resource loads")
    require(fragment.contains("mail-inline://message/123"),"inline image refers to typed attachment identity only")
    require(fragment.contains("script-src 'none'") && fragment.contains("form-action 'none'"),"body CSP blocks scripts forms and network requests")
    require(MailHTML.document("<img src='https://images.example.test/p.png'>",images:true).contains("src=\"https://images.example.test/p.png\""),"external images require explicit reader action")
    require(MailHTML.plainText("<p>Hello</p><p>World</p>").contains("Hello"),"reply quotation uses message body text")
    require(MailHTML.document("<meta charset='windows-1252'><p>中文 café français</p>").contains("中文 café français") && MailHTML.plainText("<p>中文 café français</p>").contains("中文 café français"),"Unicode survives HTML fragments and stale original charset declarations")
    require(!MailHTML.plainText("<head><style>.private {color:red}</style></head><p>正文</p><script>alert(1)</script>").contains("color:red") && MailHTML.plainText("<head><style>.private {color:red}</style></head><p>正文</p>").contains("正文"),"reply text excludes original CSS and script contents")
    let inbox=MailFolder(id:"500",name:"Inbox",path:"/Inbox",type:"Inbox"),drafts=MailFolder(id:"501",name:"Drafts",path:"/Drafts",type:"Drafts")
    require(inbox.systemName=="Inbox" && MailFolder(id:"502",name:"Vendor",path:"/Vendor",type:"Inbox").systemName==nil,"custom Inbox-type folder is not system Inbox")
    let context=MailboxSession(accountID:a.id,remoteID:"100",email:"own@example.test",origin:origin,folders:[inbox,drafts],addresses:["own@example.test"])
    cached.store(context)
    require(MailCache(directory:temp).contexts(accounts:[a.id]).first?.folders.count==2 && cached.contexts(accounts:[b.id]).isEmpty,"folder catalogs persist and respect account boundary")
    var draftRow=row;draftRow["folderId"]="501";draftRow["messageId"]="700";draftRow["status"]="unread";draftRow["threadId"]="0";draftRow.removeValue(forKey:"receivedTime");draftRow["receivedtime"]="20000"
    let draftMessage=MailMessage.parse(draftRow,accountID:a.id,remoteID:"100",folderID:"501",origin:origin)!
    require(draftMessage.unread && draftMessage.threadID==nil && draftMessage.date.timeIntervalSince1970==20,"alternate timestamp and unread encoding parsed without grouping zero thread")
    cached.store([message,draftMessage],account:a.id,replace:true);cached.store([],account:a.id,replace:true,folderID:"500")
    require(cached.messages(accounts:[a.id]).map{$0.id}==["700"] && cached.detail(message)?.html==detail.html,"folder refresh preserves other folders and body cache")
    require((try? MailAction.move("501").payload([message])["destfolderId"] as? String)=="501","move payload keeps selected source destination ID")
    require((try? MailAction.read.payload([message])["messageId"] as? [String])==[message.id],"action preserves IDs larger than JavaScript safe integer")
    require((try? MailAction.read.payload([message,other]))==nil,"batch action rejects mixed account identities")
    require((try? MailAction.move("../../").payload([message]))==nil && (try? MailAction.trash.payload([message]))==nil,"move traversal and unresolved Trash rejected")
    require((try? MailAction.flag("not-a-flag").payload([message]))==nil,"unknown flag rejected")
    var threaded=message;threaded.threadID="999";var older=message;older=MailMessage(accountID:a.id,remoteID:"100",folderID:"500",id:"701",origin:origin,subject:"older",sender:"Sender",preview:"",date:Date(timeIntervalSince1970:1),attachment:false,unread:false,threadID:"999")
    var foreign=other;foreign.threadID="999"
    let grouped=MailMessage.conversations([threaded,older,foreign])
    require(grouped.count==2 && grouped.first(where:{$0.accountID==a.id})?.threadCount==2,"conversation grouping merges only same-account thread and keeps newest first")
    let store=DraftStore(directory:temp)
    var local=MailDraft(accountID:a.id,from:"own@example.test",mode:"reply",source:detail)
    local.bcc="hidden@example.test";local.body="恢复正文";local.rtf=Data("rtf-test".utf8);local.cloudUncertain=true;local.state="uncertain";local.scheduleType=2;local.receipt=true
    let original=temp.appendingPathComponent("draft-file.txt");try! Data("original".utf8).write(to:original)
    let copy=try! store.importFile(original,id:local.id);local.files=[copy.path];try! store.save(local)
    try! Data("changed".utf8).write(to:original)
    let restored=DraftStore(directory:temp).all(accounts:[a.id]).first!
    require(restored.bcc==local.bcc && restored.rtf==local.rtf && restored.source?.message.key==message.key,"draft restores Bcc rich text and source account identity")
    require(restored.state=="uncertain" && restored.cloudUncertain && restored.receipt && restored.scheduleType==2,"uncertain send and cloud state survive process restart")
    require((try? String(contentsOf:store.files(restored).first!,encoding:.utf8))=="original","draft attachments copied into managed storage independently of originals")
    require(store.all(accounts:[b.id]).isEmpty && (try? store.folder("../../"))==nil,"draft account and directory traversal boundary")
    local.files=[original.path];require(store.files(local).isEmpty,"restoration excludes external paths")
    let permissions=(try! FileManager.default.attributesOfItem(atPath:try! store.folder(restored.id).appendingPathComponent("draft.json").path))[.posixPermissions] as? NSNumber
    require(permissions?.intValue==0o600,"draft contents are owner-only")
    require(MailAddresses.validated("Name <first@example.test>, second@example.test")?.count==2 && MailAddresses.validated("first@example.test\r\nBcc: other@example.test")==nil,"recipient validation rejects header injection")
    try? FileManager.default.removeItem(at:temp)
    print("PASS: \(checks) native model, cache persistence/isolation, body HTML, reply identity, cookie scope and trust checks.")
}
