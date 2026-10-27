import SwiftUI
import AppKit

/// Visual language for Mail Lite 0.4 "Aurora": airy spacing, soft surfaces,
/// one accent, deterministic avatar colors, no chrome noise.
enum Palette {
    static let accent = Color(red: 0.34, green: 0.40, blue: 0.98)
    static let accentDeep = Color(red: 0.24, green: 0.28, blue: 0.86)
    static let mint = Color(red: 0.16, green: 0.71, blue: 0.55)
    static let amber = Color(red: 0.95, green: 0.62, blue: 0.16)
    static let orange = Color(red: 0.96, green: 0.55, blue: 0.26)
    static let rose = Color(red: 0.91, green: 0.30, blue: 0.42)
    static let sky = Color(red: 0.18, green: 0.62, blue: 0.87)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let avatarColors: [Color] = [
        Color(red: 0.35, green: 0.45, blue: 0.95), Color(red: 0.93, green: 0.44, blue: 0.38),
        Color(red: 0.20, green: 0.68, blue: 0.55), Color(red: 0.75, green: 0.38, blue: 0.85),
        Color(red: 0.95, green: 0.58, blue: 0.16), Color(red: 0.22, green: 0.62, blue: 0.83),
        Color(red: 0.54, green: 0.42, blue: 0.90), Color(red: 0.30, green: 0.60, blue: 0.44)
    ]

    static func avatar(for text: String) -> Color {
        let seed = text.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return avatarColors[seed % avatarColors.count]
    }

    static func label(_ hex: String) -> Color {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return accent }
        return Color(red: Double((number >> 16) & 0xff) / 255, green: Double((number >> 8) & 0xff) / 255, blue: Double(number & 0xff) / 255)
    }

    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var elevated: Color { Color(nsColor: .windowBackgroundColor) }
    static var subtle: Color { Color.primary.opacity(0.045) }
    static var hairline: Color { Color(nsColor: .separatorColor).opacity(0.55) }
    static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    static var tertiaryText: Color { Color(nsColor: .tertiaryLabelColor) }
}

/// Semantic folder palette inspired by modern native clients (Flectar Mail / Slint design system).
enum MailFolderPalette {
    static let inbox = Color(red: 0.18, green: 0.61, blue: 0.96)       // #2F9CF4 Sky Blue
    static let sent = Color(red: 0.00, green: 0.66, blue: 0.95)        // #00A8F3 Cyan Blue
    static let starred = Color(red: 0.96, green: 0.70, blue: 0.00)     // #F5B301 Warm Gold
    static let drafts = Color(red: 0.85, green: 0.27, blue: 0.94)      // #D946EF Magenta
    static let archive = Color(red: 0.55, green: 0.36, blue: 0.96)     // #8B5CF6 Violet
    static let trash = Color(red: 1.00, green: 0.36, blue: 0.30)       // #FF5B4D Coral Red
    static let spam = Color(red: 0.96, green: 0.62, blue: 0.04)        // #F59E0B Amber
    static let outbox = Color(red: 0.96, green: 0.55, blue: 0.16)      // #F58C29 Orange
    static let attachments = Color(red: 0.22, green: 0.62, blue: 0.83) // #389ED4 Light Blue
}

enum Metrics {
    static let sidebar: CGFloat = 230
    static let listMin: CGFloat = 320
    static let listMax: CGFloat = 560
    static let readerMin: CGFloat = 420
    static let rowRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let titlebarInset: CGFloat = 40
}

/// Soft translucent column background that follows the system material.
struct ColumnBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

struct Avatar: View {
    let text: String
    var size: CGFloat = 34
    var body: some View {
        let color = Palette.avatar(for: text)
        ZStack {
            Circle().fill(LinearGradient(colors: [color.opacity(0.92), color.opacity(0.72)], startPoint: .top, endPoint: .bottom))
            Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
    private var initials: String {
        let clean = text.split(separator: "@").first.map(String.init) ?? text
        let parts = clean.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" }).filter { !$0.isEmpty }
        if parts.count >= 2, let a = parts[0].first, let b = parts[1].first { return "\(a)\(b)".uppercased() }
        if let first = parts.first { return String(first.prefix(2)).uppercased() }
        return "?"
    }
}

struct Badge: View {
    let count: Int
    var tint: Color = Palette.accent
    var body: some View {
        if count > 0 {
            Text(count > 999 ? "999+" : "\(count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Capsule().fill(tint.opacity(0.92)))
                .fixedSize()
        }
    }
}

struct Chip: View {
    let text: String
    var tint: Color = Palette.accent
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.12)))
            .fixedSize()
    }
}

struct FilterChip: View {
    let title: String
    var symbol: String? = nil
    var active: Bool = false
    var count: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: active ? .semibold : .medium))
                }
                Text(title)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 4.5).padding(.vertical, 1)
                        .background(Capsule().fill(active ? Palette.accent : Palette.secondaryText.opacity(0.2)))
                        .foregroundStyle(active ? .white : Palette.secondaryText)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(active ? Palette.accent : Palette.secondaryText)
            .background(
                Capsule()
                    .fill(active ? Palette.accent.opacity(0.14) : Color.primary.opacity(0.04))
            )
            .overlay(
                Capsule()
                    .strokeBorder(active ? Palette.accent.opacity(0.3) : Palette.hairline, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Palette.tertiaryText)
            .padding(.horizontal, 10)
            .padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HoverButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, tint: tint, active: active)
    }
    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let active: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(active ? Palette.accent : tint.opacity(hovering ? 1 : 0.72))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12) : hovering ? Color.primary.opacity(0.07) : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0 }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.accentGradient)
                .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4))
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = .primary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct IconAction: View {
    let symbol: String
    let help: String
    var active: Bool = false
    var tint: Color = .primary
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(active ? Palette.accent : tint.opacity(hovering ? 0.95 : 0.62))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.07) : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.accent.opacity(0.55))
            Text(title).font(.system(size: 14, weight: .semibold))
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

struct DividerLine: View {
    var body: some View { Rectangle().fill(Palette.hairline).frame(height: 1) }
}

extension Date {
    var mailRelative: String {
        let calendar = Calendar.current
        let format = DateFormatter()
        format.locale = Locale(identifier: "zh_CN")
        format.timeZone = .current
        if calendar.isDateInToday(self) { format.dateFormat = "HH:mm" }
        else if calendar.isDateInYesterday(self) { return "昨天" }
        else if calendar.isDate(self, equalTo: Date(), toGranularity: .year) { format.dateFormat = "M月d日" }
        else { format.dateFormat = "yyyy/M/d" }
        return format.string(from: self)
    }
    var mailFull: String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "zh_CN")
        format.timeZone = .current
        format.dateFormat = "yyyy年M月d日 EEE HH:mm"
        return format.string(from: self)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { trimmed.isEmpty ? nil : trimmed }
    func mailInitials() -> String {
        let clean = split(separator: "@").first.map(String.init) ?? self
        let parts = clean.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" }).filter { !$0.isEmpty }
        if parts.count >= 2 { return "\(parts[0].first ?? "?")\(parts[1].first ?? "?")".uppercased() }
        return String(clean.prefix(2)).uppercased()
    }
}
