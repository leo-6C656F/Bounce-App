import Foundation

/// Holds speaker names assigned **while a recording is still running**, until
/// there is a `Recording` to attach them to.
///
/// Same shape and same reason as `LiveTranscriptStore` and `HighlightStore`: the
/// naming happens before the recording exists. The file is still on the recorder,
/// so there is no store entry and no id — only a session id.
///
/// Naming people mid-meeting is when you actually know who is talking, which is
/// why this is worth parking rather than refusing.
///
/// ## The caveat, which is real
///
/// Diarization ids are assigned per transcription pass, in order of first
/// appearance. The live pass and the post-sync pass are **separate passes**, so
/// "1" in the live transcript is only *probably* "1" in the authoritative one —
/// usually true, since both hear the same person first, but not guaranteed.
/// Applying these is therefore best-effort: it beats losing the names, and the
/// detail view can correct them. Don't build anything on the assumption that the
/// mapping is exact.
///
/// In memory only, deliberately — the same reasoning as the transcript preview.
@MainActor
final class LiveSpeakerNameStore {

    static let shared = LiveSpeakerNameStore()

    private var pending: [Int: [String: String]] = [:]

    private init() {}

    /// Names for the session so far, keyed by diarization id.
    func names(forSessionId sessionId: Int) -> [String: String] {
        pending[sessionId] ?? [:]
    }

    /// Replace the whole map for a session. Blank values are dropped so a cleared
    /// field falls back to "Speaker N", matching `AppModel.setSpeakerNames`.
    func set(_ names: [String: String], forSessionId sessionId: Int) {
        let cleaned = names.compactMapValues { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if cleaned.isEmpty { pending.removeValue(forKey: sessionId) } else { pending[sessionId] = cleaned }
    }

    /// Attach the parked names to a freshly synced recording, if any.
    ///
    /// Does **not** overwrite names the user has already set on the recording —
    /// anything typed against the real recording is more trustworthy than a
    /// best-effort carry-over from the live pass.
    @discardableResult
    func applyIfAvailable(to recordingId: String, sessionId: Int) -> Bool {
        guard let parked = pending.removeValue(forKey: sessionId), !parked.isEmpty else { return false }
        guard let recording = RecordingStore.shared.recording(id: recordingId) else { return false }

        var merged = parked
        for (id, name) in recording.speakerNames ?? [:] { merged[id] = name }
        guard merged != recording.speakerNames else { return false }

        RecordingStore.shared.update(id: recordingId) { $0.speakerNames = merged }
        TranscribeLog.log("live: applied \(parked.count) speaker name(s) to \(recordingId)")
        return true
    }

    func discard(sessionId: Int) {
        pending.removeValue(forKey: sessionId)
    }
}
