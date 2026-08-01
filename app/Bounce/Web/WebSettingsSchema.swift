import Foundation

/// The settings API's field registry, validation, and coercion — with **no app
/// dependencies at all**.
///
/// Foundation only: no `DeliverySettings`, no keychain, no SwiftUI, no main-actor
/// isolation. Everything here operates on `[String: Any]` in and `[String: Any]`
/// out, so `tools/web-settings-tests/main.swift` can compile this one file with
/// `swiftc` and exercise the real rules rather than a copy that drifts. Same split,
/// and the same reason, as `TimelineMap` versus `AudioEditModel`: the app target is
/// iOS-only and cannot build for the Mac, so anything that must be tested has to be
/// reachable without it. `WebSettings` is the thin adapter that binds this to the
/// real settings objects.
///
/// ## Why a registry rather than a hand-written parser
///
/// Every rule the API promises is a property of a field — readable, writable,
/// write-only, its type, its permitted values, its clamp. Writing them as a
/// `switch` over key names spreads those properties across a validator, a snapshot
/// builder, and a docs page that then disagree. Declaring them once means:
///
/// - **An unknown key is a 400 naming it**, because "unknown" is simply "absent
///   from the registry". Silently ignoring an unrecognised key is the failure this
///   is built to avoid — a dropped setting looks exactly like a saved one. It is
///   the same argument `MCPEndpoint`'s tools make with
///   `"additionalProperties": false`.
/// - **A read-only field is rejected rather than ignored**, for the same reason,
///   and with a message that says *why* it was rejected rather than pretending the
///   caller invented it.
/// - **A write-only field can never be returned.** `snapshot(from:)` emits only
///   readable fields and drops everything else it is handed, so a secret cannot
///   reach the wire even if the adapter mistakenly puts one in the dictionary. That
///   guarantee is structural, not a convention someone has to remember.
///
/// ## Secrets
///
/// `transcription.sonioxApiKey` and `delivery.webhookSecret` are `.writeOnly`.
/// **No error message here ever echoes a submitted value**, precisely so a
/// malformed secret can't be reflected back into a browser console or a log — the
/// app has no redaction layer (see CLAUDE.md's credentials rules), so the only safe
/// policy is never to hold one in a string that goes anywhere.
///
/// Being write-only is a property of **this API surface**, not of how either value
/// is stored: the Soniox key is in the keychain, but `webhookSecret` is an ordinary
/// `UserDefaults` string that the phone's own Settings screen displays. Don't read
/// "never returned" as "unrecoverable".
///
/// ## Authentication is the route's job, not this file's
///
/// `/api/settings` is **cookie-only in both directions** — enforced in
/// `WebAPI.route`, not here. Gate 4 refuses a bearer token any `PATCH`, but it
/// permits every `GET`, and the snapshot carries `webhookURL`. Nothing in this file
/// knows about credentials; if the route's check is ever removed, the read leaks.
enum WebSettingsSchema {

    // MARK: - Shape

    enum Access: Equatable {
        /// Returned by GET, accepted by PATCH.
        case readWrite
        /// Returned by GET. Present in a PATCH → 400.
        case readOnly
        /// Accepted by PATCH, **never** returned. Secrets only.
        case writeOnly
    }

    /// One permitted value of an enum field, with the label the phone shows for it.
    ///
    /// The labels are duplicated from the app's own enums because this file can't
    /// import them. `WebSettings` asserts the two agree at startup in debug builds —
    /// see `WebSettings.verifyChoicesMatchApp()`.
    struct Choice: Equatable {
        let value: String
        let label: String

        init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }

        var json: [String: Any] { ["value": value, "label": label] }
    }

    /// The same, for a field whose values are numbers. Kept separate rather than
    /// stringifying the number, so `{"value": 10}` in the options array is the same
    /// JSON type the PATCH must send — a client that round-trips an option back
    /// can't be tripped by `"10"` versus `10`.
    struct IntChoice: Equatable {
        let value: Int
        let label: String

        init(_ value: Int, _ label: String) {
            self.value = value
            self.label = label
        }

        var json: [String: Any] { ["value": value, "label": label] }
    }

    enum Kind {
        case bool
        /// A boolean that can be set to **false** here and never to true.
        ///
        /// `grant` names what turning it on requires. This exists because the
        /// phone's toggles for these never assign `true` directly: they `await` a
        /// permission request and store whatever was *granted*
        /// (`RecorderSettingsView.swift:64` for calendar, `:106` for
        /// notifications), on the principle that a toggle left on when it can't do
        /// anything is a control that lies. A raw PATCH to `true` would walk past
        /// the prompt and produce exactly that. Turning one **off** needs no
        /// permission, so that direction stays open.
        case permissionBool(grant: String)
        case string
        /// A string or an explicit JSON `null`. `blankIsNull` folds `""` into
        /// `null` on input, so the two ways a client can say "unset" normalise to
        /// one — the same normalisation the phone's picker does when it maps its
        /// empty tag back to `nil`.
        case nullableString(blankIsNull: Bool)
        /// A string drawn from a fixed set.
        case choice([Choice])
        /// A number drawn from a fixed set. **Not a range**: see
        /// `lowBatteryThresholdChoices` for why a clamp is the wrong shape here.
        case intChoice([IntChoice])
        /// A string that must parse as an http(s) URL when non-empty.
        case url
        /// A fixed `[{value,label}]` array. Always read-only, and its value comes
        /// from this registry rather than from the adapter, so the options a client
        /// is offered and the values validation accepts are the same list.
        case options([Choice])
        /// The same, for an `intChoice` field.
        case intOptions([IntChoice])
        /// A read-only array the adapter supplies, because its contents depend on
        /// runtime state rather than on the registry.
        case array
    }

    struct Field {
        let section: String
        let name: String
        let kind: Kind
        let access: Access

        var path: String { "\(section).\(name)" }

        /// Whether the registry, rather than the adapter, provides the value.
        var isOptionsArray: Bool {
            switch kind {
            case .options, .intOptions: return true
            default: return false
            }
        }
    }

    // MARK: - Permitted values

    /// `TranscriptionEngine`.
    static let engineChoices = [
        Choice("local", "On-device (Apple)"),
        Choice("soniox", "Soniox (cloud)"),
    ]

    /// `PayloadContent`.
    static let payloadContentChoices = [
        Choice("audioAndTranscript", "Audio + transcript"),
        Choice("transcriptOnly", "Transcript only"),
        Choice("audioOnly", "Audio only"),
    ]

    /// `TranscriptFormat`.
    static let transcriptFormatChoices = [
        Choice("plain", "Plain text"),
        Choice("timecoded", "With timecodes"),
        Choice("markdown", "Markdown"),
    ]

    /// `DeliverySettings.lowBatteryThreshold` — **exactly** the three values the
    /// phone's picker offers (`RecorderSettingsView.swift:119`).
    ///
    /// A range with a clamp would be the obvious shape and it is the wrong one: a
    /// SwiftUI `Picker` whose selection isn't one of its tags renders as a **blank
    /// row**, silently, with no error. So a `15` accepted here — however reasonable
    /// as a percentage — breaks the phone's own settings screen for a value the
    /// user can then neither see nor correct. That argument generalises to every
    /// enum in this registry, which is why none of them are open sets.
    static let lowBatteryThresholdChoices = [
        IntChoice(10, "10%"),
        IntChoice(20, "20%"),
        IntChoice(30, "30%"),
    ]

    /// Live-translation targets — `""` for off, plus the codes
    /// `TranscriptionSettingsView.translationLanguages`
    /// (`TranscriptionSettingsView.swift:384`) offers. The common cases, not
    /// Soniox's full list.
    ///
    /// **This copy has no compile-time tie to its source**, unlike the three enums
    /// below it: `translationLanguages` is a `private static let` inside a view, so
    /// `WebSettings.verifyChoicesMatchApp()` can't reach it. Widening one list means
    /// widening the other by hand.
    static let translationLanguageCodes = [
        "en", "es", "fr", "de", "it", "pt", "nl",
        "zh", "ja", "ko", "ar", "hi", "ru",
    ]

    /// Labels are resolved through `Locale`, exactly as the phone's picker does, so
    /// the browser and Settings name a language the same way.
    static let translationChoices: [Choice] =
        [Choice("", "Off")]
        + translationLanguageCodes.map {
            Choice($0, Locale.current.localizedString(forLanguageCode: $0) ?? $0)
        }

    // MARK: - The registry

    /// Section order is the order the iOS settings pages are listed in, so the two
    /// surfaces read the same way.
    static let sections = ["transcription", "ai", "delivery", "recorder"]

    static let fields: [Field] = [
        // MARK: transcription
        Field(section: "transcription", name: "engine",
              kind: .choice(engineChoices), access: .readWrite),
        // What will actually run — `.soniox` only when it is both selected and a
        // key is stored. Derived, so writing it would be meaningless.
        Field(section: "transcription", name: "effectiveEngine",
              kind: .string, access: .readOnly),
        Field(section: "transcription", name: "engineOptions",
              kind: .options(engineChoices), access: .readOnly),
        // Whether a Soniox key exists — never the key itself.
        Field(section: "transcription", name: "sonioxKeySet",
              kind: .bool, access: .readOnly),
        Field(section: "transcription", name: "localeIdentifier",
              kind: .nullableString(blankIsNull: true), access: .readWrite),
        Field(section: "transcription", name: "localeLabel",
              kind: .string, access: .readOnly),
        Field(section: "transcription", name: "transcribeOnSync",
              kind: .bool, access: .readWrite),
        Field(section: "transcription", name: "liveTranscription",
              kind: .bool, access: .readWrite),
        Field(section: "transcription", name: "sonioxLanguageHints",
              kind: .string, access: .readWrite),
        Field(section: "transcription", name: "sonioxVocabulary",
              kind: .string, access: .readWrite),
        Field(section: "transcription", name: "sonioxTranslationTarget",
              kind: .choice(translationChoices), access: .readWrite),
        Field(section: "transcription", name: "sonioxTranslationTargetOptions",
              kind: .options(translationChoices), access: .readOnly),
        // Write-only. An empty string clears the stored key.
        Field(section: "transcription", name: "sonioxApiKey",
              kind: .string, access: .writeOnly),

        // MARK: ai
        Field(section: "ai", name: "autoOrganize", kind: .bool, access: .readWrite),
        // Off-only: enabling needs FULL calendar access, and the phone stores
        // whatever `CalendarMatcher.requestAccess()` granted rather than what the
        // user tapped (`RecorderSettingsView.swift:64`).
        Field(section: "ai", name: "calendarTitles",
              kind: .permissionBool(grant: "full calendar access"), access: .readWrite),
        // Off-only for the same reason again: enabling needs location permission,
        // which only the phone can ask for, and `IntegrationsSettingsView` stores
        // what was granted rather than what was tapped.
        Field(section: "ai", name: "geotagRecordings",
              kind: .permissionBool(grant: "location permission"), access: .readWrite),
        // Apple Intelligence is a runtime capability check, not an OS version — see
        // `TranscriptQA`. Both of these are facts about the hardware.
        Field(section: "ai", name: "appleIntelligenceAvailable",
              kind: .bool, access: .readOnly),
        Field(section: "ai", name: "appleIntelligenceReason",
              kind: .nullableString(blankIsNull: false), access: .readOnly),

        // MARK: delivery
        Field(section: "delivery", name: "autoDeliver", kind: .bool, access: .readWrite),
        Field(section: "delivery", name: "payloadContent",
              kind: .choice(payloadContentChoices), access: .readWrite),
        Field(section: "delivery", name: "payloadContentOptions",
              kind: .options(payloadContentChoices), access: .readOnly),
        Field(section: "delivery", name: "transcriptFormat",
              kind: .choice(transcriptFormatChoices), access: .readWrite),
        Field(section: "delivery", name: "transcriptFormatOptions",
              kind: .options(transcriptFormatChoices), access: .readOnly),
        // Destinations that are configured and ready, as `[{value,label}]`. Present
        // because "Send automatically" is meaningless with none — the phone disables
        // the toggle on exactly this (`DeliverySettingsView.swift:18`) — and a client
        // can't derive it: `folderEnabled` is visible here but the webhook's
        // readiness is `enabled && URL parses`, which is a rule, not a field.
        Field(section: "delivery", name: "activeDestinations", kind: .array, access: .readOnly),
        Field(section: "delivery", name: "webhookEnabled", kind: .bool, access: .readWrite),
        Field(section: "delivery", name: "webhookURL", kind: .url, access: .readWrite),
        // **`DeliverySettings.webhookSecret` — the recording-delivery webhook, and
        // only that one.** There is a second, unrelated secret for the per-task
        // webhook (`TaskDestinations.webhookSecret`,
        // `Delivery/TaskDestinations.swift:113`), which has its own URL and its own
        // toggle and is **not** exposed by this API. Both send `X-Bounce-Secret`, so
        // they are easy to confuse and expensive to confuse: writing one meaning the
        // other silently reconfigures a destination the caller wasn't looking at.
        //
        // Write-only, with a read-only "is one set?" companion — the same shape
        // `sonioxApiKey`/`sonioxKeySet` uses. Note that *this* secret is stored in
        // **UserDefaults, not the keychain** (the Soniox key is the keychain one).
        // "Never readable back" is therefore a property of this API surface only,
        // not of how the value is held on the phone.
        Field(section: "delivery", name: "webhookSecret", kind: .string, access: .writeOnly),
        Field(section: "delivery", name: "webhookSecretSet", kind: .bool, access: .readOnly),
        // The folder is a security-scoped bookmark minted by `UIDocumentPicker`,
        // which only exists on the phone. Reporting it and saying plainly that it
        // can't be changed from here beats a write that appears to work and can't.
        Field(section: "delivery", name: "folderEnabled", kind: .bool, access: .readOnly),
        Field(section: "delivery", name: "folderName",
              kind: .nullableString(blankIsNull: false), access: .readOnly),
        Field(section: "delivery", name: "folderEditable", kind: .bool, access: .readOnly),

        // MARK: recorder
        // Preferences only. Nothing from `DeviceSettings` is here: those are
        // recorder-scoped and setting one fires a BLE command, which is a different
        // kind of operation from writing a UserDefaults key and needs a connected
        // device to mean anything.
        Field(section: "recorder", name: "deleteFromRecorderAfterSync",
              kind: .bool, access: .readWrite),
        // Off-only, for the same reason as `calendarTitles`: the phone stores what
        // `NotificationCenterBridge.requestAuthorization()` granted, not what was
        // tapped (`RecorderSettingsView.swift:106`). A denial is permanent from the
        // app's side, so a PATCH to `true` would be a toggle that can never fire.
        Field(section: "recorder", name: "lowBatteryAlerts",
              kind: .permissionBool(grant: "notification permission"), access: .readWrite),
        Field(section: "recorder", name: "lowBatteryThreshold",
              kind: .intChoice(lowBatteryThresholdChoices), access: .readWrite),
        Field(section: "recorder", name: "lowBatteryThresholdOptions",
              kind: .intOptions(lowBatteryThresholdChoices), access: .readOnly),
        // Deliberately absent: `lowBatteryLatched`. It lives in `DeliverySettings`
        // only because that is the app's one UserDefaults-backed store, but it is
        // episode state owned by `BatteryAlertLatch` — exposing it would let a
        // client suppress or re-arm an alert it knows nothing about.
    ]

    static let fieldsByPath: [String: Field] = Dictionary(
        uniqueKeysWithValues: fields.map { ($0.path, $0) })

    /// Paths the adapter must supply a value for in `snapshot(from:)`. Options
    /// arrays are excluded — the registry fills those itself.
    static var suppliedPaths: [String] {
        fields.filter { $0.access != .writeOnly && !$0.isOptionsArray }.map(\.path)
    }

    // MARK: - A validated patch

    enum Value: Equatable {
        case bool(Bool)
        case int(Int)
        case string(String)
        case null
    }

    /// The result of `validate(_:)`: coerced, normalised values keyed by
    /// `"section.name"`.
    ///
    /// Nothing has been written when this is produced — validation is complete
    /// before the first assignment, so a patch with one bad field changes nothing
    /// rather than applying half of itself and then 400ing.
    struct Patch: Equatable {
        let values: [String: Value]

        var isEmpty: Bool { values.isEmpty }
        var paths: [String] { values.keys.sorted() }

        func has(_ path: String) -> Bool { values[path] != nil }

        func bool(_ path: String) -> Bool? {
            if case .bool(let value) = values[path] { return value }
            return nil
        }

        func int(_ path: String) -> Int? {
            if case .int(let value) = values[path] { return value }
            return nil
        }

        /// A non-nullable field's new value, or nil when the patch didn't mention it.
        func string(_ path: String) -> String? {
            if case .string(let value) = values[path] { return value }
            return nil
        }

        /// Outer nil means the patch didn't mention the field; inner nil means it
        /// asked for `null`. The two are different requests and must not collapse.
        func nullableString(_ path: String) -> String?? {
            switch values[path] {
            case .string(let value): return .some(.some(value))
            case .null: return .some(.none)
            default: return .none
            }
        }
    }

    // MARK: - Validation

    /// Validate a sparse patch of the nested wire shape.
    ///
    /// Throws `WebSettingsError` carrying the HTTP status and the message to send.
    /// Keys are visited in sorted order so that a patch with several problems always
    /// reports the same one — an error that changes between identical requests is
    /// miserable to write a client against.
    static func validate(_ patch: [String: Any]) throws -> Patch {
        var out: [String: Value] = [:]

        for sectionName in patch.keys.sorted() {
            guard sections.contains(sectionName) else {
                throw WebSettingsError(
                    400,
                    "Unknown settings section “\(sectionName)”. "
                        + "Sections are: \(sections.joined(separator: ", ")).")
            }
            guard let body = patch[sectionName] as? [String: Any] else {
                throw WebSettingsError(400, "“\(sectionName)” must be an object of settings.")
            }
            for name in body.keys.sorted() {
                let path = "\(sectionName).\(name)"
                guard let field = fieldsByPath[path] else {
                    throw WebSettingsError(
                        400,
                        "Unknown setting “\(path)”. "
                            + "Settings in “\(sectionName)”: \(writableNames(in: sectionName)).")
                }
                guard field.access != .readOnly else {
                    throw WebSettingsError(400, "“\(path)” is read-only and can't be changed.")
                }
                out[path] = try coerce(body[name] ?? NSNull(), as: field)
            }
        }

        return Patch(values: out)
    }

    private static func writableNames(in section: String) -> String {
        fields
            .filter { $0.section == section && $0.access != .readOnly }
            .map(\.name)
            .joined(separator: ", ")
    }

    private static func coerce(_ raw: Any, as field: Field) throws -> Value {
        switch field.kind {
        case .bool:
            guard let value = asBool(raw) else { throw typeError(field, "true or false") }
            return .bool(value)

        case .permissionBool(let grant):
            guard let value = asBool(raw) else { throw typeError(field, "true or false") }
            // The type check comes first deliberately: `{"lowBatteryAlerts": "yes"}`
            // is a different mistake from `{"lowBatteryAlerts": true}` and deserves
            // its own message.
            guard !value else {
                throw WebSettingsError(
                    400,
                    "“\(field.path)” can only be turned off from here. Turning it on "
                        + "requires \(grant), which iOS can only prompt for on the "
                        + "iPhone — use the toggle in Bounce's Settings there.")
            }
            return .bool(false)

        case .string:
            guard let value = raw as? String else { throw typeError(field, "a string") }
            return .string(value)

        case .nullableString(let blankIsNull):
            if raw is NSNull { return .null }
            guard let value = raw as? String else { throw typeError(field, "a string or null") }
            if blankIsNull, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .null
            }
            return .string(value)

        case .choice(let choices):
            // `""` is a real, meaningful value for `sonioxTranslationTarget` ("off"),
            // so it is listed as a choice and quoted here rather than special-cased.
            let permitted = choices.map { $0.value.isEmpty ? "\"\"" : $0.value }
                .joined(separator: ", ")
            guard let value = raw as? String else {
                throw typeError(field, "one of these strings: \(permitted)")
            }
            guard choices.contains(where: { $0.value == value }) else {
                throw WebSettingsError(
                    400, "“\(field.path)” must be one of: \(permitted). Got “\(value)”.")
            }
            return .string(value)

        case .intChoice(let choices):
            let permitted = choices.map { String($0.value) }.joined(separator: ", ")
            guard let value = asInt(raw) else {
                throw typeError(field, "one of these numbers: \(permitted)")
            }
            // Rejected, not clamped or snapped. See `lowBatteryThresholdChoices`:
            // a value outside the set blanks the phone's own picker.
            guard choices.contains(where: { $0.value == value }) else {
                throw WebSettingsError(
                    400, "“\(field.path)” must be one of: \(permitted). Got \(value).")
            }
            return .int(value)

        case .url:
            guard let value = raw as? String else { throw typeError(field, "a URL string") }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty is legal and means "not configured" — `DeliverySettings.webhookURL`
            // already returns nil for it, so clearing the field is how a webhook is
            // switched off without touching the toggle.
            guard !trimmed.isEmpty else { return .string("") }
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty
            else {
                throw WebSettingsError(
                    400,
                    "“\(field.path)” must be an http or https URL, "
                        + "like https://example.com/hook.")
            }
            return .string(trimmed)

        case .options, .intOptions, .array:
            // Unreachable: every one of these is `.readOnly` and the access check
            // above rejects it first. Kept total rather than fatal so a registry
            // edit that forgets the access flag degrades to a 400.
            throw WebSettingsError(400, "“\(field.path)” is read-only and can't be changed.")
        }
    }

    private static func typeError(_ field: Field, _ expected: String) -> WebSettingsError {
        // Never interpolates the submitted value — see this type's doc comment on
        // secrets. The field name and the expected type are enough to fix a client.
        WebSettingsError(400, "“\(field.path)” must be \(expected).")
    }

    // MARK: - JSON scalars

    /// JSON `true` and JSON `1` both arrive from `JSONSerialization` as `NSNumber`,
    /// and `as? Bool` accepts either — so `{"autoDeliver": 1}` would quietly work
    /// while `{"autoDeliver": 2}` would set it to true. The CoreFoundation type id
    /// is the only way to tell a boxed boolean from a boxed integer.
    private static func asBool(_ raw: Any) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    /// Rejects booleans (which bridge to `NSNumber` too) and fractional numbers.
    /// `{"lowBatteryThreshold": 20.5}` is a client bug worth naming rather than
    /// something to round.
    private static func asInt(_ raw: Any) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.rounded() == value,
              value >= Double(Int32.min), value <= Double(Int32.max)
        else { return nil }
        return number.intValue
    }

    // MARK: - Snapshot assembly

    /// Nest a flat `"section.name"` dictionary into the wire shape.
    ///
    /// Three guarantees, all structural rather than conventional:
    ///
    /// - **Write-only fields are never emitted**, so a secret can't reach the wire.
    /// - **Anything not in the registry is dropped**, so neither can a value the
    ///   adapter puts in the dictionary by mistake.
    /// - **Every readable field is present**, so a client never has to distinguish
    ///   "absent" from "off". A path the adapter forgot comes out as JSON `null`,
    ///   which the test harness asserts against.
    static func snapshot(from values: [String: Any]) -> [String: Any] {
        var out: [String: [String: Any]] = [:]
        for section in sections { out[section] = [:] }

        for field in fields where field.access != .writeOnly {
            switch field.kind {
            case .options(let choices):
                out[field.section]?[field.name] = choices.map(\.json)
            case .intOptions(let choices):
                out[field.section]?[field.name] = choices.map(\.json)
            default:
                out[field.section]?[field.name] = values[field.path] ?? NSNull()
            }
        }

        return out.mapValues { $0 as Any }
    }
}

/// A failure from the settings API, carrying the HTTP status and the message to
/// send back.
///
/// Shaped this way so the route is one line:
/// `catch let error as WebSettingsError { return .error(error.status, error.message) }`.
///
/// The message is user-facing and reaches a browser, so it is a plain sentence
/// naming the field — and it never contains a submitted value for a write-only
/// field. See `WebSettingsSchema`'s doc comment.
struct WebSettingsError: Error, Equatable {
    let status: Int
    let message: String

    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}
