import EventKit
import Foundation
import Observation

/// Reads the phone's calendars to work out which meeting a recording happened in.
///
/// This is the EventKit half; every matching rule lives in `CalendarMatching`,
/// which is EventKit-free and therefore testable on the Mac. This half only
/// fetches and flattens.
///
/// **Why there's no Google or Microsoft integration here.** EventKit reads
/// whatever calendars the user has already subscribed in iOS — iCloud, Google,
/// Exchange, all of them. No OAuth, no third-party SDK, no server.
///
/// Three rules this type is built around:
///
/// - **It never writes.** No event is created, edited, or deleted, and nothing
///   here asks for write access.
/// - **It never stores an `EKEvent`.** Events are mapped to `CandidateEvent` and
///   the objects dropped, so nothing outside this file holds a handle on the
///   user's calendar.
/// - **Denial is silent and total.** Without full access `candidates` returns
///   `[]` and `match` returns nil — no error, no banner, and `requestAccess`
///   won't ask a second time. Same shape as every guard in `AutoOrganizer`: the
///   feature disappears rather than complaining.
///
/// Nothing here logs. Attendee names are personal data and meeting titles are
/// close enough to it that neither belongs in a `print` — this app has no
/// redaction layer.
///
/// **The caller owns the settings gate.** This type answers whenever it has
/// access; it deliberately doesn't read the "Use calendar for titles" preference,
/// so callers (`AutoOrganizer`, the "Name speakers" sheet) must check it
/// themselves before asking.
@MainActor
@Observable
final class CalendarMatcher {

    static let shared = CalendarMatcher()

    /// Cheap to hold and needed for the lifetime of the app; recreating one per
    /// query re-warms the store's connection for nothing.
    @ObservationIgnored private let store = EKEventStore()

    /// Mirrors `EKEventStore.authorizationStatus(for: .event)` so views can react.
    /// Refreshed by `refreshAuthorizationStatus()`, since the user can revoke
    /// access in Settings while the app is backgrounded.
    private(set) var authorizationStatus: EKAuthorizationStatus

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// Whether events can actually be read.
    ///
    /// **Only `.fullAccess` can read events.** iOS 17 split calendar access into
    /// write-only and full, and `.writeOnly` — which permits *adding* events —
    /// reads back as an empty calendar. Checking anything looser here would make
    /// the feature silently never match, with no error to explain it.
    var canReadEvents: Bool { authorizationStatus == .fullAccess }

    func refreshAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// Ask for full access to events, returning whether reading is now possible.
    ///
    /// Call this on first enable of the settings toggle, never at launch.
    ///
    /// Only ever prompts from `.notDetermined`. iOS shows the alert once, so after
    /// a decision this just reports it — asking again would be a no-op that looks
    /// like a prompt loop in the code. A user who denied and changed their mind
    /// goes through Settings, which `refreshAuthorizationStatus()` picks up.
    @discardableResult
    func requestAccess() async -> Bool {
        refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return canReadEvents }
        // `requestFullAccessToEvents()` throws on failure and returns false on
        // denial. Neither is worth surfacing: both mean "no calendar", which the
        // status re-read below records.
        _ = try? await store.requestFullAccessToEvents()
        refreshAuthorizationStatus()
        return canReadEvents
    }

    /// The event a recording most likely belongs to, or nil when there's no
    /// access, no overlapping event, or nothing that passes
    /// `CalendarMatching.bestMatch`.
    func match(
        recordingStart: Date,
        duration: TimeInterval,
        tolerance: TimeInterval = CalendarMatching.defaultTolerance
    ) -> CandidateEvent? {
        CalendarMatching.bestMatch(
            for: recordingStart,
            duration: duration,
            among: candidates(recordingStart: recordingStart, duration: duration, tolerance: tolerance),
            tolerance: tolerance)
    }

    /// The best match together with how confident it is, or nil. The confidence
    /// is what lets a caller link automatically only when sure and otherwise
    /// fall back to the manual picker — see `CalendarMatching.MatchConfidence`.
    func evaluate(
        recordingStart: Date,
        duration: TimeInterval,
        tolerance: TimeInterval = CalendarMatching.defaultTolerance
    ) -> (event: CandidateEvent, confidence: CalendarMatching.MatchConfidence)? {
        CalendarMatching.evaluate(
            for: recordingStart,
            duration: duration,
            among: candidates(recordingStart: recordingStart, duration: duration, tolerance: tolerance),
            tolerance: tolerance)
    }

    /// How far either side of the recording the manual picker looks for meetings
    /// to offer. Deliberately wide — the whole point of the picker is to catch
    /// the cases automatic matching missed (a drifted recorder clock, a meeting
    /// that ran long or started early), so it shows the surrounding few hours,
    /// not just the ±5-minute matching window.
    static let pickerWindow: TimeInterval = 3 * 60 * 60

    /// Real meetings around the recording — before, during and after — for the
    /// manual picker, sorted by start. All-day and blank-titled events are
    /// dropped for the same reasons `bestMatch` rejects them: they can't be the
    /// specific meeting the user is linking to.
    ///
    /// Silent `[]` on no access, exactly like `candidates`.
    func surroundingEvents(
        recordingStart: Date,
        duration: TimeInterval,
        window: TimeInterval = CalendarMatcher.pickerWindow
    ) -> [CandidateEvent] {
        guard canReadEvents else { return [] }
        let span = max(0, duration)
        let window = max(0, window)
        let from = recordingStart.addingTimeInterval(-window)
        let to = max(
            recordingStart.addingTimeInterval(span + window),
            from.addingTimeInterval(1))
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .compactMap(Self.candidate(from:))
            .filter {
                !$0.isAllDay
                    && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.start < $1.start }
    }

    /// Every event near the recording, flattened. Exposed separately so a picker
    /// can offer the near misses rather than only the single best guess.
    func candidates(
        recordingStart: Date,
        duration: TimeInterval,
        tolerance: TimeInterval = CalendarMatching.defaultTolerance
    ) -> [CandidateEvent] {
        guard canReadEvents else { return [] }
        let span = max(0, duration)
        let tolerance = max(0, tolerance)
        let from = recordingStart.addingTimeInterval(-tolerance)
        // Widened by the tolerance at both ends to match `bestMatch`'s eligibility
        // window, or an event just outside the recording would never be fetched
        // and the tolerance would have nothing to work with. The 1-second floor
        // keeps the predicate from being handed an empty range when a caller
        // passes a zero duration *and* a zero tolerance.
        let to = max(
            recordingStart.addingTimeInterval(span + tolerance),
            from.addingTimeInterval(1))
        // `calendars: nil` means every calendar the user has, which is the point:
        // whichever account the meeting lives in, iOS has already synced it.
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).compactMap(Self.candidate(from:))
    }

    // MARK: - Mapping

    /// Flatten one `EKEvent`, dropping the object.
    ///
    /// Returns nil for an event with no start or end. `EKEvent.startDate` and
    /// `endDate` are `null_unspecified` in the header, so Swift imports them as
    /// implicitly-unwrapped optionals that will happily crash on a detached or
    /// half-formed event rather than being nil-checked for you.
    private static func candidate(from event: EKEvent) -> CandidateEvent? {
        guard let start: Date = event.startDate, let end: Date = event.endDate else { return nil }
        // `structuredLocation` is what a picked place populates and is the only
        // route to coordinates; `location` is the free-text field and is all
        // there is when someone typed "my office". Take the structured title
        // first, since it names the place rather than describing it.
        let structured = event.structuredLocation
        let coordinate = structured?.geoLocation?.coordinate
        let locationName = [structured?.title, event.location]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return CandidateEvent(
            title: event.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            attendees: attendeeNames(of: event),
            locationName: locationName,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            // Recurring only. A one-off meeting is not a series, and treating it
            // as one would put a "session 1 of 1" badge on half the library.
            seriesKey: event.hasRecurrenceRules ? event.calendarItemExternalIdentifier : nil)
    }

    /// Attendee display names, deduplicated, order preserved.
    ///
    /// The current user is **not** filtered out: they were in the room and will be
    /// one of the diarized speakers, so their name is as useful a suggestion as
    /// anyone else's. Names come from the calendar server, so one may be an email
    /// address when no display name is published — still a better suggestion than
    /// "Speaker 2", and the user picks from these rather than having them applied.
    private static func attendeeNames(of event: EKEvent) -> [String] {
        var seen = Set<String>()
        return (event.attendees ?? []).compactMap { participant in
            guard let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  seen.insert(name).inserted
            else { return nil }
            return name
        }
    }
}
