import Foundation

/// A calendar event flattened to the five fields matching actually needs.
///
/// `EKEvent` deliberately never reaches this layer. It's a reference type tied to
/// a live `EKEventStore`, it can't be constructed in a test, and holding one keeps
/// the user's calendar object graph alive — so `CalendarMatcher` maps into this and
/// drops the object. Keeping the rules below EventKit-free is also what lets them
/// compile and run on the Mac (`tools/calendar-match-tests/`), which is the only
/// automated coverage this feature can have: there is no test target and the app
/// can't build for the simulator.
struct CandidateEvent: Hashable {
    /// The event's title. `CalendarMatching.bestMatch` rejects blank titles — the
    /// entire point of a match is to source a title from it, so an untitled event
    /// is not a useful answer.
    var title: String
    var start: Date
    var end: Date
    /// `bestMatch` rejects all-day events. They span the whole day and would
    /// therefore match every recording made that day, which is worse than no
    /// match at all.
    var isAllDay: Bool
    /// Attendee display names, in the order the calendar reported them.
    ///
    /// **Personal data.** Never `print` or log these — this app has no redaction
    /// layer. They must also not be added to the webhook delivery payload without
    /// a settings toggle: that payload's shape is a documented contract for
    /// whatever the user has wired downstream, and silently starting to ship
    /// colleagues' names to a third-party endpoint is not a change to make on the
    /// user's behalf.
    var attendees: [String]
    /// The event's location as the calendar states it — "Room 4B", "Blue Bottle
    /// on Mint", or a pasted video-call URL. Purely a label; it plays no part in
    /// matching, and an event can have one with no coordinates at all.
    var locationName: String?
    /// The event's coordinates, when the calendar has them. Present only when
    /// the organiser picked a real place rather than typing free text, which is
    /// why both this and `locationName` are independently optional.
    ///
    /// Two `Double`s rather than a `CLLocationCoordinate2D`: this file is
    /// deliberately EventKit- *and* CoreLocation-free so `tools/calendar-match-tests/`
    /// can compile it on the Mac.
    var latitude: Double?
    var longitude: Double?
    /// The calendar's stable identifier for a **recurring** event, shared by
    /// every occurrence of it — `EKEvent.calendarItemExternalIdentifier`. Nil for
    /// a one-off, which is the point: only a recurring meeting is a series.
    ///
    /// This is what makes automatic grouping work without the user doing
    /// anything: two recordings six weeks apart resolve to the same key, and
    /// renaming the meeting in Calendar doesn't fork the series, because the key
    /// doesn't change with the title.
    var seriesKey: String?

    init(
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        attendees: [String] = [],
        locationName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        seriesKey: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.locationName = locationName
        self.latitude = latitude
        self.longitude = longitude
        self.seriesKey = seriesKey
    }

    /// The event's location as a storable place, or nil when it has no
    /// coordinates.
    ///
    /// A name with no coordinates is dropped rather than stored: `RecordingPlace`
    /// exists to put a pin on a map, and "Room 4B" cannot. The user can still set
    /// one by hand, and the event title already carries the context.
    var place: RecordingPlace? {
        guard let latitude, let longitude else { return nil }
        let place = RecordingPlace(
            latitude: latitude,
            longitude: longitude,
            name: locationName,
            source: .calendar,
            capturedAt: start)
        return place.isValid ? place : nil
    }

    /// `end`, clamped so it can never precede `start`. Calendar servers do
    /// occasionally hand back an inverted pair; clamping keeps every duration and
    /// overlap below non-negative rather than letting one bad event produce a
    /// nonsense score.
    var effectiveEnd: Date { max(start, end) }

    var duration: TimeInterval { effectiveEnd.timeIntervalSince(start) }
}

/// Which calendar event a recording belongs to — pure, synchronous, and
/// EventKit-free. `CalendarMatcher` is the EventKit half that feeds this.
enum CalendarMatching {

    /// The recorder's clock and the phone's disagree, and people hit record on
    /// the way into the room rather than on the hour. ±5 minutes absorbs both.
    static let defaultTolerance: TimeInterval = 300

    /// The event a recording most likely belongs to, or nil.
    ///
    /// An event is *eligible* when it comes within `tolerance` of
    /// `recordingStart ..< recordingStart + duration`. All-day and blank-titled
    /// events are never eligible.
    ///
    /// Among eligible events, precedence is (see `Ranked.beats`):
    ///
    /// 1. **An event containing the recording start beats one that merely
    ///    overlaps it** — even when the other overlaps more. These two rules
    ///    genuinely disagree: a 9:30–10:30 meeting you started recording at 10:00
    ///    overlaps 30 minutes of an hour-long recording, while a 10:10–11:00
    ///    meeting overlaps 50. The recording is nonetheless *of* the first one;
    ///    the second one is what the room moved on to. Where the recording began
    ///    is stronger evidence than how much of it a later event happens to span,
    ///    so containment is checked first and overlap only breaks ties within a
    ///    tier.
    /// 2. Greatest overlap with the recording.
    /// 3. The shorter event, as the more specific one.
    /// 4. Then the nearer start, the earlier start, and the title — pure
    ///    tie-breakers, so the answer is a function of the *set* of candidates
    ///    and not of the order EventKit happened to return them in.
    static func bestMatch(
        for recordingStart: Date,
        duration: TimeInterval,
        among candidates: [CandidateEvent],
        tolerance: TimeInterval = defaultTolerance
    ) -> CandidateEvent? {
        // A still-recording row has duration 0; a corrupt one could be negative.
        // Both collapse to an instant rather than an inverted interval.
        let span = max(0, duration)
        let tolerance = max(0, tolerance)
        let recordingEnd = recordingStart.addingTimeInterval(span)
        let windowStart = recordingStart.addingTimeInterval(-tolerance)
        let windowEnd = recordingEnd.addingTimeInterval(tolerance)

        var best: Ranked?
        for candidate in candidates {
            guard !candidate.isAllDay else { continue }
            guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            let end = candidate.effectiveEnd

            // Signed, deliberately unclamped: a negative value is the size of the
            // gap between the event and the tolerance-widened recording window.
            // `>= 0` therefore reads "±5 minutes" inclusively — an event exactly
            // `tolerance` clear of the recording still counts, one a second
            // further out does not.
            let reach = min(windowEnd, end).timeIntervalSince(max(windowStart, candidate.start))
            guard reach >= 0 else { continue }

            // Overlap is scored against the *real* recording interval, not the
            // widened one, so the tolerance can admit an event but never inflate
            // its score.
            let overlap = max(
                0,
                min(recordingEnd, end).timeIntervalSince(max(recordingStart, candidate.start)))

            // "Contains the recording start": the recording began during the
            // event. Tolerant at the front — starting three minutes before the
            // meeting nominally began still counts — but strict at the back, so
            // for two back-to-back meetings a recording starting exactly on the
            // boundary belongs to the one that is starting, not the one ending.
            let containsStart = candidate.start.addingTimeInterval(-tolerance) <= recordingStart
                && recordingStart < end

            let ranked = Ranked(
                event: candidate,
                containsStart: containsStart,
                overlap: overlap,
                startGap: abs(candidate.start.timeIntervalSince(recordingStart)))
            if best == nil || ranked.beats(best!) { best = ranked }
        }
        return best?.event
    }

    /// One eligible candidate with its scores, and the precedence between two of
    /// them written out in one place.
    private struct Ranked {
        let event: CandidateEvent
        let containsStart: Bool
        let overlap: TimeInterval
        let startGap: TimeInterval

        func beats(_ other: Ranked) -> Bool {
            // 1. Containment first — this is the rule that outranks overlap.
            if containsStart != other.containsStart { return containsStart }
            // 2. Then how much of the recording the event actually covers.
            if overlap != other.overlap { return overlap > other.overlap }
            // 3. Then the shorter event: "Standup" beats "Office hours 9–5".
            if event.duration != other.event.duration { return event.duration < other.event.duration }
            // 4. Tie-breakers with no product meaning, present only so the result
            //    doesn't depend on candidate order. They also carry the degenerate
            //    zero-duration-recording case, where every overlap is 0.
            if startGap != other.startGap { return startGap < other.startGap }
            if event.start != other.event.start { return event.start < other.event.start }
            return event.title < other.event.title
        }
    }
}
