import AppKit
import SwiftUI
import PDFKit
import ImageIO

@MainActor enum MailAttachmentContent {
    case pdf(PDFDocument), image(NSImage), other
    enum Failure: Error { case invalidPDF, invalidImage, empty }
    static func decode(_ data: Data, name: String) throws -> MailAttachmentContent {
        guard !data.isEmpty else { throw Failure.empty }
        let ext = (name as NSString).pathExtension.lowercased()
        if data.prefix(5) == Data("%PDF-".utf8) || ext == "pdf" {
            guard let pdf = PDFDocument(data: data), pdf.pageCount > 0, !pdf.isLocked else { throw Failure.invalidPDF }
            return .pdf(pdf)
        }
        if MailRasterImage.mimeType(for: data) != nil {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2200
                  ] as CFDictionary) else { throw Failure.invalidImage }
            return .image(NSImage(cgImage: image, size: .zero))
        }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"].contains(ext) { throw Failure.invalidImage }
        return .other
    }
}

@MainActor final class MailAttachmentPreviewModel: ObservableObject {
    typealias Fetch = (MailAttachment, MailMessage) async throws -> Data
    let message: MailMessage
    private let fetch: Fetch
    @Published private(set) var selected: MailAttachment?
    @Published private(set) var content: MailAttachmentContent?
    @Published private(set) var bytes: Data?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    init(message: MailMessage, fetch: @escaping Fetch) { self.message = message; self.fetch = fetch }
    func preview(_ file: MailAttachment, allowed: [MailAttachment]) {
        guard let canonical = allowed.first(where: { $0.id == file.id }) else { return }
        if selected?.id == canonical.id, loading || content != nil { return }
        close()
        selected = canonical; loading = true
        let token = generation
        task = Task { @MainActor in
            do {
                let data = try await fetch(canonical, message)
                guard !Task.isCancelled, generation == token else { return }
                let value = try MailAttachmentContent.decode(data, name: canonical.name)
                guard !Task.isCancelled, generation == token else { return }
                bytes = data; content = value; loading = false
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                loading = false
                if error is MailAttachmentContent.Failure {
                    self.error = "附件内容无法预览，可能已损坏、已加密或下载内容无效。可重试或保存后检查。"
                } else { self.error = "附件读取失败，请检查连接或登录状态后重试。" }
            }
        }
    }
    func close() {
        generation = UUID(); task?.cancel(); task = nil
        selected = nil; content = nil; bytes = nil; error = nil; loading = false
    }
    func wait() async { await task?.value }
}

struct MailAttachmentSection: View {
    let files: [MailAttachment]
    let message: MailMessage
    @ObservedObject var state: AppState
    @StateObject private var preview: MailAttachmentPreviewModel
    @State private var progress: String?
    @State private var savingAll = false
    @State private var showAllFiles = false

    init(files: [MailAttachment], message: MailMessage, state: AppState) {
        self.files = files; self.message = message; self.state = state
        _preview = StateObject(wrappedValue: MailAttachmentPreviewModel(message: message) { [weak state] file, owner in
            guard let state else { throw MailFailure.auth }
            return try await state.attachmentData(file, message: owner)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("\(files.count) 个附件", systemImage: "paperclip")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondaryText)
                Text(ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + Int64($1.size) }, countStyle: .file))
                    .font(.system(size: 10)).foregroundStyle(Palette.tertiaryText)
                Spacer()
                if files.count > 3 {
                    Button(showAllFiles ? "收起" : "显示全部") { showAllFiles.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
                }
                if files.count > 1 {
                    Button("全部保存…", action: saveAll).buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(Palette.accent).disabled(savingAll)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(showAllFiles ? files : Array(files.prefix(3)), id: \.id) { file in attachment(file) }
            }
            if let progress { Text(progress).font(.system(size: 11)).foregroundStyle(Palette.secondaryText) }
            if let file = preview.selected { previewContent(file) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.attachments")
        .onDisappear { preview.close() }
    }

    private func attachment(_ file: MailAttachment) -> some View {
        HStack(spacing: 8) {
            Button { preview.preview(file, allowed: files) } label: {
                HStack(spacing: 8) {
                    Image(systemName: (file.name as NSString).pathExtension.lowercased() == "pdf" ? "doc.richtext" : "paperclip")
                        .font(.system(size: 16)).foregroundStyle(Palette.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file) + " · 点击预览")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondaryText)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("预览附件：\(file.name)")
            Button { save(file) } label: { Image(systemName: "arrow.down.to.line") }
                .buttonStyle(.plain).help("保存附件").accessibilityLabel("保存附件：\(file.name)")
            Menu {
                Button("预览") { preview.preview(file, allowed: files) }
                Button("系统预览") { systemPreview(file) }
                Button("用默认应用打开") { external(file) }
                Button("存储…") { save(file) }
                Button("共享…") { share(file) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("附件操作：\(file.name)")
        }
        .font(.system(size: 11)).padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline, lineWidth: 0.75))
    }

    private func previewContent(_ file: MailAttachment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(file.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if case .pdf(let pdf) = preview.content { Text("\(pdf.pageCount) 页").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("系统预览") { systemPreview(file) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
                Button { preview.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("收起附件预览").accessibilityLabel("收起附件预览")
            }
            if preview.loading {
                HStack { ProgressView().controlSize(.small); Text("正在读取附件内容…").font(.system(size: 11)) }.padding(.vertical, 14)
            } else if let error = preview.error {
                HStack {
                    Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber)
                    Button("重试") { preview.preview(file, allowed: files) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
            } else if let content = preview.content {
                switch content {
                case .pdf(let document):
                    MailAttachmentPDFView(document: document).frame(height: 440)
                        .accessibilityLabel("附件 PDF 内容：\(file.name)")
                case .image(let image):
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(maxHeight: 440)
                        .accessibilityLabel("附件图片内容：\(file.name)")
                case .other:
                    Text("此格式可使用系统预览，或保存后用对应应用打开。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondaryText).padding(.vertical, 12)
                }
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.hairline, lineWidth: 0.75))
        .accessibilityElement(children: .contain).accessibilityIdentifier("reader.attachmentPreview")
    }

    private func data(_ file: MailAttachment) async throws -> Data {
        if preview.selected?.id == file.id, let bytes = preview.bytes { return bytes }
        return try await state.attachmentData(file, message: message)
    }
    private func systemPreview(_ file: MailAttachment) {
        Task { @MainActor in
            progress = "正在读取附件…"
            do { try AttachmentPreviewer.shared.present(name: file.name, data: try await data(file)); progress = nil }
            catch { progress = "附件读取失败，请重试。" }
        }
    }
    private func save(_ file: MailAttachment) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            progress = "正在保存附件…"
            do {
                try await data(file).write(to: url, options: .atomic)
                quarantine(url); progress = "附件已保存。"
            } catch { progress = "附件保存失败，请重试。" }
        }
    }
    private func saveAll() {
        guard !savingAll else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "保存到此文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        savingAll = true
        Task { @MainActor in
            defer { savingAll = false }
            var saved = 0
            for (index, file) in files.enumerated() {
                progress = "正在保存附件 \(index + 1)/\(files.count)…"
                do { _ = try MailAttachmentExport.save(try await data(file), name: file.name, directory: url); saved += 1 }
                catch { }
            }
            progress = saved == files.count ? "已保存全部 \(saved) 个附件。" : "已保存 \(saved)/\(files.count) 个附件，其余附件请重试。"
        }
    }
    private func external(_ file: MailAttachment) {
        Task { @MainActor in
            do {
                let url = try AttachmentPreviewer.shared.temporaryFile(name: file.name, data: try await data(file))
                quarantine(url); NSWorkspace.shared.open(url)
            } catch { progress = "附件打开失败，请重试。" }
        }
    }
    private func share(_ file: MailAttachment) {
        Task { @MainActor in
            do {
                let url = try AttachmentPreviewer.shared.temporaryFile(name: file.name, data: try await data(file))
                quarantine(url)
                guard let view = NSApp.keyWindow?.contentView else { return }
                NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            } catch { progress = "附件共享失败，请重试。" }
        }
    }
    private func quarantine(_ url: URL) {
        let value = "0001;\(String(Int(Date().timeIntervalSince1970), radix: 16));Mail Lite;\(UUID().uuidString)"
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }
}

struct MailAttachmentPDFView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.backgroundColor = .controlBackgroundColor
        view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document; view.autoScales = true }
    }
}
