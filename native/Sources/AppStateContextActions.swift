import Foundation

/// The sole definition of message-list menu commands (not the reader/toolbar).
enum MailContextCommand: String, CaseIterable, Identifiable {
    case sender, subject, reply, replyAll, forward, spam, delete, reminder, pin
    var id: String { rawValue }
    func title(pinned: Bool = false, reminded: Bool = false) -> String {
        switch self {
        case .sender: return "列出发自该发件人的邮件"
        case .subject: return "列出该主题的邮件"
        case .reply: return "回复"
        case .replyAll: return "回复所有人"
        case .forward: return "转发"
        case .spam: return "标为垃圾邮件"
        case .delete: return "删除"
        case .reminder: return reminded ? "修改提醒…" : "设置提醒…"
        case .pin: return pinned ? "取消固定" : "固定邮件"
        }
    }
}

enum MailContextSearch: String {
    case sender = "from", subject = "subject"

    func query(_ literal: String) -> String? {
        // The API rejects line breaks and has a 1000-character searchKey limit.
        guard !literal.isEmpty, !literal.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let escaped = literal.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let value = "\(rawValue):\"\(escaped)\""
        return value.count <= 1000 ? value : nil
    }

    /// From's mailbox is the final angle-bracket address, never an email-looking
    /// display name. Accept bare mailboxes only when the entire value is one address.
    static func senderLiteral(_ sender: String) -> String? {
        guard !sender.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let value = sender.trimmingCharacters(in: .whitespaces)
        let mailbox: String
        if value.contains("<") || value.contains(">") {
            guard let open = value.firstIndex(of: "<"), let close = value.lastIndex(of: ">"),
                  open < close, value.index(after: close) == value.endIndex,
                  !value[..<open].contains(">"),
                  !value[value.index(after: open)..<close].contains("<"),
                  !value[value.index(after: open)..<close].contains(">") else { return nil }
            // Reject multiple mailbox lists, while allowing commas inside a
            // quoted display name (and escaped quotes inside that name).
            var quoted = false, escaped = false
            for character in value[..<open] {
                if escaped { escaped = false; continue }
                if character == "\\" && quoted { escaped = true }
                else if character == "\"" { quoted.toggle() }
                else if !quoted && (character == "," || character == ";") { return nil }
            }
            guard !quoted, !escaped else { return nil }
            mailbox = String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        } else {
            mailbox = value
        }
        let addresses = MailAddresses.extract(mailbox)
        guard addresses.count == 1, addresses[0] == mailbox else { return nil }
        return addresses[0]
    }

    /// Only consume a complete single quoted field. Never reinterpret general searches.
    static func parse(_ query: String) -> (field: MailContextSearch, literal: String)? {
        guard let colon = query.firstIndex(of: ":"), let field = Self(rawValue: String(query[..<colon])) else { return nil }
        let suffix = query[query.index(after: colon)...]
        guard suffix.first == "\"", suffix.count >= 2 else { return nil }
        var literal = "", escaped = false
        let body = suffix.dropFirst()
        for index in body.indices {
            let character = body[index]
            if escaped {
                guard character == "\\" || character == "\"" else { return nil }
                literal.append(character); escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                guard body.index(after: index) == body.endIndex else { return nil }
                return (field, literal)
            } else {
                literal.append(character)
            }
        }
        return nil
    }

    static func senderLiteral(_ message: MailMessage) -> String? {
        if let address = message.fromAddress { return senderLiteral(address) }
        return senderLiteral(message.sender)
    }

    static func needsLegacySenderLookup(_ message: MailMessage) -> Bool {
        let name = message.sender.trimmingCharacters(in: .whitespaces)
        return message.fromAddress == nil && !name.isEmpty &&
            !name.contains(where: { "@<>,;".contains($0) }) &&
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func matches(_ message: MailMessage, query: String) -> Bool {
        guard let term = parse(query) else { return true }
        switch term.field {
        case .subject: return message.subject == term.literal
        case .sender:
            guard let address = senderLiteral(message) else { return false }
            return address.caseInsensitiveCompare(term.literal) == .orderedSame
        }
    }
}

@MainActor extension AppState {
    func searchContextMessage(_ message: MailMessage, field: MailContextSearch) {
        contextSearchTask?.cancel(); contextSearchTask = nil
        contextSearchToken = UUID()
        let literal: String
        if field == .sender {
            if let address = MailContextSearch.senderLiteral(message) { literal = address }
            else if MailContextSearch.needsLegacySenderLookup(message) {
                let token = contextSearchToken, lifetime = contextActionLifetime()
                let requestedGeneration = generation, requestedScope = scope, requestedText = searchText
                let account = accounts.first { $0.id == message.accountID }
                let initialSession = sessions[message.accountID]
                contextSearchTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    @MainActor func currentIntent() -> Bool {
                        self.contextSearchToken == token && self.generation == requestedGeneration &&
                            self.scope == requestedScope && self.searchText == requestedText && !Task.isCancelled
                    }
                    guard let account, self.acceptsContextAction(accountID: message.accountID, lifetime: lifetime) else {
                        if currentIntent() { self.status = "邮件账号已移除或会话已结束" }; return
                    }
                    do {
                        let source = try await self.fetchReadingDetail(message)
                        guard currentIntent() else { return }
                        let loaded = source.message
                        guard loaded.key == message.key, loaded.origin == message.origin,
                              loaded.remoteID == message.remoteID, loaded.folderID == message.folderID,
                              self.accounts.first(where: { $0.id == account.id }) == account,
                              self.acceptsContextAction(accountID: account.id, lifetime: lifetime),
                              self.messageStore[message.key].map({ $0.origin == message.origin }) ?? true else {
                            self.status = "邮件或账号已变化，请重新选择邮件"; return
                        }
                        if let session = self.sessions[account.id] {
                            guard session.accountID == message.accountID, session.remoteID == message.remoteID, session.origin == message.origin,
                                  initialSession.map({ $0.remoteID == session.remoteID && $0.origin == session.origin && $0.email == session.email }) ?? true else {
                                self.status = "邮件账号身份已变化，请重新选择邮件"; return
                            }
                        } else if initialSession != nil { self.status = "邮件账号会话已结束"; return }
                        guard let address = MailContextSearch.senderLiteral(source.from), let query = MailContextSearch.sender.query(address) else {
                            self.status = "发件人地址为空或格式不明确"; return
                        }
                        self.search(query)
                    } catch {
                        if currentIntent() { self.status = "发件人地址读取失败，请重试" }
                    }
                }
                return
            } else { status = "发件人地址为空或格式不明确"; return }
        } else { literal = message.subject }
        guard let query = field.query(literal) else {
            status = "此邮件的搜索条件为空、过长或包含控制字符"
            return
        }
        search(query)
    }

    /// Captures the clicked identity, not activeKey/detail. Changing selection while
    /// the body downloads never changes which source is used to open the draft.
    @discardableResult
    func composeContextMessage(_ clicked: MailMessage, mode: ComposeMode) async -> Bool {
        guard mode == .reply || mode == .replyAll || mode == .forward else {
            status = "此菜单仅支持回复、回复所有人和转发"; return false
        }
        let lifetime = contextActionLifetime()
        guard let account = accounts.first(where: { $0.id == clicked.accountID }),
              acceptsContextAction(accountID: account.id, lifetime: lifetime) else {
            status = "邮件账号已移除或会话已结束"; return false
        }
        guard contextComposePending.insert(clicked.key).inserted else { return false }
        defer { contextComposePending.remove(clicked.key) }
        let sessionIdentity = sessions[account.id]
        func accepts(_ message: MailMessage) -> Bool {
            guard message.key == clicked.key, message.origin == clicked.origin,
                  message.remoteID == clicked.remoteID, message.folderID == clicked.folderID,
                  accounts.first(where: { $0.id == account.id }) == account,
                  acceptsContextAction(accountID: account.id, lifetime: lifetime) else { return false }
            if let current = messageStore[clicked.key], current.origin != clicked.origin { return false }
            if let current = sessions[account.id] {
                guard current.accountID == clicked.accountID, current.remoteID == clicked.remoteID,
                      current.origin == clicked.origin else { return false }
                if let sessionIdentity {
                    guard current.remoteID == sessionIdentity.remoteID, current.origin == sessionIdentity.origin,
                          current.email == sessionIdentity.email else { return false }
                }
            } else if sessionIdentity != nil { return false }
            return true
        }
        guard accepts(clicked) else { status = "邮件身份已变化，请重新选择邮件"; return false }
        do {
            let cached = threadDetails[clicked.key] ?? cache.detail(clicked)
            let source: MailDetail
            if let cached, accepts(cached.message), (fixture || mode == .forward || cached.replyHeadersChecked == true) {
                source = cached
            } else {
                source = try await fetchReadingDetail(clicked)
            }
            try Task.checkCancellation()
            guard accepts(source.message) else { status = "邮件或账号已变化，请重新选择邮件"; return false }
            // Never hand an unchecked cache to composeReply's unguarded background
            // refetch. The direct draft path is used only after all acceptance checks.
            guard fixture || mode == .forward || source.replyHeadersChecked == true else {
                status = "回复地址读取失败，请重试"; return false
            }
            cache.store(source)
            threadDetails[clicked.key] = source
            if let hook = contextComposeHook { hook(source, mode) }
            else { openReplyDraft(source, mode: mode) }
            return true
        } catch {
            status = "邮件读取失败，请重试：\((error as? MailFailure)?.label ?? error.localizedDescription)"
            return false
        }
    }
}
