import Foundation

/// Holds a location fix between the moment a recording starts and the arrival
/// of its audio file — the same shape as `HighlightStore` and
/// `LiveTranscriptStore`, and for the same reason: the interesting moment
/// happens while the recorder is still recording, long before a `Recording`
/// exists to attach anything to.
///
/// In memory only. A fix lost to a relaunch costs nothing — the sync-time
/// fallback and the calendar still run, and the user can set the pin by hand.
@MainActor
final class PlaceStore {

    static let shared = PlaceStore()

    private var pending: [Int: RecordingPlace] = [:]

    /// How stale a recording may be before a sync-time fix stops being an
    /// honest guess at where it happened.
    ///
    /// The judgement: sync usually follows a meeting by a couple of minutes,
    /// and half an hour is about as long as you can be somewhere else. Beyond
    /// it, "where the phone was when the file transferred" is just a different
    /// place, and a confidently wrong pin is worse than none — so the recording
    /// gets no location and the map simply doesn't show it.
    static let syncFallbackWindow: TimeInterval = 30 * 60

    private init() {}

    // MARK: - Record-time capture

    /// Take a fix now and park it against `sessionId`.
    ///
    /// Fire-and-forget: the fix takes seconds to arrive and nothing waits on it.
    /// Silently does nothing when the feature is off or unauthorized, which is
    /// also what makes this safe to call unconditionally from the SDK callback.
    func captureAtRecordStart(sessionId: Int) {
        guard DeliverySettings.shared.geotagRecordings else { return }
        guard LocationCapture.shared.isAuthorized else { return }
        Task { [weak self] in
            guard let place = await LocationCapture.shared.currentPlace(source: .recordStart)
            else { return }
            // Recording may have stopped and synced while the fix was in flight,
            // in which case the row already exists and parking would strand it.
            self?.attachOrPark(place, sessionId: sessionId)
        }
    }

    /// Whether a fix is parked for this session, for immediate UI feedback.
    func hasPending(sessionId: Int) -> Bool { pending[sessionId] != nil }

    func discard(sessionId: Int) { pending.removeValue(forKey: sessionId) }

    // MARK: - Attaching

    /// Attach the parked fix to a freshly synced recording, if there is one.
    ///
    /// Returns whether the library changed, so the caller can decide whether to
    /// refresh — matching `HighlightStore.applyIfAvailable(to:sessionId:)`.
    @discardableResult
    func applyIfAvailable(to recordingId: String, sessionId: Int) -> Bool {
        guard let place = pending.removeValue(forKey: sessionId) else { return false }
        return Self.write(place, to: recordingId)
    }

    /// The fallback for a recording that arrived with no parked fix: take one
    /// now and label it `.sync`.
    ///
    /// Only for recordings that just happened — see `syncFallbackWindow`. Runs
    /// after `applyIfAvailable`, so a real record-time fix always wins.
    func captureAtSyncIfUseful(recordingId: String, sessionId: Int) {
        guard DeliverySettings.shared.geotagRecordings else { return }
        guard LocationCapture.shared.isAuthorized else { return }
        guard let recording = RecordingStore.shared.recording(id: recordingId) else { return }
        guard recording.place == nil else { return }
        let ended = recording.createdAt.addingTimeInterval(max(0, recording.duration))
        guard -ended.timeIntervalSinceNow <= Self.syncFallbackWindow else { return }

        Task {
            guard let place = await LocationCapture.shared.currentPlace(source: .sync) else { return }
            if Self.write(place, to: recordingId) { SyncManager.shared.refreshLibrary() }
        }
    }

    /// The one place a `RecordingPlace` is written.
    ///
    /// **Precedence is enforced here, not at the call sites.** Four independent
    /// sources can each fire late — a slow GPS fix, the auto-organize pass, a
    /// re-sync — and without a single gate the last writer wins, which means a
    /// sync-time approximation can quietly replace the real thing.
    @discardableResult
    static func write(_ place: RecordingPlace, to recordingId: String) -> Bool {
        guard place.isValid else { return false }
        guard let existing = RecordingStore.shared.recording(id: recordingId) else { return false }
        if let current = existing.place, !current.shouldBeReplaced(by: place) { return false }
        RecordingStore.shared.update(id: recordingId) { $0.place = place }
        return true
    }

    /// Park the fix, unless the recording has already landed — in which case
    /// write it straight through.
    private func attachOrPark(_ place: RecordingPlace, sessionId: Int) {
        if let recording = RecordingStore.shared.recordings.first(where: { $0.sessionId == sessionId }) {
            if Self.write(place, to: recording.id) { SyncManager.shared.refreshLibrary() }
        } else {
            pending[sessionId] = place
        }
    }
}
