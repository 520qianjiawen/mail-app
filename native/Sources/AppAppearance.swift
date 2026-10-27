import AppKit

@MainActor enum MailApplicationAppearance {
    static func apply(_ mode: MailAppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor extension AppState {
    /// Apply before creating windows, so launch uses the saved local selection.
    func applySavedAppearance() {
        MailApplicationAppearance.apply(preferences.value.appearanceMode)
    }

    @discardableResult func setAppearanceMode(_ mode: MailAppearanceMode) -> Bool {
        let previous = preferences.value
        preferences.value.appearanceMode = mode
        guard preferences.save() else {
            preferences.value = previous
            status = "外观设置保存失败，已保留原选择，请重试。"
            return false
        }
        objectWillChange.send()
        MailApplicationAppearance.apply(mode)
        return true
    }
}
