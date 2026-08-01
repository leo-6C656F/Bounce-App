import Foundation

/// The pure half of Reminders sync: working out what one reconciliation pass
/// between Bounce's action items and Apple Reminders should actually do.
///
/// Split out of `RemindersSync.swift` — which imports EventKit and drives a live
/// `EKEventStore` — for the same reason `CalendarMatching` is split out of
/// `CalendarMatcher`: there is no test target and no simulator, so logic that can
/// be compiled and exercised on the Mac should live somewhere it can be. See
/// `tools/reminders-sync-tests/main.swift`, which compiles this file and the real
/// `ActionItem` from `ActionItemMerge.swift` — no stubs.
///
/// ## The sync is one-way, with a completion read-back
///
/// Bounce is authoritative for everything about a task **except whether it has
/// been ticked**. Full two-way sync needs conflict resolution for every field
/// plus deletion detection in both directions, and every one of those decisions
/// has a wrong answer that silently loses a user's edit. So, per field:
///
/// | Field | Direction |
/// |---|---|
/// | existence (Bounce → Reminders) | pushed once, on create |
/// | `text` → reminder title | written at create, **never updated** |
/// | `owner`, `dueText` → reminder notes | written at create, **never updated** |
/// | `isDone` ↔ reminder completion | **both ways** — see below |
/// | reminder deleted in Reminders | link dropped, never recreated |
/// | reminder edited in Reminders | left alone; Bounce never reads it back |
/// | item deleted in Bounce | reminder left alone |
///
/// Text is written once rather than kept in step because doing it properly needs
/// a record of what was last pushed, and without one a re-push clobbers a title
/// the user retyped in Reminders. Leaving it is the failure mode that loses
/// nothing.
///
/// Completion is the exception because it's the one that stings: ticking a
/// reminder in the Reminders app and having Bounce's Tasks tab not notice is the
/// single most annoying way this feature could fail.
///
/// ## Which side wins when the two disagree
///
/// `lastSeen` is what Reminders said about each reminder at the end of the
/// previous pass. It is what makes "who changed?" answerable:
///
/// - **Reminders still says what it said last time** → Bounce is the side that
///   moved, so push Bounce's state. This is the *only* way `toUncomplete` is ever
///   produced, and it is what lets a user untick a task in Bounce and have it
///   untick in Reminders too.
/// - **Reminders says something new**, or there is no baseline at all → adopt
///   Reminders' state, but only in the tick direction: a completed reminder marks
///   the Bounce item done (`completedInReminders`), whereas a reminder *un*ticked
///   in the Reminders app is not honoured — Bounce re-ticks it (`toComplete`).
///   Read-back exists so a tick isn't missed, not so Reminders can reopen a task
///   the user already finished.
///
/// With `lastSeen` left empty the whole thing degrades to exactly the two obvious
/// stateless rules — done in Bounce and not in Reminders is completed there, done
/// in Reminders and not in Bounce flows back — and `toUncomplete` is simply never
/// populated, because statelessly an untick in Bounce is indistinguishable from a
/// tick in Reminders. That is why the parameter exists.
struct ReminderPlan: Equatable {

    /// Items with no reminder yet. The caller creates one each and records the
    /// resulting identifier back onto `ActionItem.reminderId`.
    var toCreate: [ActionItem] = []

    /// Reminder identifiers to mark completed in the Reminders app.
    var toComplete: [String] = []

    /// Reminder identifiers to mark *not* completed in the Reminders app.
    var toUncomplete: [String] = []

    /// `ActionItem.id`s the user ticked in the Reminders app. The caller sets
    /// `isDone = true` on each.
    var completedInReminders: [String] = []

    /// `ActionItem.id`s whose reminder no longer exists. The caller sets
    /// `reminderId = nil` on each — and must not recreate it; see
    /// `ReminderPlanning.plan(items:existing:syncEnabled:lastSeen:forgotten:)`.
    var toUnlink: [String] = []

    static let empty = ReminderPlan()

    /// True when there is nothing at all to do — which is the normal outcome of
    /// a repeated sync, and the reason this runs cheaply on every foreground.
    var isEmpty: Bool {
        toCreate.isEmpty
            && toComplete.isEmpty
            && toUncomplete.isEmpty
            && completedInReminders.isEmpty
            && toUnlink.isEmpty
    }
}

enum ReminderPlanning {

    /// What to do to bring Bounce's action items and Apple Reminders back into
    /// agreement.
    ///
    /// Every item falls into **at most one** bucket, so no item is ever both
    /// created and completed, or both completed and unlinked. Applying the
    /// returned plan and planning again yields `ReminderPlan.empty` (provided the
    /// caller carries `lastSeen` forward with `nextLastSeen(existing:plan:created:)`
    /// and `forgotten` with `toUnlink`) — the plan is a fixed point, which is what
    /// makes it safe to run on every app foreground.
    ///
    /// - Parameters:
    ///   - items: every action item across the library, in any order.
    ///   - existing: reminder identifier → whether that reminder is completed, as
    ///     Reminders reports it *right now*. This must be a **complete** picture:
    ///     an identifier missing from it is read as "the user deleted that
    ///     reminder". A failed fetch must never be passed here as `[:]`, or every
    ///     linked item is unlinked at once — the EventKit layer distinguishes a
    ///     fetch that returned nothing from one that failed, and refuses to plan
    ///     on the latter.
    ///   - syncEnabled: the user's setting. False returns an empty plan and
    ///     touches nothing, so turning the feature off freezes both sides where
    ///     they are rather than tearing anything down.
    ///   - lastSeen: `existing` as of the end of the previous pass. Empty on a
    ///     first run, which is handled — see the type's documentation.
    ///   - forgotten: `ActionItem.id`s whose reminder was previously deleted in
    ///     the Reminders app.
    ///
    ///     **This is what stops a deleted reminder resurrecting.** Unlinking
    ///     alone can't: it sets `reminderId` to nil, which makes the item
    ///     indistinguishable from one that was never pushed, so the very next
    ///     pass would create the reminder again — and again after the user
    ///     deletes it again. Recreating fights the user, so a deleted reminder
    ///     means "forget the link", permanently. The caller persists this set;
    ///     the escape hatch is turning the setting off and on again, which is an
    ///     explicit "sync my tasks" gesture and clears it.
    static func plan(
        items: [ActionItem],
        existing: [String: Bool],
        syncEnabled: Bool,
        lastSeen: [String: Bool] = [:],
        forgotten: Set<String> = []
    ) -> ReminderPlan {
        guard syncEnabled else { return .empty }

        var plan = ReminderPlan()
        // Two items must never drive one reminder: the second would fight the
        // first over its completion state, and could land the same identifier in
        // both `toComplete` and `toUncomplete`.
        var claimed = Set<String>()

        for item in items {
            guard let reminderId = item.reminderId, !reminderId.isEmpty else {
                // Never pushed. Create one, unless there's nothing to chase or
                // the user has already thrown its reminder away once.
                //
                // Already-done items are deliberately **not** created. Pushing a
                // pre-completed reminder puts nothing in front of the user, and
                // first-enable on a mature library would dump every historical
                // finished task into the Reminders app at once. The rule is
                // stable — `isDone` doesn't change as a result of syncing — so
                // this stays idempotent, and an item the user unticks later
                // becomes eligible and is created then.
                if !item.isDone, !forgotten.contains(item.id) {
                    plan.toCreate.append(item)
                }
                continue
            }

            guard claimed.insert(reminderId).inserted else {
                // A duplicated link, which shouldn't happen but would be poison
                // if it did. The first item keeps the reminder; the rest lose
                // theirs and get their own on a later pass.
                plan.toUnlink.append(item.id)
                continue
            }

            guard let remote = existing[reminderId] else {
                // Linked to a reminder that isn't there any more. `forgotten`
                // keeps it from coming back.
                plan.toUnlink.append(item.id)
                continue
            }

            if item.isDone == remote { continue }

            if lastSeen[reminderId] == remote {
                // Reminders hasn't moved since the last pass, so Bounce is the
                // side that changed. Push it, in whichever direction.
                if item.isDone {
                    plan.toComplete.append(reminderId)
                } else {
                    plan.toUncomplete.append(reminderId)
                }
            } else if remote {
                // Ticked in the Reminders app. This is the read-back the whole
                // design exists for.
                plan.completedInReminders.append(item.id)
            } else {
                // Unticked in the Reminders app while Bounce still has it done.
                // Not honoured: Bounce stays authoritative for everything but the
                // tick, so the reminder is re-completed. Doing it now rather than
                // leaving the two disagreeing keeps the plan a fixed point —
                // there is no stable "leave it alone" here, because the next pass
                // would see a matching baseline, conclude Bounce had moved, and
                // push anyway.
                plan.toComplete.append(reminderId)
            }
        }

        return plan
    }

    /// `existing` advanced by everything `plan` is about to do, to be carried into
    /// the next pass as `lastSeen`.
    ///
    /// Derived from the *current* fetch rather than accumulated, so identifiers
    /// for reminders that no longer exist drop out on their own and this can't
    /// grow without bound.
    ///
    /// - Parameter created: identifiers of the reminders just created. They are
    ///   recorded as open, because `plan` only ever creates open ones.
    static func nextLastSeen(
        existing: [String: Bool],
        plan: ReminderPlan,
        created: [String]
    ) -> [String: Bool] {
        var result = existing
        for reminderId in plan.toComplete { result[reminderId] = true }
        for reminderId in plan.toUncomplete { result[reminderId] = false }
        for reminderId in created { result[reminderId] = false }
        return result
    }
}
