import AppKit
import Combine
import WebKit

@MainActor private final class MailAppearanceChangeCounter {
    var value = 0
}

/// Process-local appearance only: synthetic accounts, isolated fixture stores, no OS settings.
@MainActor func runMailAppearanceTests(_ require: (Bool, String) -> Void) async {
    let originalAppearance = NSApp.appearance
    defer { NSApp.appearance = originalAppearance }
    let fm = FileManager.default
    let temporaryRoot = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL

    // Every deletion is restricted to a fresh immediate child of the actual temporary root.
    func verifiedTemporaryDirectory(_ directory: URL, prefix: String) -> Bool {
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        return resolved.deletingLastPathComponent() == temporaryRoot &&
            resolved.lastPathComponent.hasPrefix(prefix) &&
            UUID(uuidString: String(resolved.lastPathComponent.dropFirst(prefix.count))) != nil
    }
    func cleanup(_ directory: URL, prefix: String) {
        guard verifiedTemporaryDirectory(directory, prefix: prefix) else {
            require(false, "appearance cleanup stays inside its UUID temporary directory")
            return
        }
        if fm.fileExists(atPath: directory.path) {
            do { try fm.removeItem(at: directory) }
            catch { require(false, "appearance fixture cleanup: \(error)") }
        }
    }
    func matches(_ appearance: NSAppearance, _ name: NSAppearance.Name) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == name
    }
    func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        return window
    }

    require(MailAppearanceMode.allCases == [.system, .light, .dark], "appearance has exactly system/light/dark in menu order")
    require(MailAppearanceMode.allCases.map(\.rawValue) == ["system", "light", "dark"], "appearance Codable raw values are stable")
    require(MailAppearanceMode.allCases.map(\.title) == ["跟随系统", "浅色", "深色"], "appearance exposes all three Chinese titles")
    require(NativePreferences().appearanceMode == .system, "new preferences follow system appearance")

    do {
        // Construct complete valid old preferences, then vary only the newly introduced key.
        var older = NativePreferences()
        older.width = 1472
        older.compactRows = true
        older.accounts = [MailAccount(id: "appearance-dummy", name: "Dummy", region: "global")]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as! [String: Any]
        object.removeValue(forKey: "appearanceMode")
        let variants: [(String, Any?)] = [
            ("missing", nil), ("unknown string", "future-theme"),
            ("wrong integer type", 42), ("wrong boolean type", false),
            ("wrong object type", ["mode": "dark"]), ("null", NSNull())
        ]
        for (label, invalid) in variants {
            var candidate = object
            if let invalid { candidate["appearanceMode"] = invalid }
            let decoded = try JSONDecoder().decode(NativePreferences.self, from: JSONSerialization.data(withJSONObject: candidate))
            require(decoded.appearanceMode == .system, "\(label) appearance falls back to system")
            require(decoded.width == 1472 && decoded.compactRows && decoded.accounts.map(\.id) == ["appearance-dummy"] && decoded.accounts.first?.name == "Dummy",
                    "\(label) appearance preserves width, other preferences and dummy account")
        }

        let directory = temporaryRoot.appendingPathComponent("mail-appearance-tests-" + UUID().uuidString)
        defer { cleanup(directory, prefix: "mail-appearance-tests-") }
        let file = PreferenceFile(directory: directory)
        file.value = older
        for mode in MailAppearanceMode.allCases {
            file.value.appearanceMode = mode
            let encoded = try JSONEncoder().encode(file.value)
            let roundTrip = try JSONDecoder().decode(NativePreferences.self, from: encoded)
            require(roundTrip.appearanceMode == mode, "\(mode.rawValue) survives Codable round trip")
            require(file.save(), "\(mode.rawValue) writes actual isolated preferences file")
            let reloaded = PreferenceFile(directory: directory)
            require(reloaded.value.appearanceMode == mode && reloaded.value.width == 1472 && reloaded.value.accounts.map(\.id) == ["appearance-dummy"],
                    "\(mode.rawValue) reloads from a fresh PreferenceFile without losing unrelated values")
        }
    } catch { require(false, "appearance decoding/persistence setup: \(error)") }

    do {
        let state = AppState(fixture: true)
        defer { _ = state.shutdown(); cleanup(state.preferences.directory, prefix: "mail-lite-fixture-") }
        let counter = MailAppearanceChangeCounter()
        let subscription = state.objectWillChange.sink { _ in counter.value += 1 }
        defer { subscription.cancel() }
        let accountIDs = state.preferences.value.accounts.map(\.id)
        for mode in MailAppearanceMode.allCases {
            let before = counter.value
            require(state.setAppearanceMode(mode), "AppState saves \(mode.rawValue) selection successfully")
            require(state.preferences.value.appearanceMode == mode && PreferenceFile(directory: state.preferences.directory).value.appearanceMode == mode,
                    "AppState \(mode.rawValue) selection agrees in memory and on disk")
            require(counter.value > before, "AppState \(mode.rawValue) selection notifies observers")
            if mode == .system {
                require(NSApp.appearance == nil, "system selection removes process appearance override")
            } else {
                require(NSApp.appearance?.name == (mode == .light ? .aqua : .darkAqua), "AppState \(mode.rawValue) applies matching native appearance")
            }
        }
        // Exercise the launch application method with reloaded data, not a claimed process restart.
        let reloaded = PreferenceFile(directory: state.preferences.directory)
        state.preferences.value.appearanceMode = reloaded.value.appearanceMode
        MailApplicationAppearance.apply(.light)
        state.applySavedAppearance()
        require(NSApp.appearance?.name == .darkAqua, "applySavedAppearance applies the disk-reloaded mode over a different current override")
        require(state.preferences.value.accounts.map(\.id) == accountIDs && state.accountSessions.isEmpty,
                "appearance changes preserve fixture accounts without constructing real account sessions")

        MailApplicationAppearance.apply(.light)
        let existing = makeWindow()
        defer { existing.close() }
        require(existing.appearance == nil && matches(existing.effectiveAppearance, .aqua), "existing window initially inherits app light appearance without an override")
        MailApplicationAppearance.apply(.dark)
        await Task.yield()
        existing.contentView?.layoutSubtreeIfNeeded()
        require(existing.appearance == nil && matches(existing.effectiveAppearance, .darkAqua), "existing window follows application dark appearance")
        let openedLater = makeWindow()
        defer { openedLater.close() }
        require(openedLater.appearance == nil && matches(openedLater.effectiveAppearance, .darkAqua), "newly opened window inherits current application dark appearance")
        MailApplicationAppearance.apply(.light)
        await Task.yield()
        require(matches(existing.effectiveAppearance, .aqua) && matches(openedLater.effectiveAppearance, .aqua), "old and new windows both follow later light selection")
        MailApplicationAppearance.apply(.system)
        require(NSApp.appearance == nil && existing.appearance == nil && openedLater.appearance == nil,
                "system mode leaves application and both native windows unforced without changing OS appearance")

        MailApplicationAppearance.apply(.dark)
        let editor = WebHTMLComposerHandle()
        let editorWindow = makeWindow()
        editorWindow.contentView = editor.webView
        editorWindow.orderFront(nil)
        defer { editor.dispose(); editorWindow.contentView = nil; editorWindow.close() }
        editor.setText("Appearance fixture body")
        _ = await editor.flush()
        require(editorWindow.appearance == nil && matches(editorWindow.effectiveAppearance, .darkAqua) && editor.webView.appearance?.name == .aqua,
                "dark compose window retains editor's explicit Aqua appearance")
        let colors = await editor.inspectDOM("return {paper:getComputedStyle(document.body).backgroundColor, ink:getComputedStyle(document.getElementById('editor')).color};") as? [String: String]
        require(editor.failure == nil && colors?["paper"] == "rgb(255, 255, 255)" && colors?["ink"] == "rgb(0, 0, 0)",
                "real WebKit composer keeps white paper and black body text under dark application appearance")
    }

    do {
        let state = AppState(fixture: true)
        defer { _ = state.shutdown(); cleanup(state.preferences.directory, prefix: "mail-lite-fixture-") }
        require(state.setAppearanceMode(.light), "rollback fixture first persists a known light preference")
        let previousMode = state.preferences.value.appearanceMode
        let previousAccounts = state.preferences.value.accounts.map(\.id)
        let previousAppearance = NSApp.appearance
        let directory = state.preferences.directory.resolvingSymlinksInPath().standardizedFileURL
        let target = directory.appendingPathComponent("preferences.json").standardizedFileURL
        guard verifiedTemporaryDirectory(directory, prefix: "mail-lite-fixture-"),
              target.deletingLastPathComponent() == directory, target.lastPathComponent == "preferences.json" else {
            require(false, "rollback blocker resolves to this test's temporary fixture preferences only")
            return
        }
        // Inspect and verify the existing regular test file before replacing it with a directory.
        let attributes = try fm.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let inspected = try? JSONDecoder().decode(NativePreferences.self, from: Data(contentsOf: target)),
              inspected.appearanceMode == previousMode else {
            require(false, "rollback blocker verifies the existing fixture preference file before removal")
            return
        }
        try fm.removeItem(at: target)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        state.status = "appearance failure sentinel"
        require(!state.setAppearanceMode(.dark), "appearance reports actual preferences I/O failure")
        require(state.preferences.value.appearanceMode == previousMode && state.preferences.value.accounts.map(\.id) == previousAccounts,
                "failed save rolls mode back and preserves all fixture accounts")
        require(NSApp.appearance === previousAppearance, "failed save leaves the prior application appearance object untouched")
        require(state.status != "appearance failure sentinel" && state.status.contains("失败"), "failed save publishes a visible status failure label")
        require(state.accountSessions.isEmpty, "I/O failure path creates no real account session")
    } catch { require(false, "appearance rollback setup: \(error)") }
}
