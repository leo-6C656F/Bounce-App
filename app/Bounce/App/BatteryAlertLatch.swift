import Foundation

/// Decides when a recorder battery reading should raise a low-battery
/// notification.
///
/// Deliberately pure — `Foundation` only, no `UserNotifications`, no UIKit, no
/// `AppModel` — so it can be compiled and exercised on the Mac. It lives in its
/// own file rather than beside `NotificationCenterBridge` for exactly that
/// reason: the bridge drags in `UserNotifications`, and the interesting logic is
/// here. Regression checks: `tools/battery-latch-tests/main.swift`.
///
/// ## What "once per low episode" means
///
/// A *low episode* starts when the battery is first seen at or below
/// `threshold` and ends when the battery either recovers above
/// `threshold + recoveryMargin` or goes on charge. Exactly one notification is
/// produced per episode, so a level hovering on the boundary (21, 20, 21, 20…)
/// notifies once, not four times.
///
/// ## The first reading of a session counts as a crossing
///
/// A strict reading of "downward crossing" would require a previous reading
/// *above* the threshold, and that silently misses the most common real case:
/// the app launches next to a recorder that is already at 15%, then watches it
/// drain 15 → 14 → 13 without ever observing a crossing, and never warns at all.
/// Missing the warning entirely is worse than one duplicate, so the first
/// in-range reading at or below the threshold fires.
///
/// That is only safe because the latch is **restorable**: `isLatched` is
/// readable and `init(threshold:isLatched:)` takes it back, so the integration
/// persists it (`UserDefaults`) across launches. Without that, "fire on the
/// first reading" would notify on every cold launch while the battery is low.
/// If you drop the persistence, you reintroduce that spam.
///
/// ## Disconnect
///
/// A disconnect never fires and never *clears* the latch. Going out of BLE range
/// is not the battery recovering, and BLE auto-reconnect churn (a 30 s timer, up
/// to 10 attempts — see `DeviceManager`) would otherwise re-notify on every
/// successful reconnect while the recorder is low. The case
/// `docs/plans/feedback-board-top-15.md` worries about — reconnecting a recorder
/// that was charged while away — is already handled by the recovery rule: its
/// first reading is above `threshold + recoveryMargin`, which clears the latch.
/// `reset()` exists for the case where the episode genuinely is over because it
/// is a *different* recorder (unpair / switch device).
struct BatteryAlertLatch {

    /// How far above `threshold` the level must climb to end a low episode.
    /// Hysteresis: without it, a reading oscillating across the threshold
    /// notifies on every dip.
    static let recoveryMargin = 5

    /// Percentage at or below which a notification is due.
    ///
    /// Changing it ends the current episode: the old latch was set against the
    /// old threshold, so keeping it would swallow the first crossing of the new
    /// one. Assigning the same value is a no-op, so callers can write
    /// `latch.threshold = settings.threshold` unconditionally on every reading.
    var threshold: Int {
        didSet {
            guard threshold != oldValue else { return }
            isLatched = false
        }
    }

    /// Whether a low episode is currently in progress (i.e. we have already
    /// notified and are waiting for recovery). Exposed so the integration can
    /// persist it across launches — see the type comment.
    private(set) var isLatched: Bool

    init(threshold: Int, isLatched: Bool = false) {
        self.threshold = threshold
        self.isLatched = isLatched
    }

    /// Feed one battery reading. Returns true when this reading should raise a
    /// notification — at most once per low episode.
    ///
    /// - Parameters:
    ///   - level: Battery percentage, or nil when unknown. A nil or
    ///     out-of-range reading is inert: it neither fires nor clears the latch.
    ///     **0 counts as unknown**, because `DeviceManager` builds `PlaudDevice`
    ///     with `raw?.power ?? 0` before the first real reading arrives and a
    ///     placeholder must not announce "0%".
    ///   - isCharging: Never fires while charging, and charging ends the
    ///     episode. Consequence to be aware of: a recorder unplugged while still
    ///     below the threshold will notify again, which is intended — but a
    ///     recorder whose charge state flaps will too.
    ///   - isConnected: Never fires while disconnected. Does not clear the
    ///     latch; see the type comment.
    mutating func shouldNotify(level: Int?, isCharging: Bool, isConnected: Bool) -> Bool {
        guard isConnected else { return false }

        if isCharging {
            isLatched = false
            return false
        }

        guard let level, (1...100).contains(level) else { return false }

        if level > threshold + Self.recoveryMargin { isLatched = false }

        guard !isLatched, level <= threshold else { return false }
        isLatched = true
        return true
    }

    /// Forget the current episode. For when the recorder itself changes
    /// (unpair, switch device) — not for a mere disconnect.
    mutating func reset() {
        isLatched = false
    }
}
