import ActivityKit
import Foundation

/// Runs the recording Live Activity from the app side: starts it when recording
/// begins, updates it on pause/resume, ends it when recording stops — and routes
/// the Lock Screen / Dynamic Island button taps back into the recorder.
///
/// Single source of truth: the buttons post notifications, this calls
/// `DeviceManager`, the resulting `RecordingState` change flows back through
/// `AppModel` into `sync(_:deviceName:)`, which updates the activity. So the
/// on-screen controls and the Live Activity never disagree.
@MainActor
final class RecordingLiveActivityController {

    static let shared = RecordingLiveActivityController()

    private var activity: Activity<RecordingActivityAttributes>?

    private init() {
        observeIntents()
    }

    /// Reflect the current recording state into the Live Activity.
    func sync(_ state: RecordingState, deviceName: String) {
        switch state {
        case .recording(_, let startedAt):
            if let activity {
                // Resume (or a plain update): unpause, keep the anchor.
                let content = RecordingActivityAttributes.ContentState(
                    startedAt: activity.content.state.startedAt,
                    isPaused: false,
                    pausedElapsed: 0)
                Task { await activity.update(ActivityContent(state: content, staleDate: nil)) }
            } else {
                start(startedAt: startedAt, deviceName: deviceName)
            }

        case .paused:
            guard let activity else { return }
            let anchor = activity.content.state.startedAt
            let content = RecordingActivityAttributes.ContentState(
                startedAt: anchor,
                isPaused: true,
                pausedElapsed: max(Date().timeIntervalSince(anchor), 0))
            Task { await activity.update(ActivityContent(state: content, staleDate: nil)) }

        case .idle:
            end()
        }
    }

    // MARK: - Lifecycle

    private func start(startedAt: Date, deviceName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = RecordingActivityAttributes.ContentState(
            startedAt: startedAt, isPaused: false, pausedElapsed: 0)
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(deviceName: deviceName),
                content: ActivityContent(state: content, staleDate: nil),
                pushType: nil)   // local only — no push entitlement needed
        } catch {
            // Non-fatal: the in-app indicator still works without the Live Activity.
            print("[LiveActivity] start failed: \(error)")
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(
                ActivityContent(state: activity.content.state, staleDate: nil),
                dismissalPolicy: .immediate)
        }
    }

    // MARK: - Intent routing

    /// The Live Activity buttons post these; drive the recorder in response. The
    /// state change then flows back through `AppModel` → `sync`, updating the
    /// activity, so there's exactly one source of truth.
    private func observeIntents() {
        let center = NotificationCenter.default
        center.addObserver(forName: .bounceRecordingPause, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DeviceManager.shared.pauseRecord() }
        }
        center.addObserver(forName: .bounceRecordingResume, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DeviceManager.shared.resumeRecord() }
        }
        center.addObserver(forName: .bounceRecordingStop, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DeviceManager.shared.stopRecord() }
        }
    }
}
