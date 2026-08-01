import Foundation

/// The pure half of writing tasks into Apple Calendar: working out what one
/// reconciliation pass between Bounce's dated action items and the user's
/// calendar should actually do.
///
/// Split out of `TaskCalendarWriter.swift` — which imports EventKit and drives a
/// live `EKEventStore` — for the same reason `ReminderPlanning` is split out of
/// `RemindersSync` and `CalendarMatching` out of `CalendarMatcher`: there is no
/// test target and no simulator, so logic that can be compiled and exercised on
/// the Mac should live somewhere it can be. See
/// `tools/task-calendar-tests/main.swift`, which compiles this file and the real
/// `ActionItem` from `ActionItemMerge.swift` — no stubs.
///
/// ## Only dated, open tasks get an event
///
/// A calendar is a schedule. A task with no resolved `dueDate` has nothing to be
/// scheduled *at*, so it has no place here and is left to Apple Reminders, which
/// is happy to hold an undated task forever. `dueText` alone is not enough: "by
/// Friday" is a phrase, and `DueDateResolver` is the only thing allowed to turn it
/// into an instant. A task whose date is resolved by a later pass becomes eligible
/// then and gets its event then.
///
/// This is the one substantive difference from `ReminderPlanning`, which pushes
/// every open task. The two destinations are complementary rather than redundant:
/// Reminders is the list of everything, Calendar is the subset that has a time.
///
/// ## Bounce is authoritative for the date, until the user disagrees
///
/// Unlike `ReminderPlanning`, which writes text once and never updates it, this
/// **does** keep the date in step. The reasoning that made "write once" right for
/// a reminder's title makes it wrong for an event's date: a stale title is a
/// cosmetic annoyance, whereas a stale date is the entire content of a calendar
/// event. An event left at a superseded deadline fires its alert at the wrong
/// time and cannot be corrected — unlinking never recreates — so it would be
/// permanently, silently wrong.
///
/// `lastPushed` is what makes "who moved this?" answerable, exactly as
/// `ReminderPlanning.lastSeen` does for completion. It records the start date
/// Bounce itself last wrote for each event:
///
/// - **The event still sits where Bounce put it** → Bounce is the side that
///   moved, so push the new deadline.
/// - **The event has been dragged somewhere else** → the user moved it. Leave it
///   alone, *and leave the baseline where it is*, so Bounce never pushes to that
///   event again. The user has taken ownership of its date.
///
/// That second rule has to keep the stale baseline to be stable. Adopting the
/// user's date as the new baseline would make the very next pass conclude Bounce
/// had moved and push anyway — the same trap `ReminderPlanning` documents for
/// un-ticking, resolved in the opposite direction because here the user's edit is
/// the one worth keeping.
///
/// With `lastPushed` empty the rule degrades to "push whenever the dates differ",
/// which is the right stateless default — Bounce owning the date is the feature —
/// at the cost of overriding a drag made before the baseline existed exactly once.
/// In practice the baseline is written in the same pass as the create, so this
/// only arises after an upgrade or a lost `UserDefaults`.
///
/// ## Deleting is the user's decision, and it sticks
///
/// An event the user deleted in Calendar is **never recreated**, the same rule and
/// the same reasoning as `ReminderPlanning`: recreating fights the user, and
/// losing that argument once per foreground is intolerable. `forgotten` is what
/// makes it stick, because unlinking alone can't — an item with a nil
/// `calendarEventId` is indistinguishable from one that was never pushed.
///
/// This is why an unlink has to say *why*. Bounce clears a link for two quite
/// different reasons, and only one of them is a user's decision:
/// `CalendarUnlinkReason`.
///
/// Nothing here logs. A task's text and a meeting's title are as personal as a
/// transcript, and this app has no redaction layer.

// MARK: - Inputs

/// One action item together with the recording it came from.
///
/// The recording's title is needed for the event's notes — "which conversation did
/// this come out of?" is the first thing anyone asks when a task shows up on their
/// calendar a week later — and `ActionItem` doesn't carry it. Pairing them here
/// rather than having the EventKit layer hold a side table keeps the plan
/// self-contained: `toCreate` has everything needed to build an event.
///
/// Deliberately a title string rather than a `Recording`. This file must stay
/// Foundation-only so it can compile on the Mac, and the plan has no use for the
/// rest of the model.
struct CalendarTask: Equatable {
    var item: ActionItem
    /// The source recording's title, for the event's notes. Nil or blank is fine
    /// and simply omits the line — an untitled recording is normal before the
    /// organize pass has run.
    var recordingTitle: String?

    init(item: ActionItem, recordingTitle: String? = nil) {
        self.item = item
        self.recordingTitle = recordingTitle
    }
}

// MARK: - Plan

/// Why an item's `calendarEventId` is being cleared.
///
/// The distinction is the whole point of the enum: only a user's own deletion
/// tombstones. Collapsing the two would either resurrect events the user threw
/// away, or permanently strand an item over a bookkeeping slip Bounce made itself.
enum CalendarUnlinkReason: Equatable {
    /// The linked event is no longer in the calendar. The user deleted it, so the
    /// item is tombstoned in `forgotten` and never gets another event.
    case userDeletedEvent
    /// Two items claimed the same event — a corrupt link, not a user decision. The
    /// link is dropped with no tombstone, so the item gets an event of its own on
    /// the next pass.
    case duplicateLink
}

/// One link to clear. See `CalendarUnlinkReason`.
struct CalendarEventUnlink: Equatable {
    let itemId: String
    let reason: CalendarUnlinkReason

    init(itemId: String, reason: CalendarUnlinkReason) {
        self.itemId = itemId
        self.reason = reason
    }
}

/// An existing event to move onto a new deadline.
///
/// Carries the resolved window rather than the raw deadline so the plan fully
/// specifies the write and can be asserted against in the tests, instead of the
/// EventKit layer re-deriving something the planner already knew.
struct CalendarEventUpdate: Equatable {
    let itemId: String
    let eventId: String
    let start: Date
    let end: Date

    init(itemId: String, eventId: String, start: Date, end: Date) {
        self.itemId = itemId
        self.eventId = eventId
        self.start = start
        self.end = end
    }
}

/// An event to delete, because the task it stands for is done or has lost its
/// deadline.
///
/// Carries `itemId` as well as `eventId` because the caller must also clear the
/// item's `calendarEventId` — and, crucially, must **not** tombstone it. This is
/// Bounce's own decision, so a task that is reopened, or that gets its date back,
/// is eligible again immediately.
struct CalendarEventRemoval: Equatable {
    let itemId: String
    let eventId: String

    init(itemId: String, eventId: String) {
        self.itemId = itemId
        self.eventId = eventId
    }
}

/// What one pass should do to bring Bounce's dated tasks and Apple Calendar back
/// into agreement.
struct CalendarEventPlan: Equatable {

    /// Dated, open tasks with no event yet. The caller creates one each and
    /// records the resulting identifier back onto `ActionItem.calendarEventId`.
    var toCreate: [CalendarTask] = []

    /// Events whose task's deadline has moved. See the type documentation for when
    /// this is and isn't produced.
    var toUpdate: [CalendarEventUpdate] = []

    /// Events to delete because their task is done or no longer dated. The
    /// caller clears the link **without** tombstoning.
    var toRemove: [CalendarEventRemoval] = []

    /// Links to clear. Whether to tombstone depends on the reason — use
    /// `toForget`.
    var toUnlink: [CalendarEventUnlink] = []

    static let empty = CalendarEventPlan()

    /// True when there is nothing at all to do — the normal outcome of a repeated
    /// pass, and the reason this is cheap enough to run on every app foreground.
    var isEmpty: Bool {
        toCreate.isEmpty && toUpdate.isEmpty && toRemove.isEmpty && toUnlink.isEmpty
    }

    /// The `ActionItem.id`s to add to `forgotten`: the ones whose event the *user*
    /// deleted. A duplicate-link unlink is deliberately absent.
    var toForget: [String] {
        toUnlink.filter { $0.reason == .userDeletedEvent }.map(\.itemId)
    }
}

// MARK: - Planning

enum CalendarEventPlanning {

    /// How long the event standing for a deadline lasts, ending *at* the deadline.
    ///
    /// **A short timed event, not an all-day one**, and the deciding fact is what
    /// `DueDateResolver` actually produces: a real instant with a meaningful time
    /// of day. It uses the spoken time when one was said ("by two on Thursday"),
    /// and `DueDateResolver.defaultHour` — 9am, matching Apple Reminders' own
    /// all-day alert time — when one wasn't. An all-day event would throw that
    /// away and turn "due at 2pm" into an anonymous banner across the whole day,
    /// discarding the one thing the resolver worked hardest to preserve.
    ///
    /// The block **ends** at the deadline rather than starting there, so it reads
    /// as the run-up to the thing being due. An event starting at the deadline
    /// says work begins once it is already late.
    ///
    /// Thirty minutes is a compromise between two failure modes: much shorter and
    /// the event collapses into an unreadable sliver in Calendar's day view; much
    /// longer and it looks like a meeting and starts colliding with real ones. The
    /// clutter question is answered properly by the target-calendar picker — a
    /// dedicated calendar can be hidden with one tap in Calendar — rather than by
    /// making the event less informative.
    static let eventDuration: TimeInterval = 30 * 60

    /// When the event's single alert fires, relative to its **start**.
    ///
    /// Zero, so the alert lands as the block opens — half an hour before the thing
    /// is actually due. That is early enough to still act on and late enough not to
    /// be forgotten again, and one alert is the right number: a task pushed from a
    /// recording has no claim to be noisier than one the user typed themselves.
    static let alarmOffset: TimeInterval = 0

    /// The event window for a deadline: `eventDuration` long, ending on the dot.
    static func window(endingAt deadline: Date) -> (start: Date, end: Date) {
        (deadline.addingTimeInterval(-eventDuration), deadline)
    }

    /// Whether a task should have an event at all.
    ///
    /// Three requirements, each of which is also a *removal* trigger when it stops
    /// holding: a resolved deadline, still open, and something to call it. Blank
    /// text can only arrive from a hand-added item — `ActionItemMerge` drops
    /// anything with no letters or digits — but an untitled block on someone's
    /// calendar is garbage, so it is refused here too.
    static func isEligible(_ item: ActionItem) -> Bool {
        item.dueDate != nil && !item.isDone && !title(for: item).isEmpty
    }

    /// What to do to bring Bounce's dated tasks and Apple Calendar back into
    /// agreement.
    ///
    /// Every task falls into **at most one** bucket, so no item is ever both
    /// created and removed, or both updated and unlinked. Applying the plan and
    /// planning again yields `CalendarEventPlan.empty` — the plan is a fixed point,
    /// which is what makes it safe on every app foreground. The single exception is
    /// a duplicate link, which is corrupt state being repaired and settles on the
    /// second pass rather than the first; see `CalendarUnlinkReason.duplicateLink`.
    ///
    /// - Parameters:
    ///   - tasks: every action item across the library, paired with its recording's
    ///     title, in any order.
    ///   - existing: event identifier → that event's current **start** date, as
    ///     Calendar reports it right now. This must be a **complete** picture of
    ///     the events Bounce has links to: an identifier missing from it is read as
    ///     "the user deleted that event". A failed read must never be passed here
    ///     as `[:]`, or every linked task is unlinked *and tombstoned* at once,
    ///     which is unrecoverable short of toggling the setting. `TaskCalendarWriter`
    ///     refuses to plan unless the store answered.
    ///   - enabled: the user's setting. False returns an empty plan and touches
    ///     nothing, so turning the feature off freezes both sides where they are
    ///     rather than tearing down every event the user can now see in Calendar.
    ///   - lastPushed: event identifier → the start date Bounce last wrote for it.
    ///     Empty degrades gracefully — see the type documentation.
    ///   - forgotten: `ActionItem.id`s whose event the user deleted in Calendar.
    static func plan(
        tasks: [CalendarTask],
        existing: [String: Date],
        enabled: Bool,
        lastPushed: [String: Date] = [:],
        forgotten: Set<String> = []
    ) -> CalendarEventPlan {
        guard enabled else { return .empty }

        var plan = CalendarEventPlan()
        // Two items must never drive one event: they would fight over its date,
        // and one of them removing it would leave the other pointing at nothing —
        // which then reads as a user deletion and tombstones an innocent task.
        var claimed = Set<String>()

        for task in tasks {
            let item = task.item
            let eligible = isEligible(item)

            guard let eventId = item.calendarEventId, !eventId.isEmpty else {
                // Never pushed. An already-done or undated task is simply not
                // created — same posture as `ReminderPlanning`, and it is what
                // stops a first enable on a mature library backfilling months of
                // finished work into the user's calendar.
                if eligible, !forgotten.contains(item.id) { plan.toCreate.append(task) }
                continue
            }

            guard claimed.insert(eventId).inserted else {
                plan.toUnlink.append(.init(itemId: item.id, reason: .duplicateLink))
                continue
            }

            guard let currentStart = existing[eventId] else {
                // Linked to an event that isn't there any more. `forgotten` is
                // what keeps it from coming back.
                plan.toUnlink.append(.init(itemId: item.id, reason: .userDeletedEvent))
                continue
            }

            guard eligible, let deadline = item.dueDate else {
                // Ticked off, or the deadline was edited away. A calendar is about
                // what is still ahead: a done task's block is a false commitment
                // that will fire its alert for work already finished, and an
                // undated task has nothing to be scheduled at. Removing rather
                // than leaving it also keeps this symmetric with the create rule,
                // so the two can't disagree about what belongs on the calendar.
                // The completion record lives in Bounce and in Reminders; the
                // calendar is the schedule, not the log.
                plan.toRemove.append(.init(itemId: item.id, eventId: eventId))
                continue
            }

            let target = window(endingAt: deadline)
            if currentStart == target.start { continue }

            // The event has been dragged away from where Bounce put it, so the
            // user owns its date now. Leave it — and see `nextLastPushed`, which
            // deliberately does not adopt `currentStart` as the new baseline.
            if let baseline = lastPushed[eventId], baseline != currentStart { continue }

            plan.toUpdate.append(
                .init(itemId: item.id, eventId: eventId, start: target.start, end: target.end))
        }

        return plan
    }

    /// `previous` advanced by the writes that actually landed, to be carried into
    /// the next pass as `lastPushed`.
    ///
    /// Three things this does **not** do, all load-bearing:
    ///
    /// - It is not derived from `existing`. `ReminderPlanning.nextLastSeen` is,
    ///   because there the baseline means "what the other side said last time".
    ///   Here it means "what Bounce itself wrote", so adopting an event's current
    ///   start would erase the evidence that the user had moved it, and the next
    ///   pass would drag it back.
    /// - **It is not derived from the plan.** It takes what was written, not what
    ///   was intended, and the difference is not academic: recording a baseline for
    ///   an update that failed to save would leave `lastPushed` disagreeing with
    ///   the event's real start, which the next pass reads as "the user moved it"
    ///   — and that event's date would then be frozen forever.
    /// - It does not grow without bound. Entries for events no longer in `existing`
    ///   — deleted by the user — are pruned, as are the ones this pass removed.
    ///
    /// - Parameters:
    ///   - removed: identifiers of the events actually deleted in this pass.
    ///   - written: event identifier → the start date actually written for it,
    ///     across both the events created and the ones moved.
    static func nextLastPushed(
        previous: [String: Date],
        existing: [String: Date],
        removed: [String],
        written: [String: Date]
    ) -> [String: Date] {
        var result = previous.filter { existing[$0.key] != nil }
        for eventId in removed { result[eventId] = nil }
        for (eventId, start) in written { result[eventId] = start }
        return result
    }

    // MARK: - Event content

    /// The event's title: the task itself, trimmed.
    ///
    /// Not prefixed with "Task:" or the like. The user chose which calendar these
    /// land in, and a prefix repeated down a day view is noise that costs the
    /// width the actual task needs.
    static func title(for item: ActionItem) -> String {
        item.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Owner, the deadline as spoken, and the source recording, as the event's
    /// notes — or nil when none of the three is known.
    ///
    /// Labelled rather than run together, for the same reason as
    /// `RemindersSync.notes(for:)`: the title already carries the task, so an
    /// unlabelled fragment underneath it reads as debris once it is out of Bounce's
    /// own row layout.
    ///
    /// `dueText` is included even though the event's own date says when it is due,
    /// because the two can disagree and the phrase is the evidence. "by the end of
    /// the month" next to a block on the 31st is reassuring; next to a block on the
    /// 3rd it is the user's cue that the resolution was wrong.
    static func notes(for task: CalendarTask) -> String? {
        var lines: [String] = []
        if let owner = trimmed(task.item.owner) { lines.append("Owner: \(owner)") }
        if let due = trimmed(task.item.dueText) { lines.append("Due: \(due)") }
        if let source = trimmed(task.recordingTitle) { lines.append("From: \(source)") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
