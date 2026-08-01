import Foundation
import Observation

/// What gets included when a recording is sent somewhere.
enum PayloadContent: String, Codable, CaseIterable, Identifiable {
    case audioAndTranscript
    case transcriptOnly
    case audioOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .audioAndTranscript: return "Audio + transcript"
        case .transcriptOnly: return "Transcript only"
        case .audioOnly: return "Audio only"
        }
    }

    var includesAudio: Bool { self != .transcriptOnly }
    var includesTranscript: Bool { self != .audioOnly }
}

/// Which engine turns audio into text.
enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    /// Apple's `SpeechAnalyzer`, entirely on device. The default.
    case local
    /// Soniox cloud STT. Higher accuracy and more languages, but audio leaves
    /// the phone — see `Soniox`.
    case soniox

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "On-device (Apple)"
        case .soniox: return "Soniox (cloud)"
        }
    }
}

/// How transcripts are formatted when sent as text.
enum TranscriptFormat: String, Codable, CaseIterable, Identifiable {
    case plain
    case timecoded
    case markdown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: return "Plain text"
        case .timecoded: return "With timecodes"
        case .markdown: return "Markdown"
        }
    }

    /// Extension for a rendered transcript file. Owned by the format rather than
    /// by each destination: `.txt` was previously hardcoded at three separate
    /// call sites (the webhook's `transcript_file`, the folder export, and the
    /// share sheet's temporary file), so adding a format that isn't plain text
    /// meant every one of them silently mislabelled it.
    var fileExtension: String {
        switch self {
        case .plain, .timecoded: return "txt"
        case .markdown: return "md"
        }
    }

    var mimeType: String {
        switch self {
        case .plain, .timecoded: return "text/plain"
        case .markdown: return "text/markdown"
        }
    }

    func render(_ transcript: Transcript, speakerNames: [String: String]? = nil) -> String {
        switch self {
        case .plain: return transcript.plainText
        case .timecoded: return transcript.timecodedText(speakerNames: speakerNames)
        case .markdown: return MarkdownTranscript.render(transcript, speakerNames: speakerNames)
        }
    }

    /// Render with the whole recording available.
    ///
    /// **Prefer this over the transcript-only overload.** Markdown's YAML
    /// frontmatter carries the title, date, category and summaries, none of which
    /// a `Transcript` knows about — so the transcript-only path produces a valid
    /// but frontmatter-less note. The other two formats ignore the difference.
    ///
    /// Returns nil when there's no transcript, which is the caller's cue that
    /// there is nothing to send rather than something empty to send.
    func render(_ recording: Recording) -> String? {
        guard let transcript = recording.transcript else { return nil }
        switch self {
        case .markdown:
            return MarkdownTranscript.render(recording, speakerNames: recording.speakerNames)
        case .plain, .timecoded:
            return render(transcript, speakerNames: recording.speakerNames)
        }
    }
}

/// User configuration for transcription and delivery, persisted in UserDefaults.
///
/// `@Observable` so SwiftUI settings controls bind straight to it; every setter
/// writes through to disk immediately.
/// UserDefaults keys, at file scope so non-main-actor code can reach them too.
enum SettingsKey {
    static let transcribeOnSync = "transcribeOnSync"
    static let liveTranscription = "liveTranscription"
    static let transcriptionEngine = "transcriptionEngine"
    static let transcriptionLocale = "transcriptionLocale"
    static let deleteAfterSync = "deleteFromRecorderAfterSync"
    static let webhookEnabled = "webhookEnabled"
    static let webhookURL = "webhookURL"
    static let webhookSecret = "webhookSecret"
    static let folderEnabled = "folderEnabled"
    static let folderBookmark = "folderBookmark"
    static let autoDeliver = "autoDeliver"
    static let autoOrganize = "autoOrganize"
    static let payloadContent = "payloadContent"
    static let transcriptFormat = "transcriptFormat"
    static let calendarTitles = "calendarTitles"
    static let geotagRecordings = "geotagRecordings"
    static let lowBatteryAlerts = "lowBatteryAlerts"
    static let lowBatteryThreshold = "lowBatteryThreshold"
    static let lowBatteryLatched = "lowBatteryLatched"
    static let sonioxLanguageHints = "sonioxLanguageHints"
    static let sonioxVocabulary = "sonioxVocabulary"
    static let sonioxTranslationTarget = "sonioxTranslationTarget"
    static let shortcutsDataAccessEnabled = "shortcutsDataAccessEnabled"
}

@MainActor
@Observable
final class DeliverySettings {

    static let shared = DeliverySettings()

    private let defaults = UserDefaults.standard

    private typealias Keys = SettingsKey

    /// Thread-safe read for SDK callbacks, which arrive on the SDK's own queues
    /// and so can't touch this main-actor type.
    ///
    /// `UserDefaults` is safe to read from any thread, and `object(forKey:)`
    /// rather than `bool(forKey:)` because the latter returns false for an absent
    /// key — which would silently invert the default.
    nonisolated static var deletesFromRecorderAfterSync: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.deleteAfterSync) as? Bool ?? true
    }

    // MARK: - Transcription

    /// Transcribe automatically as soon as a recording lands on the phone.
    var transcribeOnSync: Bool {
        didSet { defaults.set(transcribeOnSync, forKey: Keys.transcribeOnSync) }
    }

    /// BCP-47 identifier, or nil to follow the system language.
    var transcriptionLocaleIdentifier: String? {
        didSet { defaults.set(transcriptionLocaleIdentifier, forKey: Keys.transcriptionLocale) }
    }

    /// Which engine the user picked. Note this is the *preference*; use
    /// `effectiveTranscriptionEngine` for what will actually run.
    var transcriptionEngine: TranscriptionEngine {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    /// The engine that will actually run. Soniox is only used when it is both
    /// selected *and* has an API key stored; otherwise this falls back to
    /// on-device, so a Soniox preference with no key never blocks transcription.
    /// Runtime failures (network, auth) fall back to `.local` inside the engine
    /// code — this only guards the missing-key case.
    ///
    /// `nonisolated` so the batch transcriber, which runs off the main actor, can
    /// read it. `UserDefaults` and the keychain are both thread-safe.
    nonisolated var effectiveTranscriptionEngine: TranscriptionEngine {
        let preferred = UserDefaults.standard.string(forKey: SettingsKey.transcriptionEngine)
            .flatMap(TranscriptionEngine.init(rawValue:)) ?? .local
        if preferred == .soniox, Soniox.Credentials.hasKey { return .soniox }
        return .local
    }

    /// Transcribe as the conversation happens, from the live Bluetooth stream.
    ///
    /// **Experimental.** `blePcmData` never fires for E2EE recordings, so the
    /// audio is reassembled and decrypted from the raw `bleData` stream instead —
    /// see `LiveStreamAssembler`. Decoding is file-based, so the transcript lands
    /// a few seconds behind the conversation rather than word by word.
    ///
    /// The post-sync pass still runs and still wins: this only ever produces a
    /// transcript marked `isPreview`.
    var liveTranscription: Bool {
        didSet { defaults.set(liveTranscription, forKey: Keys.liveTranscription) }
    }

    /// Delete each recording from the recorder once it is safely on the phone.
    ///
    /// On by default, which keeps the recorder's 64GB from filling up and matches
    /// what the reference app did unconditionally. Turn it off to keep a copy on
    /// the device — at the cost of re-syncing everything to a fresh install,
    /// since Bounce reconciles "still on the recorder" as "not yet synced".
    var deleteFromRecorderAfterSync: Bool {
        didSet { defaults.set(deleteFromRecorderAfterSync, forKey: Keys.deleteAfterSync) }
    }

    var transcriptionLocale: Locale {
        transcriptionLocaleIdentifier.map(Locale.init(identifier:)) ?? .current
    }

    // MARK: - Soniox options

    /// Comma-separated language codes the user expects to speak, e.g. "en, es".
    /// Sent to Soniox as `language_hints`; empty means "follow the transcription
    /// language" like before.
    var sonioxLanguageHintsRaw: String {
        didSet { defaults.set(sonioxLanguageHintsRaw, forKey: Keys.sonioxLanguageHints) }
    }

    /// Comma-separated names/jargon sent to Soniox as `context.terms`, so
    /// domain vocabulary is recognized instead of guessed at.
    var sonioxVocabularyRaw: String {
        didSet { defaults.set(sonioxVocabularyRaw, forKey: Keys.sonioxVocabulary) }
    }

    /// Language code the live preview is translated into (Soniox one-way
    /// translation), or "" for off. Live only — the post-sync transcript stays
    /// in the original language.
    var sonioxTranslationTarget: String {
        didSet { defaults.set(sonioxTranslationTarget, forKey: Keys.sonioxTranslationTarget) }
    }

    /// Parsed hints, readable off the main actor (the Soniox request builders
    /// run on background tasks). Same UserDefaults-direct pattern as
    /// `deletesFromRecorderAfterSync`.
    nonisolated static var sonioxLanguageHints: [String] {
        parseList(UserDefaults.standard.string(forKey: SettingsKey.sonioxLanguageHints))
    }

    nonisolated static var sonioxVocabularyTerms: [String] {
        parseList(UserDefaults.standard.string(forKey: SettingsKey.sonioxVocabulary))
    }

    nonisolated static var sonioxTranslationTargetCode: String? {
        let value = UserDefaults.standard.string(forKey: SettingsKey.sonioxTranslationTarget) ?? ""
        return value.isEmpty ? nil : value
    }

    private nonisolated static func parseList(_ raw: String?) -> [String] {
        raw?.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
    }

    // MARK: - Delivery

    /// Send to every enabled destination once transcription finishes.
    var autoDeliver: Bool {
        didSet { defaults.set(autoDeliver, forKey: Keys.autoDeliver) }
    }

    /// Run the on-device AI pass after each transcription: classify the
    /// recording into a category, title it if untitled, and run that category's
    /// summary templates. See `AutoOrganizer`. On by default — it no-ops on
    /// hardware without Apple Intelligence.
    var autoOrganize: Bool {
        didSet { defaults.set(autoOrganize, forKey: Keys.autoOrganize) }
    }

    var payloadContent: PayloadContent {
        didSet { defaults.set(payloadContent.rawValue, forKey: Keys.payloadContent) }
    }

    var transcriptFormat: TranscriptFormat {
        didSet { defaults.set(transcriptFormat.rawValue, forKey: Keys.transcriptFormat) }
    }

    /// Use an overlapping calendar event's title to name a recording, and its
    /// attendees to suggest speaker names.
    ///
    /// Off by default and **not** flipped on by granting access — reading the
    /// calendar is the kind of thing a user should opt into explicitly, and
    /// permission is requested on first enable rather than at launch.
    var calendarTitles: Bool {
        didSet { defaults.set(calendarTitles, forKey: SettingsKey.calendarTitles) }
    }

    /// Tag recordings with where they were made, and show them on the map in
    /// Library. See `PlaceStore` for which moment each fix is taken at.
    ///
    /// Off by default and gated behind an explicit enable, for the same reason
    /// as `calendarTitles`: location is the most sensitive thing this app can
    /// ask for, and a prompt at launch that the user can't connect to anything
    /// they just did gets denied permanently. Turning it off leaves places
    /// already recorded in place — they are the user's data, and silently
    /// erasing a month of pins because a switch moved would be worse than
    /// leaving them.
    var geotagRecordings: Bool {
        didSet { defaults.set(geotagRecordings, forKey: SettingsKey.geotagRecordings) }
    }

    // MARK: - Low battery

    /// Notify when the connected recorder's battery drops below
    /// `lowBatteryThreshold`. Off by default: it needs notification permission,
    /// and a permission prompt at launch that the user can't connect to anything
    /// they just did gets denied.
    var lowBatteryAlerts: Bool {
        didSet { defaults.set(lowBatteryAlerts, forKey: SettingsKey.lowBatteryAlerts) }
    }

    var lowBatteryThreshold: Int {
        didSet { defaults.set(lowBatteryThreshold, forKey: SettingsKey.lowBatteryThreshold) }
    }

    /// Whether a low-battery episode is already in progress.
    ///
    /// Persisted, not derived: `BatteryAlertLatch` fires on the *first* in-range
    /// reading — so that a recorder already at 15% when the app opens still warns
    /// — and that rule only avoids notifying on every cold launch because this
    /// survives relaunch. It is app state rather than a user preference, but it
    /// lives here because this is the only UserDefaults-backed store in the app.
    var lowBatteryLatched: Bool {
        didSet { defaults.set(lowBatteryLatched, forKey: SettingsKey.lowBatteryLatched) }
    }

    /// Seeds for `AppModel`'s latch, which is built during its own
    /// initialisation — before `DeliverySettings.shared` can safely be touched.
    nonisolated static var lowBatteryThresholdValue: Int {
        UserDefaults.standard.object(forKey: SettingsKey.lowBatteryThreshold) as? Int ?? 20
    }

    nonisolated static var lowBatteryLatchedValue: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.lowBatteryLatched)
    }

    // MARK: - Webhook

    var webhookEnabled: Bool {
        didSet { defaults.set(webhookEnabled, forKey: Keys.webhookEnabled) }
    }

    var webhookURLString: String {
        didSet { defaults.set(webhookURLString, forKey: Keys.webhookURL) }
    }

    /// Sent as `X-Bounce-Secret` so the receiving end can verify the caller.
    ///
    /// Kept in the keychain, not `UserDefaults` — unlike the rest of this class,
    /// which is plain preference state. This authenticates the phone to the
    /// user's own receiving server, so a plaintext copy sitting in an
    /// unencrypted backup or readable via bare filesystem access would let
    /// anyone forge requests to that endpoint. Same `ThisDeviceOnly`,
    /// non-synced pattern as `Soniox.Credentials` and the Plaud account
    /// credentials — `webhookSecretCache` is the stored, `@Observable`-tracked
    /// half of this pair so SwiftUI still sees changes; Keychain has no
    /// observation of its own.
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
                // `webhookSecretCache` above is already updated, so this looks
                // like it worked for the rest of the session — but nothing was
                // actually written, and the next launch reads back whatever was
                // last *persisted*, silently dropping this change. Surfacing the
                // failure matches `APITokenStore.save`, which throws for exactly
                // this reason and whose caller (`DesktopViewSettingsView`) shows
                // the error rather than swallowing it.
                webhookSecretPersistFailed = true
            }
        }
    }
    private var webhookSecretCache: String = ""
    /// Read by `IntegrationsSettingsView` to show a warning when the secret
    /// above didn't actually make it to the keychain.
    private(set) var webhookSecretPersistFailed = false
    private static let webhookSecretKeychainKey = "delivery_webhook_secret"

    var webhookURL: URL? {
        guard webhookEnabled, let url = URL(string: webhookURLString), url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }

    // MARK: - Shortcuts

    /// Gates the Shortcuts/Siri intents that return transcript text or trigger
    /// delivery (`LatestTranscriptIntent`, `TranscriptForRecordingIntent`,
    /// `TranscribeRecordingIntent`, `SendRecordingIntent`) — not
    /// `SyncRecorderIntent`, which returns no data. On by default so existing
    /// automations keep working; a personal automation can run these with the
    /// phone locked and no confirmation UI, so a user who finds that too broad
    /// for what may be confidential recordings can turn it off here.
    var shortcutsDataAccessEnabled: Bool {
        didSet { defaults.set(shortcutsDataAccessEnabled, forKey: Keys.shortcutsDataAccessEnabled) }
    }

    // MARK: - Folder (Files / iCloud Drive)

    var folderEnabled: Bool {
        didSet { defaults.set(folderEnabled, forKey: Keys.folderEnabled) }
    }

    /// Security-scoped bookmark for the chosen folder. A bookmark rather than a
    /// path because the user picks a location outside our sandbox.
    private var folderBookmark: Data? {
        didSet { defaults.set(folderBookmark, forKey: Keys.folderBookmark) }
    }

    /// Remember the folder the user picked in the document picker.
    func setFolder(_ url: URL) {
        folderBookmark = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        folderEnabled = folderBookmark != nil
    }

    func clearFolder() {
        folderBookmark = nil
        folderEnabled = false
    }

    /// Resolve the folder for writing. Caller must balance this with
    /// `stopAccessingSecurityScopedResource()`.
    func resolveFolder() -> URL? {
        guard folderEnabled, let bookmark = folderBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale { setFolder(url) }
        return url.startAccessingSecurityScopedResource() ? url : nil
    }

    var folderName: String? {
        guard folderEnabled, let bookmark = folderBookmark else { return nil }
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return url?.lastPathComponent
    }

    // MARK: - Init

    private init() {
        transcribeOnSync = defaults.object(forKey: Keys.transcribeOnSync) as? Bool ?? true
        liveTranscription = defaults.object(forKey: Keys.liveTranscription) as? Bool ?? true
        transcriptionEngine = defaults.string(forKey: Keys.transcriptionEngine)
            .flatMap(TranscriptionEngine.init(rawValue:)) ?? .local
        transcriptionLocaleIdentifier = defaults.string(forKey: Keys.transcriptionLocale)
        // `object(forKey:)` rather than `bool(forKey:)`: the latter returns false
        // for an absent key, which would silently flip the default to off.
        deleteFromRecorderAfterSync = defaults.object(forKey: Keys.deleteAfterSync) as? Bool ?? true
        autoDeliver = defaults.bool(forKey: Keys.autoDeliver)
        // `object(forKey:)` for the same reason as above — the default is on.
        autoOrganize = defaults.object(forKey: Keys.autoOrganize) as? Bool ?? true
        webhookEnabled = defaults.bool(forKey: Keys.webhookEnabled)
        webhookURLString = defaults.string(forKey: Keys.webhookURL) ?? ""
        webhookSecretCache = Self.loadWebhookSecretMigratingIfNeeded(defaults: defaults)
        folderEnabled = defaults.bool(forKey: Keys.folderEnabled)
        folderBookmark = defaults.data(forKey: Keys.folderBookmark)
        payloadContent = defaults.string(forKey: Keys.payloadContent)
            .flatMap(PayloadContent.init(rawValue:)) ?? .audioAndTranscript
        transcriptFormat = defaults.string(forKey: Keys.transcriptFormat)
            .flatMap(TranscriptFormat.init(rawValue:)) ?? .timecoded
        sonioxLanguageHintsRaw = defaults.string(forKey: Keys.sonioxLanguageHints) ?? ""
        sonioxVocabularyRaw = defaults.string(forKey: Keys.sonioxVocabulary) ?? ""
        sonioxTranslationTarget = defaults.string(forKey: Keys.sonioxTranslationTarget) ?? ""
        // `bool(forKey:)`, which is false for an absent key — correct here, since
        // both of these default OFF. A default-ON Bool needs
        // `object(forKey:) as? Bool ?? true` instead; see the comment above.
        calendarTitles = defaults.bool(forKey: Keys.calendarTitles)
        geotagRecordings = defaults.bool(forKey: Keys.geotagRecordings)
        lowBatteryAlerts = defaults.bool(forKey: Keys.lowBatteryAlerts)
        // Matches `lowBatteryThresholdValue`'s default. Both exist because
        // `AppModel` builds its latch before `shared` is available.
        lowBatteryThreshold = defaults.object(forKey: Keys.lowBatteryThreshold) as? Int ?? 20
        lowBatteryLatched = defaults.bool(forKey: Keys.lowBatteryLatched)
        // `object(forKey:)` — the default is on, so `bool(forKey:)` would flip
        // it for anyone who's never touched this setting.
        shortcutsDataAccessEnabled = defaults.object(forKey: Keys.shortcutsDataAccessEnabled) as? Bool ?? true
    }

    /// One-time move off `UserDefaults`, where this secret used to live in
    /// plaintext. Keychain wins if both exist (it's the current source of
    /// truth); a legacy `UserDefaults` value is copied over once and then
    /// deleted so it doesn't keep sitting there in cleartext alongside it.
    ///
    /// **The delete must only happen after a confirmed-successful write.**
    /// This ran unconditionally in an earlier version of this migration —
    /// deleting the plaintext legacy copy whether or not the keychain write
    /// actually succeeded, which is worse than the bug it was fixing: a
    /// keychain write can legitimately fail (e.g. before first unlock since
    /// boot), and when it did, that version silently lost the secret from
    /// *both* stores in the same call, permanently, with the returned in-memory
    /// value the only copy left — gone the moment the process exits.
    private static func loadWebhookSecretMigratingIfNeeded(defaults: UserDefaults) -> String {
        if let current = KeychainStore.loadData(for: webhookSecretKeychainKey)
            .flatMap({ String(data: $0, encoding: .utf8) }), !current.isEmpty {
            return current
        }
        guard let legacy = defaults.string(forKey: SettingsKey.webhookSecret), !legacy.isEmpty else { return "" }
        do {
            try KeychainStore.saveData(Data(legacy.utf8), for: webhookSecretKeychainKey)
            defaults.removeObject(forKey: SettingsKey.webhookSecret)
        } catch {
            // Leave the legacy UserDefaults copy in place so the next launch
            // gets another chance to migrate it, rather than losing it.
        }
        return legacy
    }

    /// Destinations that are configured and ready.
    ///
    /// **Every case must be gated on its own configuration.** An unconditional
    /// `append` here makes a destination permanently "active", which silently
    /// enrols every auto-delivery in it and makes
    /// `.disabled(activeDestinations.isEmpty)` — the gate on the auto-delivery
    /// toggle in `IntegrationsSettingsView` — dead.
    ///
    /// Task destinations (Reminders, the task calendar) are deliberately *not*
    /// here: they run off action items rather than the recording payload, and
    /// `TaskDestinations` already owns their enablement and permission model.
    var activeDestinations: [Destination] {
        var result: [Destination] = []
        if webhookURL != nil { result.append(.webhook) }
        if folderEnabled { result.append(.folder) }
        return result
    }
}

/// A place a recording can be sent.
enum Destination: String, Identifiable, CaseIterable {
    case webhook
    case folder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .webhook: return "Webhook"
        case .folder: return "Folder"
        }
    }

    var symbolName: String {
        switch self {
        case .webhook: return "antenna.radiowaves.left.and.right"
        case .folder: return "folder"
        }
    }
}
