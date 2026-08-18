import EventKit
import Foundation
import Observation

/// Mirrors Bounce's action items into Apple Reminders.
///
/// This is the EventKit half; every reconciliation rule lives in
/// `ReminderPlanning`, which is EventKit-free and therefore testable on the Mac
/// (`tools/reminders-sync-tests/main.swift`). This half only fetches, writes, and
/// remembers the little state the planner needs. **Read `ReminderPlanning`'s
/// documentation first** — it is where the per-field direction of the sync and
/// the conflict rules are written down.
///
/// The same store as `CalendarMatcher` (`EKEventStore`), a different entity type
/// (`.reminder`), and a **separate permission**: granting calendar access grants
/// nothing here, and `NSRemindersFullAccessUsageDescription` must be in
/// `Info.plist` or iOS denies the request without even showing a prompt.
///
/// Three rules, two of them borrowed from `CalendarMatcher` and one that has to
/// differ:
///
/// - **Denial is silent and total.** Without full access `sync` does nothing and
///   returns an empty outcome — no error, no banner — and `requestAccess` won't
///   ask a second time.
/// - **No `EKReminder` escapes this file.** Reminders are read as
///   `ReminderSnapshot` (an identifier and a flag) and lists as `ReminderList`.
///   `ReminderSyncOutcome` is plain strings.
/// - **Unlike `CalendarMatcher`, this writes.** So it does hold `EKReminder`
///   objects — but only inside a single `sync` call, long enough to save them,
///   never as stored state.
///
/// Nothing here logs. A task's text is as personal as a transcript, and this app
/// has no redaction layer.
@MainActor
@Observable
final class RemindersSync {

    static let shared = RemindersSync()

    /// Cheap to hold and needed for the lifetime of the app; a fresh store per
    /// sync re-warms the connection for nothing. Separate from
    /// `CalendarMatcher`'s deliberately — one store per feature keeps an
    /// uncommitted write in one from being committed by the other.
    @ObservationIgnored private let store = EKEventStore()

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Mirrors `EKEventStore.authorizationStatus(for: .reminder)` so views can
    /// react. Refreshed by `refreshAuthorizationStatus()`, since the user can
    /// revoke access in Settings while the app is backgrounded.
    private(set) var authorizationStatus: EKAuthorizationStatus

    // MARK: - Settings
    //
    // UserDefaults-backed and read straight from views as `RemindersSync.shared`,
    // the `DeliverySettings` pattern for synchronous local preference state. The
    // keys live here rather than in `SettingsKey` only because this type owns
    // them entirely; move them if a second reader ever appears.

    private enum Key {
        static let enabled = "remindersSyncEnabled"
        static let list = "remindersSyncListIdentifier"
        static let lastSeen = "remindersSyncLastSeen"
        static let forgotten = "remindersSyncForgotten"
    }

    /// Push action items to Apple Reminders.
    ///
    /// Off by default, and **not** flipped on by granting access: mirroring the
    /// user's tasks into another app is something to opt into explicitly, and
    /// permission is requested on first enable rather than at launch.
    /// `bool(forKey:)` is correct here precisely because the default is off — a
    /// default-ON Bool would need `object(forKey:) as? Bool ?? true`.
    ///
    /// Turning it on clears `forgotten`, so reminders the user deleted are
    /// eligible again. That's the only escape from "deleted means gone", and
    /// re-enabling is an explicit enough gesture to be it.
    var syncEnabled: Bool {
        didSet {
            defaults.set(syncEnabled, forKey: Key.enabled)
            if syncEnabled, !oldValue { forgotten = [] }
        }
    }

    /// `EKCalendar.calendarIdentifier` of the list new reminders go into, or nil
    /// to follow the Reminders app's own default list.
    ///
    /// Only consulted when *creating*. Existence and completion are read across
    /// every list (see `fetchSnapshot`), so moving a synced reminder into another
    /// list in the Reminders app keeps it linked rather than looking deleted.
    var targetListIdentifier: String? {
        didSet { defaults.set(targetListIdentifier, forKey: Key.list) }
    }

    /// What Reminders said about each reminder at the end of the last pass. See
    /// `ReminderPlanning` — this is what makes "which side changed?" answerable.
    @ObservationIgnored private var lastSeen: [String: Bool] {
        didSet { defaults.set(lastSeen, forKey: Key.lastSeen) }
    }

    /// `ActionItem.id`s whose reminder the user deleted in the Reminders app.
    /// Never pushed again — see `ReminderPlanning.plan`.
    @ObservationIgnored private var forgotten: Set<String> {
        didSet { defaults.set(Array(forgotten), forKey: Key.forgotten) }
    }

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        syncEnabled = defaults.bool(forKey: Key.enabled)
        targetListIdentifier = defaults.string(forKey: Key.list)
        lastSeen = defaults.dictionary(forKey: Key.lastSeen) as? [String: Bool] ?? [:]
        forgotten = Set(defaults.stringArray(forKey: Key.forgotten) ?? [])
    }

    // MARK: - Authorization

    /// Whether reminders can be read *and* written.
    ///
    /// **Only `.fullAccess` will do.** `.writeOnly` exists for calendar events
    /// only — there is no write-only tier for reminders — and treating anything
    /// looser as usable here would make the fetch come back empty, which the
    /// planner would read as "the user deleted every reminder".
    var canSyncReminders: Bool { authorizationStatus == .fullAccess }

    func refreshAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    /// Ask for full access to reminders, returning whether syncing is now
    /// possible.
    ///
    /// Call this on first enable of the settings toggle, never at launch.
    ///
    /// Only ever prompts from `.notDetermined`, exactly as `CalendarMatcher`
    /// does: iOS shows the alert once, so after a decision this just reports it.
    /// A user who denied and changed their mind goes through Settings, which
    /// `refreshAuthorizationStatus()` picks up.
    @discardableResult
    func requestAccess() async -> Bool {
        refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return canSyncReminders }
        // Throws on failure and returns false on denial. Neither is worth
        // surfacing: both mean "no Reminders", which the status re-read records.
        _ = try? await store.requestFullAccessToReminders()
        refreshAuthorizationStatus()
        return canSyncReminders
    }

    // MARK: - Lists

    /// The reminder lists new reminders could be created in, for a settings
    /// picker. Empty without access.
    ///
    /// Filtered to lists that accept new content — a subscribed or read-only list
    /// would fail every save, silently.
    var availableLists: [ReminderList] {
        guard canSyncReminders else { return [] }
        return store.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
    }

    /// The list new reminders go into: the user's choice if it still exists and
    /// is writable, otherwise the Reminders app's default.
    ///
    /// Nil means there is nowhere to write — no reminder list at all, or the
    /// default one is read-only — and creation is skipped rather than throwing
    /// per item.
    var targetList: ReminderList? {
        Self.resolveTargetCalendar(in: store, identifier: targetListIdentifier)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
    }

    /// The create-target resolution, factored out so both the main-actor
    /// `targetList` picker property and the off-main `performSync` share one rule.
    /// `nonisolated` so the sync pass can call it off the main actor.
    ///
    /// Resolved against the **live** set — **never `store.calendar(withIdentifier:)`.**
    /// That can hand back a stale, zombie `EKCalendar` for a list the user deleted in
    /// the Reminders app — the object still answers to its identifier, so the write
    /// "succeeds" against a list that isn't there and silently reaches nothing (device
    /// log: `Requested to fetch non-existent list …`). Membership in
    /// `calendars(for: .reminder)` is the truth: a deleted list is absent from it, so a
    /// stored identifier that no longer appears there falls through to the Reminders
    /// app's default list rather than a ghost.
    ///
    /// Pure — it does not clear the stored identifier, so it is safe to call from a
    /// view-read (`targetList`). `reconcileTargetList()` on the write path does the
    /// clearing.
    nonisolated private static func resolveTargetCalendar(
        in store: EKEventStore, identifier: String?
    ) -> EKCalendar? {
        let writable = store.calendars(for: .reminder).filter(\.allowsContentModifications)
        if let identifier,
           let match = writable.first(where: { $0.calendarIdentifier == identifier }) {
            return match
        }
        guard let fallback = store.defaultCalendarForNewReminders(),
              fallback.allowsContentModifications
        else { return nil }
        return fallback
    }

    /// Forget a stored target-list identifier that no longer names a writable list
    /// — the user deleted it in the Reminders app. Creation then falls back to the
    /// default list (see `resolveTargetCalendar(in:identifier:)`), and the Settings
    /// picker stops showing a dead selection.
    ///
    /// Write-path only: it mutates the observed `targetListIdentifier`, so it must
    /// never run from inside a SwiftUI view read.
    private func reconcileTargetList() {
        guard let identifier = targetListIdentifier else { return }
        let stillThere = store.calendars(for: .reminder)
            .contains { $0.calendarIdentifier == identifier && $0.allowsContentModifications }
        if !stillThere { targetListIdentifier = nil }
    }

    // MARK: - Sync

    /// Reconcile `items` with Apple Reminders, and report back what Bounce itself
    /// must now change.
    ///
    /// **This type never writes to the library.** It can't reach `RecordingStore`
    /// from here without knowing which recording each item belongs to, and a
    /// sync layer reaching into the store is the wrong seam anyway. So the
    /// caller applies `ReminderSyncOutcome` — the three Bounce-side edits — and
    /// then does the one `refreshLibrary()`.
    ///
    /// Safe to call repeatedly: with everything already in agreement the plan is
    /// empty, nothing is written, and the outcome is empty. That is what makes it
    /// suitable for an app-foreground hook.
    @discardableResult
    func sync(items: [ActionItem]) async -> ReminderSyncOutcome {
        guard syncEnabled else { return .empty }
        refreshAuthorizationStatus()
        guard canSyncReminders else { return .empty }

        // Start from a fresh view of the store before resolving anything.
        // `EKEventStore` caches, and a list deleted in the Reminders app can linger
        // in that cache — which is what let a write target a zombie list. `reset()`
        // refreshes it (nothing here holds an uncommitted change to lose), and
        // nothing in the app observes the `EKEventStoreChanged` it posts, so there is
        // no re-entry to guard against. Done on the main actor, before the off-main
        // pass, so `reconcileTargetList()` — which mutates the observed
        // `targetListIdentifier` — can run here where that mutation is legal, and so
        // the snapshot taken below already reflects a dropped dead list.
        store.reset()
        // Drop a stored target list the user has since deleted, so creation falls
        // back to the default list instead of failing against a ghost, and the
        // Settings picker stops showing a dead selection.
        reconcileTargetList()

        // Snapshot the main-actor state, then do the fetch *and* every
        // `calendarItem(withIdentifier:)`/`save`/`commit` off the main actor. The
        // fetch was already async, but the reconciliation after it ran back on main
        // on *every foreground* — N synchronous lookups plus a batched commit. The
        // store is owned solely by this type and `sync` is called serially, so it's
        // safe off-main; only Sendable values cross the hop and the
        // `@Published`/UserDefaults writes stay on main below.
        let store = self.store
        let lastSeenSnapshot = self.lastSeen
        let forgottenSnapshot = self.forgotten
        let targetId = self.targetListIdentifier

        guard let result = await Task.detached(priority: .utility, operation: {
            await Self.performSync(
                store: store,
                items: items,
                lastSeen: lastSeenSnapshot,
                forgotten: forgottenSnapshot,
                targetListIdentifier: targetId)
        }).value else { return .empty }

        // Write back on main. Only when the value actually changed, matching the
        // previous conditional mutations — each assignment persists via `didSet`.
        if result.lastSeen != self.lastSeen { self.lastSeen = result.lastSeen }
        if result.forgotten != self.forgotten { self.forgotten = result.forgotten }
        return result.outcome
    }

    /// The updated state the main actor must persist after a sync pass.
    private struct SyncResult {
        var outcome: ReminderSyncOutcome
        var lastSeen: [String: Bool]
        var forgotten: Set<String>
    }

    /// The whole EventKit reconciliation, off the main actor. Returns `nil` only
    /// when the fetch fails (mapped to `.empty` with no state change on main),
    /// otherwise the outcome plus the new `lastSeen`/`forgotten` for the caller to
    /// persist. Pure of `self`: everything it touches is passed in, which is what
    /// makes it safe to run off the actor.
    nonisolated private static func performSync(
        store: EKEventStore,
        items: [ActionItem],
        lastSeen: [String: Bool],
        forgotten: Set<String>,
        targetListIdentifier: String?
    ) async -> SyncResult? {
        var lastSeen = lastSeen
        var forgotten = forgotten

        // A failed fetch must never be mistaken for an empty one. `existing` is
        // read by the planner as the complete truth about what exists, so `[:]`
        // from a fetch that didn't work would unlink every synced item at once.
        guard let snapshot = await fetchSnapshot(store: store) else { return nil }

        var existing: [String: Bool] = [:]
        existing.reserveCapacity(snapshot.count)
        for reminder in snapshot { existing[reminder.id] = reminder.isCompleted }

        // Keep the tombstone set bounded by the library: an item the user deleted
        // in Bounce can never come back, so remembering it forever is pointless.
        let liveIds = Set(items.map(\.id))
        if !forgotten.isSubset(of: liveIds) { forgotten = forgotten.intersection(liveIds) }

        let plan = ReminderPlanning.plan(
            items: items,
            existing: existing,
            syncEnabled: true,
            lastSeen: lastSeen,
            forgotten: forgotten)

        guard !plan.isEmpty else {
            // Still record what Reminders currently says, or a change made there
            // that happens to agree with Bounce would never become the baseline.
            lastSeen = existing
            return SyncResult(outcome: .empty, lastSeen: lastSeen, forgotten: forgotten)
        }

        // Bounce-side read-backs. These don't depend on anything being written to
        // the store, so they survive a failed commit.
        var outcome = ReminderSyncOutcome(
            linked: [:],
            completed: plan.completedInReminders,
            unlinked: plan.toUnlink)

        if !plan.toUnlink.isEmpty { forgotten.formUnion(plan.toUnlink) }

        // Which pushed items we're trying to create a reminder for this pass. What
        // doesn't end up in `outcome.linked` after the commit failed to write, and
        // the explicit-send path uses it to tell the user (and to keep those items
        // from wrongly showing "Sent").
        let attemptedCreateIds = Set(plan.toCreate.map(\.id))

        // Batched: every write with `commit: false`, then a single `commit()`.
        // One round trip instead of one per item, which matters on a first enable
        // that creates a hundred reminders at once.
        var pending: [(itemId: String, reminder: EKReminder)] = []
        var didWrite = false

        if !plan.toCreate.isEmpty,
           let calendar = resolveTargetCalendar(in: store, identifier: targetListIdentifier) {
            for item in plan.toCreate {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = calendar
                reminder.title = item.text
                reminder.notes = notes(for: item)
                // The spoken deadline (`dueText`) stays in the notes as the
                // evidence, and when `DueDateResolver` managed to turn it into a
                // real, validated instant (`dueDate`) that instant is set on the
                // reminder so it actually alerts.
                //
                // This is only safe *because* `dueDate` is validated: it is nil
                // unless a date was spoken and survived `DueDateResolver`'s hard
                // checks, so Bounce never fabricates a deadline — an undated task
                // stays undated in Reminders, exactly as before. The earlier
                // build set no date at all because there was no trustworthy one to
                // set; there is now.
                applyDueDate(item.dueDate, to: reminder)
                guard (try? store.save(reminder, commit: false)) != nil else { continue }
                pending.append((item.id, reminder))
                didWrite = true
            }
        }

        for reminderId in plan.toComplete {
            guard let reminder = reminder(in: store, withIdentifier: reminderId) else { continue }
            reminder.isCompleted = true
            guard (try? store.save(reminder, commit: false)) != nil else { continue }
            didWrite = true
        }

        for reminderId in plan.toUncomplete {
            guard let reminder = reminder(in: store, withIdentifier: reminderId) else { continue }
            // Setting `completed` to false clears `completionDate` itself; the
            // two properties are documented as inextricably linked.
            reminder.isCompleted = false
            guard (try? store.save(reminder, commit: false)) != nil else { continue }
            didWrite = true
        }

        if didWrite {
            do {
                try store.commit()
            } catch {
                // Nothing reached the database, so the identifiers on the
                // reminders we built are meaningless — drop them rather than
                // storing dead links. The read-backs above still stand. Every
                // attempted creation failed, so the caller can say so.
                store.reset()
                lastSeen = existing
                outcome.failedToCreate = Array(attemptedCreateIds)
                return SyncResult(outcome: outcome, lastSeen: lastSeen, forgotten: forgotten)
            }
        }

        // `calendarItemIdentifier` is read only after a successful commit, so a
        // link is never recorded for a reminder that doesn't exist.
        for entry in pending { outcome.linked[entry.itemId] = entry.reminder.calendarItemIdentifier }

        // Anything we meant to create but didn't link — no writable list at all, or
        // a per-item save that failed — is a creation that silently reached nowhere.
        // The explicit-send path surfaces it and keeps those items un-"Sent".
        outcome.failedToCreate = Array(attemptedCreateIds.subtracting(outcome.linked.keys))

        lastSeen = ReminderPlanning.nextLastSeen(
            existing: existing,
            plan: plan,
            created: Array(outcome.linked.values))
        return SyncResult(outcome: outcome, lastSeen: lastSeen, forgotten: forgotten)
    }

    // MARK: - Store access

    /// Every reminder the app can see, flattened to an identifier and a flag.
    ///
    /// Nil means the fetch failed — which callers must not treat as "there are no
    /// reminders". An empty array means exactly that.
    ///
    /// `calendars: nil` fetches across **every** list rather than just the target
    /// one, on purpose: a reminder the user dragged into a different list is
    /// still theirs, and scoping the fetch would make it look deleted and unlink
    /// it. `predicateForReminders(in:)` matches completed and incomplete alike,
    /// which is what the completion read-back needs.
    ///
    /// `nonisolated static` over the passed-in store so `performSync` can drive it
    /// off the main actor.
    nonisolated private static func fetchSnapshot(store: EKEventStore) async -> [ReminderSnapshot]? {
        let predicate = store.predicateForReminders(in: nil)
        return await withCheckedContinuation { continuation in
            // The return value is a fetch handle for `cancelFetchRequest`; there
            // is nothing to cancel here. The completion arrives on an arbitrary
            // queue, so the reminders are reduced to `Sendable` values right
            // there rather than being carried back to the main actor.
            _ = store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: reminders.map {
                    ReminderSnapshot(id: $0.calendarItemIdentifier, isCompleted: $0.isCompleted)
                })
            }
        }
    }

    /// The live object behind an identifier, or nil if it has since gone.
    ///
    /// A stale identifier returns nil rather than throwing or crashing, which is
    /// what makes "the user deleted the reminder" an ordinary case. Reminders to
    /// mutate are re-resolved this way instead of being held from the snapshot,
    /// so no `EKReminder` ever crosses an actor boundary.
    nonisolated private static func reminder(
        in store: EKEventStore, withIdentifier identifier: String
    ) -> EKReminder? {
        store.calendarItem(withIdentifier: identifier) as? EKReminder
    }

    /// Set a validated deadline on a freshly built reminder, or leave it undated.
    ///
    /// A no-op for a nil `dueDate`, so an undated task creates an undated reminder
    /// exactly as before — the caller passes `item.dueDate` straight through, and
    /// that is nil unless `DueDateResolver` validated a spoken deadline.
    ///
    /// `dueDateComponents` carries the day *and* the time of day (9am by default,
    /// or the spoken hour — `DueDateResolver.defaultHour`), which is what makes the
    /// reminder a timed one that alerts rather than a silent all-day entry. An
    /// **absolute** `EKAlarm` is added on the same instant to guarantee the
    /// notification fires: an absolute alarm is anchored to a concrete date and so
    /// needs no `startDateComponents`, sidestepping the `EKErrorNoStartDate` a
    /// relative alarm would demand one for. Only ever a date the resolver produced,
    /// never a fabricated one.
    nonisolated private static func applyDueDate(_ dueDate: Date?, to reminder: EKReminder) {
        guard let dueDate else { return }
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: dueDate)
        reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
    }

    /// Owner and deadline as the reminder's notes, or nil when neither is known.
    ///
    /// Labelled rather than run together — the reminder's title is already the
    /// task, so an unlabelled "Ana · by Friday" underneath it reads as a fragment
    /// once it's out of Bounce's own row layout.
    nonisolated private static func notes(for item: ActionItem) -> String? {
        var lines: [String] = []
        if let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            lines.append("Owner: \(owner)")
        }
        if let due = item.dueText?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
            lines.append("Due: \(due)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// One reminder, flattened. See `RemindersSync.fetchSnapshot`.
private struct ReminderSnapshot: Sendable {
    let id: String
    let isCompleted: Bool
}

/// A reminder list, flattened, so no `EKCalendar` leaves `RemindersSync`.
struct ReminderList: Identifiable, Hashable {
    /// `EKCalendar.calendarIdentifier`.
    let id: String
    let title: String
}

/// What Bounce must change about its own action items after a sync.
///
/// Returned rather than applied because `RemindersSync` doesn't own the library —
/// see `RemindersSync.sync(items:)`.
struct ReminderSyncOutcome: Equatable {

    /// `ActionItem.id` → the identifier of the reminder just created for it. The
    /// caller sets `reminderId`.
    var linked: [String: String] = [:]

    /// `ActionItem.id`s the user ticked in the Reminders app. The caller sets
    /// `isDone = true`.
    var completed: [String] = []

    /// `ActionItem.id`s whose reminder no longer exists. The caller sets
    /// `reminderId = nil`. They will not be pushed again.
    var unlinked: [String] = []

    /// `ActionItem.id`s the user pushed but whose reminder could not be written —
    /// no writable list, or the EventKit commit failed. **Not** a Bounce-side edit
    /// like the others: it exists so an explicit Send can tell the user it failed,
    /// and can keep those items from wrongly showing "Sent". Empty on a clean pass.
    var failedToCreate: [String] = []

    static let empty = ReminderSyncOutcome()

    /// Nothing changed, so there is nothing to write and nothing to refresh.
    ///
    /// `failedToCreate` is deliberately excluded: it isn't a change to apply, and a
    /// pass that only *failed* to create still has nothing for the caller to write
    /// back — but the failure itself is read separately by the send path.
    var isEmpty: Bool { linked.isEmpty && completed.isEmpty && unlinked.isEmpty }
}
