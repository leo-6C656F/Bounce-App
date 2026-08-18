import Foundation

/// Turns the deadline the model heard ("by Friday", "end of next week") into a
/// real `Date`.
///
/// The trick is that the model does not need to know what day it is — **we tell
/// it.** Every recording carries a `createdAt`, so the prompt can state the day
/// the conversation happened, spelled out with its weekday, and ask for a strict
/// ISO-8601 fragment resolved against it. That is the whole reason a deadline can
/// become a date at all; without the anchor "by Friday" has no answer.
///
/// Two halves, deliberately kept apart:
///
/// - `instructions(recordedAt:calendar:)` is the prompt fragment. It is the only
///   place the required output format is described, so the format and the parser
///   can't drift.
/// - `resolve(_:recordedAt:calendar:)` parses and *validates* what came back.
///
/// The validation is the part that earns the feature. A wrong date in someone's
/// Reminders is worse than no date — it fires at the wrong time and quietly
/// teaches the user not to trust any of them — so every check here prefers nil
/// over a plausible-looking guess. Unparseable, before the recording, absurdly
/// far out, or an impossible calendar day all return nil, and the caller keeps
/// the spoken phrase it already had.
///
/// **Pure Foundation on purpose.** No FoundationModels import, no actor
/// isolation, no `Date()` and no `Calendar.current` anywhere inside: the caller
/// passes both the anchor and the calendar, so `tools/due-date-tests` can drive
/// every branch deterministically. A resolver that can only be tested by talking
/// to the on-device model is a resolver that never gets tested.
///
/// ### Time zones and DST
///
/// The model returns a **wall-clock date with no zone** — "the 7th at 2pm" — and
/// that is the right thing for it to return, because that is what was said out
/// loud. We interpret it in `calendar.timeZone`, which in the app is the device's
/// current zone at the moment the transcript is processed. Consequences worth
/// knowing:
///
/// - If the user flies somewhere else *after* a due date is resolved, the stored
///   `Date` is a fixed instant and will fire at the original zone's 9am, not the
///   new one's. Apple Reminders behaves the same way for a timed reminder, so
///   this matches the user's expectation elsewhere on the system.
/// - A wall-clock time that does not exist because the clocks sprang forward
///   (02:30 on a transition day) resolves to the next instant that does exist.
///   `Calendar` does that for us and it is the desired behaviour — the deadline
///   still lands on the right day, which is all a reminder needs.
/// - Only the year/month/day are round-tripped when validating, never the hour,
///   precisely so a DST shift can't be mistaken for a bad parse.
enum DueDateResolver {

    /// The hour a dateless deadline lands on, in the anchor calendar's zone.
    ///
    /// The model gives us a bare day for "by Friday", and a bare day taken
    /// literally is midnight — the single worst time to be reminded of anything.
    /// A midnight reminder either fires while the user is asleep or, more often,
    /// is silently already overdue by the time they look at their phone in the
    /// morning, which makes every task from a recording look late. 9am is the
    /// start of a working day, it is what Apple Reminders itself uses as the
    /// default alert time for an all-day reminder, and matching that means a task
    /// pushed from Bounce sits alongside the user's other tasks instead of
    /// standing out as wrong.
    static let defaultHour = 9

    /// How far past the recording a deadline may sit before we call it a misparse.
    ///
    /// Two years comfortably clears anything a person actually says into a voice
    /// recorder — "next year", "by the end of next summer", a contract renewal —
    /// while catching the failure that actually happens, which is a hallucinated
    /// or mistyped year (2126, 2226, or a model that anchored on nothing at all).
    /// The cost of the bound is a deadline three years out being dropped; the
    /// benefit is that a century-away reminder never reaches the user.
    static let maxYearsAhead = 2

    // MARK: - Prompt

    /// The prompt fragment describing how to express a deadline, anchored on when
    /// the recording happened.
    ///
    /// The anchor is stated twice on purpose — once spelled out with its weekday
    /// ("Friday, 31 July 2026") so relative weekday wording can be resolved, and
    /// once in ISO form so the model has the exact string shape it is being asked
    /// to produce. Every worked example is computed from `recordedAt` through
    /// `calendar` rather than hardcoded, so the examples can never contradict the
    /// anchor.
    ///
    /// The English is fixed (`en_US_POSIX`) rather than localised: the rest of
    /// this prompt and every other prompt in the app is English, and a mixed
    /// language anchor line reads as noise to the model.
    static func instructions(recordedAt: Date, calendar: Calendar) -> String {
        let spelled = spelledOut(recordedAt, calendar: calendar)
        let today = isoDay(recordedAt, calendar: calendar)
        let tomorrow = isoDay(byAdding: 1, to: recordedAt, calendar: calendar)
        let nextWeek = isoDay(byAdding: 7, to: recordedAt, calendar: calendar)
        let monthEnd = isoDay(endOfMonthFor: recordedAt, calendar: calendar)

        return """
        This conversation took place on \(spelled). Work every deadline out from \
        that day.

        When the transcript states a deadline, give it as a calendar date in \
        exactly one of these two formats and nothing else:
        - \(nextWeek) — a day on its own, when no time of day was spoken.
        - \(nextWeek)T14:00 — a day and a 24-hour time, when a time of day was \
        actually spoken.

        Return an empty string when no deadline is spoken. Never invent one, and \
        never return a date before \(today).

        For this recording:
        - "tomorrow" is \(tomorrow).
        - "next week" or "in a week" is \(nextWeek).
        - "by the end of the month" is \(monthEnd).
        - "tomorrow at two in the afternoon" is \(tomorrow)T14:00.
        - "by Friday" is the first Friday falling on or after \(today).
        """
    }

    /// The placeholder values for the `dueDateRules` prompt template
    /// (`PromptDefaults.dueDateRules`), keyed by the token names that template uses.
    ///
    /// Exposed so the caller — `ActionItemExtractor`, which owns the `PromptStore`
    /// routing — can fill the user-editable template with the same date anchors
    /// `instructions` bakes into its literal. Kept here, and pure, so both the
    /// literal fallback and the template are computed from one source and can't
    /// drift; `DueDateResolver` deliberately never imports `PromptStore`, so
    /// `tools/due-date-tests` can drive it standalone.
    static func ruleValues(recordedAt: Date, calendar: Calendar) -> [String: String] {
        [
            "recorded_date": spelledOut(recordedAt, calendar: calendar),
            "today": isoDay(recordedAt, calendar: calendar),
            "tomorrow": isoDay(byAdding: 1, to: recordedAt, calendar: calendar),
            "next_week": isoDay(byAdding: 7, to: recordedAt, calendar: calendar),
            "month_end": isoDay(endOfMonthFor: recordedAt, calendar: calendar),
        ]
    }

    // MARK: - Parsing

    /// The `Date` `raw` denotes, or nil if it is missing, malformed or
    /// implausible.
    ///
    /// Accepts `YYYY-MM-DD` and `YYYY-MM-DDTHH:MM` (a space in place of the `T`,
    /// and trailing `:SS`, are tolerated because models produce them and neither
    /// is ambiguous). Everything else is nil, including anything carrying a time
    /// zone designator — see below.
    static func resolve(_ raw: String?, recordedAt: Date, calendar: Calendar) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = parse(trimmed) else { return nil }

        var components = DateComponents()
        components.year = parsed.year
        components.month = parsed.month
        components.day = parsed.day
        components.hour = parsed.hour ?? defaultHour
        components.minute = parsed.minute ?? 0
        components.second = 0
        guard let date = calendar.date(from: components) else { return nil }

        // `Calendar` rolls impossible components over rather than refusing them:
        // month 13 becomes January of the next year and 30 February becomes 1 or 2
        // March. Both are misparses wearing a valid date's clothes, so the day is
        // round-tripped back out and compared. Only year/month/day — never the
        // hour, which a DST spring-forward legitimately moves.
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == parsed.year, check.month == parsed.month, check.day == parsed.day
        else { return nil }

        return plausible(date, recordedAt: recordedAt, calendar: calendar) ? date : nil
    }

    /// Whether `date` is a deadline the recording could actually have been
    /// talking about.
    ///
    /// Two bounds, both of which reject rather than clamp:
    ///
    /// - **Not before the recording.** A deadline in the past is not a deadline,
    ///   it is a misparse — most often the model resolving a weekday backwards,
    ///   or anchoring on its own training-time notion of "now". The floor is the
    ///   *start of the recording's day*, not the recording's own timestamp, so a
    ///   task recorded at 10pm and due "today" still resolves: it lands at 9am
    ///   the same morning, which is behind the recording but plainly meant.
    /// - **Not absurdly far ahead** — see `maxYearsAhead`.
    private static func plausible(
        _ date: Date, recordedAt: Date, calendar: Calendar
    ) -> Bool {
        let floor = calendar.startOfDay(for: recordedAt)
        guard date >= floor else { return false }
        guard let ceiling = calendar.date(
            byAdding: .year, value: maxYearsAhead, to: recordedAt)
        else { return true }
        return date <= ceiling
    }

    /// `YYYY-MM-DD`, optionally followed by `T` or a space and `HH:MM[:SS]`.
    ///
    /// Hand-rolled rather than a regex or `ISO8601DateFormatter`, for two
    /// reasons. The formatter is *lenient* in ways that hurt here — it will
    /// happily interpret a zone suffix and hand back an instant we'd then
    /// misattribute to a local wall clock — and a fixed-width digit scan makes
    /// the accepted grammar obvious to the next reader. Anything with a `Z` or a
    /// `+02:00` on the end fails the all-digits test and returns nil, which is
    /// the safe answer: we cannot tell whether the model meant a real UTC instant
    /// or was decorating its output, and guessing wrong moves the deadline a day
    /// for users far from UTC.
    private static func parse(
        _ text: String
    ) -> (year: Int, month: Int, day: Int, hour: Int?, minute: Int?)? {
        let datePart: Substring
        var timePart: Substring?
        if let separator = text.firstIndex(where: { $0 == "T" || $0 == " " }) {
            datePart = text[text.startIndex..<separator]
            timePart = text[text.index(after: separator)...]
        } else {
            datePart = text[...]
        }

        let dateFields = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard dateFields.count == 3,
              let year = digits(dateFields[0], width: 4),
              let month = digits(dateFields[1], width: 2),
              let day = digits(dateFields[2], width: 2),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        guard let timePart else { return (year, month, day, nil, nil) }

        let timeFields = timePart.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(timeFields.count),
              let hour = digits(timeFields[0], width: 2),
              let minute = digits(timeFields[1], width: 2),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        // Seconds are accepted but discarded — no deadline is spoken to the
        // second. They still have to be well-formed, so junk after the minutes
        // can't slip through.
        if timeFields.count == 3 {
            guard let seconds = digits(timeFields[2], width: 2), (0...59).contains(seconds)
            else { return nil }
        }
        return (year, month, day, hour, minute)
    }

    /// `field` as an integer, but only if it is exactly `width` ASCII digits.
    /// The width check is what rejects `2026-8-7` and `...T14:30Z`.
    private static func digits(_ field: Substring, width: Int) -> Int? {
        guard field.count == width, field.allSatisfy(\.isASCII), field.allSatisfy(\.isNumber)
        else { return nil }
        return Int(field)
    }

    // MARK: - Formatting

    /// "Friday, 31 July 2026" — the anchor the whole prompt hangs on.
    private static func spelledOut(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter.string(from: date)
    }

    /// `YYYY-MM-DD` for `date` in `calendar`'s zone.
    ///
    /// Built from `DateComponents` rather than a `DateFormatter` so it agrees
    /// with `parse` by construction: same calendar, same zone, same fields.
    static func isoDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func isoDay(byAdding days: Int, to date: Date, calendar: Calendar) -> String {
        let shifted = calendar.date(byAdding: .day, value: days, to: date) ?? date
        return isoDay(shifted, calendar: calendar)
    }

    /// The last day of the month `date` falls in.
    private static func isoDay(endOfMonthFor date: Date, calendar: Calendar) -> String {
        guard let range = calendar.range(of: .day, in: .month, for: date) else {
            return isoDay(date, calendar: calendar)
        }
        var parts = calendar.dateComponents([.year, .month], from: date)
        parts.day = range.upperBound - 1
        guard let last = calendar.date(from: parts) else { return isoDay(date, calendar: calendar) }
        return isoDay(last, calendar: calendar)
    }
}
