import Foundation

@MainActor private final class ReminderTestGate {
    private var entered = false, released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entryWaiters.append($0) } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
@MainActor private final class ReminderTestTransport: MailReminderTransport {
    var allowed = true, fails = false
    var permissionGate: ReminderTestGate?, scheduleGate: ReminderTestGate?
    var scheduled: [MailReminderRecord] = [], current: Set<String> = [], canceled: [String] = []
    func permission(request: Bool) async throws -> Bool { if let permissionGate { await permissionGate.pause() }; return allowed }
    func schedule(_ record: MailReminderRecord, sound: Bool) async throws {
        scheduled.append(record)
        // Model the OS accepting add before its completion callback returns.
        current.insert(record.requestID)
        if let scheduleGate { await scheduleGate.pause() }
        if fails { throw MailReminderError.unavailable }
    }
    func cancel(_ identifiers: [String]) { canceled += identifiers; current.subtract(identifiers) }
    func pendingIDs() async -> Set<String> { current }
}

@MainActor func runMailReminderTests(_ require: (Bool, String) -> Void) async {
    func setup() -> (AppState, MailReminderStore, ReminderTestTransport, MailMessage) {
        let state = AppState(fixture: true), transport = ReminderTestTransport()
        state.preferences.value.notificationsEnabled = true
        let store = MailReminderStore(state: state, transport: transport)
        state.mailReminderStore = store
        let message = MailMessage(accountID: state.accounts[0].id, remoteID: "100", folderID: "200", id: "300", origin: URL(string: "https://mail.zoho.com")!, subject: "Reminder", sender: "sender@example.test", preview: "PRIVATE BODY", date: Date(), attachment: false, unread: true)
        return (state, store, transport, message)
    }
    let due = Date().addingTimeInterval(3600)
    require(!MailReminderPolicy.isFuture(Date().addingTimeInterval(-1)) && !MailReminderPolicy.isFuture(Date(timeIntervalSince1970: .infinity)), "reminder requires finite future date")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
    require(MailReminderPolicy.date(components: DateComponents(year: 2027, month: 3, day: 14, hour: 2, minute: 30), calendar: calendar, now: Date(timeIntervalSince1970: 1_798_761_600)) == nil, "DST nonexistent local time rejected")
    require(MailReminderPolicy.date(components: DateComponents(year: 2027, month: 2, day: 30, hour: 9), calendar: calendar, now: Date(timeIntervalSince1970: 1_798_761_600)) == nil, "invalid calendar day rejected")
    do {
        let (state, store, transport, message) = setup()
        let originalSnooze = message.snoozedUntil
        let first = try await store.set(message, dueDate: due)
        require(transport.current == [first.requestID], "actual transport receives future reminder")
        require(message.snoozedUntil == originalSnooze && state.messageStore.isEmpty && state.accountSessions.isEmpty, "local reminder never mutates server, snooze, list, or session")
        require(first.snapshot.preview.isEmpty && first.snapshot.subject == message.subject, "bounded target snapshot excludes body/preview")
        let reload = PreferenceFile(directory: state.preferences.directory)
        require(reload.value.mailReminders[message.key]?.requestID == first.requestID, "reminder persists and reloads with stable message/account key")
        var secondMessage = message
        secondMessage = MailMessage(accountID: state.accounts[1].id, remoteID: "100", folderID: "200", id: "300", origin: message.origin, subject: "Other", sender: "Other", preview: "", date: Date(), attachment: false, unread: false)
        let other = try await store.set(secondMessage, dueDate: due)
        let edit = try await store.set(message, dueDate: due.addingTimeInterval(60))
        require(edit.requestID != first.requestID && transport.current == [edit.requestID, other.requestID], "edit uniquely replaces only matching account request")
        require(store.message(for: message.key)?.key == message.key, "notification tap resolves persisted snapshot without cache")
        try store.cancel(key: message.key)
        require(store.date(for: message.key) == nil && transport.current == [other.requestID], "cancel persists deletion before removing matching notification")
        require(store.removeAccount(accountID: secondMessage.accountID) && store.removeAccount(accountID: secondMessage.accountID), "account removal is idempotent")
        require(transport.current.isEmpty && state.preferences.value.mailReminders.isEmpty, "account removal removes only its reminder records")
        let legacy = try JSONDecoder().decode(NativePreferences.self, from: Data("{}".utf8))
        require(legacy.mailReminders.isEmpty, "legacy preferences decode without reminder field")
        store.stop()
    } catch { require(false, "reminder CRUD: \(error)") }
    do {
        let (state, store, transport, message) = setup()
        let first = try await store.set(message, dueDate: due)
        transport.allowed = false
        do { try await store.set(message, dueDate: due); require(false, "permission denial surfaces") } catch { require(true, "permission denial surfaces") }
        require(transport.current == [first.requestID] && store.date(for: message.key) == due, "denial preserves existing record and OS request")
        transport.allowed = true; transport.fails = true
        do { try await store.set(message, dueDate: due); require(false, "schedule failure surfaces") } catch { require(true, "schedule failure surfaces") }
        require(transport.current == [first.requestID], "schedule failure never removes old request")
        transport.fails = false; store.saveHook = { false }
        do { try await store.set(message, dueDate: due.addingTimeInterval(90)); require(false, "save failure surfaces") } catch { require(true, "save failure surfaces") }
        require(state.preferences.value.mailReminders[message.key]?.requestID == first.requestID && transport.current == [first.requestID], "save failure rolls back record and cancels only new request")
        do { try store.cancel(key: message.key); require(false, "cancel save failure surfaces") } catch { require(true, "cancel save failure surfaces") }
        require(!store.removeAccount(accountID: message.accountID) && transport.current == [first.requestID], "failed cancellation/account removal keeps OS request and stored record")
        state.preferences.value.notificationsEnabled = false; store.saveHook = nil
        do { try await store.set(message, dueDate: due); require(false, "disabled preference honored") } catch { require(true, "disabled preference honored") }
        store.stop()
        require(transport.current == [first.requestID], "shutdown preserves committed reminders for delivery after quit")
    } catch { require(false, "reminder failure setup: \(error)") }
    // Each race is gated, never timed or dependent on native notifications.
    for action in ["replace", "cancel", "account", "stop"] {
        do {
            let (state, store, transport, message) = setup()
            let gate = ReminderTestGate(); transport.scheduleGate = gate
            let pending = Task { @MainActor in try await store.set(message, dueDate: due) }
            await gate.wait()
            let obsolete = transport.scheduled[0].requestID
            require(transport.current.contains(obsolete), "OS add exists before gated completion")
            transport.scheduleGate = nil
            var replacement: MailReminderRecord?
            switch action {
            case "replace": replacement = try await store.set(message, dueDate: due.addingTimeInterval(60))
            case "cancel": try store.cancel(key: message.key)
            case "account": require(store.removeAccount(accountID: message.accountID), "pending account removal succeeds"); state.accounts.removeAll { $0.id == message.accountID }
            default: store.stop()
            }
            require(!transport.current.contains(obsolete), "\(action) immediately removes uncommitted OS request before callback/quit")
            if let replacement { require(transport.current == [replacement.requestID], "immediate cleanup preserves newer committed request") }
            gate.release()
            do { _ = try await pending.value; require(false, "late \(action) must not commit") } catch { require(true, "late \(action) fenced") }
            require(!transport.current.contains(obsolete), "late \(action) cleans only obsolete request")
            if let replacement {
                require(transport.current == [replacement.requestID] && state.preferences.value.mailReminders[message.key]?.requestID == replacement.requestID, "late old callback cannot cancel or overwrite replacement")
            } else { require(state.preferences.value.mailReminders[message.key] == nil, "late \(action) never resurrects record") }
            store.stop()
        } catch { require(false, "race \(action): \(error)") }
    }
    do {
        let (_, store, transport, message) = setup()
        // Keep the state strongly retained for the duration of the pending operation.
        let (state, permissionStore, permissionTransport, permissionMessage) = setup()
        let gate = ReminderTestGate(); permissionTransport.permissionGate = gate
        let task = Task { @MainActor in try await permissionStore.set(permissionMessage, dueDate: due) }
        await gate.wait(); try permissionStore.cancel(key: permissionMessage.key); gate.release()
        do { _ = try await task.value; require(false, "late permission callback fenced") } catch { require(true, "late permission callback fenced") }
        require(permissionTransport.scheduled.isEmpty && state.preferences.value.mailReminders.isEmpty, "cancel during permission never schedules")
        require(transport.scheduled.isEmpty && store.date(for: message.key) == nil, "fixture default paths make no native requests")
        permissionStore.stop(); store.stop()
    } catch { require(false, "permission race: \(error)") }
}
