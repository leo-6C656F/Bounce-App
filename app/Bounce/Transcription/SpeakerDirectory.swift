import Foundation
import Observation

/// A name the user has typed into a "Name speakers" sheet, remembered so it can
/// be offered again instead of retyped.
///
/// **This is a name pool, not a voiceprint.** Nothing in this file recognises a
/// voice, and nothing can: Soniox diarization is anonymous — the labels it
/// returns (`"1"`, `"2"`) are assigned per recording in order of first
/// appearance, and there is no voice-profile or enrollment API to attach an
/// identity to. Label `"1"` is not the same person twice. So all this type
/// carries is *what the user has typed before, and how recently* — a prior over
/// a keyboard, not over a voice. See `CLAUDE.md`'s speaker-diarization section.
///
/// Fields are non-optional, unlike new fields on `Recording` (plan
/// Read-this-first #1). The reason that rule exists is that a throwing decode
/// takes the *whole* stored list down — and here that list is a suggestion pool
/// that `SpeakerSuggestions.decode` degrades to empty. The user retypes six
/// names once; they don't lose a library.
struct KnownSpeaker: Codable, Hashable, Identifiable {

    let id: String
    /// The spelling the user typed most recently. See
    /// `SpeakerSuggestions.applying(name:to:now:)` for why the newest wins.
    var name: String
    var lastUsed: Date
    var useCount: Int

    init(id: String = UUID().uuidString, name: String, lastUsed: Date, useCount: Int = 1) {
        self.id = id
        self.name = name
        self.lastUsed = lastUsed
        self.useCount = useCount
    }
}

/// The pure half of the speaker directory: ranking, dedupe, decode, and the
/// conservative auto-fill rule.
///
/// Deliberately Foundation-only, non-isolated, and free of `UserDefaults` so it
/// can be compiled and exercised on the Mac by
/// `tools/speaker-directory-tests/main.swift` — the app target is iOS-only (the
/// Plaud frameworks ship an arm64-device slice) and there is no test target.
/// Keep new logic here rather than in `SpeakerDirectory`, which is a thin
/// persistence shell over these functions.
enum SpeakerSuggestions {

    // MARK: - Ranking

    /// Known speakers in the order they should be offered: most recent first,
    /// most used breaking a tie.
    ///
    /// Recency is bucketed into whole 24-hour periods back from `now` rather
    /// than compared as raw timestamps, and that bucketing is the point. Exact
    /// `Date`s never tie, so a raw sort would order today's names by whichever
    /// happened to be tapped last — which is noise. Bucketing lets `useCount`
    /// decide within a day, so the six people in the standup settle into a
    /// stable order instead of reshuffling every time one is named.
    ///
    /// Fixed 86,400-second periods, not `Calendar` days: no locale, no DST, no
    /// time zone, and testable with fixed `timeIntervalSince1970` dates.
    /// A `lastUsed` in the future (clock skew) is treated as "today" rather
    /// than sorting best-of-all.
    ///
    /// `now` is a parameter, not `Date()`, so the ordering is testable.
    static func ranked(_ speakers: [KnownSpeaker], now: Date) -> [KnownSpeaker] {
        speakers.sorted { a, b in
            let aDays = daysAgo(a.lastUsed, from: now)
            let bDays = daysAgo(b.lastUsed, from: now)
            if aDays != bDays { return aDays < bDays }
            if a.useCount != b.useCount { return a.useCount > b.useCount }
            // Name last, so the order is total and stable rather than
            // dependent on the stored array's order.
            return a.name.compare(b.name, options: .caseInsensitive) == .orderedAscending
        }
    }

    private static func daysAgo(_ date: Date, from now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    // MARK: - Auto-fill

    /// Names to pre-fill for a new recording's speakers, or nil for "don't
    /// guess".
    ///
    /// **The names this returns are unconfirmed and must stay that way.** The
    /// caller holds them in view state, shows them greyed with a one-tap
    /// Confirm and a one-tap Clear, and writes them into
    /// `Recording.speakerNames` only once confirmed. A wrong name silently
    /// baked into a transcript — and from there into every share, export and
    /// webhook payload — is worse than no name.
    ///
    /// The rule is deliberately narrow. A pre-fill is offered **only** when the
    /// new recording has the same number of speakers as the previous recording
    /// in the same category *and* every speaker in that one was named. Anything
    /// else returns nil. Matching is by position (`orderedLabels`), which is a
    /// guess about turn-taking order and nothing more — there is no voice
    /// matching available, so a longer chain of inference would just be a
    /// better-dressed guess.
    ///
    /// - Parameters:
    ///   - speakerLabels: the new recording's diarization labels, e.g.
    ///     `["1", "2"]`. Duplicates are ignored. Every key of the returned map
    ///     comes from this array; nothing is invented.
    ///   - previous: the previous same-category recording's
    ///     `Recording.speakerNames` — label → name. Selecting *which* recording
    ///     that is belongs to the caller; this function only compares.
    ///   - previousLabelCount: how many speakers that recording's transcript
    ///     actually had. Passed separately because `previous` only contains the
    ///     labels that were named, so its count can't tell "all three named"
    ///     from "one of three named".
    static func autoFill(
        speakerLabels: [String],
        previous: [String: String]?,
        previousLabelCount: Int
    ) -> [String: String]? {
        guard let previous, !previous.isEmpty, previousLabelCount > 0 else { return nil }

        let labels = orderedLabels(speakerLabels)
        guard labels.count == previousLabelCount else { return nil }

        // Every name must be present and non-blank. `compactMap` + a count
        // check covers both a missing label and a stored-but-empty one, and
        // also rejects a `previous` carrying more names than the transcript had
        // speakers — all three mean "not the clean case", which means nil.
        let names = orderedLabels(Array(previous.keys)).compactMap { label -> String? in
            let trimmed = previous[label]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard names.count == previousLabelCount else { return nil }

        return Dictionary(uniqueKeysWithValues: zip(labels, names))
    }

    /// Diarization labels in a stable, human order, deduped.
    ///
    /// Numeric labels sort numerically — a lexicographic sort puts `"10"`
    /// before `"2"`, which would pair the wrong names once a meeting has ten
    /// speakers. Non-numeric labels (Soniox can return a name-shaped label)
    /// sort alphabetically, after the numbers.
    private static func orderedLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels
            .filter { seen.insert($0).inserted }
            .sorted { a, b in
                switch (Int(a), Int(b)) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.compare(b, options: .caseInsensitive) == .orderedAscending
                }
            }
    }

    // MARK: - Recording a naming

    /// The pool after the user applies `name` to a speaker.
    ///
    /// Matching is case-insensitive — `compare(options: .caseInsensitive)`, the
    /// same comparison `CategoryStore.category(named:)` uses — so "leo" and
    /// "Leo" are one entry rather than two.
    ///
    /// **On a collision the newly typed spelling wins**, replacing the stored
    /// one while keeping the `id`, `useCount` and position. Retyping a name is
    /// how the user fixes its capitalisation; if the first spelling won, a name
    /// first entered as "leo" could never be corrected without deleting it and
    /// starting its history over. The cost is that a sloppy retype can
    /// downgrade a good spelling — recoverable by typing it properly again,
    /// which is not true the other way round. The `id` is stable so SwiftUI's
    /// `Identifiable` diffing doesn't treat a bump as a new row.
    ///
    /// Blank and whitespace-only names are rejected: they'd offer an empty
    /// suggestion chip, and `AppModel.setSpeakerNames` drops blanks anyway.
    /// Returns `speakers` unchanged in that case, so the caller can skip a
    /// write by comparing.
    static func applying(name: String, to speakers: [KnownSpeaker], now: Date) -> [KnownSpeaker] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return speakers }

        var result = speakers
        if let index = result.firstIndex(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            result[index].name = trimmed
            result[index].lastUsed = now
            result[index].useCount += 1
        } else {
            result.append(KnownSpeaker(name: trimmed, lastUsed: now))
        }
        return result
    }

    // MARK: - Persistence

    /// Decode the stored pool, degrading to empty rather than throwing.
    ///
    /// Absent key (first launch) and unreadable data (a shape change, a partial
    /// write) both mean "no known speakers yet", which is a state the UI
    /// already handles. Same `try?` posture as `CategoryStore`.
    static func decode(_ data: Data?) -> [KnownSpeaker] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([KnownSpeaker].self, from: data)) ?? []
    }

    static func encode(_ speakers: [KnownSpeaker]) -> Data? {
        try? JSONEncoder().encode(speakers)
    }
}

/// The names the user has given speakers before, so they can be suggested
/// instead of retyped.
///
/// Synchronous local preference state with no device round-trip, so per
/// `CLAUDE.md` it follows the `DeliverySettings` pattern — a `@MainActor`
/// `@Observable` singleton over `UserDefaults`, read directly from views as
/// `SpeakerDirectory.shared`, **not** plumbed through `AppModel`. There is no
/// callback to wait for and nothing else in the app reacts to a naming.
///
/// Every decision lives in `SpeakerSuggestions`; this is the persistence shell.
@MainActor
@Observable
final class SpeakerDirectory {

    static let shared = SpeakerDirectory(defaults: .standard)

    private static let defaultsKey = "knownSpeakers"

    private let defaults: UserDefaults

    /// Storage order, which is arrival order. Views want `suggestions`.
    private(set) var speakers: [KnownSpeaker]

    /// Not `private` only so `tools/speaker-directory-tests/main.swift` can
    /// point an instance at a throwaway suite — there is no test target and
    /// `UserDefaults.standard` is shared with the running app. App code uses
    /// `shared`.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        speakers = SpeakerSuggestions.decode(defaults.data(forKey: Self.defaultsKey))
    }

    /// Names to offer, best first. See `SpeakerSuggestions.ranked(_:now:)`.
    ///
    /// When a recording has `calendarAttendees`, offer those *above* these:
    /// they're evidence about this meeting, where this is only a general prior.
    var suggestions: [KnownSpeaker] {
        SpeakerSuggestions.ranked(speakers, now: Date())
    }

    /// Call on every naming — each speaker the user names in the sheet, and
    /// each name applied from a suggestion. Creates the entry or bumps its
    /// recency and count.
    func record(name: String) {
        let updated = SpeakerSuggestions.applying(name: name, to: speakers, now: Date())
        guard updated != speakers else { return }
        speakers = updated
        persist()
    }

    /// Convenience for the "Name speakers" sheet, which saves a whole map at
    /// once. Blank values are simply not recorded.
    func record(names: [String: String]) {
        for name in names.values { record(name: name) }
    }

    func forget(id: String) {
        guard speakers.contains(where: { $0.id == id }) else { return }
        speakers.removeAll { $0.id == id }
        persist()
    }

    /// Empty the pool. Forgetting a name here does not touch any
    /// `Recording.speakerNames` already saved — those are the transcript's, and
    /// deleting the suggestion shouldn't silently rewrite past transcripts.
    func clear() {
        guard !speakers.isEmpty else { return }
        speakers = []
        persist()
    }

    private func persist() {
        defaults.set(SpeakerSuggestions.encode(speakers), forKey: Self.defaultsKey)
    }
}
