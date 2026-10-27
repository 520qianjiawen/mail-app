import AppKit

// Formatting is deliberately attached-view-only. Initial document buffering is
// owned by EditorHandle; these actions never replace an unattached draft.
@MainActor extension EditorHandle {
    func undo() {
        guard let view = textView, let manager = view.undoManager, manager.canUndo else { return }
        manager.undo()
        view.didChangeText()
        view.window?.makeFirstResponder(view)
    }

    func redo() {
        guard let view = textView, let manager = view.undoManager, manager.canRedo else { return }
        manager.redo()
        view.didChangeText()
        view.window?.makeFirstResponder(view)
    }

    func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard trait.rawValue != 0 else { return }
        let remove = allSelectedAttributes { attributes in
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            return NSFontManager.shared.traits(of: font).contains(trait)
        }
        changeCharacters("字体样式") { attributes in
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            attributes[.font] = remove
                ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                : NSFontManager.shared.convert(font, toHaveTrait: trait)
        }
    }

    func toggleUnderlineFormatting() { toggleDecoration(.underlineStyle, name: "下划线") }

    func toggleStrikeFormatting() { toggleDecoration(.strikethroughStyle, name: "删除线") }

    func applyLinkFormatting(_ url: URL) {
        guard Trust.outside(url), let view = textView, let storage = view.textStorage,
              let selection = validSelection(in: view) else { return }
        if selection.length > 0 {
            changeCharacters("链接") { $0[.link] = url }
        } else {
            // An empty selection inserts the supplied address, matching the
            // existing insertLink action; selected text only changes its link.
            var attributes = view.typingAttributes
            attributes[.link] = url
            let address = NSAttributedString(string: url.absoluteString, attributes: attributes)
            edit(view, name: "插入链接") {
                storage.replaceCharacters(in: selection, with: address)
                view.setSelectedRange(NSRange(location: selection.location + address.length, length: 0))
            }
        }
    }

    private func allSelectedAttributes(_ predicate: ([NSAttributedString.Key: Any]) -> Bool) -> Bool {
        guard let view = textView, let storage = view.textStorage,
              let selection = validSelection(in: view) else { return false }
        if selection.length == 0 { return predicate(view.typingAttributes) }
        var result = true
        storage.enumerateAttributes(in: selection) { attributes, _, stop in
            if !predicate(attributes) { result = false; stop.pointee = true }
        }
        return result
    }

    private func toggleDecoration(_ key: NSAttributedString.Key, name: String) {
        let remove = allSelectedAttributes { ($0[key] as? Int ?? 0) != 0 }
        changeCharacters(name) { attributes in
            if remove { attributes.removeValue(forKey: key) }
            else { attributes[key] = NSUnderlineStyle.single.rawValue }
        }
    }

    func setFontFamily(_ name: String) {
        guard !name.isEmpty else { return }
        let familyExists = NSFontManager.shared.availableFontFamilies.contains(name)
        guard familyExists || NSFont(name: name, size: 14) != nil else { return }
        changeCharacters("字体") { attributes in
            let current = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            if familyExists {
                attributes[.font] = NSFontManager.shared.convert(current, toFamily: name)
            } else if let font = NSFont(name: name, size: current.pointSize) {
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: NSFontManager.shared.traits(of: current))
            }
        }
    }

    func setFontSize(_ points: CGFloat) {
        guard points.isFinite, (6...144).contains(points) else { return }
        changeCharacters("字号") { attributes in
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            attributes[.font] = NSFontManager.shared.convert(font, toSize: points)
        }
    }

    func setForeground(_ color: NSColor) {
        changeCharacters("文字颜色") { $0[.foregroundColor] = color }
    }

    func setHighlight(_ color: NSColor?) {
        changeCharacters("高亮颜色") { attributes in
            if let color { attributes[.backgroundColor] = color }
            else { attributes.removeValue(forKey: .backgroundColor) }
        }
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        changeParagraphs("对齐方式") { $0.alignment = alignment }
    }

    func setLineSpacing(_ multiple: CGFloat) {
        guard multiple.isFinite, (0.5...3).contains(multiple) else { return }
        changeParagraphs("行距") { $0.lineHeightMultiple = multiple }
    }

    func indent(_ delta: CGFloat) {
        guard delta.isFinite, abs(delta) <= 144 else { return }
        changeParagraphs("缩进") { style in
            style.headIndent = min(288, max(0, style.headIndent + delta))
            style.firstLineHeadIndent = min(288, max(0, style.firstLineHeadIndent + delta))
        }
    }

    func insertList(numbered: Bool) {
        guard let view = textView, let storage = view.textStorage,
              let selection = validSelection(in: view) else { return }
        let range = (storage.string as NSString).paragraphRange(for: selection)
        let list = NSTextList(markerFormat: numbered ? .decimal : .disc, options: 0)
        list.startingItemNumber = 1
        edit(view, name: numbered ? "编号列表" : "项目列表") {
            // NSTextList supplies both semantic list metadata and the marker;
            // no hard-coded bullet characters or cosmetic list-only buttons.
            let original = storage.string as NSString
            var paragraphs: [(NSRange, Int)] = []
            var offset = range.location
            while offset < NSMaxRange(range) {
                let paragraph = original.paragraphRange(for: NSRange(location: offset, length: 0))
                paragraphs.append((paragraph, paragraphs.count + 1))
                offset = NSMaxRange(paragraph)
            }
            if paragraphs.isEmpty { paragraphs = [(NSRange(location: selection.location, length: 0), 1)] }
            var adjusted = selection
            for (paragraph, number) in paragraphs.reversed() {
                let attributes = paragraph.location < storage.length ? storage.attributes(at: paragraph.location, effectiveRange: nil) : view.typingAttributes
                let oldStyle = attributes[.paragraphStyle] as? NSParagraphStyle
                var oldPrefixLength = 0
                if oldStyle?.textLists.isEmpty == false, paragraph.length > 0 {
                    let text = (storage.string as NSString).substring(with: paragraph)
                    // Only replace an AppKit-style tab-delimited marker on a
                    // paragraph already carrying NSTextList metadata.
                    if text.hasPrefix("\t"), let end = text.dropFirst().firstIndex(of: "\t") {
                        oldPrefixLength = (String(text[...end]) as NSString).length
                    }
                }
                let marker = "\t" + list.marker(forItemNumber: number) + "\t"
                let replacement = NSAttributedString(string: marker, attributes: attributes)
                let prefixRange = NSRange(location: paragraph.location, length: oldPrefixLength)
                storage.replaceCharacters(in: prefixRange, with: replacement)
                adjusted = selectionAfterReplacing(prefixRange, withLength: replacement.length, selection: adjusted)
                let currentRange = (storage.string as NSString).paragraphRange(for: NSRange(location: paragraph.location, length: 0))
                let style = (oldStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.textLists = [list]
                style.firstLineHeadIndent = 0
                style.headIndent = 32
                style.tabStops = [NSTextTab(textAlignment: .right, location: 24), NSTextTab(textAlignment: .left, location: 32)]
                storage.addAttribute(.paragraphStyle, value: style, range: currentRange)
                if paragraph.length == 0 { view.typingAttributes[.paragraphStyle] = style }
            }
            view.setSelectedRange(adjusted)
        }
    }

    func clearFormatting() {
        changeCharacters("清除格式") { attributes in
            let blocks = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks ?? []
            let attachment = attributes[.attachment]
            attributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]
            if let attachment { attributes[.attachment] = attachment }
            let style = NSMutableParagraphStyle()
            style.textBlocks = blocks // Preserve table structure, not visual styling.
            attributes[.paragraphStyle] = style
        }
    }

    func insertTable(rows: Int, columns: Int) {
        guard (1...10).contains(rows), (1...10).contains(columns),
              let view = textView, let storage = view.textStorage,
              let selection = validSelection(in: view) else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        let content = NSMutableAttributedString(string: "")
        for row in 0..<rows {
            for column in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setBorderColor(.separatorColor)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setWidth(6, type: .absoluteValueType, for: .padding)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                var attributes = view.typingAttributes
                attributes[.paragraphStyle] = style
                // Each cell is an actual table-block paragraph, not tabular text.
                content.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        content.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]))
        edit(view, name: "插入表格") {
            storage.replaceCharacters(in: selection, with: content)
            // Place the insertion point in the first real cell, not after table.
            view.setSelectedRange(NSRange(location: selection.location, length: 0))
            view.typingAttributes = content.attributes(at: 0, effectiveRange: nil)
        }
    }

    private func validSelection(in view: NSTextView) -> NSRange? {
        let selection = view.selectedRange()
        let length = view.textStorage?.length ?? 0
        guard selection.location != NSNotFound, selection.location <= length,
              selection.length <= length - selection.location else { return nil }
        return selection
    }

    private func changeCharacters(_ name: String, change: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let view = textView, let storage = view.textStorage,
              let selection = validSelection(in: view) else { return }
        edit(view, name: name) {
            if selection.length == 0 {
                var attributes = view.typingAttributes
                change(&attributes)
                view.typingAttributes = attributes
            } else {
                var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
                storage.enumerateAttributes(in: selection) { attributes, range, _ in runs.append((range, attributes)) }
                for (range, oldAttributes) in runs {
                    var attributes = oldAttributes
                    change(&attributes)
                    storage.setAttributes(attributes, range: range)
                }
            }
            view.setSelectedRange(selection)
        }
    }

    private func changeParagraphs(_ name: String, change: (NSMutableParagraphStyle) -> Void) {
        guard let view = textView, let storage = view.textStorage,
              let selection = validSelection(in: view) else { return }
        let range = (storage.string as NSString).paragraphRange(for: selection)
        edit(view, name: name) {
            var offset = range.location
            while offset < NSMaxRange(range) {
                let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: offset, length: 0))
                let existing = storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
                let style = existing?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                change(style)
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                offset = NSMaxRange(paragraph)
            }
            let typing = (view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            change(typing)
            view.typingAttributes[.paragraphStyle] = typing
            view.setSelectedRange(selection)
        }
    }

    private func edit(_ view: NSTextView, name: String, action: () -> Void) {
        guard let storage = view.textStorage else { return }
        let old = NSAttributedString(attributedString: storage)
        let selection = view.selectedRange()
        let typing = view.typingAttributes
        let manager = view.undoManager
        manager?.beginUndoGrouping()
        manager?.registerUndo(withTarget: view) { target in
            MainActor.assumeIsolated { restoreFormatting(target, content: old, selection: selection, typing: typing) }
        }
        storage.beginEditing()
        action()
        let desiredSelection = view.selectedRange()
        let desiredTyping = view.typingAttributes
        storage.endEditing()
        // NSTextView adjusts its selection when a batched character edit ends.
        // Restore the action's logical selection only after those notifications.
        if desiredSelection.location <= storage.length, desiredSelection.length <= storage.length - desiredSelection.location {
            view.setSelectedRange(desiredSelection)
        }
        view.typingAttributes = desiredTyping
        manager?.setActionName(name)
        manager?.endUndoGrouping()
        view.didChangeText()
        view.window?.makeFirstResponder(view)
    }
}

@MainActor private func restoreFormatting(_ view: NSTextView, content: NSAttributedString, selection: NSRange, typing: [NSAttributedString.Key: Any]) {
    guard let storage = view.textStorage else { return }
    let inverse = NSAttributedString(attributedString: storage)
    let inverseSelection = view.selectedRange()
    let inverseTyping = view.typingAttributes
    view.undoManager?.registerUndo(withTarget: view) { target in
        MainActor.assumeIsolated { restoreFormatting(target, content: inverse, selection: inverseSelection, typing: inverseTyping) }
    }
    storage.setAttributedString(content)
    view.setSelectedRange(selection)
    view.typingAttributes = typing
    view.didChangeText()
    view.window?.makeFirstResponder(view)
}

private func selectionAfterReplacing(_ range: NSRange, withLength length: Int, selection: NSRange) -> NSRange {
    func map(_ position: Int) -> Int {
        if position < range.location { return position }
        if position >= NSMaxRange(range) { return position + length - range.length }
        return range.location + length
    }
    let start = map(selection.location)
    let end = map(NSMaxRange(selection))
    return NSRange(location: start, length: max(0, end - start))
}

@MainActor private final class ComposeFormattingTestView: NSTextView {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}

@MainActor func runComposeFormattingTests(_ require: (Bool, String) -> Void) {
    let view = ComposeFormattingTestView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    view.isRichText = true
    view.allowsUndo = true
    view.testUndoManager.groupsByEvent = false
    let handle = EditorHandle()
    handle.attach(view)
    view.string = "Alpha\nBeta\n"
    view.setSelectedRange(NSRange(location: 0, length: 5))
    handle.setFontSize(22)
    require((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22 && view.selectedRange() == NSRange(location: 0, length: 5), "font size applies to actual selection without moving it")
    handle.setFontFamily("Helvetica")
    require((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName == "Helvetica", "font family updates NSTextView text attributes")
    handle.setForeground(.systemRed)
    handle.setHighlight(.yellow)
    require(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.systemRed && view.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.yellow, "foreground and highlight are real attributed text formatting")
    handle.setHighlight(nil)
    require(view.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil, "highlight can be removed")
    handle.setAlignment(.center)
    handle.setLineSpacing(1.5)
    handle.indent(24)
    let paragraph = view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    require(paragraph?.alignment == .center && paragraph?.lineHeightMultiple == 1.5 && paragraph?.headIndent == 24, "alignment spacing and indent update actual paragraph styles")
    view.setSelectedRange(NSRange(location: 5, length: 0))
    handle.setFontSize(18)
    require((view.typingAttributes[.font] as? NSFont)?.pointSize == 18 && view.string == "Alpha\nBeta\n", "caret-only formatting changes typing attributes without inserting text")
    handle.setFontSize(.nan)
    handle.setLineSpacing(.infinity)
    require((view.typingAttributes[.font] as? NSFont)?.pointSize == 18, "non-finite formatting values are ignored")
    view.setSelectedRange(NSRange(location: 0, length: view.textStorage!.length))
    handle.insertList(numbered: true)
    let firstList = (view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first
    require(firstList?.markerFormat == .decimal && view.string.contains("Alpha") && view.string.contains("Beta"), "numbered list creates NSTextList metadata and keeps paragraph text")
    let listRTF = try? view.attributedString().data(from: NSRange(location: 0, length: view.textStorage!.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let restoredList = listRTF.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
    require((restoredList?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first?.markerFormat == .decimal, "RTF draft round-trip preserves semantic numbered lists")
    let listHTMLData = try? view.attributedString().data(from: NSRange(location: 0, length: view.textStorage!.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
    let listHTML = listHTMLData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    require(listHTML.contains("<ol") && listHTML.contains("Alpha") && listHTML.contains("Beta"), "HTML send export emits a real ordered list")
    handle.insertList(numbered: false)
    require((view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first?.markerFormat == .disc && !view.string.contains("\t1.\t"), "list conversion replaces generated old markers instead of duplicating them")
    view.setSelectedRange(NSRange(location: 0, length: view.textStorage!.length))
    handle.clearFormatting()
    require((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 14 && (view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textLists.isEmpty == true, "clear formatting resets font and list paragraph styling")
    view.string = "Before\n"
    view.setSelectedRange(NSRange(location: view.textStorage!.length, length: 0))
    let beforeTable = view.string
    handle.insertTable(rows: 2, columns: 3)
    var blocks: [NSTextTableBlock] = []
    view.textStorage?.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: view.textStorage!.length)) { value, _, _ in
        if let style = value as? NSParagraphStyle { blocks += style.textBlocks.compactMap { $0 as? NSTextTableBlock } }
    }
    require(blocks.count == 6 && blocks.first?.table.numberOfColumns == 3, "table insertion creates six real NSTextTableBlock cell paragraphs")
    let tableRTF = try? view.attributedString().data(from: NSRange(location: 0, length: view.textStorage!.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let restoredTable = tableRTF.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
    var restoredCells = 0
    if let restoredTable {
        restoredTable.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: restoredTable.length)) { value, _, _ in
            restoredCells += (value as? NSParagraphStyle)?.textBlocks.compactMap { $0 as? NSTextTableBlock }.count ?? 0
        }
    }
    require(restoredCells == 6, "RTF draft round-trip preserves native table cells")
    let tableHTMLData = try? view.attributedString().data(from: NSRange(location: 0, length: view.textStorage!.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
    let tableHTML = tableHTMLData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    require(tableHTML.contains("<table") && tableHTML.contains("<td"), "HTML send export emits an actual table rather than tab-separated text")
    let tableContent = view.string
    handle.undo()
    require(view.string == beforeTable, "formatting table operation supports undo without an application window")
    handle.redo()
    require(view.string == tableContent, "formatting table operation supports redo without an application window")
    handle.insertTable(rows: 11, columns: 1)
    handle.insertTable(rows: 0, columns: 2)
    require(view.string == tableContent, "table dimensions outside one through ten are rejected")

    let mixedView = ComposeFormattingTestView()
    mixedView.isRichText = true
    mixedView.allowsUndo = true
    mixedView.testUndoManager.groupsByEvent = false
    let mixedHandle = EditorHandle()
    mixedHandle.attach(mixedView)
    let firstFont = NSFontManager.shared.convert(NSFont(name: "Helvetica", size: 22)!, toHaveTrait: .boldFontMask)
    let secondFont = NSFont(name: "Courier", size: 16)!
    let mixed = NSMutableAttributedString(string: "Bold", attributes: [.font: firstFont])
    mixed.append(NSAttributedString(string: " Plain", attributes: [.font: secondFont]))
    mixedView.textStorage?.setAttributedString(mixed)
    let mixedRange = NSRange(location: 0, length: mixed.length)
    mixedView.setSelectedRange(mixedRange)
    mixedHandle.toggleFontTrait(.boldFontMask)
    let boldFirst = mixedView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    let boldSecond = mixedView.textStorage?.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
    require(boldFirst?.familyName == firstFont.familyName && boldSecond?.familyName == secondFont.familyName && boldFirst?.pointSize == 22 && boldSecond?.pointSize == 16 && boldSecond.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "mixed selected font runs retain families and sizes while uniformly applying bold")
    mixedHandle.undo()
    let undoneSecond = mixedView.textStorage?.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
    require(undoneSecond.map { !NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true && mixedView.selectedRange() == mixedRange, "font trait undo restores mixed original fonts and selection")
    mixedHandle.redo()
    mixedHandle.toggleFontTrait(.boldFontMask)
    require((mixedView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).map { !NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "uniform bold selection toggles off consistently")
    mixedHandle.toggleUnderlineFormatting()
    mixedHandle.toggleStrikeFormatting()
    require((mixedView.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int) == NSUnderlineStyle.single.rawValue && (mixedView.textStorage?.attribute(.strikethroughStyle, at: 5, effectiveRange: nil) as? Int) == NSUnderlineStyle.single.rawValue, "underline and strike actions update selected attributed text")
    mixedHandle.undo()
    require(mixedView.textStorage?.attribute(.strikethroughStyle, at: 5, effectiveRange: nil) == nil && mixedView.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil, "strike undo preserves earlier underline formatting")
    let link = URL(string: "https://example.test/product")!
    mixedHandle.applyLinkFormatting(link)
    require(mixedView.textStorage?.attribute(.link, at: 0, effectiveRange: nil) as? URL == link && mixedView.selectedRange() == mixedRange, "selected-text link formatting preserves selection")
    mixedHandle.undo()
    require(mixedView.textStorage?.attribute(.link, at: 0, effectiveRange: nil) == nil, "link formatting participates in undo")
    mixedView.setSelectedRange(NSRange(location: mixedView.textStorage!.length, length: 0))
    let beforeLink = mixedView.string
    mixedHandle.applyLinkFormatting(link)
    require(mixedView.string == beforeLink + link.absoluteString, "caret-only link action inserts the requested linked URL")
    mixedHandle.undo()
    require(mixedView.string == beforeLink, "inserted URL text and link attribute undo together")
    mixedHandle.applyLinkFormatting(URL(string: "javascript:alert(1)")!)
    require(mixedView.string == beforeLink, "link formatting rejects non-external URL schemes")
}
