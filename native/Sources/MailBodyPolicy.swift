import Foundation

/// Local allocation guards, not claims about the provider's delivery limits.
/// Image count is governed by total encoded body size, not a fixed count.
enum MailBodyPolicy {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumImageBytes = 25 * 1024 * 1024
    static let maximumNodes = 131072
    static let maximumDepth = 1024
    // Content JSON may escape quotes, Unicode and control characters.
    static let maximumResponseBytes = 128 * 1024 * 1024
}
