import Foundation
import Security

enum ZohoOAuthKeychain {
    static func refreshToken(for email: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.mail-lite.native.zoho-oauth",
            kSecAttrAccount as String: email.lowercased(), kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { throw MailFailure.auth }
        return token
    }
}

// MARK: - OAuth Credential Registry
// Add/remove accounts here to switch between WebKit session (old) and OAuth REST API (new).
// To disable OAuth for an account, comment out its entry — it will fall back to WebKit session.

struct ZohoOAuthCredential: Sendable {
    let clientID: String
    let clientSecret: String
    let refreshToken: String
    let accountID: String   // Zoho numeric account ID (from API Console)
    let email: String       // primary email address of the account
    let region: String      // e.g. "zoho.com", "zoho.eu", "zoho.com.cn"

    var tokenURL: URL { URL(string: "https://accounts.\(region)/oauth/v2/token")! }
    var apiBase: URL { URL(string: "https://mail.\(region)/api/accounts/\(accountID)/")! }
}

// ─── Accounts using official OAuth REST API ────────────────────────────────
let zohoOAuthAccounts: [ZohoOAuthCredential] = [

    // sales@recyclemachine.net — switched to OAuth REST API (zoho.com)
    ZohoOAuthCredential(
        clientID:     "1000.IRDBNVI2DZW00HEKC14NSLZW7WSISA",
        clientSecret: "40cbd595658375248209ca8b4c8bbbb80cad537893",
        refreshToken: "1000.a322c9e0a52b0bb77cb5bfdd27a14b8e.f357692593e7b86d33c5ea43473ae64f",
        accountID:    "7394075000000008002",
        email:        "sales@recyclemachine.net",
        region:       "zoho.com"
    ),

    // info@energycle.com — switched to OAuth REST API (zoho.com)
    ZohoOAuthCredential(
        clientID:     "1000.1AYIYXT2P6RZ81K0NRAV6DB407SOYD",
        clientSecret: "0ce3f94afe60c605772be998bb19c7b269f5e73117",
        refreshToken: "1000.724d0dd02c7c0ee167b501ece9ae3aea.5c4765829a391cb5976123896606fad6",
        accountID:    "1650226000000008002",
        email:        "info@energycle.com",
        region:       "zoho.com"
    ),

    // cavon@energycle.com — switched to OAuth REST API (zoho.com)
    ZohoOAuthCredential(
        clientID:     "1000.7GMEZG6LQJ679T3JEARNMSSNELVGYF",
        clientSecret: "06133f65d4ffb42172b25a530bcebbeb9a66b0caa9",
        refreshToken: "1000.2f42d51948d05802d27e25ae8e5e12bb.faa58f3b46f50afe1f2bb37429713095",
        accountID:    "3430212000000008002",
        email:        "cavon@energycle.com",
        region:       "zoho.com"
    ),

    // info@damao-tech.com — switched to OAuth REST API (zoho.com)
    ZohoOAuthCredential(
        clientID:     "1000.MWNCWZXJG000O3VGDQBLCYUG9Y0ZXF",
        clientSecret: "bbe05410c2d6f7ec95247be6f1aa4ce28413e1d1e1",
        refreshToken: "1000.5f67bc3b6752ad4c3ea65627cbc79675.8f046274e8b0d1f9e9d79add636f9f1d",
        accountID:    "5833342000000008002",
        email:        "info@damao-tech.com",
        region:       "zoho.com"
    ),

    // sales@rumtoo.com — switched to OAuth REST API (zoho.com)
    ZohoOAuthCredential(
        clientID:     "1000.PMGAE3749FFRZWCTAZG8J43NFGPGJF",
        clientSecret: "d363185bbcb6aae753979f7cb851620d48212b2bda",
        refreshToken: "1000.90a140c9ee9ebfc27b644918b778d53b.95e98d396094d4a0ad7d5e0fe786c79d",
        accountID:    "6003523000000008002",
        email:        "sales@rumtoo.com",
        region:       "zoho.com"
    ),

    // info@asgrecycle.com — switched to OAuth REST API (zoho.com)
    ZohoOAuthCredential(
        clientID:     "1000.R6XQM4F6XB83YA59UHNINLDLTISDTB",
        clientSecret: "ddb3980531e272d8d653cc96468a6a61d694869339",
        refreshToken: "1000.b32219b3bc7e306a12bf0c58516f143f.a413b6eec37327ab1559f1a9c5aae98c",
        accountID:    "161958000000008002",
        email:        "info@asgrecycle.com",
        region:       "zoho.com"
    ),

    // ── Add more OAuth accounts below ──────────────────────────────────────
    // ZohoOAuthCredential(clientID: "...", clientSecret: "...", refreshToken: "...",
    //                     accountID: "...", email: "...", region: "zoho.com"),

]

// MARK: - Token Manager
/// Thread-safe actor that caches access tokens and refreshes them transparently.
actor ZohoOAuthManager {
    static let shared = ZohoOAuthManager()
    private init() {}

    // (email → (token, expiry))
    private var cache: [String: (token: String, expiry: Date)] = [:]

    /// Returns a valid access token, refreshing if necessary.
    func accessToken(for credential: ZohoOAuthCredential) async throws -> String {
        // Return cached token if it still has > 60 s left
        if let cached = cache[credential.email], cached.expiry > Date().addingTimeInterval(60) {
            return cached.token
        }
        let token = try await refresh(credential)
        // Zoho access tokens live 3600 s; cache for 3500 s to be safe
        cache[credential.email] = (token, Date().addingTimeInterval(3500))
        return token
    }

    /// Invalidate cached token (e.g. after a 401 response).
    func invalidate(_ email: String) { cache.removeValue(forKey: email) }

    // MARK: Private

    private func refresh(_ credential: ZohoOAuthCredential) async throws -> String {
        let refreshToken = try ZohoOAuthKeychain.refreshToken(for: credential.email) ?? credential.refreshToken
        var req = URLRequest(url: credential.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=refresh_token",
            "client_id=\(credential.clientID)",
            "client_secret=\(credential.clientSecret)",
            "refresh_token=\(refreshToken)"
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw MailFailure.auth
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw MailFailure.response
        }
        return token
    }
}

// MARK: - Native HTTP list request
extension ZohoOAuthManager {
    /// Calls the Zoho REST API with a Bearer token instead of WebKit cookies.
    /// Mirrors the contract of MailboxAPI.listRequest — returns the inner `data` array.
    func listRequest(path: String, query: [String: String],
                     credential: ZohoOAuthCredential) async throws -> [[String: Any]] {
        let token = try await accessToken(for: credential)

        var comps = URLComponents(url: credential.apiBase.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = query.sorted { $0.key < $1.key }
                                .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw MailFailure.response }

        var req = URLRequest(url: url)
        req.setValue("Zoho-oauthtoken \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json",          forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)

        // On 401, invalidate cached token so next call forces a refresh
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            invalidate(credential.email)
            throw MailFailure.auth
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MailFailure.response
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MailFailure.response
        }
        if let arr = json["data"] as? [[String: Any]] { return arr }
        if let obj = json["data"] as? [String: Any]   { return [obj] }
        return []
    }

    /// Calls the Zoho REST API with a Bearer token and returns an object dictionary (from `data` or root).
    func objectRequest(path: String, query: [String: String] = [:],
                       credential: ZohoOAuthCredential) async throws -> [String: Any] {
        let token = try await accessToken(for: credential)

        var comps = URLComponents(url: credential.apiBase.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }
                                    .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw MailFailure.response }

        var req = URLRequest(url: url)
        req.setValue("Zoho-oauthtoken \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json",          forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)

        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            invalidate(credential.email)
            throw MailFailure.auth
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MailFailure.response
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MailFailure.response
        }
        if let obj = json["data"] as? [String: Any] { return obj }
        return json
    }

    /// Calls PUT /updatemessage with a Bearer token to update message state (trash, spam, read, unread, flag, move, etc.).
    func updateMessage(payload: [String: Any], credential: ZohoOAuthCredential) async throws {
        let token = try await accessToken(for: credential)
        let url = credential.apiBase.appendingPathComponent("updatemessage")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Zoho-oauthtoken \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json",          forHTTPHeaderField: "Content-Type")
        req.setValue("application/json",          forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 20

        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            invalidate(credential.email)
            throw MailFailure.auth
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MailFailure.response
        }
    }
}
