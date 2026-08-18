import EventKit
import Foundation
import Observation

/// Writes Bounce's dated action items into Apple Calendar as timed events.
///
/// This is the EventKit half; every reconciliation rule lives in
/// `CalendarEventPlanning`, which is EventKit-free and therefore testable on the
/// Mac (`tools/task-calendar-tests/main.swift`). This half only fetches, writes,
/// and remembers the little state the planner needs. **Read
/// `CalendarEventPlanning`'s documentation first** — it is where the eligibility
/// rule, the date-ownership rule and the two kinds of unlink are written down.
///
/// ## This is the file that writes to the calendar
///
/// `CalendarMatcher` reads the user's calendar and its documentation promises, in
/// as many words, that it never writes and never holds an `EKEvent`. That promise
/// is unchanged and this type does not touch it: **a separate type, a separate
/// `EKEventStore`, and a separate opt-in setting.** The read path keeps its
/// guarantee, and everything that can modify a calendar is in this one file.
///
/// The corollary is that `NSCalendarsFullAccessUsageDescription` can no longer say
/// nothing is written. It has to describe both halves now.
///
/// ## Full access, not write-only — and this is not a choice
///
/// iOS 17 added a write-only tier (`requestWriteOnlyAccessToEvents()`), which
/// sounds like exactly the right fit for a type that only creates events. It
/// isn't. Apple's documentation is explicit: with write-only access "your app can
/// create events, but it can't access any of the existing calendars and events on
/// the device, **including events your app created**. API calls to read event data
/// from the event store don't return any events."
///
/// Three things this design needs are therefore impossible on write-only:
///
/// - reading an event back to notice the user deleted it, which is what drives
///   `CalendarUnlinkReason.userDeletedEvent`;
/// - resolving an event by identifier in order to move or delete it — `remove` and
///   `save` both need the live object, and `event(withIdentifier:)` returns nil;
/// - listing calendars for the target picker.
///
/// So this asks for full access. **No new permission prompt appears**: Bounce
/// already holds `.fullAccess` for `CalendarMatcher`, and iOS shows the alert once
/// per entity type. A user who granted calendar access for meeting titles has, as
/// far as iOS is concerned, already granted this — which is precisely why the
/// feature is off by default and gated on its own setting instead.
///
/// ## Rules, borrowed from the two types either side of it
///
/// - **Denial is silent and total.** Without full access `sync` does nothing and
///   returns an empty outcome — no error, no banner — and `requestAccess` won't
///   ask a second time.
/// - **No `EKEvent` escapes this file.** Events are read as identifier-and-start
///   pairs and calendars as `TaskCalendarList`; `TaskCalendarOutcome` is plain
///   strings. `EKEvent` objects exist only inside a single `sync` call, long
///   enough to save or delete them.
/// - **Never touch an event Bounce didn't create.** Every event this type resolves
///   comes from an identifier Bounce itself stored on `ActionItem.calendarEventId`
///   after creating it. There is no predicate scan and no search-by-title anywhere
///   in this file, so an event the user made can't be found, let alone modified.
///
/// Nothing here logs. A task's text is as personal as a transcript, and this app
/// has no redaction layer.
@MainActor
@Observable
final class TaskCalendarWriter {

    static let shared = TaskCalendarWriter()

    /// Cheap to hold and needed for the lifetime of the app; a fresh store per
    /// sync re-warms the connection for nothing. Separate from `CalendarMatcher`'s
    /// and `RemindersSync`'s deliberately — one store per feature keeps an
    /// uncommitted write here from being committed by another, and keeps the
    /// read-only matcher genuinely read-only.
    @ObservationIgnored private let store = EKEventStore()

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Mirrors `EKEventStore.authorizationStatus(for: .event)` so views can react.
    /// Refreshed by `refreshAuthorizationStatus()`, since the user can revoke
    /// access in Settings while the app is backgrounded.
    private(set) var authorizationStatus: EKAuthorizationStatus

    // MARK: - Settings
    //
    // UserDefaults-backed and read straight from views as
    // `TaskCalendarWriter.shared`, the `DeliverySettings` pattern for synchronous
    // local preference state — the same arrangement as `RemindersSync`. The keys
    // live here rather than in `SettingsKey` only because this type owns them
    // entirely; move them if a second reader ever appears.

    private enum Key {
        static let enabled = "taskCalendarWriteEnabled"
        static let calendar = "taskCalendarIdentifier"
        static let lastPushed = "taskCalendarLastPushed"
        static let forgotten = "taskCalendarForgotten"
    }

    /// Write dated tasks into Apple Calendar.
    ///
    /// Off by default, and **not** flipped on by already holding calendar access.
    /// Bounce has full access for reading meeting titles; that must not silently
    /// become licence to start creating events. Writing into someone's calendar is
    /// the most visible thing this app does to data it doesn't own, so it is an
    /// explicit opt-in. `bool(forKey:)` is correct precisely because the default is
    /// off — a default-ON Bool would need `object(forKey:) as? Bool ?? true`.
    ///
    /// Turning it on clears `forgotten`, so events the user deleted are eligible
    /// again. That is the only escape from "deleted means gone", and re-enabling is
    /// an explicit enough gesture to be it. Same contract as
    /// `RemindersSync.syncEnabled`.
    ///
    /// Turning it **off** deliberately deletes nothing. Those events are in the
    /// user's calendar now and may have been shared, dragged, or annotated;
    /// silently sweeping them away on a toggle would be far worse than leaving
    /// them. The planner freezes instead — `plan` returns `.empty`.
    var writeEnabled: Bool {
        didSet {
            defaults.set(writeEnabled, forKey: Key.enabled)
            if writeEnabled, !oldValue { forgotten = [] }
        }
    }

    /// `EKCalendar.calendarIdentifier` of the calendar new events go into, or nil
    /// to follow the Calendar app's own default.
    ///
    /// Only consulted when *creating*. Existence and start dates are read by
    /// identifier regardless of which calendar an event now lives in, so moving a
    /// Bounce event to another calendar keeps it linked rather than looking
    /// deleted.
    var targetCalendarIdentifier: String? {
        didSet { defaults.set(targetCalendarIdentifier, forKey: Key.calendar) }
    }

    /// The start date Bounce last wrote for each event. See
    /// `CalendarEventPlanning` — this is what makes "who moved this?" answerable.
    ///
    /// Stored as `[String: Double]` (seconds since 1970) because `UserDefaults`
    /// will not round-trip a `[String: Date]` through `dictionary(forKey:)`
    /// reliably as a property list of `Date`s once it has been through a plist
    /// encode; seconds are unambiguous and comparison-exact, which is what the
    /// baseline rule needs.
    @ObservationIgnored private var lastPushed: [String: Date] {
        didSet {
            defaults.set(
                lastPushed.mapValues { $0.timeIntervalSince1970 }, forKey: Key.lastPushed)
        }
    }

    /// `ActionItem.id`s whose event the user deleted in Calendar. Never pushed
    /// again — see `CalendarEventPlanning.plan`.
    @ObservationIgnored private var forgotten: Set<String> {
        didSet { defaults.set(Array(forgotten), forKey: Key.forgotten) }
    }

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        writeEnabled = defaults.bool(forKey: Key.enabled)
        targetCalendarIdentifier = defaults.string(forKey: Key.calendar)
        let stored = defaults.dictionary(forKey: Key.lastPushed) as? [String: Double] ?? [:]
        lastPushed = stored.mapValues { Date(timeIntervalSince1970: $0) }
        forgotten = Set(defaults.stringArray(forKey: Key.forgotten) ?? [])
    }

    // MARK: - Authorization

    /// Whether events can be read *and* written.
    ///
    /// **Only `.fullAccess` will do** — see the type documentation for why
    /// `.writeOnly` cannot support this feature. Treating `.writeOnly` as usable
    /// would make every read come back empty, which the planner reads as "the user
    /// deleted every event" — and that tombstones the entire library in one pass.
    /// The `calendars(for:)` guard in `sync` is the second line of defence against
    /// exactly that.
    var canWriteEvents: Bool { authorizationStatus == .fullAccess }

    func refreshAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// Ask for full access to events, returning whether writing is now possible.
    ///
    /// Call this on first enable of the settings toggle, never at launch.
    ///
    /// Only ever prompts from `.notDetermined`, exactly as `CalendarMatcher` and
    /// `RemindersSync` do: iOS shows the alert once, so after a decision this just
    /// reports it. In practice it usually *won't* prompt at all, because
    /// `CalendarMatcher` has already asked for the same entity type — the two share
    /// one system permission even though they are separate stores.
    @discardableResult
    func requestAccess() async -> Bool {
        refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return canWriteEvents }
        // Throws on failure and returns false on denial. Neither is worth
        // surfacing: both mean "no calendar", which the status re-read records.
        _ = try? await store.requestFullAccessToEvents()
        refreshAuthorizationStatus()
        return canWriteEvents
    }

    // MARK: - Calendars

    /// The calendars new events could be created in, for a settings picker. Empty
    /// without access.
    ///
    /// Filtered to calendars that accept new content — a subscribed holiday feed or
    /// a read-only shared calendar would fail every save, silently.
    var availableCalendars: [TaskCalendarList] {
        guard canWriteEvents else { return [] }
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { TaskCalendarList(id: $0.calendarIdentifier, title: $0.title) }
    }

    /// The calendar new events go into: the user's choice if it still exists and is
    /// writable, otherwise the Calendar app's default.
    ///
    /// Nil means there is nowhere to write — no writable calendar at all — and
    /// creation is skipped rather than throwing per item.
    var targetCalendar: TaskCalendarList? {
        resolvedTargetCalendar().map { TaskCalendarList(id: $0.calendarIdentifier, title: $0.title) }
    }

    private func resolvedTargetCalendar() -> EKCalendar? {
        Self.resolveTargetCalendar(in: store, identifier: targetCalendarIdentifier)
    }

    /// The create-target resolution, factored out so both the main-actor
    /// `targetCalendar` picker property and the off-main `performSync` share one
    /// rule. `nonisolated` so the sync pass can call it off the main actor.
    nonisolated private static func resolveTargetCalendar(
        in store: EKEventStore, identifier: String?
    ) -> EKCalendar? {
        if let identifier,
           let calendar = store.calendar(withIdentifier: identifier),
           calendar.allowsContentModifications {
            return calendar
        }
        guard let fallback = store.defaultCalendarForNewEvents,
              fallback.allowsContentModifications
        else { return nil }
        return fallback
    }

    // MARK: - Sync

    /// Reconcile `tasks` with Apple Calendar, and report back what Bounce itself
    /// must now change.
    ///
    /// **This type never writes to the library.** It can't reach `RecordingStore`
    /// from here without knowing which recording each task belongs to, and a sync
    /// layer reaching into the store is the wrong seam anyway — the same division
    /// `RemindersSync` draws. So the caller applies `TaskCalendarOutcome` and then
    /// does the one `refreshLibrary()`.
    ///
    /// Safe to call repeatedly: with everything already in agreement the plan is
    /// empty, nothing is written, and the outcome is empty. That is what makes it
    /// suitable for an app-foreground hook.
    @discardableResult
    func sync(tasks: [CalendarTask]) async -> TaskCalendarOutcome {
        guard writeEnabled else { return .empty }
        refreshAuthorizationStatus()
        guard canWriteEvents else { return .empty }

        // Snapshot the main-actor state the reconciliation needs, then do every
        // EventKit fetch/save/commit off the main actor. These calls block on the
        // EventKit DB and used to run on main on *every foreground* — ~100 dated
        // tasks meant N synchronous lookups plus a batched commit stalling the UI.
        // The store is owned solely by this type and `sync` is called serially, so
        // it's safe off-main; only Sendable values cross the hop, and the
        // `@Published`/UserDefaults writes stay on main below.
        let store = self.store
        let lastPushedSnapshot = self.lastPushed
        let forgottenSnapshot = self.forgotten
        let targetId = self.targetCalendarIdentifier

        guard let result = await Task.detached(priority: .utility, operation: {
            Self.performSync(
                store: store,
                tasks: tasks,
                lastPushed: lastPushedSnapshot,
                forgotten: forgottenSnapshot,
                targetCalendarIdentifier: targetId)
        }).value else { return .empty }

        // Write back on main. Only when the value actually changed, matching the
        // previous conditional mutations — each assignment persists via `didSet`.
        if result.forgotten != self.forgotten { self.forgotten = result.forgotten }
        if result.lastPushed != self.lastPushed { self.lastPushed = result.lastPushed }
        return result.outcome
    }

    /// The updated state the main actor must persist after a sync pass.
    private struct SyncResult {
        var outcome: TaskCalendarOutcome
        var lastPushed: [String: Date]
        var forgotten: Set<String>
    }

    /// The whole EventKit reconciliation, off the main actor. Returns `nil` only
    /// when the store is unusable (mapped to `.empty` with no state change on main),
    /// otherwise the outcome plus the new `lastPushed`/`forgotten` for the caller to
    /// persist. Pure of `self`: everything it touches is passed in, which is what
    /// makes it safe to run off the actor.
    nonisolated private static func performSync(
        store: EKEventStore,
        tasks: [CalendarTask],
        lastPushed: [String: Date],
        forgotten: Set<String>,
        targetCalendarIdentifier: String?
    ) -> SyncResult? {
        var lastPushed = lastPushed
        var forgotten = forgotten

        // A store that can't answer must never be mistaken for an empty calendar.
        // `existing` is read by the planner as the complete truth about what
        // exists, so a blank read would unlink *and tombstone* every linked task at
        // once — unrecoverable short of toggling the setting off and on. Every
        // device with granted access has at least one event calendar, so an empty
        // list here means the store is not usable, not that the user has none.
        guard !store.calendars(for: .event).isEmpty else { return nil }

        // Resolved by identifier, one lookup per linked task, rather than by date
        // predicate. A predicate needs a window, and an event the user dragged
        // outside it would read as deleted and be tombstoned. It is also what
        // enforces "never touch an event Bounce didn't create": nothing but a
        // stored identifier can name an event here.
        let linkedIds = Set(tasks.compactMap { task -> String? in
            guard let id = task.item.calendarEventId, !id.isEmpty else { return nil }
            return id
        })
        var existing: [String: Date] = [:]
        existing.reserveCapacity(linkedIds.count)
        for eventId in linkedIds {
            guard let event = store.event(withIdentifier: eventId),
                  let start: Date = event.startDate
            else { continue }
            existing[eventId] = start
        }

        // Keep the tombstone set bounded by the library: a task the user deleted in
        // Bounce can never come back, so remembering it forever is pointless.
        let liveIds = Set(tasks.map(\.item.id))
        if !forgotten.isSubset(of: liveIds) { forgotten = forgotten.intersection(liveIds) }

        let plan = CalendarEventPlanning.plan(
            tasks: tasks,
            existing: existing,
            enabled: true,
            lastPushed: lastPushed,
            forgotten: forgotten)

        guard !plan.isEmpty else {
            // Still prune the baseline. An entry whose task was unlinked in an
            // earlier pass is no longer in `existing` and would otherwise linger
            // for the life of the install, since every other prune happens on a
            // pass that had work to do.
            lastPushed = CalendarEventPlanning.nextLastPushed(
                previous: lastPushed, existing: existing, removed: [], written: [:])
            return SyncResult(outcome: .empty, lastPushed: lastPushed, forgotten: forgotten)
        }

        // Bounce-side read-backs. These don't depend on anything reaching the
        // store, so they survive a failed commit.
        var outcome = TaskCalendarOutcome(
            linked: [:],
            unlinked: plan.toUnlink.map(\.itemId))

        if !plan.toForget.isEmpty { forgotten.formUnion(plan.toForget) }

        // Batched: every write with `commit: false`, then a single `commit()`. One
        // round trip instead of one per item, which matters on a first enable that
        // creates a hundred events at once.
        var pending: [(itemId: String, event: EKEvent)] = []
        // Only what actually landed feeds the next baseline and the read-backs. An
        // individual `save`/`remove` can throw while the rest of the batch is fine,
        // and recording an intent that failed is how `lastPushed` ends up
        // disagreeing with the calendar — see `nextLastPushed`.
        var written: [String: Date] = [:]
        var removedEventIds: [String] = []
        var clearedItemIds: [String] = []
        var didWrite = false

        if !plan.toCreate.isEmpty,
           let calendar = resolveTargetCalendar(in: store, identifier: targetCalendarIdentifier) {
            for task in plan.toCreate {
                guard let deadline = task.item.dueDate else { continue }
                let window = CalendarEventPlanning.window(endingAt: deadline)
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                event.title = CalendarEventPlanning.title(for: task.item)
                event.notes = CalendarEventPlanning.notes(for: task)
                event.startDate = window.start
                event.endDate = window.end
                event.addAlarm(EKAlarm(relativeOffset: CalendarEventPlanning.alarmOffset))
                // `.thisEvent` because nothing Bounce creates recurs. Saying so
                // rather than `.futureEvents` states the intent, and would refuse
                // to fan out if one of these ever did become recurring.
                guard (try? store.save(event, span: .thisEvent, commit: false)) != nil else { continue }
                pending.append((task.item.id, event))
                didWrite = true
            }
        }

        for update in plan.toUpdate {
            guard let event = store.event(withIdentifier: update.eventId) else { continue }
            event.startDate = update.start
            event.endDate = update.end
            // Title and notes are deliberately left alone. The date is the one
            // field Bounce keeps authoritative — see `CalendarEventPlanning` — and
            // re-pushing text would clobber a note the user added to the event.
            guard (try? store.save(event, span: .thisEvent, commit: false)) != nil else { continue }
            written[update.eventId] = update.start
            didWrite = true
        }

        for removal in plan.toRemove {
            guard let event = store.event(withIdentifier: removal.eventId) else {
                // Already gone, so the link is dead either way — clear it, but
                // don't tombstone: this is still Bounce's own removal, and the task
                // being reopened should put it back on the calendar.
                clearedItemIds.append(removal.itemId)
                continue
            }
            guard (try? store.remove(event, span: .thisEvent, commit: false)) != nil else { continue }
            removedEventIds.append(removal.eventId)
            clearedItemIds.append(removal.itemId)
            didWrite = true
        }

        if didWrite {
            do {
                try store.commit()
            } catch {
                // Nothing reached the database, so the identifiers on the events we
                // built are meaningless — drop them rather than storing dead links.
                // The read-backs above still stand.
                store.reset()
                return SyncResult(outcome: outcome, lastPushed: lastPushed, forgotten: forgotten)
            }
        }

        // `eventIdentifier` is read only after a successful commit, so a link is
        // never recorded for an event that doesn't exist.
        for entry in pending {
            let eventId: String? = entry.event.eventIdentifier
            guard let eventId, !eventId.isEmpty else { continue }
            outcome.linked[entry.itemId] = eventId
            if let start: Date = entry.event.startDate { written[eventId] = start }
        }
        outcome.cleared = clearedItemIds

        lastPushed = CalendarEventPlanning.nextLastPushed(
            previous: lastPushed,
            existing: existing,
            removed: removedEventIds,
            written: written)
        return SyncResult(outcome: outcome, lastPushed: lastPushed, forgotten: forgotten)
    }
}

/// A calendar, flattened, so no `EKCalendar` leaves `TaskCalendarWriter`.
struct TaskCalendarList: Identifiable, Hashable {
    /// `EKCalendar.calendarIdentifier`.
    let id: String
    let title: String
}

/// What Bounce must change about its own action items after a calendar pass.
///
/// Returned rather than applied because `TaskCalendarWriter` doesn't own the
/// library — see `TaskCalendarWriter.sync(tasks:)`. Mirrors
/// `ReminderSyncOutcome`'s shape, minus a completion read-back: Calendar has no
/// notion of a done event, so nothing flows back from it.
struct TaskCalendarOutcome: Equatable {

    /// `ActionItem.id` → the identifier of the event just created for it. The
    /// caller sets `calendarEventId`.
    var linked: [String: String] = [:]

    /// `ActionItem.id`s whose event no longer exists, or whose link was a
    /// duplicate. The caller sets `calendarEventId = nil`. Those the user deleted
    /// are already tombstoned and will not be pushed again; a duplicate will get an
    /// event of its own next pass.
    var unlinked: [String] = []

    /// `ActionItem.id`s whose event Bounce itself deleted, because the task was
    /// ticked off or lost its deadline. The caller sets `calendarEventId = nil`.
    /// **Not** tombstoned: reopening the task, or giving it a date again, should
    /// put it back on the calendar.
    var cleared: [String] = []

    static let empty = TaskCalendarOutcome()

    /// Nothing changed, so there is nothing to write and nothing to refresh.
    var isEmpty: Bool { linked.isEmpty && unlinked.isEmpty && cleared.isEmpty }
}
