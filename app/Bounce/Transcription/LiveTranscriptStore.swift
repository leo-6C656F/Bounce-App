import Foundation

/// Holds live transcripts between the end of a recording and the arrival of its
/// audio file.
///
/// A live transcript exists before the recording does: `blePcmData` finishes
/// while the file is still on the recorder, so there is no `Recording` to attach
/// it to yet. This parks it by session id and applies it when the file lands, so
/// the user sees text immediately rather than waiting for sync and then a second
/// transcription pass.
///
/// Backed by `LiveSessionCheckpoint`, which is already writing the same segments
/// to disk as the session runs. A preview *is* lossy and the authoritative
/// version comes from the complete file — but the window between "recording
/// stopped" and "file synced" can be long, and losing the preview to a relaunch
/// in it costs the user the only text they have.
@MainActor
final class LiveTranscriptStore {

    static let shared = LiveTranscriptStore()

    private var pending: [Int: Transcript] = [:]

    private init() {
        // Adopt anything a previous run left behind. `LiveTranscriber` restores
        // in-progress sessions from the same records, and a session id is a Unix
        // timestamp, so the two can't collide over one recording.
        for record in LiveSessionCheckpoint.shared.allRecords() where !record.segments.isEmpty {
            pending[record.sessionId] = Transcript(
                segments: record.segments,
                localeIdentifier: record.localeIdentifier,
                createdAt: record.updatedAt,
                isPreview: true)
        }
        if !pending.isEmpty {
            TranscribeLog.log("live: recovered \(pending.count) preview(s) from disk")
        }
    }

    func hold(_ transcript: Transcript, forSessionId sessionId: Int) {
        pending[sessionId] = transcript
        TranscribeLog.log("live: holding \(transcript.segments.count) segment(s) "
            + "for session \(sessionId)")
    }

    /// Apply the parked transcript to a freshly synced recording, if there is one.
    ///
    /// Never overwrites an existing transcript: the batch pass reads the whole
    /// file and beats anything assembled from a Bluetooth stream.
    func applyIfAvailable(to recordingId: String, sessionId: Int) -> Bool {
        guard let transcript = pending.removeValue(forKey: sessionId) else { return false }
        // Done with either way — applied here, or superseded by a real transcript
        // below. Leaving the disk copy would have it adopted again next launch.
        LiveSessionCheckpoint.shared.clear(sessionId: sessionId)
        guard let recording = RecordingStore.shared.recording(id: recordingId),
              recording.transcript == nil
        else { return false }

        RecordingStore.shared.update(id: recordingId) { $0.transcript = transcript }
        TranscribeLog.log("live: applied preview transcript to \(recordingId)")
        return true
    }

    func discard(sessionId: Int) {
        pending.removeValue(forKey: sessionId)
        LiveSessionCheckpoint.shared.clear(sessionId: sessionId)
    }
}
