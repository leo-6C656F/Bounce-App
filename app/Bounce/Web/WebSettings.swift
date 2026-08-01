import Foundation

/// The settings API's adapter: `WebSettingsSchema`'s pure rules bound to the real
/// settings objects.
///
/// Everything app-shaped lives here — `DeliverySettings`, `Soniox.Credentials`,
/// `TranscriptQA` — and nothing rule-shaped does. The split is what lets
/// `tools/web-settings-tests/main.swift` compile the schema on its own; see that
/// file's header and `WebSettingsSchema`'s doc comment.
///
/// `@MainActor` because `DeliverySettings` is, and because **every handler in
/// `WebAPI` runs on the main actor** — the header comment there explains why
/// (`RecordingStore` has no lock, and `SWIFT_STRICT_CONCURRENCY: minimal` means a
/// handler racing off the main actor compiles clean and fails at runtime).
///
/// ## What a write here does *not* do
///
/// These are plain UserDefaults preferences plus one keychain item. Nothing here
/// touches the recorder: `DeviceSettings` is deliberately absent from the registry
/// because setting one of its properties fires a BLE command, which needs a
/// connected device and has a completely different failure model from writing a
/// preference.
///
/// Nor does it grant permissions. `ai.calendarTitles`, `ai.geotagRecordings` and
/// `recorder.lowBatteryAlerts` can only be switched **off** from here — see `Kind.permissionBool`. iOS can only
/// prompt on the phone, and the phone's toggles store what was granted rather than
/// what was tapped.
///
/// ## Authentication is `WebAPI.route`'s job
///
/// `/api/settings` is cookie-only for **both** verbs. Gate 4 makes the `PATCH`
/// cookie-only on its own, but it lets any bearer token `GET` — and the snapshot
/// carries `webhookURL`. Nothing here checks a credential.
@MainActor
enum WebSettings {

    // MARK: - Read

    /// The full settings snapshot, in the API's nested shape.
    ///
    /// Safe to hand straight to `JSONSerialization`: every value is a `String`,
    /// `Bool`, `Int`, `NSNull`, or an array of `[String: String]`.
    static func snapshot() -> [String: Any] {
        #if DEBUG
        verifyChoicesMatchApp()
        #endif

        let settings = DeliverySettings.shared

        // Apple Intelligence is a runtime capability check, not an OS-version one —
        // the model only exists on A17 Pro / M1-and-later hardware with the feature
        // switched on. `TranscriptQA` is the app's own reading of that, reused here
        // rather than re-derived so the browser and the phone can't disagree about
        // whether AI features are usable. Constructing one is cheap; `WebAPI.ask`
        // does the same.
        let readiness = TranscriptQA().readiness
        let aiReason: Any
        if case .unavailable(let reason) = readiness { aiReason = reason } else { aiReason = NSNull() }

        // The locale that will actually be used — `transcriptionLocale` resolves a
        // nil identifier to `.current`, so the label always describes what will run
        // rather than what was configured. Preformatted here for the same reason
        // every duration in `WebTypes` is: formatting in the client is how the app
        // ended up with four disagreeing timecode formatters.
        let locale = settings.transcriptionLocale
        let localeLabel = Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier

        // Built by assignment rather than as one 25-entry literal: a heterogeneous
        // `[String: Any]` literal that size is a known "expression too complex to be
        // solved in reasonable time" trap, and it fails at the whole-expression level
        // so the error points at nothing useful.
        var values: [String: Any] = [:]

        // MARK: transcription
        values["transcription.engine"] = settings.transcriptionEngine.rawValue
        values["transcription.effectiveEngine"] = settings.effectiveTranscriptionEngine.rawValue
        values["transcription.sonioxKeySet"] = Soniox.Credentials.hasKey
        values["transcription.localeIdentifier"] = orNull(settings.transcriptionLocaleIdentifier)
        values["transcription.localeLabel"] = localeLabel
        values["transcription.transcribeOnSync"] = settings.transcribeOnSync
        values["transcription.liveTranscription"] = settings.liveTranscription
        values["transcription.sonioxLanguageHints"] = settings.sonioxLanguageHintsRaw
        values["transcription.sonioxVocabulary"] = settings.sonioxVocabularyRaw
        values["transcription.sonioxTranslationTarget"] = settings.sonioxTranslationTarget

        // MARK: ai
        values["ai.autoOrganize"] = settings.autoOrganize
        values["ai.calendarTitles"] = settings.calendarTitles
        values["ai.geotagRecordings"] = settings.geotagRecordings
        values["ai.appleIntelligenceAvailable"] = readiness.isReady
        values["ai.appleIntelligenceReason"] = aiReason

        // MARK: delivery
        values["delivery.autoDeliver"] = settings.autoDeliver
        // Same `[{value,label}]` shape as the `*Options` arrays, so a client renders
        // it with the same code — but adapter-supplied, because "active" depends on
        // whether the webhook URL currently parses, not on the registry.
        values["delivery.activeDestinations"] = settings.activeDestinations.map {
            ["value": $0.rawValue, "label": $0.label]
        }
        values["delivery.payloadContent"] = settings.payloadContent.rawValue
        values["delivery.transcriptFormat"] = settings.transcriptFormat.rawValue
        values["delivery.webhookEnabled"] = settings.webhookEnabled
        values["delivery.webhookURL"] = settings.webhookURLString
        // Whether one is set, never the secret. Same shape as `sonioxKeySet`.
        values["delivery.webhookSecretSet"] = !settings.webhookSecret.isEmpty
        values["delivery.folderEnabled"] = settings.folderEnabled
        values["delivery.folderName"] = orNull(settings.folderName)
        // Always false, and reported rather than omitted: the folder is a
        // security-scoped bookmark that only `UIDocumentPicker` on the phone can
        // mint, so a client needs to know the control exists *and* that it can't
        // drive it. Omitting the field would look like the feature is missing.
        values["delivery.folderEditable"] = false

        // MARK: recorder
        values["recorder.deleteFromRecorderAfterSync"] = settings.deleteFromRecorderAfterSync
        values["recorder.lowBatteryAlerts"] = settings.lowBatteryAlerts
        values["recorder.lowBatteryThreshold"] = settings.lowBatteryThreshold

        return WebSettingsSchema.snapshot(from: values)
    }

    // MARK: - Write

    /// Apply a sparse patch and return the fresh snapshot.
    ///
    /// Throws `WebSettingsError` carrying an HTTP status and a message. Validation
    /// runs to completion before the first assignment, so a patch with one bad
    /// field changes nothing — a partially-applied settings write is worse than a
    /// rejected one, because the client's next GET disagrees with the error it just
    /// got.
    ///
    /// **Never log the patch.** It can carry `sonioxApiKey` or `webhookSecret`, and
    /// the app has no redaction layer.
    static func apply(patch raw: [String: Any]) throws -> [String: Any] {
        let patch = try WebSettingsSchema.validate(raw)
        let settings = DeliverySettings.shared

        // Enum values are resolved before anything is written, so a registry that
        // drifted from the app's own cases fails the whole request rather than
        // applying half of it. `verifyChoicesMatchApp` catches that drift in debug
        // builds long before it can happen in the field.
        let engine: TranscriptionEngine? =
            try resolve(patch.string("transcription.engine"), "transcription.engine")
        let payloadContent: PayloadContent? =
            try resolve(patch.string("delivery.payloadContent"), "delivery.payloadContent")
        let transcriptFormat: TranscriptFormat? =
            try resolve(patch.string("delivery.transcriptFormat"), "delivery.transcriptFormat")

        // The keychain first, because it is the only write below that can fail.
        // Everything after this point is a UserDefaults assignment that can't throw,
        // so the all-or-nothing promise above holds.
        if let key = patch.string("transcription.sonioxApiKey") {
            do {
                // An empty string clears the key — `Credentials.save` routes a blank
                // value to `clear()`. That is how a client switches Soniox off
                // without a separate verb.
                try Soniox.Credentials.save(key)
            } catch {
                // No `error` in the message and nothing logged: the only detail worth
                // reporting is that it failed, and anything richer risks the key.
                throw WebSettingsError(500, "Couldn't save the Soniox API key to the keychain.")
            }
        }

        // MARK: transcription
        if let engine { settings.transcriptionEngine = engine }
        if let identifier = patch.nullableString("transcription.localeIdentifier") {
            settings.transcriptionLocaleIdentifier = identifier
        }
        if let value = patch.bool("transcription.transcribeOnSync") {
            settings.transcribeOnSync = value
        }
        if let value = patch.bool("transcription.liveTranscription") {
            settings.liveTranscription = value
        }
        if let value = patch.string("transcription.sonioxLanguageHints") {
            settings.sonioxLanguageHintsRaw = value
        }
        if let value = patch.string("transcription.sonioxVocabulary") {
            settings.sonioxVocabularyRaw = value
        }
        if let value = patch.string("transcription.sonioxTranslationTarget") {
            settings.sonioxTranslationTarget = value
        }

        // MARK: ai
        if let value = patch.bool("ai.autoOrganize") { settings.autoOrganize = value }
        // Only ever `false` — the schema rejects `true` for both permission-coupled
        // toggles, so these two assignments can't grant anything. Written as plain
        // assignments rather than `= false` so the intent stays "apply what the
        // patch said" and the rule lives in exactly one place.
        if let value = patch.bool("ai.calendarTitles") { settings.calendarTitles = value }
        if let value = patch.bool("ai.geotagRecordings") { settings.geotagRecordings = value }

        // MARK: delivery
        if let value = patch.bool("delivery.autoDeliver") { settings.autoDeliver = value }
        if let payloadContent { settings.payloadContent = payloadContent }
        if let transcriptFormat { settings.transcriptFormat = transcriptFormat }
        if let value = patch.bool("delivery.webhookEnabled") { settings.webhookEnabled = value }
        if let value = patch.string("delivery.webhookURL") { settings.webhookURLString = value }
        if let value = patch.string("delivery.webhookSecret") { settings.webhookSecret = value }

        // MARK: recorder
        if let value = patch.bool("recorder.deleteFromRecorderAfterSync") {
            settings.deleteFromRecorderAfterSync = value
        }
        if let value = patch.bool("recorder.lowBatteryAlerts") { settings.lowBatteryAlerts = value }
        if let value = patch.int("recorder.lowBatteryThreshold") {
            // Already validated as one of 10/20/30 — anything else would blank the
            // phone's picker.
            settings.lowBatteryThreshold = value
        }

        return snapshot()
    }

    // MARK: - Serialisation

    /// `GET /api/settings`'s body.
    ///
    /// `[String: Any]` rather than an `Encodable` DTO — unlike `WebTypes`, this
    /// payload's shape *is* the registry, and hand-writing a mirror struct would
    /// guarantee the two disagree the first time a field is added.
    static func snapshotData() -> Data {
        json(snapshot())
    }

    /// `PATCH /api/settings`'s body: the fresh snapshot after the patch applies.
    static func applyData(patch raw: [String: Any]) throws -> Data {
        json(try apply(patch: raw))
    }

    /// `nil` → JSON `null`. Written out rather than `?? NSNull()` inline because
    /// that spelling makes the type checker unify `String?` and `NSNull` at `Any`,
    /// which it manages but slowly, and does so once per call site.
    private static func orNull(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func json(_ object: [String: Any]) -> Data {
        // `.sortedKeys` so the payload is stable between requests — a diffable
        // response is worth the negligible cost, and it makes the browser's
        // change detection honest.
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    // MARK: - Registry ↔ app agreement

    private static func resolve<T: RawRepresentable>(
        _ raw: String?, _ path: String
    ) throws -> T? where T.RawValue == String {
        guard let raw else { return nil }
        guard let value = T(rawValue: raw) else {
            throw WebSettingsError(
                500, "“\(path)” isn't a value this version of Bounce understands.")
        }
        return value
    }

    /// The schema can't import the app's enums, so its `Choice` lists are a copy.
    /// This is the thing that stops the copy rotting: a case added to
    /// `TranscriptionEngine`, `PayloadContent` or `TranscriptFormat` — or a label
    /// reworded in Settings — trips here on the first `GET /api/settings` in a debug
    /// build, rather than shipping an API that rejects a value the phone offers.
    ///
    /// **Two lists can't be checked this way**, because both live as `private static
    /// let` literals inside SwiftUI views with no accessible symbol:
    /// `lowBatteryThresholdChoices` (`RecorderSettingsView.swift:119`) and
    /// `translationChoices` (`TranscriptionSettingsView.swift:384`). Widening either
    /// picker means editing `WebSettingsSchema` by hand. Making them internal
    /// `static let`s on their views would close the gap, but those are the lead's
    /// files.
    #if DEBUG
    private static func verifyChoicesMatchApp() {
        func compare(_ app: [(String, String)], _ schema: [WebSettingsSchema.Choice], _ name: String) {
            let mine = schema.map { ($0.value, $0.label) }
            // `allSatisfy` sees one tuple-of-tuples argument, not two — `$0.0 == $1.0`
            // is a compile error here, not a shorthand.
            guard mine.count == app.count,
                  zip(mine, app).allSatisfy({ pair in pair.0 == pair.1 })
            else {
                assertionFailure(
                    "WebSettingsSchema.\(name) has drifted from the app's enum. "
                        + "App: \(app). Schema: \(mine).")
                return
            }
        }
        compare(
            TranscriptionEngine.allCases.map { ($0.rawValue, $0.label) },
            WebSettingsSchema.engineChoices, "engineChoices")
        compare(
            PayloadContent.allCases.map { ($0.rawValue, $0.label) },
            WebSettingsSchema.payloadContentChoices, "payloadContentChoices")
        compare(
            TranscriptFormat.allCases.map { ($0.rawValue, $0.label) },
            WebSettingsSchema.transcriptFormatChoices, "transcriptFormatChoices")
    }
    #endif
}
