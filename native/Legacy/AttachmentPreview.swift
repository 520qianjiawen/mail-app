import AppKit
import PDFKit
import Darwin

@MainActor final class AttachmentPreview:NSObject,NSWindowDelegate {
    weak var owner:MailWindow?
    let window:NSWindow,url:URL
    init(owner:MailWindow,name:String,data:Data) throws {
        self.owner=owner
        let folder=owner.preferences.directory.appendingPathComponent("Previews",isDirectory:true).appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        url=folder.appendingPathComponent((name as NSString).lastPathComponent);try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        let quarantine="0001;\(String(Int(Date().timeIntervalSince1970),radix:16));Mail Lite;\(UUID().uuidString)"
        let path=url.path
        _=quarantine.withCString{setxattr(path,"com.apple.quarantine",$0,strlen($0),0,0)}
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        super.init();window.title=name;window.isReleasedWhenClosed=false;window.delegate=self
        let root=NSView(),save=NSButton(title:"保存附件…",target:self,action:#selector(saveFile));save.bezelStyle = .rounded;window.contentView=root
        let content:NSView
        let ext=url.pathExtension.lowercased()
        if ext=="pdf",let document=PDFDocument(data:data) {let pdf=PDFView();pdf.document=document;pdf.autoScales=true;content=pdf}
        else if ["jpg","jpeg","png","gif","tiff","tif","heic","webp","bmp"].contains(ext),let image=NSImage(data:data) {let view=NSImageView();view.image=image;view.imageScaling = .scaleProportionallyUpOrDown;content=view}
        else if ["txt","csv","log","eml","md","json","xml"].contains(ext),data.count<2*1024*1024,let value=String(data:data,encoding:.utf8) {let text=NSTextView();text.string=value;text.isEditable=false;let scroll=NSScrollView();scroll.documentView=text;scroll.hasVerticalScroller=true;text.autoresizingMask = .width;content=scroll}
        else {content=NSTextField(labelWithString:"此附件可保存后使用相应应用查看。")}
        root.addSubview(save);root.addSubview(content);save.translatesAutoresizingMaskIntoConstraints=false;content.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([save.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-18),save.topAnchor.constraint(equalTo:root.topAnchor,constant:14),content.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:14),content.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-14),content.topAnchor.constraint(equalTo:save.bottomAnchor,constant:12),content.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-14)])
        window.center();window.makeKeyAndOrderFront(nil)
    }
    @objc func saveFile() {
        let save=NSSavePanel();save.nameFieldStringValue=url.lastPathComponent
        save.beginSheetModal(for:window){[weak self] response in guard response == .OK,let self,let destination=save.url else{return};do{let bytes=try Data(contentsOf:self.url);try bytes.write(to:destination,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path);let flag="0001;0;Mail Lite;";_=flag.withCString{setxattr(destination.path,"com.apple.quarantine",$0,strlen($0),0,0)}}catch{self.owner?.status.stringValue="附件未能保存，请重试"}}
    }
    func windowWillClose(_ notification:Notification) {try? FileManager.default.removeItem(at:url.deletingLastPathComponent());owner?.previewWindows.removeAll{$0===self}}
}

@MainActor extension MailWindow {
    func previewAttachment(_ file:MailAttachment,message:MailMessage) {
        busyDownloads+=1;status.stringValue="正在读取附件…"
        Task { @MainActor [weak self] in
            guard let self else{return};defer{self.busyDownloads-=1}
            do {let bytes=try await self.attachmentData(file,message:message);let preview=try AttachmentPreview(owner:self,name:file.name,data:bytes);self.previewWindows.append(preview);self.status.stringValue="\(file.name)"}
            catch {self.status.stringValue="附件预览失败，请重试（单个附件上限 25 MB）"}
        }
    }
}
