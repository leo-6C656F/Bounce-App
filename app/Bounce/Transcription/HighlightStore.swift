import Foundation

/// Holds live "highlight" marks between the end of a recording and the arrival
/// of its audio file — the same shape as `LiveTranscriptStore`, and for the same
/// reason: the marks are made while recording, before a `Recording` exists to
/// attach them to.
///
/// A highlight is just a second-offset into the recording that the user flagged
/// with the Highlight button. In memory only; losing them on relaunch costs
/// nothing since they're a convenience, not content.
@MainActor
final class HighlightStore {

    static let shared = HighlightStore()

    private var pending: [Int: [TimeInterval]] = [:]

    private init() {}

    func add(_ offset: TimeInterval, forSessionId sessionId: Int) {
        var list = pending[sessionId] ?? []
        if !list.contains(where: { abs($0 - offset) < 0.5 }) {
            list.append(offset)
            pending[sessionId] = list.sorted()
        }
    }

    /// Add marks received from physical device hardware post-sync.
    func addDeviceMarks(_ marks: [TimeInterval], forSessionId sessionId: Int) {
        for mark in marks {
            add(mark, forSessionId: sessionId)
        }
        updateRecordingHighlightsIfExist(sessionId: sessionId)
    }

    /// Direct update if recording already exists in RecordingStore
    private func updateRecordingHighlightsIfExist(sessionId: Int) {
        guard let recording = RecordingStore.shared.recordings.first(where: { $0.sessionId == sessionId }) else { return }
        let pendingMarks = pending[sessionId] ?? []
        guard !pendingMarks.isEmpty else { return }

        RecordingStore.shared.update(id: recording.id) { rec in
            let existing = rec.highlights ?? []
            var merged = existing
            for mark in pendingMarks {
                if !merged.contains(where: { abs($0 - mark) < 0.5 }) {
                    merged.append(mark)
                }
            }
            rec.highlights = merged.sorted()
        }
    }

    /// Number held so far this session, for immediate UI feedback.
    func count(forSessionId sessionId: Int) -> Int {
        pending[sessionId]?.count ?? 0
    }

    /// Attach the parked marks to a freshly synced recording, if any.
    @discardableResult
    func applyIfAvailable(to recordingId: String, sessionId: Int) -> Bool {
        guard let marks = pending.removeValue(forKey: sessionId), !marks.isEmpty else { return false }
        RecordingStore.shared.update(id: recordingId) { $0.highlights = marks.sorted() }
        return true
    }

    func discard(sessionId: Int) {
        pending.removeValue(forKey: sessionId)
    }
}
