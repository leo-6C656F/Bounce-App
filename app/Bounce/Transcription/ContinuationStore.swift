import Foundation
import Observation

/// "The recording I am about to make continues that one."
///
/// A Plaud closes its file every time recording stops, so a session captured in
/// bursts arrives as separate rows. `RecordingMerge` can join them afterwards;
/// this is the same thing decided *up front*, while the recorder is still
/// running, which is when the user actually knows the two belong together.
///
/// ## It is an intent, not an action
///
/// Nothing can be joined at the moment the link is made. The audio is still on
/// the recorder — the phone holds only the encrypted live stream and a preview
/// transcript, and no `Recording` row exists until `SyncManager` reconciles the
/// device's file list. So the link is *parked by session id* and redeemed later,
/// the same shape as `PlaceStore.attachOrPark` and `HighlightStore`: the thing
/// being attached to doesn't exist yet, and the id that will identify it does.
///
/// The redemption point is `TranscriptionCoordinator`, once a recording has its
/// authoritative transcript. Both directions have to be checked there, because
/// the two halves can finish in either order — a short continuation can sync and
/// transcribe before the long session it continues.
///
/// ## Chains
///
/// Merging produces a *new* recording and deletes its sources, so a third
/// session linked to the original target would point at a row that no longer
/// exists. `repoint` moves those links onto the merged recording, which is what
/// makes pause-resume-pause across an afternoon collapse into one transcript
/// rather than three pairs.
@MainActor
@Observable
final class ContinuationStore {

    static let shared = ContinuationStore()

    struct Link: Codable, Hashable {
        /// The recorder session that will continue something. Known before the
        /// recording exists, which is the whole point.
        var sessionId: Int
        /// `Recording.id` of what it continues.
        var targetRecordingId: String
        var linkedAt: Date
    }

    private(set) var links: [Link] = []

    private let defaults = UserDefaults.standard
    private let key = "recordingContinuations"

    /// A link the user never redeemed — the recording was deleted before it
    /// synced, or transcription failed permanently — would otherwise sit in the
    /// store forever and fire against an unrelated recording if a session id ever
    /// repeated. A week is far longer than any sync delay.
    private static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    private init() {
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([Link].self, from: data) {
            links = stored
        }
        prune()
    }

    // MARK: - Linking

    /// Mark `sessionId` as continuing `recordingId`. Replaces any existing link
    /// for that session, so changing your mind mid-recording works.
    func link(sessionId: Int, to recordingId: String) {
        links.removeAll { $0.sessionId == sessionId }
        links.append(Link(
            sessionId: sessionId, targetRecordingId: recordingId, linkedAt: Date()))
        save()
    }

    func unlink(sessionId: Int) {
        guard links.contains(where: { $0.sessionId == sessionId }) else { return }
        links.removeAll { $0.sessionId == sessionId }
        save()
    }

    /// What this session will be joined to, if anything.
    func targetId(forSessionId sessionId: Int) -> String? {
        links.first { $0.sessionId == sessionId }?.targetRecordingId
    }

    /// The recording a session will be joined to, or nil if it's gone.
    func target(forSessionId sessionId: Int) -> Recording? {
        targetId(forSessionId: sessionId).flatMap { RecordingStore.shared.recording(id: $0) }
    }

    // MARK: - Redemption

    /// Fold `recordingId` together with whatever it is linked to, if both halves
    /// are ready.
    ///
    /// Returns true when a merge happened — in which case `recordingId` has been
    /// **deleted** and folded into a new recording, and the caller must not go on
    /// to organize or deliver it. The merge runs both of those itself, over the
    /// combined recording, which is the one the user asked for.
    ///
    /// Called from `TranscriptionCoordinator` for every completed transcription;
    /// silent and cheap when there's no link.
    @discardableResult
    func absorb(recordingId: String) async -> Bool {
        prune()
        guard let recording = RecordingStore.shared.recording(id: recordingId) else { return false }

        // This recording continues something else.
        if let link = links.first(where: { $0.sessionId == recording.sessionId }) {
            guard let target = RecordingStore.shared.recording(id: link.targetRecordingId) else {
                // The target was deleted while this was syncing. Drop the intent
                // rather than guessing at a replacement.
                unlink(sessionId: recording.sessionId)
                return false
            }
            if isReady(target) {
                return await join([target, recording], consuming: [link])
            }
            // The target is still syncing or transcribing. Leave the link parked —
            // the branch below redeems it when the target's own pass finishes.
            return false
        }

        // Something else continues this recording.
        let waiting = links.filter { $0.targetRecordingId == recordingId }
        guard !waiting.isEmpty else { return false }
        let parts = waiting.compactMap { link in
            RecordingStore.shared.recording(sessionId: link.sessionId)
        }.filter(isReady)
        guard !parts.isEmpty else { return false }
        let redeemed = waiting.filter { link in
            parts.contains { $0.sessionId == link.sessionId }
        }
        return await join([recording] + parts, consuming: redeemed)
    }

    /// A part can be joined once its audio is on the phone and nothing is still
    /// working on it.
    ///
    /// Deliberately **not** "has a final transcript". A part whose transcription
    /// failed would otherwise never be redeemed, and joining it anyway is
    /// harmless: a stitched transcript with a hole in it is marked as a preview,
    /// and the merged file goes through a full pass on arrival.
    private func isReady(_ recording: Recording) -> Bool {
        RecordingMerge.canMerge(recording)
            && TranscriptionCoordinator.shared.status(for: recording)?.isWorking != true
    }

    private func join(_ recordings: [Recording], consuming redeemed: [Link]) async -> Bool {
        do {
            let result = try await RecordingMerge.merge(
                recordings,
                deletingSources: true,
                organize: true,
                // Stands in for the delivery the part's own transcription would
                // have triggered — it was suppressed precisely because this merge
                // was going to happen.
                deliver: true)
            for link in redeemed { unlink(sessionId: link.sessionId) }
            // Anything still pointing at a recording that has just been deleted
            // now points at what replaced it, so a chain of continuations keeps
            // collapsing into one.
            for consumed in recordings {
                repoint(from: consumed.id, to: result.recording.id)
            }
            TranscribeLog.log(
                "continuation: joined \(result.partCount) recordings into "
                    + "\(result.recording.id)")
            return true
        } catch {
            // Left linked on purpose: a merge that failed because a file was
            // briefly unreadable should be retried the next time either half
            // finishes a pass, not silently abandoned.
            TranscribeLog.log("continuation: merge failed — "
                + "\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            return false
        }
    }

    private func repoint(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        var changed = false
        for index in links.indices where links[index].targetRecordingId == oldId {
            links[index].targetRecordingId = newId
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Storage

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        let kept = links.filter { link in
            link.linkedAt > cutoff
                && RecordingStore.shared.recording(id: link.targetRecordingId) != nil
        }
        guard kept.count != links.count else { return }
        links = kept
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(links) else { return }
        defaults.set(data, forKey: key)
    }
}
