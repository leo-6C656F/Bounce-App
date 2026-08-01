import Foundation
import Observation

/// Drives on-device transcription and writes results into the store.
///
/// Keeps one status per recording so several rows in the library can show
/// independent progress, and serialises the actual work — the speech model is
/// happier doing one file at a time, and so is the battery.
@MainActor
@Observable
final class TranscriptionCoordinator {

    static let shared = TranscriptionCoordinator()

    enum Status: Equatable {
        case queued
        case installingModel
        case transcribing
        case failed(String)

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .installingModel: return "Downloading language model"
            case .transcribing: return "Transcribing"
            case .failed(let message): return message
            }
        }

        var isWorking: Bool {
            switch self {
            case .queued, .installingModel, .transcribing: return true
            case .failed: return false
            }
        }
    }

    /// Recording id → current status. Absent means idle or finished.
    private(set) var statuses: [String: Status] = [:]

    /// FIFO so an auto-sync of ten files doesn't start ten transcriptions at once.
    private var queue: [String] = []
    private var isRunning = false

    private init() {}

    func status(for recording: Recording) -> Status? {
        statuses[recording.id]
    }

    var isBusy: Bool { isRunning || !queue.isEmpty }

    // MARK: - Queueing

    /// Add to the queue unless it's already transcribed or in flight.
    ///
    /// `force` re-runs even when a real transcript already exists — for the
    /// "Transcribe again" action, e.g. after switching the engine.
    func enqueue(recordingId: String, force: Bool = false) {
        // A live preview counts as "not transcribed": it came off a lossy
        // Bluetooth stream and should be replaced by a pass over the whole file.
        guard let recording = RecordingStore.shared.recording(id: recordingId),
              force || !recording.isTranscribed || recording.transcript?.isLivePreview == true,
              recording.isSynced,
              statuses[recordingId]?.isWorking != true,
              !queue.contains(recordingId)
        else { return }

        queue.append(recordingId)
        statuses[recordingId] = .queued
        drainQueue()
    }

    private func drainQueue() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        let next = queue.removeFirst()

        Task { @MainActor in
            defer {
                isRunning = false
                drainQueue()
            }
            guard let recording = RecordingStore.shared.recording(id: next) else {
                // `next` was already popped off `queue` above, so nothing will
                // revisit it — without clearing `statuses[next]` here, a
                // recording deleted (or merged/absorbed) while it sat queued
                // leaves its status permanently stuck at `.queued`, a small
                // but real leak in the coordinator's own bookkeeping.
                statuses[next] = nil
                return
            }
            do {
                _ = try await transcribe(recording)
            } catch {
                statuses[next] = .failed(Self.message(for: error))
            }
        }
    }

    // MARK: - Work

    /// Transcribe now and persist the result. Throws so callers — including the
    /// Shortcuts intent — can surface a real error.
    @discardableResult
    func transcribe(_ recording: Recording) async throws -> Transcript {
        guard let audioURL = RecordingStore.shared.audioURL(for: recording) else {
            let error = DeliveryService.Failure.audioMissing
            statuses[recording.id] = .failed(Self.message(for: error))
            throw error
        }

        statuses[recording.id] = .queued

        do {
            // No timeout wrapper here. A `withThrowingTaskGroup` watchdog was
            // tried and made things worse: cancelling the group tore down the
            // analysis mid-flight and every transcription failed instantly with
            // `CancellationError`. With `finalizeAndFinishThroughEndOfInput()`
            // now called in the right place, the results stream terminates on its
            // own, so there is no hang left to guard against.
            let locale = DeliverySettings.shared.transcriptionLocale
            let onPhase: @Sendable (LocalTranscriber.Phase) -> Void = { [weak self] phase in
                Task { @MainActor in
                    guard let self else { return }
                    switch phase {
                    case .installingModel: self.statuses[recording.id] = .installingModel
                    case .transcribing: self.statuses[recording.id] = .transcribing
                    }
                }
            }
            let transcript = try await transcribeWithSelectedEngine(
                audioURL: audioURL, locale: locale, onPhase: onPhase)

            RecordingStore.shared.update(id: recording.id) { rec in
                // Archive the live preview rather than dropping it when the
                // authoritative pass takes over — the first draft is kept for
                // reference. Only archive an actual live preview, and only once.
                if rec.transcript?.isLivePreview == true, rec.livePreview == nil {
                    rec.livePreview = rec.transcript
                }
                rec.transcript = transcript
            }
            statuses[recording.id] = nil
            SyncManager.shared.refreshLibrary()

            // If this recording was linked to another while it was being made —
            // "continue that one" — this is where the two become one. It returns
            // true only when a merge actually happened, in which case this row has
            // been deleted and folded in, and the organize and delivery below must
            // not run against it: the merge does both, over the combined
            // recording, which is the artifact the user asked for.
            if await ContinuationStore.shared.absorb(recordingId: recording.id) {
                return transcript
            }

            // The automatic AI pass — categorize, title, summarize — runs
            // before delivery so the payload carries the final title and
            // summaries. Awaiting it here also keeps it serialized with the
            // transcription queue: one on-device model job at a time.
            await AutoOrganizer.shared.process(recordingId: recording.id)

            if DeliverySettings.shared.autoDeliver,
               let updated = RecordingStore.shared.recording(id: recording.id) {
                _ = await DeliveryService.shared.deliverToAllDestinations(updated)
            }

            return transcript
        } catch {
            statuses[recording.id] = .failed(Self.message(for: error))
            throw error
        }
    }

    /// Transcribe with whichever engine the user chose, falling back to on-device
    /// if the cloud engine fails for any reason — a missing key, a network error,
    /// a server timeout. The user never loses a transcript to a Soniox hiccup.
    private func transcribeWithSelectedEngine(
        audioURL: URL,
        locale: Locale,
        onPhase: @escaping @Sendable (LocalTranscriber.Phase) -> Void
    ) async throws -> Transcript {
        if DeliverySettings.shared.effectiveTranscriptionEngine == .soniox {
            do {
                return try await SonioxBatchTranscriber.shared.transcribe(
                    audioAt: audioURL, locale: locale, onPhase: onPhase)
            } catch {
                TranscribeLog.log("soniox batch failed, falling back to on-device: "
                    + "\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
        return try await LocalTranscriber.shared.transcribe(
            audioAt: audioURL, locale: locale, onPhase: onPhase)
    }

    func clearStatus(for recordingId: String) {
        statuses[recordingId] = nil
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

}
