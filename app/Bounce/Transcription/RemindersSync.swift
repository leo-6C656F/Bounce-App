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
        targetCalendar().map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
    }

    private func targetCalendar() -> EKCalendar? {
        if let identifier = targetListIdentifier,
           let calendar = store.calendar(withIdentifier: identifier),
           calendar.allowsContentModifications {
            return calendar
        }
        guard let fallback = store.defaultCalendarForNewReminders(),
              fallback.allowsContentModifications
        else { return nil }
        return fallback
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

        // A failed fetch must never be mistaken for an empty one. `existing` is
        // read by the planner as the complete truth about what exists, so `[:]`
        // from a fetch that didn't work would unlink every synced item at once.
        guard let snapshot = await fetchSnapshot() else { return .empty }

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
            return .empty
        }

        // Bounce-side read-backs. These don't depend on anything being written to
        // the store, so they survive a failed commit.
        var outcome = ReminderSyncOutcome(
            linked: [:],
            completed: plan.completedInReminders,
            unlinked: plan.toUnlink)

        if !plan.toUnlink.isEmpty { forgotten.formUnion(plan.toUnlink) }

        // Batched: every write with `commit: false`, then a single `commit()`.
        // One round trip instead of one per item, which matters on a first enable
        // that creates a hundred reminders at once.
        var pending: [(itemId: String, reminder: EKReminder)] = []
        var didWrite = false

        if !plan.toCreate.isEmpty, let calendar = targetCalendar() {
            for item in plan.toCreate {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = calendar
                reminder.title = item.text
                reminder.notes = Self.notes(for: item)
                // Owner and deadline go in the notes, and the due date is
                // deliberately left unset. `ActionItem.dueText` is the deadline
                // exactly as it was spoken — "by Friday", "end of the month",
                // "before the board meeting" — not a date, on purpose (see the
                // type's own documentation): the on-device model has no reliable
                // notion of what today is, so resolving one would be a guess, and
                // a guessed date is worse than a phrase because a phrase is
                // obviously approximate while a date looks authoritative. Setting
                // `dueDateComponents` would also drag in `startDateComponents`,
                // which iOS requires alongside it or the save fails with
                // `EKErrorNoStartDate` — a second invented date to prop up the
                // first.
                guard (try? store.save(reminder, commit: false)) != nil else { continue }
                pending.append((item.id, reminder))
                didWrite = true
            }
        }

        for reminderId in plan.toComplete {
            guard let reminder = self.reminder(withIdentifier: reminderId) else { continue }
            reminder.isCompleted = true
            guard (try? store.save(reminder, commit: false)) != nil else { continue }
            didWrite = true
        }

        for reminderId in plan.toUncomplete {
            guard let reminder = self.reminder(withIdentifier: reminderId) else { continue }
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
                // storing dead links. The read-backs above still stand.
                store.reset()
                lastSeen = existing
                return outcome
            }
        }

        // `calendarItemIdentifier` is read only after a successful commit, so a
        // link is never recorded for a reminder that doesn't exist.
        for entry in pending { outcome.linked[entry.itemId] = entry.reminder.calendarItemIdentifier }

        lastSeen = ReminderPlanning.nextLastSeen(
            existing: existing,
            plan: plan,
            created: Array(outcome.linked.values))
        return outcome
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
    private func fetchSnapshot() async -> [ReminderSnapshot]? {
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
    private func reminder(withIdentifier identifier: String) -> EKReminder? {
        store.calendarItem(withIdentifier: identifier) as? EKReminder
    }

    /// Owner and deadline as the reminder's notes, or nil when neither is known.
    ///
    /// Labelled rather than run together — the reminder's title is already the
    /// task, so an unlabelled "Ana · by Friday" underneath it reads as a fragment
    /// once it's out of Bounce's own row layout.
    private static func notes(for item: ActionItem) -> String? {
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

    static let empty = ReminderSyncOutcome()

    /// Nothing changed, so there is nothing to write and nothing to refresh.
    var isEmpty: Bool { linked.isEmpty && completed.isEmpty && unlinked.isEmpty }
}
