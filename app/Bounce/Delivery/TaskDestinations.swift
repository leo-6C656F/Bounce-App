import Foundation
import Observation

/// Where an extracted action item goes once Bounce has it.
///
/// Distinct from `Destination` (`DeliverySettings.swift`), which is about
/// *recordings* — audio and transcript, multipart, one send per recording. A task
/// is small structured data and there are many per recording, so the two never
/// share a transport, a payload shape, or an enable flag.
enum TaskDestination: String, CaseIterable, Identifiable {
    /// Apple Reminders, via `RemindersSync`.
    case reminders
    /// A JSON POST per task. See `TaskWebhook`.
    case webhook
    /// A timed Apple Calendar event per task with a resolved due date.
    case calendar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reminders: return "Apple Reminders"
        case .webhook: return "Webhook"
        case .calendar: return "Apple Calendar"
        }
    }

    var symbolName: String {
        switch self {
        case .reminders: return "checklist"
        case .webhook: return "antenna.radiowaves.left.and.right"
        case .calendar: return "calendar"
        }
    }

    /// One line for a settings footer or a summary row.
    var blurb: String {
        switch self {
        case .reminders: return "Mirror tasks into a Reminders list."
        case .webhook: return "POST each task to a URL as JSON."
        case .calendar: return "Put tasks with a resolved date on your calendar."
        }
    }
}

/// Which task destinations are switched on, and the webhook's own configuration.
///
/// UserDefaults-backed, `@Observable`, read straight from views as
/// `TaskDestinations.shared` — the `DeliverySettings` / `RemindersSync` pattern
/// for synchronous local preference state. Everything is **off by default**:
/// each destination writes into something outside Bounce, and none of them
/// should start doing that because the user updated the app.
///
/// ## The three flags are not owned in the same place, on purpose
///
/// This type does **not** mint a second switch for a destination that already
/// has one. `.reminders` is already `RemindersSync.shared.syncEnabled`
/// (`remindersSyncEnabled`), and that setter has behaviour attached — it clears
/// the `forgotten` set so deleted reminders become eligible again. A duplicate
/// toggle here would be a second source of truth that silently disagrees with
/// the first, and worse, would bypass that side effect. So:
///
/// | Destination | Flag lives in | Writable here |
/// |---|---|---|
/// | `.reminders` | `RemindersSync.shared.syncEnabled` | **no** — read-through only |
/// | `.webhook` | here (`taskWebhookEnabled`) | yes |
/// | `.calendar` | here (`taskCalendarEnabled`) | yes |
///
/// `.calendar`'s flag lives here because nothing else owns one yet. If the
/// calendar-writing feature grows its own settings object, it should read this
/// key rather than add a second — same reasoning as above.
///
/// The asymmetry is visible in the UI: the Reminders toggle binds to
/// `RemindersSync.shared`, the other two bind to this. `isEnabled(_:)` exists so
/// everything that only *reads* can stay uniform.
@MainActor
@Observable
final class TaskDestinations {

    static let shared = TaskDestinations()

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// At file scope so the `nonisolated` accessors below and any off-main
    /// caller can reach them without touching this main-actor type.
    enum Key {
        static let webhookEnabled = "taskWebhookEnabled"
        static let webhookURL = "taskWebhookURL"
        static let webhookSecret = "taskWebhookSecret"
        static let calendarEnabled = "taskCalendarEnabled"
        /// `ActionItem.id`s the webhook has already fired for. See
        /// `TaskWebhook.unsent(_:alreadySent:)`.
        static let webhookSentIds = "taskWebhookSentIds"
        /// Owned by `RemindersSync`; mirrored here read-only.
        static let remindersEnabled = "remindersSyncEnabled"
    }

    // MARK: - Webhook

    /// `bool(forKey:)` throughout this type, which is false for an absent key —
    /// correct because every one of these defaults OFF. A default-ON Bool needs
    /// `object(forKey:) as? Bool ?? true` instead; see `DeliverySettings`.
    var webhookEnabled: Bool {
        didSet { defaults.set(webhookEnabled, forKey: Key.webhookEnabled) }
    }

    var webhookURLString: String {
        didSet { defaults.set(webhookURLString, forKey: Key.webhookURL) }
    }

    /// Sent as `X-Bounce-Secret`, the same header the recording webhook uses, so
    /// a receiver can verify both with one check.
    ///
    /// Kept in the keychain, not `UserDefaults` — same reasoning and pattern as
    /// `DeliverySettings.webhookSecret`: this authenticates the phone to the
    /// user's own receiving server, so a plaintext copy is a forgeable-request
    /// risk on any device/backup that can read the sandbox filesystem.
    var webhookSecret: String {
        get { webhookSecretCache }
        set {
            webhookSecretCache = newValue
            do {
                if newValue.isEmpty {
                    KeychainStore.delete(Self.webhookSecretKeychainKey)
                } else {
                    try KeychainStore.saveData(Data(newValue.utf8), for: Self.webhookSecretKeychainKey)
                }
                webhookSecretPersistFailed = false
            } catch {
                // See `DeliverySettings.webhookSecret` for why this can't stay
                // a bare `try?` — `webhookSecretCache` already updated above
                // looks like success for the rest of this session, but the
                // nonisolated `webhookSecret` reader below (used by the
                // off-main-actor webhook sender) reads straight from the
                // keychain, live, on every send — so a failed write here isn't
                // just a "wrong value on next launch" bug, it's an
                // immediately-wrong value for the very next webhook POST.
                webhookSecretPersistFailed = true
            }
        }
    }
    private var webhookSecretCache: String = ""
    private(set) var webhookSecretPersistFailed = false
    private static let webhookSecretKeychainKey = "task_webhook_secret"

    /// Non-nil only when the destination is switched on *and* the URL parses as
    /// http(s) — mirrors `DeliverySettings.webhookURL`, so "configured" means the
    /// same thing for both webhooks.
    var webhookURL: URL? { Self.parseURL(webhookURLString, enabled: webhookEnabled) }

    // MARK: - Calendar

    var calendarEnabled: Bool {
        didSet { defaults.set(calendarEnabled, forKey: Key.calendarEnabled) }
    }

    // MARK: - Reminders (read-through)

    /// `RemindersSync.shared.syncEnabled`, read from its key rather than from the
    /// object so this type stays compilable without EventKit. **Read-only** — set
    /// `RemindersSync.shared.syncEnabled` instead, which also handles permission
    /// and the `forgotten` reset.
    var remindersEnabled: Bool { defaults.bool(forKey: Key.remindersEnabled) }

    // MARK: - Reads

    func isEnabled(_ destination: TaskDestination) -> Bool {
        switch destination {
        case .reminders: return remindersEnabled
        case .webhook: return webhookEnabled
        case .calendar: return calendarEnabled
        }
    }

    /// Switched-on destinations in declaration order, for a settings summary.
    /// Note this is "on", not "ready": the webhook can be on with an unparseable
    /// URL, which `webhookURL` is the check for.
    var enabled: [TaskDestination] {
        TaskDestination.allCases.filter(isEnabled)
    }

    // MARK: - Off-main reads
    //
    // The webhook send runs off the main actor (it is called from the transcription
    // queue, like the Soniox request builders), so it can't touch the properties
    // above. `UserDefaults` is safe to read from any thread. Same pattern as
    // `DeliverySettings.sonioxLanguageHints` and friends.

    nonisolated static var isWebhookEnabled: Bool {
        UserDefaults.standard.bool(forKey: Key.webhookEnabled)
    }

    nonisolated static var isCalendarEnabled: Bool {
        UserDefaults.standard.bool(forKey: Key.calendarEnabled)
    }

    nonisolated static var areRemindersEnabled: Bool {
        UserDefaults.standard.bool(forKey: Key.remindersEnabled)
    }

    nonisolated static func isEnabled(_ destination: TaskDestination) -> Bool {
        switch destination {
        case .reminders: return areRemindersEnabled
        case .webhook: return isWebhookEnabled
        case .calendar: return isCalendarEnabled
        }
    }

    nonisolated static var webhookURL: URL? {
        parseURL(UserDefaults.standard.string(forKey: Key.webhookURL) ?? "", enabled: isWebhookEnabled)
    }

    /// Keychain reads are thread-safe, same as `Soniox.Credentials.apiKey`, so
    /// this can stay `nonisolated` for the off-main-actor webhook sender below.
    nonisolated static var webhookSecret: String {
        KeychainStore.loadData(for: webhookSecretKeychainKey)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private nonisolated static func parseURL(_ string: String, enabled: Bool) -> URL? {
        guard enabled, let url = URL(string: string), url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }

    // MARK: - Init

    private init() {
        webhookEnabled = defaults.bool(forKey: Key.webhookEnabled)
        webhookURLString = defaults.string(forKey: Key.webhookURL) ?? ""
        webhookSecretCache = Self.loadWebhookSecretMigratingIfNeeded(defaults: defaults)
        calendarEnabled = defaults.bool(forKey: Key.calendarEnabled)
    }

    /// One-time move off `UserDefaults`, where this secret used to live in
    /// plaintext. Keychain wins if both exist; a legacy `UserDefaults` value is
    /// copied over once and then deleted so it doesn't keep sitting there in
    /// cleartext alongside it.
    ///
    /// The delete only happens after a confirmed-successful write — see
    /// `DeliverySettings.loadWebhookSecretMigratingIfNeeded` for why an
    /// unconditional delete here is a real, previously-shipped bug: a keychain
    /// write can fail, and deleting the plaintext copy regardless loses the
    /// secret from both stores at once, permanently.
    private static func loadWebhookSecretMigratingIfNeeded(defaults: UserDefaults) -> String {
        if let current = KeychainStore.loadData(for: webhookSecretKeychainKey)
            .flatMap({ String(data: $0, encoding: .utf8) }), !current.isEmpty {
            return current
        }
        guard let legacy = defaults.string(forKey: Key.webhookSecret), !legacy.isEmpty else { return "" }
        do {
            try KeychainStore.saveData(Data(legacy.utf8), for: webhookSecretKeychainKey)
            defaults.removeObject(forKey: Key.webhookSecret)
        } catch {
            // Leave the legacy copy for the next launch to retry.
        }
        return legacy
    }
}

/// The per-task webhook: one JSON POST per action item.
///
/// A sibling of `DeliveryService.postWebhook`, not a copy of it. Same
/// `X-Bounce-Secret` header, same "flat and snake_cased so a no-code tool can map
/// it" spirit, same http-status failure. What differs, and why:
///
/// - **JSON, not `multipart/form-data`.** Multipart exists in the recording path
///   because that request carries an audio file. A task is a handful of strings;
///   a body a receiver can `JSON.parse` beats three form parts it has to reassemble.
/// - **Many sends per recording, not one.** Hence the fire-once bookkeeping in
///   `unsent(_:alreadySent:)` — a task must not re-POST on every re-transcription.
///
/// ## The payload never contains the transcript
///
/// Not an omission — a boundary. This webhook fires once per *task*, so a meeting
/// that yields twelve action items makes twelve requests. If each carried the
/// transcript, a feature the user turned on to get tasks into their tracker would
/// quietly become a bulk transcript export, twelve copies over. The recording
/// reference (`recording.id` and `recording.api_path`) is enough for a receiver
/// that legitimately wants the text to come and ask for it over the local API,
/// authenticated, once.
///
/// Two consequences that look like bugs and aren't:
///
/// - **`recording.title` is omitted when the recording is untitled**, rather than
///   sent as "Untitled Recording" or filled in from `Recording.displayTitle`.
///   `displayTitle` falls back to *the first seven words of the transcript*, which
///   would leak transcript text through the title field on exactly the recordings
///   the auto-organize pass failed to name. `tools/task-destinations-tests` asserts
///   this.
/// - `calendarAttendees` and `summaries` are absent for the same reason: personal
///   data that this destination has no need for.
enum TaskWebhook {

    // MARK: - Errors

    enum Failure: LocalizedError {
        case notConfigured
        case encodingFailed
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "The task webhook isn't set up yet."
            case .encodingFailed:
                return "Couldn't encode the task as JSON."
            case .http(let code, let body):
                let detail = body.isEmpty ? "" : " \(body.prefix(200))"
                return "The task webhook returned HTTP \(code).\(detail)"
            }
        }
    }

    // MARK: - Payload

    /// The JSON body for one task, as a dictionary.
    ///
    /// **Absent fields are omitted, never emitted as null.** A receiver writing
    /// `if (payload.task.owner)` in a no-code tool, or `owner ?? "unassigned"` in
    /// a script, should not have to special-case a null that means exactly what a
    /// missing key means. Emitting null also makes the two indistinguishable from
    /// "the field exists and the user cleared it", which is a distinction this
    /// payload doesn't carry and shouldn't imply.
    ///
    /// Every date is ISO-8601 `.withInternetDateTime` in UTC — never a
    /// locale-formatted string, which a receiver in another locale cannot parse
    /// and which changes shape depending on the phone's region settings.
    static func payload(for item: ActionItem, in recording: Recording) -> [String: Any] {
        payload(for: item, in: recording, dueDate: resolvedDueDate(of: item))
    }

    /// The same payload with the resolved due date supplied explicitly.
    ///
    /// Exists because the AI due-date resolution lands in a different workstream:
    /// `ActionItem` is gaining `var dueDate: Date?`, and until it does
    /// `resolvedDueDate(of:)` has nothing to read. This overload lets the emission
    /// be built and tested now, so when the field arrives the only change is the
    /// one line in `resolvedDueDate(of:)`.
    static func payload(
        for item: ActionItem,
        in recording: Recording,
        dueDate: Date?
    ) -> [String: Any] {
        var task: [String: Any] = [
            "id": item.id,
            "text": item.text,
            "is_done": item.isDone,
            "created_at": iso8601(item.createdAt),
        ]
        if let owner = trimmed(item.owner) { task["owner"] = owner }
        if let dueText = trimmed(item.dueText) { task["due_text"] = dueText }
        if let dueDate { task["due_date"] = iso8601(dueDate) }
        // Seconds, not a timecode string: a receiver that wants "1:32" can format
        // it, whereas one that wants to seek can't parse it back reliably.
        if let offset = item.sourceOffset, offset.isFinite, offset >= 0 {
            task["source_offset_seconds"] = offset
        }
        // Included so a receiver that also watches Apple Reminders can recognise
        // the two as one task instead of creating a duplicate.
        if let reminderId = trimmed(item.reminderId) { task["reminder_id"] = reminderId }

        var source: [String: Any] = [
            "id": recording.id,
            "recorded_at": iso8601(recording.createdAt),
            "duration_seconds": recording.duration,
            // Relative on purpose. The absolute base is the phone's LAN address,
            // which changes with the network, so a receiver joins this onto the
            // `DesktopServer` origin it already knows rather than being handed a
            // URL that was correct once. There is no `bounce://` scheme registered
            // in `Info.plist`, and emitting a deep link that opens nothing would be
            // worse than emitting none.
            "api_path": "/api/recordings/\(recording.id)",
        ]
        // See the type's doc comment: `displayTitle` would substitute transcript
        // text here, so this reads the stored title and omits the placeholder.
        if recording.title != Recording.untitled, let title = trimmed(recording.title) {
            source["title"] = title
        }
        if let category = trimmed(recording.categoryName) { source["category"] = category }

        return [
            // Matches the recording payload's marker. `type` discriminates the two
            // when a user points both webhooks at the same URL.
            "source": "bounce",
            "type": "action_item",
            "task": task,
            "recording": source,
        ]
    }

    /// The serialised body.
    ///
    /// `.sortedKeys` so two payloads diff cleanly — without it `JSONSerialization`
    /// emits dictionary order, which Swift seeds per process, so the same task
    /// would serialise differently on every launch and no byte comparison of two
    /// requests would mean anything. `.prettyPrinted` matches `JSONEncoder.iso8601`,
    /// the recording path's encoder. `.withoutEscapingSlashes` keeps `api_path`
    /// readable rather than `\/api\/recordings\/…`.
    static func body(for item: ActionItem, in recording: Recording) throws -> Data {
        try body(payload(for: item, in: recording))
    }

    static func body(for item: ActionItem, in recording: Recording, dueDate: Date?) throws -> Data {
        try body(payload(for: item, in: recording, dueDate: dueDate))
    }

    static func body(_ payload: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(payload) else { throw Failure.encodingFailed }
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Fire-once bookkeeping

    /// The items that haven't been POSTed yet.
    ///
    /// `alreadySent` holds **`ActionItem.id`s**, and that choice is the whole
    /// design:
    ///
    /// - **An edited task is not re-sent.** `id` survives a re-extraction
    ///   (`ActionItemMerge` rule 2 preserves it) and survives the user retyping
    ///   the text, so neither produces a second POST. That is deliberate. A
    ///   receiver that has already created a ticket cannot tell an "update" POST
    ///   from a new task unless it does its own upsert on `task.id`, and the
    ///   failure mode of guessing wrong is a duplicate task in the user's tracker
    ///   — which is worse than a stale one, because a stale task is merely out of
    ///   date while a duplicate has to be found and deleted, in a system Bounce
    ///   can't reach. It also matches how `RemindersSync` treats text: written at
    ///   create, never updated, for the same reason.
    ///   The escape hatch is on the receiver's side and costs nothing: `task.id`
    ///   is stable, so a receiver that *wants* updates can upsert on it the day we
    ///   add an update trigger.
    /// - Keying on the text instead would invert this — every edit, every model
    ///   rephrasing, every stray full stop would look like a new task.
    ///
    /// Also dropped: items whose text normalises to nothing (the same guard
    /// `ActionItemMerge.merged` applies — a task with no letters or digits in it
    /// isn't a task), and duplicate ids within one batch.
    ///
    /// **Only tasks the user has pushed are sent.** `pushRequested` is the same
    /// gate the Reminders and Calendar planners apply: extraction proposes tasks,
    /// and a task webhook is a write into someone else's system, so nothing goes
    /// out until the user explicitly pushes the task. An un-pushed candidate is
    /// dropped here rather than at each call site, so every webhook path inherits
    /// the rule.
    ///
    /// Completed items are **not** filtered. A pushed task the user ticked before
    /// the first send still gets sent, carrying `is_done: true`; whether that
    /// becomes a closed ticket or nothing at all is the receiver's call, and
    /// silently dropping it would mean a task that existed left no trace anywhere.
    static func unsent(_ items: [ActionItem], alreadySent: Set<String>) -> [ActionItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard item.pushRequested else { return false }
            guard !alreadySent.contains(item.id) else { return false }
            guard !ActionItemMerge.normalisedKey(item.text).isEmpty else { return false }
            return seen.insert(item.id).inserted
        }
    }

    // MARK: - Sent-id store
    //
    // Persisted here rather than on `ActionItem` because that type is stored in
    // `library.json` and adding a field to it is a decode-compat change; this is
    // delivery bookkeeping, not part of the task.

    /// Most recent ids kept. Ids are UUID strings (~37 bytes), so this caps the
    /// store at roughly 75 KB. Eviction is FIFO and can in principle let a very
    /// old task fire twice — only if it is still in the library *and* something
    /// re-processes it after 5,000 newer tasks have gone out, which is a better
    /// trade than an unbounded UserDefaults key growing for the life of the app.
    static let sentIdLimit = 5_000

    /// Serialises the read-modify-write in `markSent`. The send path is already
    /// serial (it runs inside the transcription queue), but a lost update here
    /// means a duplicate POST, and a lock is cheaper than relying on that.
    private static let sentLock = NSLock()

    nonisolated static func sentTaskIds(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: TaskDestinations.Key.webhookSentIds) ?? [])
    }

    /// Stored as an ordered array, not a set, because the order *is* the eviction
    /// policy — a `Set` round-tripped through UserDefaults has no oldest element.
    nonisolated static func markSent(_ ids: [String], in defaults: UserDefaults = .standard) {
        guard !ids.isEmpty else { return }
        sentLock.lock()
        defer { sentLock.unlock() }
        var stored = defaults.stringArray(forKey: TaskDestinations.Key.webhookSentIds) ?? []
        var known = Set(stored)
        for id in ids where known.insert(id).inserted { stored.append(id) }
        if stored.count > sentIdLimit { stored.removeFirst(stored.count - sentIdLimit) }
        defaults.set(stored, forKey: TaskDestinations.Key.webhookSentIds)
    }

    /// Forget everything that has been sent, so the next pass re-POSTs. For a
    /// "resend all" affordance and for the erase-recordings path.
    nonisolated static func clearSentTaskIds(in defaults: UserDefaults = .standard) {
        sentLock.lock()
        defer { sentLock.unlock() }
        defaults.removeObject(forKey: TaskDestinations.Key.webhookSentIds)
    }

    // MARK: - Sending

    /// The request one task produces, built without sending it. Separated so the
    /// headers and body are checkable, and so a "Send test task" button can show
    /// the user exactly what will go out.
    static func request(
        for item: ActionItem,
        in recording: Recording,
        url: URL,
        secret: String
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 60s, not the recording webhook's 300s: that budget is sized for an audio
        // upload, and a few KB of JSON hanging for five minutes is a stall, not a
        // slow transfer.
        request.timeoutInterval = 60
        if !secret.isEmpty {
            request.setValue(secret, forHTTPHeaderField: "X-Bounce-Secret")
        }
        request.httpBody = try body(for: item, in: recording)
        return request
    }

    /// POST one task. `nonisolated` and settings-reading, so it can be called from
    /// the transcription queue without hopping to the main actor.
    nonisolated static func send(_ item: ActionItem, in recording: Recording) async throws {
        guard let url = TaskDestinations.webhookURL else { throw Failure.notConfigured }
        let request = try request(for: item, in: recording, url: url, secret: TaskDestinations.webhookSecret)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// What one pass over a recording's tasks did.
    struct SendOutcome {
        /// `ActionItem.id`s that got a 2xx. Already recorded in the sent-id store.
        var sent: [String] = []
        /// Ids that failed, with why. Left unrecorded, so the next pass retries.
        var failed: [(id: String, error: Error)] = []

        var isEmpty: Bool { sent.isEmpty && failed.isEmpty }
    }

    /// Send every not-yet-sent task on a recording, serially, and record the
    /// successes.
    ///
    /// A no-op when the destination is off or unconfigured — the same silent-skip
    /// posture as `AutoOrganizer`'s guards, because a webhook the user hasn't set
    /// up is not an error to surface after a transcription finishes.
    ///
    /// Serial rather than a task group: these are writes into someone else's
    /// system, ordered the way the tasks appear in the recording, and a receiver
    /// that rate-limits shouldn't be hit with twelve concurrent POSTs. Failures
    /// don't stop the rest, matching `deliverToAllDestinations`.
    @discardableResult
    nonisolated static func sendPendingTasks(in recording: Recording) async -> SendOutcome {
        var outcome = SendOutcome()
        guard TaskDestinations.webhookURL != nil else { return outcome }
        let pending = unsent(recording.actionItems ?? [], alreadySent: sentTaskIds())
        guard !pending.isEmpty else { return outcome }

        for item in pending {
            do {
                try await send(item, in: recording)
                outcome.sent.append(item.id)
            } catch {
                outcome.failed.append((id: item.id, error: error))
            }
        }
        markSent(outcome.sent)
        return outcome
    }

    // MARK: - Helpers

    /// Nil for nil, nil for whitespace-only, trimmed otherwise — so a field the
    /// model returned as `" "` is omitted rather than sent as a blank string the
    /// receiver has to trim itself.
    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// UTC, `.withInternetDateTime` — e.g. `2026-07-31T14:05:00Z`.
    ///
    /// A `static let` configured once and never mutated. Apple's date formatters
    /// are safe to *use* concurrently in that state, and this is read from the
    /// send path off the main actor.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func iso8601(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// The task's resolved deadline.
    ///
    /// `ActionItem.dueDate` is the deadline `DueDateResolver` validated from the
    /// spoken phrase — nil unless a real date was stated and survived validation,
    /// so a fabricated or implausible date never reaches the payload. Everything
    /// downstream of it — the `due_date` key, the omit-when-absent rule, the
    /// ISO-8601 shape — is covered by `tools/task-destinations-tests/main.swift`,
    /// both through this accessor and the explicit-`dueDate` overload of
    /// `payload(for:in:dueDate:)`.
    private static func resolvedDueDate(of item: ActionItem) -> Date? {
        item.dueDate
    }
}
