import AppKit

struct EditorSignatureOwnership {
    let token: String
    let identity: String
    let reference: String
    let baseline: NSAttributedString
}

enum ManagedSignatureResult { case changed, unchanged, protected }

@MainActor extension EditorHandle {
    static var signatureKey: NSAttributedString.Key { NSAttributedString.Key("MailLiteOwnedSignature") }
    private func withoutSignatureTag(_ value: NSAttributedString) -> NSAttributedString {
        let clean = NSMutableAttributedString(attributedString: value)
        clean.removeAttribute(Self.signatureKey, range: NSRange(location: 0, length: clean.length))
        return clean
    }
    private func verifiedSignatureRange() -> NSRange? {
        guard let owner = signatureOwnership else { return nil }
        let current = currentAttributedContent
        var ranges: [NSRange] = []
        current.enumerateAttribute(Self.signatureKey, in: NSRange(location: 0, length: current.length)) { value, range, _ in
            if value as? String == owner.token { ranges.append(range) }
        }
        guard !ranges.isEmpty else { return nil }
        let start = ranges[0].location
        var end = start
        for range in ranges {
            guard range.location == end else { return nil }
            end += range.length
        }
        let range = NSRange(location: start, length: end - start)
        return withoutSignatureTag(current.attributedSubstring(from: range)).isEqual(to: owner.baseline) ? range : nil
    }
    var hasVerifiedSignature: Bool { verifiedSignatureRange() != nil }

    @discardableResult func replaceManagedSignature(_ html: String?, reference: String = "none", identity: String, beforeQuote: Bool, allowInsert: Bool) -> ManagedSignatureResult {
        let current = currentAttributedContent
        let range: NSRange
        if signatureOwnership != nil {
            guard let existing = verifiedSignatureRange() else {
                // User edits/deletion revoke ownership. Never search for matching
                // text and delete it, nor append another automatic signature.
                let clean = withoutSignatureTag(current)
                applySignatureContent(clean, selection: textView?.selectedRange() ?? NSRange(location: 0, length: 0))
                signatureOwnership = nil; signatureWasEdited = true
                return .protected
            }
            range = existing
        } else {
            guard !signatureWasEdited else { return .protected }
            guard html != nil, allowInsert else { return .unchanged }
            let marker = (current.string as NSString).range(of: ComposeDocument.quoteMarker)
            guard !beforeQuote || marker.location != NSNotFound else { return .protected }
            range = NSRange(location: beforeQuote ? marker.location : current.length, length: 0)
        }
        let replacement: NSAttributedString
        if let html {
            guard let fragment = SignaturePolicy.cleanHTML(html), let parsed = try? NSAttributedString(data: Data(ComposeDocument.nativeDocument("<br>" + fragment + "<br><br>").utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return .protected }
            replacement = parsed
        } else { replacement = NSAttributedString(string: "") }
        let value = NSMutableAttributedString(attributedString: current)
        let tagged = NSMutableAttributedString(attributedString: replacement)
        let token = UUID().uuidString
        if tagged.length > 0 { tagged.addAttribute(Self.signatureKey, value: token, range: NSRange(location: 0, length: tagged.length)) }
        value.replaceCharacters(in: range, with: tagged)
        let selection = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        func mapped(_ point: Int) -> Int {
            if point <= range.location { return point }
            if point >= range.location + range.length { return point + tagged.length - range.length }
            return range.location + min(point - range.location, tagged.length)
        }
        let start = mapped(selection.location), end = mapped(selection.location + selection.length)
        applySignatureContent(value, selection: NSRange(location: start, length: max(0, end - start)))
        signatureOwnership = tagged.length > 0 ? EditorSignatureOwnership(token: token, identity: identity, reference: reference, baseline: withoutSignatureTag(replacement)) : nil
        return .changed
    }
    func signatureDraftSegment(rtf: Data) -> SignatureDraftSegment? {
        guard let owner = signatureOwnership, let range = verifiedSignatureRange() else { return nil }
        return SignatureDraftSegment(location: range.location, length: range.length, text: owner.baseline.string, identity: owner.identity, reference: owner.reference, rtfSHA256: SignaturePolicy.digest(rtf))
    }
    @discardableResult func restoreSignature(_ segment: SignatureDraftSegment?, rtf: Data) -> Bool {
        guard let segment, segment.rtfSHA256 == SignaturePolicy.digest(rtf), segment.location >= 0, segment.length > 0 else { return false }
        let current = currentAttributedContent
        guard segment.length <= current.length, segment.location <= current.length - segment.length else { return false }
        let range = NSRange(location: segment.location, length: segment.length)
        let baseline = withoutSignatureTag(current.attributedSubstring(from: range))
        guard baseline.string == segment.text else { return false }
        let value = NSMutableAttributedString(attributedString: current), token = UUID().uuidString
        value.addAttribute(Self.signatureKey, value: token, range: range)
        applySignatureContent(value, selection: NSRange(location: 0, length: 0))
        signatureOwnership = EditorSignatureOwnership(token: token, identity: segment.identity, reference: segment.reference, baseline: baseline)
        return true
    }
}
