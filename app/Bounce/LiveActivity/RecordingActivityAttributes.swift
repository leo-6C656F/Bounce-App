import ActivityKit
import Foundation

/// Shape of the recording Live Activity. Shared by the app (which starts,
/// updates, and ends the activity) and the widget extension (which renders it),
/// via target membership in both.
///
/// All display state lives in `ContentState` so the activity is driven entirely
/// by local updates — no push, no App Group, no shared container. That is what
/// keeps it buildable on any signing setup (the widget extension carries no
/// signable entitlement).
struct RecordingActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        /// Anchor for the self-running timer on the Lock Screen / Dynamic Island.
        /// The widget renders elapsed time from this with `Text(timerInterval:)`,
        /// so the app only pushes an update on a state change, not every second.
        var startedAt: Date
        var isPaused: Bool
        /// Frozen elapsed seconds to show while paused (the live timer can't run).
        var pausedElapsed: TimeInterval
    }

    /// Static for the life of the activity — e.g. the recorder's name.
    var deviceName: String
}
