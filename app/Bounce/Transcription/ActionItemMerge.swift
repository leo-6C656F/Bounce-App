import Foundation

/// The pure half of action items: folding a fresh extraction into the list a
/// recording already carries, and locating where in the audio an item was said.
///
/// Split out of `ActionItems.swift` — which imports `FoundationModels` for the
/// guided-generation types — so that this logic has no dependency beyond
/// Foundation and can therefore be compiled and exercised on the Mac. See
/// `tools/action-items-tests/main.swift`. The same arrangement as
/// `TranscriptEdit` and `TimelineMap`, and for the same reason: there is no test
/// target and no simulator, so pure logic that can be checked off-device should
/// live somewhere it can be.
///
/// ## Merging, not replacing
///
/// Everywhere else in this pipeline a re-run replaces its previous output:
/// `AutoOrganizer` does `summaries.removeAll { $0.templateId == … }` before
/// appending. Action items cannot work that way, because an item carries state
/// the model doesn't know about — `isDone`. Re-transcribing a recording, or
/// re-running the organize pass after editing a template, must not resurrect
/// three tasks the user ticked off last week.
///
/// So items are matched on their **normalised text** and the existing item wins
/// for everything the user could have touched.
// `ActionItem` lives here, in the pure file, rather than beside the extractor.
// `Recording` stores it, so it has to be compilable without `FoundationModels`
// — otherwise `Recording.swift` stops building standalone and
// `tools/library-decode-tests` can no longer exercise the real model. It was
// briefly stubbed in the merge tests for the same reason; a stub that drifts
// from the type it stands for is worse than no test.

/// One actionable task taken from a recording.
///
/// Stored on `Recording.actionItems` (optional, like every other stored field
/// added after the fact) and aggregated across the library by the Tasks tab. The
/// user can tick an item, edit it, delete it, or add one by hand — which is also
/// the only way items appear at all on hardware without Apple Intelligence.
///
/// ## `dueText` is a phrase, never a `Date`
///
/// The deadline is kept exactly as it was spoken — "by Friday", "end of the
/// month", "before the board meeting" — and is deliberately **not** resolved to a
/// `Date`. The on-device model has no reliable notion of what today is, so any
/// resolution would be a guess; and a guessed date in a task list is worse than
/// a phrase, because a phrase is obviously approximate while a date looks
/// authoritative and can be wrong by a week. If real dates are ever wanted they
/// should be derived at display time from the recording's `createdAt`, with the
/// original phrase kept alongside.
struct ActionItem: Codable, Hashable, Identifiable {
    let id: String
    /// The task itself, short and imperative. Editable by the user; the merge
    /// keys on a normalised form of this (see `ActionItemMerge.normalisedKey`).
    var text: String
    /// Who owes it, as named in the recording. Nil when nobody was named — never
    /// a guess, and never "you".
    var owner: String?
    /// The deadline as spoken. See the note above: not a `Date`, on purpose.
    var dueText: String?
    var isDone: Bool
    let createdAt: Date
    /// Seconds into the recording where this was said, for tap-to-seek. Nil when
    /// the item was added by hand or couldn't be located — see
    /// `ActionItemMerge.offset(matching:in:)`, which is best-effort.
    var sourceOffset: TimeInterval?
    /// The Apple Reminders item this task is mirrored to
    /// (`EKCalendarItem.calendarItemIdentifier`), or nil when it has never been
    /// pushed — or when the reminder was deleted in the Reminders app and the link
    /// was dropped rather than recreated. Optional for the usual decode-compat
    /// reason: `ActionItem` uses synthesised `Codable`, so an absent key would
    /// otherwise fail the decode of the whole library.
    /// The deadline resolved to a real date, or nil when none was stated or the
    /// model's answer failed validation.
    ///
    /// Kept **alongside** `dueText`, not instead of it: "by Friday" is better UI
    /// text than "1 Aug 2026", and if the resolution is wrong the phrase is the
    /// evidence. `dueText` is what a human reads; this is what a reminder, a
    /// calendar event or a webhook consumes.
    ///
    /// Resolution is only possible because the extractor anchors the model on the
    /// recording's own date — the model has no idea what "today" is, but we do.
    /// `DueDateResolver` validates hard and prefers nil to a wrong date.
    var dueDate: Date?
    var reminderId: String?
    /// The Calendar event mirroring this task, when it has a deadline and calendar
    /// delivery is on. Nil when never written, or when the user deleted the event
    /// and the link was dropped rather than recreated.
    var calendarEventId: String?
    /// Whether the user has explicitly approved this task for delivery to the
    /// enabled task destinations (Reminders, Calendar, webhook).
    ///
    /// **This is what makes a task a candidate until the user acts.** Extraction
    /// only ever *proposes* action items; nothing is written to Apple Reminders,
    /// Calendar, or a webhook until the user pushes it, which flips this to true.
    /// The reconciliation planners (`ReminderPlanning`, `CalendarEventPlanning`)
    /// and the task webhook all refuse to *create* anything for an item whose flag
    /// is false — see `ReminderPlanning.plan`. Completion read-back and date
    /// updates for tasks already pushed are unaffected, because a pushed task has
    /// this set.
    ///
    /// Preserved verbatim across a re-extraction, exactly like `isDone`: the merge
    /// keeps every existing item wholesale, so a user's decision to push survives
    /// re-transcription. A freshly extracted item starts false.
    ///
    /// Decoded with `decodeIfPresent ?? false` (see the `Decodable` extension
    /// below) for the usual library decode-compat reason: a library written before
    /// this field existed has no key for it, and a plain `Bool` would fail the
    /// whole decode. A false default is the safe one — an upgrade never
    /// retroactively pushes tasks the user never approved.
    var pushRequested: Bool

    init(
        id: String = UUID().uuidString,
        text: String,
        owner: String? = nil,
        dueText: String? = nil,
        isDone: Bool = false,
        createdAt: Date = Date(),
        sourceOffset: TimeInterval? = nil,
        dueDate: Date? = nil,
        reminderId: String? = nil,
        calendarEventId: String? = nil,
        pushRequested: Bool = false
    ) {
        self.id = id
        self.text = text
        self.owner = owner
        self.dueText = dueText
        self.isDone = isDone
        self.createdAt = createdAt
        self.sourceOffset = sourceOffset
        self.dueDate = dueDate
        self.reminderId = reminderId
        self.calendarEventId = calendarEventId
        self.pushRequested = pushRequested
    }
}

/// Custom decode kept in an extension so the memberwise-style `init` above — the
/// one every test harness and call site constructs `ActionItem` through — is not
/// suppressed. `encode(to:)` stays synthesised, so a freshly written library
/// always carries the key; only *reading* an older one needs the fallback.
extension ActionItem {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        dueText = try container.decodeIfPresent(String.self, forKey: .dueText)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceOffset = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceOffset)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        reminderId = try container.decodeIfPresent(String.self, forKey: .reminderId)
        calendarEventId = try container.decodeIfPresent(String.self, forKey: .calendarEventId)
        // The one field that has to tolerate an absent key.
        pushRequested = try container.decodeIfPresent(Bool.self, forKey: .pushRequested) ?? false
    }

    /// Owner and deadline as one subtitle line, or nil when neither is known.
    /// Display sugar so the row and the Markdown export don't each re-derive it.
    var detail: String? {
        let parts = [owner, dueText].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum ActionItemMerge {

    // MARK: - Merge

    /// The recording's action items after folding in a fresh extraction.
    ///
    /// Rules, in the order they matter:
    ///
    /// 1. **Nothing is ever deleted.** An existing item the extractor no longer
    ///    produces is kept verbatim. The model is not authoritative about the
    ///    user's task list: the item may have been typed by hand (the tab works
    ///    with no Apple Intelligence at all, where *every* item is manual), or
    ///    already ticked, and silently dropping either is unacceptable in a way
    ///    that a stale item simply isn't. Deleting is the user's job, via
    ///    swipe-to-delete.
    /// 2. **A match preserves `id`, `createdAt`, `isDone` and `text`.** `isDone`
    ///    is the point of the whole exercise. `id` matters because the list is
    ///    `Identifiable` and a regenerated id would animate every row as an
    ///    insertion; `text` is preserved so a user's own capitalisation or wording
    ///    isn't churned by a model that phrased it a shade differently — the two
    ///    normalise the same, so any difference is cosmetic by definition.
    /// 3. **A match refreshes `owner`, `dueText` and `sourceOffset`, but only
    ///    where the extraction actually supplies one.** A later pass that failed
    ///    to hear the owner must not erase an owner an earlier pass got right.
    ///    Merging never loses information.
    /// 4. **Two extracted items that normalise the same collapse to one.** The
    ///    first phrasing wins for display; metadata it lacks is backfilled from
    ///    the duplicate rather than thrown away.
    /// 5. **Order is deterministic**: existing items in their existing order,
    ///    then genuinely new items in extraction order. No sorting happens here —
    ///    "open first", "group by recording" and so on are display decisions and
    ///    belong to the view, which can re-sort a stable array. A merge that
    ///    reordered would reshuffle the user's list on every re-transcription.
    ///
    /// An empty `extracted` therefore returns `existing` unchanged, which is what
    /// makes it safe for the caller to treat "the model is unavailable", "the
    /// model failed" and "this recording has no action items" identically.
    static func merged(existing: [ActionItem], extracted: [ActionItem]) -> [ActionItem] {
        // Rule 4: dedupe the extraction before it meets the existing list, so a
        // model that says the same thing twice can't produce two rows.
        var freshOrder: [String] = []
        var fresh: [String: ActionItem] = [:]
        for item in extracted {
            let key = normalisedKey(item.text)
            // An item with no letters or digits in it isn't a task. Dropping it
            // here rather than in the extractor means a hand-built list can't
            // smuggle one in either.
            guard !key.isEmpty else { continue }
            guard var seen = fresh[key] else {
                fresh[key] = item
                freshOrder.append(key)
                continue
            }
            if seen.owner == nil { seen.owner = item.owner }
            if seen.dueText == nil { seen.dueText = item.dueText }
            if seen.sourceOffset == nil { seen.sourceOffset = item.sourceOffset }
            fresh[key] = seen
        }

        var result: [ActionItem] = []
        result.reserveCapacity(existing.count + freshOrder.count)
        var matched = Set<String>()

        // Rules 1–3: every existing item survives, in place.
        for var item in existing {
            let key = normalisedKey(item.text)
            if !key.isEmpty, let update = fresh[key], matched.insert(key).inserted {
                if let owner = update.owner { item.owner = owner }
                if let dueText = update.dueText { item.dueText = dueText }
                if let sourceOffset = update.sourceOffset { item.sourceOffset = sourceOffset }
            }
            result.append(item)
        }

        // Rule 5: then whatever the extraction found that wasn't already there.
        for key in freshOrder where !matched.contains(key) {
            if let item = fresh[key] { result.append(item) }
        }
        return result
    }

    /// The key two items are considered the same by: lower-cased, punctuation
    /// reduced to word boundaries, runs of whitespace collapsed, trimmed.
    ///
    /// So "Email Bob." , "email bob" and "  EMAIL   BOB  " are one item, which is
    /// what stops a re-run duplicating a row over a full stop the model dropped.
    ///
    /// Punctuation becomes a **space** rather than being deleted, so
    /// "follow-up with Ana" and "follow up with Ana" match. The cost is that
    /// elisions split ("Bob's" → "bob s", which no longer matches "bobs"), and
    /// that direction is the right one to lose in: a missed match adds a
    /// duplicate row the user can delete, whereas a false match would silently
    /// merge two different tasks and could mark an undone one as done.
    ///
    /// Symbols are deliberately *not* folded — "$500" keeps its "$" — because
    /// they carry meaning in a task ("+1 the PR", "C++ migration") far more often
    /// than they vary between two phrasings of the same one.
    static func normalisedKey(_ text: String) -> String {
        let separators = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
        let folded = String(text.lowercased().unicodeScalars.map {
            separators.contains($0) ? " " : Character($0)
        })
        return folded.split(separator: " ").joined(separator: " ")
    }

    // MARK: - Locating an item in the audio

    /// Where in the recording an item was most likely said, for tap-to-seek.
    ///
    /// The model is not asked for a timestamp: guided generation will happily
    /// invent a plausible-looking one, and a `TimeInterval` that reads as precise
    /// but is fabricated is worse than no seek at all. So the offset is recovered
    /// afterwards by matching the item's own words back onto the transcript,
    /// which is at least wrong in a way that can be inspected.
    ///
    /// **Best-effort by design.** An action item is a paraphrase ("Send Ana the
    /// budget" for "yeah I'll get that budget over to Ana"), so a miss is normal
    /// and returns nil — the item then simply has no timecode, and the row opens
    /// the recording at the start. Same posture as Phase 11's interpolated split
    /// timings: this drives a convenience, not a contract.
    ///
    /// - Parameters:
    ///   - text: the item text, as it will be stored.
    ///   - segments: the transcript's segments, in order.
    /// - Returns: the `start` of the best-matching segment, or nil when nothing
    ///   matches well enough to be worth offering.
    static func offset(matching text: String, in segments: [TranscriptSegment]) -> TimeInterval? {
        let keywords = Set(keywords(in: text))
        guard !keywords.isEmpty else { return nil }
        // One coincidental word is not evidence — "send" appears in half a
        // meeting. Two is a low bar but a real one, and an item that only *has*
        // one distinctive word has to be matched on it or never at all.
        let needed = min(2, keywords.count)

        var best: (score: Int, start: TimeInterval)?
        for segment in segments {
            let tokens = Set(normalisedKey(segment.text).split(separator: " ").map(String.init))
            let score = keywords.intersection(tokens).count
            guard score >= needed else { continue }
            // Strictly greater, so ties go to the earliest segment: an item is
            // usually agreed before it is recapped, and seeking too early lands
            // the user in the run-up rather than after the fact.
            if let current = best, score <= current.score { continue }
            best = (score, segment.start)
        }
        return best?.start
    }

    /// The words of `text` distinctive enough to match on: four characters or
    /// more, minus a small stop list.
    ///
    /// Four is a blunt filter that removes most function words ("the", "and",
    /// "to", "by", "a") for free; the list then catches the common longer ones
    /// that a task sentence is otherwise full of. Deliberately short — every
    /// entry is a word that can no longer contribute evidence, and over-pruning
    /// turns a findable item into an unfindable one.
    private static func keywords(in text: String) -> [String] {
        normalisedKey(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "will", "that", "this", "then", "with", "have", "need", "needs", "must",
        "should", "going", "about", "from", "them", "their", "your", "make",
        "sure", "also", "next", "before", "after", "into", "each", "over",
        "when", "what", "which", "there", "these", "those", "been", "were",
    ]
}
