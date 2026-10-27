import Foundation

/// Local UI appearance only; email HTML and provider settings are unaffected.
enum MailAppearanceMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}
