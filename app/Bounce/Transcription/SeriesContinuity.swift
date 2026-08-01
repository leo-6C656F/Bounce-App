import Foundation
import FoundationModels

/// Reads each session of a recurring meeting against the ones before it.
///
/// **The design constraint is the context window, and it shapes everything.**
/// The on-device model has ~4,096 tokens shared across instructions, question
/// and answer (see `TranscriptQA`), so "summarise these eleven transcripts
/// together" is not a thing that can be asked. What fits is a *rolling* one:
/// after each session, rewrite a compact "where things stand" note from the
/// previous note plus this transcript. It stays a fixed size however long the
/// series runs, and every session is folded in exactly once.
///
/// The cost of that choice, stated because it is a real limitation: the model
/// never sees an older transcript again, only its own notes about it. Detail
/// not carried forward is gone from this pass — the transcripts are all still
/// there to read, and Ask still works over any single one.
///
/// On device, same availability rules as everything else here, and every guard
/// exits silently.
@MainActor
final class SeriesContinuity {

    static let shared = SeriesContinuity()

    /// The transcript slice fed in. Smaller than the 10k the other passes use,
    /// because this prompt also has to fit the previous notes *and* produce two
    /// outputs — the window is shared, so the input budget isn't the same.
    private static let maxTranscriptChars = 6_000
    /// The carry-forward is written to a ~200-word target; this is the hard cap
    /// that stops a model that ignored the instruction from crowding out the
    /// transcript on the following session.
    private static let maxDigestChars = 1_600
    /// Below this there is nothing to read against anything.
    private static let minTranscriptChars = 200

    private let model = SystemLanguageModel.default

    private init() {}

    /// Whether the on-device model can run at all. A runtime capability check,
    /// not an OS version — see `TranscriptQA`. The series screen uses it to
    /// explain an empty digest rather than leaving it looking broken.
    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    /// What one pass returns. Guided generation, so the two halves come back
    /// separately rather than having to be split out of prose.
    @Generable
    struct SeriesUpdate {
        @Guide(description: "Three to six '- ' bullet lines recapping this session against the earlier ones.")
        let recap: String
        @Guide(description: "Replacement running notes for the series, under 200 words, folding this session in.")
        let carryForward: String
    }

    /// Fold `recordingId` into its series, and write its recap.
    ///
    /// No-ops when the recording is in no series, the model is unavailable, the
    /// transcript is a live preview or too short, or this recording has already
    /// been folded in — that last one is what makes a re-transcribe safe.
    func update(for recordingId: String) async {
        guard case .available = model.availability else { return }
        guard let recording = RecordingStore.shared.recording(id: recordingId),
              let seriesId = recording.seriesId,
              let series = MeetingSeriesStore.shared.series(id: seriesId)
        else { return }
        guard let transcript = recording.transcript, !transcript.isLivePreview else { return }

        // Idempotency. `TranscriptionCoordinator` re-runs the whole organize pass
        // on a re-transcribe, and without this the same session would be folded
        // into the running notes a second time — which reads as the meeting
        // having happened twice.
        guard series.digestThroughRecordingId != recordingId else { return }

        let text = transcript.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minTranscriptChars else { return }

        let previous = series.digest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let update = await generate(
            seriesName: series.name,
            previous: previous,
            transcript: text)
        else { return }

        let carryForward = Self.cap(update.carryForward, to: Self.maxDigestChars)
        let recap = update.recap.trimmingCharacters(in: .whitespacesAndNewlines)

        // A session that arrived out of order is still folded into the notes —
        // dropping it would lose it forever — but gets no recap, because
        // "since last time" would be a claim about a sequence it isn't in.
        let isLatest = series.isNewerThanDigest(recording.createdAt)

        MeetingSeriesStore.shared.update(id: seriesId) { stored in
            if !carryForward.isEmpty { stored.digest = carryForward }
            stored.digestUpdatedAt = Date()
            stored.digestThroughRecordingId = recordingId
            if isLatest { stored.digestThroughDate = recording.createdAt }
        }

        if isLatest, !recap.isEmpty {
            RecordingStore.shared.update(id: recordingId) { $0.seriesRecap = recap }
            SyncManager.shared.refreshLibrary()
        }

        TranscribeLog.log(
            "series: \(series.name) — folded in \(isLatest ? "latest" : "out-of-order") session")
    }

    /// Rebuild a series' running notes from scratch, oldest session first.
    ///
    /// For a series assembled by hand out of recordings that were transcribed
    /// before it existed — otherwise the notes would only ever reflect sessions
    /// added from that point on, and the feature would look broken on exactly the
    /// library it is most useful for.
    ///
    /// **Serial**, like `AutoOrganizer.scanForActionItems` and for the same
    /// reason: each step is a model session, and running them concurrently
    /// contends for one on-device model at a real thermal cost.
    func rebuild(seriesId: String, progress: @MainActor (Int, Int) -> Void) async {
        guard case .available = model.availability else { return }
        guard MeetingSeriesStore.shared.series(id: seriesId) != nil else { return }

        let sessions = MeetingSeriesStore.shared.recordings(in: seriesId)
            .filter { ($0.transcript?.isLivePreview == false) }
            .sorted { $0.createdAt < $1.createdAt }
        guard !sessions.isEmpty else { return }

        // Cleared first so a cancelled rebuild leaves notes that are incomplete
        // rather than notes that mix two runs.
        MeetingSeriesStore.shared.update(id: seriesId) {
            $0.digest = nil
            $0.digestUpdatedAt = nil
            $0.digestThroughDate = nil
            $0.digestThroughRecordingId = nil
        }

        for (index, session) in sessions.enumerated() {
            if Task.isCancelled { return }
            await update(for: session.id)
            progress(index + 1, sessions.count)
        }
    }

    // MARK: - The model call

    private func generate(
        seriesName: String, previous: String, transcript: String
    ) async -> SeriesUpdate? {
        let instructions = Self.instructions(
            seriesName: seriesName, previous: previous, transcript: transcript)
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: "Write the recap and the replacement notes.",
                generating: SeriesUpdate.self)
            return response.content
        } catch {
            // Silent, like every other pass here: a failed continuity update
            // leaves the series exactly as it was, and the next session tries
            // again from the same notes.
            TranscribeLog.log("series: continuity pass failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Routed through `PromptStore` so Settings › AI › Prompts can edit it. The
    /// literal below is only the fallback for the impossible case of the
    /// catalogue having lost this id — same arrangement as `ActionItemExtractor`.
    private static func instructions(
        seriesName: String, previous: String, transcript: String
    ) -> String {
        let values = [
            "series_name": seriesName,
            // "(none)" rather than an empty string: an empty section reads to the
            // model as a missing one, and the prompt has an explicit branch for
            // "this is the first session" that this is the trigger for.
            "previous": previous.isEmpty ? "(none — this is the first session)" : previous,
            "transcript": cap(transcript, to: maxTranscriptChars),
        ]
        let edited = PromptStore.shared.filled(PromptID.seriesContinuity, with: values)
        if !edited.isEmpty { return edited }
        return PromptTemplating.filled(PromptDefaults.seriesContinuity, with: values)
    }

    /// Keeps the **most recent** slice, matching every other cap in the app: the
    /// end of a meeting is where the decisions are.
    private static func cap(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.suffix(limit))
    }
}
