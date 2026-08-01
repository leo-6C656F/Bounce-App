import Foundation

/// Where a recording's title comes from, and whether a calendar event is
/// entitled to supply it — pure, synchronous, Foundation-only.
///
/// This exists because `AutoOrganizer` got the answer wrong in a way that was
/// invisible until it happened on real data: an 8-second "remember to take the
/// trash out" note was titled **"Test Meeting Calendar"**, because a 30-minute
/// event happened to be running at the time. `CalendarMatching.bestMatch` was
/// right — that *is* the overlapping event — but overlapping an event and being a
/// recording *of* it are different claims, and nothing checked the second one.
///
/// Two independent guards, both of which must pass (`acceptsCalendarTitle`):
///
/// 1. **An absolute floor on the recording** (`minimumCalendarRecordingDuration`).
///    Under a minute, a recording is a note, whatever is in the calendar.
/// 2. **A coverage ratio against the event** (`minimumCalendarCoverage`).
///    Below it, the recording is a fragment of the event rather than a record
///    of it.
///
/// Plus a third, non-automatic one the user controls: a category can opt out
/// entirely, so "Reminder" recordings are never named after a meeting even when
/// they do cover it.
///
/// **Declining only costs the title.** The caller still stores
/// `Recording.calendarEventTitle` / `calendarAttendees` for a rejected match, so
/// the association with the meeting survives and only the *naming* falls through
/// to the AI title — which describes what was actually said. That asymmetry is
/// what makes a false rejection cheap and a false acceptance expensive, and it is
/// the reason the thresholds below can afford to be conservative.
///
/// EventKit-free and store-free on purpose: everything here takes plain values,
/// so it compiles and runs on the Mac under `tools/title-selection-tests/`, which
/// is the only automated coverage this app can have.
enum RecordingTitleSelection {

    /// Where a title came from. `.none` means nothing was eligible and the
    /// recording keeps its placeholder.
    enum Source: Equatable {
        /// The user typed a title. Never overwritten, by anything.
        case userTyped
        /// Take the calendar event's title (already part-numbered if needed).
        case calendar(String)
        /// Take the model's title (already composed with the category prefix).
        case ai(String)
        case none
    }

    // MARK: - Thresholds

    /// A recording must cover at least this fraction of the event's duration
    /// before it may take the event's name.
    ///
    /// **10%.** The bound that matters is the *other* error: someone who joins an
    /// hour-long meeting twenty minutes late and records the remaining forty is
    /// genuinely recording that meeting, and stripping their title would be worse
    /// than the bug this fixes. That case scores 67%, and even a ten-minute tail
    /// of an hour scores 17%, so a tenth leaves the honest late start a wide
    /// margin while still rejecting a three-minute aside dropped into a
    /// three-hour "Focus time" block (1.7%). It is deliberately not higher: the
    /// ratio is the weaker of the two guards, present for long events, and the
    /// absolute floor below is what actually kills the reported case.
    static let minimumCalendarCoverage: Double = 0.10

    /// A recording shorter than this never takes a calendar event's title,
    /// whatever the ratio says.
    ///
    /// **60 seconds.** A pure ratio can't see the reported bug: an 8-second note
    /// inside a 20-second calendar block would score 40% and pass. Length is the
    /// signal that actually separates the two behaviours — people speak notes to
    /// themselves in seconds and attend meetings in minutes — and unlike the
    /// ratio it doesn't depend on the event being long. Nobody's recording *of* a
    /// meeting is fifty seconds; a great many notes are.
    static let minimumCalendarRecordingDuration: TimeInterval = 60

    // MARK: - Calendar eligibility

    /// Whether a calendar event's title should name this recording.
    ///
    /// Assumes `event` already won `CalendarMatching.bestMatch` — this is the
    /// second question ("is this recording *of* that event?"), not a re-run of
    /// the first ("which event is nearest?").
    static func acceptsCalendarTitle(
        recordingStart: Date,
        recordingDuration: TimeInterval,
        event: CandidateEvent,
        categoryAllowsCalendarTitles: Bool,
        minimumCoverage: Double = minimumCalendarCoverage,
        minimumDuration: TimeInterval = minimumCalendarRecordingDuration
    ) -> Bool {
        // The user's own rule, and the only one of the three they can see. It
        // comes first because it is not a heuristic: "never name a Reminder after
        // a meeting" is an instruction, not an estimate, so no amount of coverage
        // may override it.
        guard categoryAllowsCalendarTitles else { return false }

        // A blank event title is not a title. `bestMatch` filters these already;
        // repeated here so the rule holds for any caller.
        guard !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        guard recordingDuration >= minimumDuration else { return false }

        return coverage(
            recordingStart: recordingStart,
            recordingDuration: recordingDuration,
            of: event) >= minimumCoverage
    }

    /// The fraction of the event the recording actually overlaps, `0...1`.
    ///
    /// Measured as real overlap rather than raw recording length, so a recording
    /// that merely sits *near* an event — admitted by `CalendarMatching`'s ±5
    /// minute tolerance but not actually inside it — scores 0 rather than
    /// scoring on its own length. Clipped at the event's edges, so a recording
    /// running an hour past a ten-minute standup scores 100%, not 600%.
    ///
    /// **A zero-length event scores 1.** Dividing by its duration is undefined,
    /// and there is no coherent sense in which a recording is a "fragment" of an
    /// instant. Such an event has to be judged by the absolute floor alone, which
    /// is the guard that matters anyway.
    static func coverage(
        recordingStart: Date,
        recordingDuration: TimeInterval,
        of event: CandidateEvent
    ) -> Double {
        let eventDuration = event.duration
        guard eventDuration > 0 else { return 1 }

        // A still-recording row has duration 0; a corrupt one could be negative.
        // Both collapse to an instant, matching `CalendarMatching`.
        let span = max(0, recordingDuration)
        let recordingEnd = recordingStart.addingTimeInterval(span)
        let overlap = max(
            0,
            min(recordingEnd, event.effectiveEnd)
                .timeIntervalSince(max(recordingStart, event.start)))
        return min(1, overlap / eventDuration)
    }

    // MARK: - Part numbering

    /// Rendered as `"Weekly sync (Pt 2)"`. Parsed case-insensitively, always
    /// written in this form.
    private static let partWord = "Pt"

    /// What to write when several recordings share one event title.
    ///
    /// `title` is for the new recording. `originalToRenumber` /
    /// `renumberedOriginal` are the *optional* second half: the already-stored
    /// title that should become "(Pt 1)" now that a second one exists, and what
    /// it should become. Both nil when there is nothing to do — which is the
    /// common case, since only the transition from one to two ever triggers it.
    struct Numbering: Equatable {
        /// The title the new recording should take.
        let title: String
        /// An existing library title that is now ambiguous, or nil.
        let originalToRenumber: String?
        /// What `originalToRenumber` should be rewritten to, or nil.
        let renumberedOriginal: String?

        static let none = Numbering(title: "", originalToRenumber: nil, renumberedOriginal: nil)
    }

    /// Disambiguate when several recordings share one event title.
    ///
    /// The convenience half of `numbering(for:existingTitles:)` — the new
    /// recording's title only.
    static func numbered(_ title: String, existingTitles: [String]) -> String {
        numbering(for: title, existingTitles: existingTitles).title
    }

    /// Full numbering decision, including whether the *first* recording of the
    /// series should be retroactively renamed.
    ///
    /// Rules, and why:
    ///
    /// - **No existing match leaves the title untouched.** This is almost every
    ///   recording; a lone "(Pt 1)" would be noise on all of them.
    /// - **Matching is on the base title, exactly** — after stripping any
    ///   existing "(Pt N)" and normalising case and surrounding whitespace. Exact,
    ///   so "Weekly sync follow-up" is a different recording and not part two of
    ///   "Weekly sync"; case- and whitespace-insensitive, because two titles that
    ///   a person reads as the same string are the same string here, and calendar
    ///   titles come from one event anyway so leniency can only help.
    /// - **Already-numbered titles are parsed, not re-suffixed**, so a third
    ///   recording is "(Pt 3)" and never "(Pt 2) (Pt 2)".
    /// - **Gaps are not filled.** `["Weekly sync", "Weekly sync (Pt 3)"]` yields
    ///   Pt 4, not the free Pt 2. A gap means a deletion, and reusing a dead
    ///   number silently claims a position in a series the user remembers
    ///   differently; the numbers are labels, not an index.
    /// - The input's own "(Pt N)" is stripped before matching, so feeding a
    ///   result back in renumbers rather than nesting.
    static func numbering(for title: String, existingTitles: [String]) -> Numbering {
        let (base, _) = split(title)
        guard !base.isEmpty else {
            return Numbering(title: title, originalToRenumber: nil, renumberedOriginal: nil)
        }

        let key = normalised(base)
        var highest = 0
        var bareOriginal: String?
        var hasExplicitFirst = false

        for existing in existingTitles {
            let (existingBase, part) = split(existing)
            guard normalised(existingBase) == key else { continue }
            // A bare title is the series' part one whether or not it says so.
            highest = max(highest, part ?? 1)
            if part == nil, bareOriginal == nil { bareOriginal = existing }
            if part == 1 { hasExplicitFirst = true }
        }

        guard highest > 0 else {
            // Untouched, verbatim — not even re-trimmed. The overwhelmingly
            // common path, and the one that must not add anything.
            return Numbering(title: title, originalToRenumber: nil, renumberedOriginal: nil)
        }

        // Renaming the original is offered only when there is exactly one
        // unnumbered title and nothing already occupies Pt 1, so the suggestion
        // can never create a duplicate.
        let renameOriginal = !hasExplicitFirst ? bareOriginal : nil
        return Numbering(
            title: numbered(base: base, part: highest + 1),
            originalToRenumber: renameOriginal,
            renumberedOriginal: renameOriginal.map { _ in numbered(base: base, part: 1) })
    }

    private static func numbered(base: String, part: Int) -> String {
        "\(base) (\(partWord) \(part))"
    }

    /// Split `"Weekly sync (Pt 2)"` into `("Weekly sync", 2)`. Anything that
    /// isn't exactly that shape comes back as `(trimmed, nil)` — including
    /// "(Pt 0)", "(Pt -1)" and "(Part 2)", none of which this ever writes.
    private static func split(_ title: String) -> (base: String, part: Int?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(")
        else { return (trimmed, nil) }

        let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        guard inside.count > partWord.count,
              inside.prefix(partWord.count).caseInsensitiveCompare(partWord) == .orderedSame
        else { return (trimmed, nil) }

        let digits = inside.dropFirst(partWord.count).trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy(\.isWholeNumber),
              let part = Int(digits), part > 0
        else { return (trimmed, nil) }

        let base = trimmed[trimmed.startIndex..<open]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "(Pt 2)" with nothing in front of it is its own title, not a suffix.
        guard !base.isEmpty else { return (trimmed, nil) }
        return (base, part)
    }

    /// Comparison key: case-folded, edges trimmed, internal runs of whitespace
    /// collapsed. Calendar titles routinely arrive with a stray double space.
    private static func normalised(_ title: String) -> String {
        title
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    // MARK: - The decision

    /// Whether a stored title is still the app's placeholder rather than
    /// something the user (or an earlier pass) chose.
    static func isUntitled(_ title: String, placeholder: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == placeholder
    }

    /// The whole ordering, in one testable place: **a title the user typed is
    /// never overwritten**, then the calendar if it earns it, then the model.
    ///
    /// `event` is whatever `CalendarMatching.bestMatch` returned (nil for no
    /// match), `aiTitle` the already-composed `"<prefix> <title>"`, and
    /// `existingTitles` the library's current titles so the result arrives
    /// already part-numbered. Pass `Recording.untitled` as `untitledPlaceholder`.
    ///
    /// Note what this deliberately does *not* decide: whether to record
    /// `calendarEventTitle` and `calendarAttendees`. Those are written for any
    /// match, accepted or not — see the type comment.
    static func select(
        currentTitle: String,
        untitledPlaceholder: String,
        recordingStart: Date,
        recordingDuration: TimeInterval,
        event: CandidateEvent?,
        categoryAllowsCalendarTitles: Bool,
        aiTitle: String?,
        existingTitles: [String] = [],
        minimumCoverage: Double = minimumCalendarCoverage,
        minimumDuration: TimeInterval = minimumCalendarRecordingDuration
    ) -> Source {
        guard isUntitled(currentTitle, placeholder: untitledPlaceholder) else { return .userTyped }

        if let event, acceptsCalendarTitle(
            recordingStart: recordingStart,
            recordingDuration: recordingDuration,
            event: event,
            categoryAllowsCalendarTitles: categoryAllowsCalendarTitles,
            minimumCoverage: minimumCoverage,
            minimumDuration: minimumDuration) {
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return .calendar(numbered(title, existingTitles: existingTitles))
            }
        }

        if let aiTitle {
            let title = aiTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return .ai(title) }
        }

        return .none
    }
}
