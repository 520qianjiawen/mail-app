import Foundation
import SwiftUI

struct MailSourceIPRecord: Codable {
    let account, remote, folder, id, origin: String
    let source: MailSourceIP
    init(message: MailMessage, source: MailSourceIP) {
        account = message.accountID; remote = message.remoteID; folder = message.folderID
        id = message.id; origin = message.origin.absoluteString; self.source = source
    }
    func matches(_ message: MailMessage) -> Bool {
        account == message.accountID && remote == message.remoteID && folder == message.folderID && id == message.id && origin == message.origin.absoluteString
    }
    static func key(_ message: MailMessage) -> String {
        [message.accountID, message.remoteID, message.folderID, message.id, message.origin.absoluteString].joined(separator: "|")
    }
}

@MainActor final class MailListSourceIPLoader {
    private var active = 0
    private var running = Set<String>()
    private var failures: [String: Date] = [:]
    func load(key: String, cached: @MainActor () -> MailSourceIP?, fetch: @MainActor () async throws -> MailSourceIP) async -> MailSourceIP? {
        if let value = cached() { return value }
        if let failed = failures[key], Date().timeIntervalSince(failed) < 120 { return nil }
        do {
            while active >= 2 || running.contains(key) {
                try await Task.sleep(nanoseconds: 150_000_000)
                if let value = cached() { return value }
                if let failed = failures[key], Date().timeIntervalSince(failed) < 120 { return nil }
            }
            try Task.checkCancellation()
            active += 1; running.insert(key)
            defer { active -= 1; running.remove(key) }
            return try await fetch()
        } catch {
            if !Task.isCancelled {
                if failures.count >= 10000 { failures.removeAll() }
                failures[key] = Date()
            }
            return nil
        }
    }
}

extension AppState {
    func listSourceIP(_ message: MailMessage) async -> MailSourceIP? {
        if let value = cache.sourceIP(message) { return value }
        let lifetime = contextActionLifetime()
        guard !fixture, acceptsContextAction(accountID: message.accountID, lifetime: lifetime),
              let context = sessions[message.accountID], context.remoteID == message.remoteID, context.origin == message.origin,
              let account = accounts.first(where: { $0.id == message.accountID }) else { return nil }
        return await listSourceIPLoader.load(key: MailSourceIPRecord.key(message), cached: { self.cache.sourceIP(message) }) {
            try Task.checkCancellation()
            guard self.acceptsContextAction(accountID: message.accountID, lifetime: lifetime) else { throw CancellationError() }
            let source: MailSourceIP
            if let credential = zohoOAuthAccounts.first(where: { $0.email == context.email }) {
                let object = try await ZohoOAuthManager.shared.objectRequest(
                    path: "folders/\(message.folderID)/messages/\(message.id)/header", query: ["raw": "false"], credential: credential)
                guard Trust.numericID(object["messageId"]) == message.id, let headers = object["headerContent"] as? [String: Any] else { throw MailFailure.response }
                source = MailSourceIP.parse(headers)
            } else {
                let web = self.webSession(account)
                try await web.ready()
                source = try await self.api.sourceIPHeaders(message, store: web.store, browser: web.webView)
            }
            try Task.checkCancellation()
            guard self.acceptsContextAction(accountID: message.accountID, lifetime: lifetime),
                  self.sessions[message.accountID]?.remoteID == message.remoteID,
                  self.sessions[message.accountID]?.origin == message.origin else { throw CancellationError() }
            self.cache.storeSourceIP(source, for: message)
            return source
        }
    }
}

struct MailListCountryBadge: View {
    let message: MailMessage
    @Binding var country: String?
    @EnvironmentObject private var state: AppState
    @ObservedObject private var locations = MailIPLocationStore.shared
    @State private var source: MailSourceIP?
    var body: some View {
        HStack(spacing: 0) {
            if let country {
                Text(country).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Palette.secondaryText)
                    .lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.045)))
                    .frame(maxWidth: 84).layoutPriority(1)
                    .help("邮件来源 IP 归属地：\(country)。可能是邮件服务器，不代表客户实际位置。")
                    .accessibilityIdentifier("list.sourceCountry")
            } else {
                // Keep a mounted view so the header-loading task also runs
                // before the first country result exists.
                Color.clear.frame(width: 0, height: 14).accessibilityHidden(true)
            }
        }
        .task(id: MailSourceIPRecord.key(message) + ":\(state.sessions[message.accountID] != nil)") {
            let value = await state.listSourceIP(message)
            guard !Task.isCancelled else { return }
            source = value; updateCountry()
        }
        .onReceive(locations.$database) { database in
            country = source?.primary.flatMap { database?.country($0.address) }
        }
        .onReceive(state.$detail) { detail in
            if let detail, MailSourceIPRecord(message: detail.message, source: .init(candidates: [])).matches(message), let value = detail.sourceIP {
                source = value; updateCountry()
            }
        }
    }
    private func updateCountry() { country = source?.primary.flatMap { locations.database?.country($0.address) } }
}
