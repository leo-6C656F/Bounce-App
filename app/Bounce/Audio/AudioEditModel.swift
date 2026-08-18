import Foundation
import Observation

/// State for the audio editor: which parts of a recording survive, and how to
/// write them out as a new recording.
///
/// The whole edit is one value — `kept`, an ascending list of disjoint ranges of
/// the *original* timeline. Every operation is a set operation on it:
///
/// | Action | Effect on `kept` |
/// |---|---|
/// | Trim | intersect with the selection |
/// | Delete | subtract the selection |
/// | Remove silence | intersect with the detected speech segments |
///
/// Nothing touches the file until Save. That's what makes undo trivial (a stack
/// of previous `kept` values) and it's why auditioning an edit uses
/// `AudioPlayerModel.playbackRanges` to seek over the removed audio rather than
/// rendering a preview — the removed audio is all still there.
@MainActor
@Observable
final class AudioEditModel {

    /// The recording being edited. Never modified — Save always produces a new
    /// one, so an edit can't destroy the original.
    let recording: Recording
    let sourceURL: URL

    private(set) var duration: TimeInterval = 0
    private(set) var peaks: [UInt8] = []
    /// Set when the file can't be indexed — not an MP3, truncated, unreadable.
    /// The editor shows this and offers nothing but Cancel.
    private(set) var loadFailure: String?
    private(set) var isLoaded = false

    /// Ascending, disjoint ranges of the original that survive.
    private(set) var kept: [ClosedRange<TimeInterval>] = []
    /// The two-handle selection, in the original's timeline. Independent of
    /// `kept`: you can select across a gap that a previous delete opened.
    var selection: ClosedRange<TimeInterval> = 0...0

    private(set) var progress: Progress?

    /// A one-line explanation of something that finished without changing
    /// anything, shown until the next action. "Remove silence" is the case that
    /// needs it: it costs a full decode pass, and on a recording with no long
    /// pauses it correctly does nothing — which is indistinguishable from a broken
    /// button unless it says so.
    private(set) var notice: String?

    enum Progress: Equatable {
        case analysing(Double)
        case saving

        var label: String {
            switch self {
            case .analysing: "Finding silence…"
            case .saving: "Saving…"
            }
        }
    }

    /// The MP3 frame index. Held so Save doesn't re-parse a 30 MB file the editor
    /// already walked, and so the UI can report the frame quantisation honestly.
    private var index: MP3Frames.Index?
    private var undoStack: [[ClosedRange<TimeInterval>]] = []
    private var redoStack: [[ClosedRange<TimeInterval>]] = []

    /// Refuse an edit that would leave less audio than this. A zero-length
    /// recording is a row that can't be played, transcribed or deleted usefully,
    /// and `MP3Frames.write` would throw anyway — better to grey the button out.
    private static let minimumResult: TimeInterval = 0.5

    init(recording: Recording, sourceURL: URL) {
        self.recording = recording
        self.sourceURL = sourceURL
    }

    // MARK: - Loading

    func load() async {
        guard !isLoaded, loadFailure == nil else { return }
        let url = sourceURL

        // Indexing is a full byte walk; the envelope is a full decode. Both off
        // the main actor, and concurrently — they read the same memory-mapped
        // file and neither blocks the other.
        async let indexed = Task.detached(priority: .userInitiated) {
            Result { try MP3Frames.index(of: url) }
        }.value
        async let envelope = WaveformCache.shared.peaks(for: url)

        let (result, peaks) = await (indexed, envelope)
        self.peaks = peaks ?? []

        switch result {
        case .failure(let error):
            loadFailure = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        case .success(let index):
            self.index = index
            // The index's duration, not `recording.duration`: the stored value
            // came from the recorder's file listing and can disagree with the
            // file by a frame or two. Every position in this screen is resolved
            // against the frames, so they have to agree or the right-hand handle
            // can't reach the end.
            duration = index.duration
            kept = [0...duration]
            selection = 0...duration
            isLoaded = true
        }
    }

    // MARK: - Derived state

    /// What playback is confined to, for `AudioPlayerModel.playbackRanges`.
    ///
    /// While the selection is a strict subset of the edit, audition the
    /// *selection* — that's the segment the user is reviewing before trimming or
    /// deleting it. Otherwise audition the whole edit.
    var auditionRanges: [ClosedRange<TimeInterval>] {
        let selected = TimelineMap.intersect(kept, [selection])
        if !selected.isEmpty, selected.totalDuration < keptDuration - 0.05 {
            return selected
        }
        return kept
    }

    var keptDuration: TimeInterval { kept.totalDuration }

    /// How much the edit removes. Drives the "saves 4:12" affordance.
    var removedDuration: TimeInterval { max(0, duration - keptDuration) }

    var hasEdits: Bool { !undoStack.isEmpty }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isBusy: Bool { progress != nil }

    /// Trim keeps only the selection, so it's pointless when the selection
    /// already covers everything kept.
    var canTrim: Bool {
        guard isLoaded, !isBusy else { return false }
        let result = TimelineMap.intersect(kept, [selection])
        return result.totalDuration >= Self.minimumResult
            && result.totalDuration < keptDuration - 0.01
    }

    /// Delete removes the selection, so it needs the selection to overlap
    /// something and to leave enough behind.
    var canDelete: Bool {
        guard isLoaded, !isBusy else { return false }
        let result = TimelineMap.subtract(kept, selection)
        return result.totalDuration >= Self.minimumResult
            && result.totalDuration < keptDuration - 0.01
    }

    var canRemoveSilence: Bool { isLoaded && !isBusy }

    var canSave: Bool { isLoaded && !isBusy && hasEdits && keptDuration >= Self.minimumResult }

    /// One frame, in seconds — the granularity every cut is snapped to. Shown in
    /// the UI so the quantisation isn't a surprise.
    var frameDuration: TimeInterval {
        guard let index, index.sampleRate > 0 else { return 0 }
        return Double(index.version.samplesPerFrame) / Double(index.sampleRate)
    }

    // MARK: - Editing

    func selectAll() {
        selection = 0...duration
    }

    func select(_ range: ClosedRange<TimeInterval>) {
        selection = clamp(range)
    }

    /// Move one handle, keeping the range ordered and inside the recording.
    func moveSelectionStart(to time: TimeInterval) {
        let upper = selection.upperBound
        let lower = min(max(0, time), max(0, upper - frameFloor))
        selection = lower...upper
    }

    func moveSelectionEnd(to time: TimeInterval) {
        let lower = selection.lowerBound
        let upper = max(min(duration, time), min(duration, lower + frameFloor))
        selection = lower...upper
    }

    /// The shortest selection the handles allow. One frame is too small to grab
    /// or to mean anything; a quarter second is draggable and still finer than
    /// any real edit.
    private var frameFloor: TimeInterval { max(0.25, frameDuration) }

    func trim() {
        apply(TimelineMap.intersect(kept, [selection]))
    }

    func deleteSelection() {
        apply(TimelineMap.subtract(kept, selection))
    }

    func removeSilence() async {
        guard canRemoveSilence else { return }
        progress = .analysing(0)
        notice = nil
        let url = sourceURL
        // `duration` is the MP3 frame-index duration (set from `index.duration`
        // at load). The detector reports speech in the decoded-PCM timeline, so
        // the segments are scaled onto this one before they meet `kept` below.
        let frameTimelineDuration = duration

        // `levels` + `segments(from:)` rather than the `segments(of:)` convenience
        // so `levels.duration` (the decoded-PCM length) is in hand for the
        // timeline conversion — intersecting the two timelines raw shifts every
        // cut by the decoder delay/padding.
        let detection = await Task.detached(priority: .userInitiated) {
            () -> (ranges: [ClosedRange<TimeInterval>], decoded: TimeInterval)? in
            guard let levels = SilenceDetector.levels(
                of: url,
                window: SilenceDetector.Options.default.window,
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Written out rather than `if case .analysing = self?.progress`,
                        // which pattern-matches against a double optional and so never
                        // matched — the bar sat at zero for the whole pass.
                        guard case .analysing = self.progress else { return }
                        self.progress = .analysing(fraction)
                    }
                }),
                !levels.windows.isEmpty
            else { return nil }
            let speech = SilenceDetector.segments(from: levels)
            return (
                SilenceDetector.speechRanges(
                    speech, decodedDuration: levels.duration, frameDuration: frameTimelineDuration),
                levels.duration)
        }.value

        progress = nil
        guard let detection, !detection.ranges.isEmpty else {
            notice = "Couldn't analyse this recording's audio."
            return
        }

        let result = TimelineMap.intersect(kept, detection.ranges)
        // Nothing worth cutting, or the detector read the whole recording as
        // silence. Leaving `kept` alone is the honest outcome either way — the
        // alternative is an edit the user didn't ask for that throws most of the
        // audio away. But say so: this ran a full decode pass, and finishing with
        // a visually identical screen and no message reads as a broken button.
        guard result.totalDuration >= Self.minimumResult,
              result.totalDuration < keptDuration - 0.05 else {
            let threshold = SilenceDetector.Options.default.minimumSilence
            notice = "No silence worth removing — every pause here is shorter than "
                + "\(threshold.formatted(.number.precision(.fractionLength(1)))) seconds."
            return
        }
        apply(result)
        notice = nil
        // Point the selection at the first surviving segment so the transport's
        // jump-to-start/end buttons have something meaningful to move between.
        if let first = result.first { selection = first }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(kept)
        kept = previous
        clampSelectionToRecording()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(kept)
        kept = next
        clampSelectionToRecording()
    }

    private func apply(_ new: [ClosedRange<TimeInterval>]) {
        guard new.totalDuration >= Self.minimumResult, new != kept else { return }
        notice = nil
        undoStack.append(kept)
        // A new edit invalidates the redo branch — standard, and the alternative
        // (keeping it) would let redo reinstate a state that no longer follows.
        redoStack.removeAll()
        kept = new
        clampSelectionToRecording()
    }

    private func clampSelectionToRecording() {
        selection = clamp(selection)
    }

    private func clamp(_ range: ClosedRange<TimeInterval>) -> ClosedRange<TimeInterval> {
        let lower = min(max(0, range.lowerBound), duration)
        let upper = min(max(lower, range.upperBound), duration)
        return lower...upper
    }

    // MARK: - Saving

    struct SaveResult {
        var recording: Recording
        /// Whether a transcript was carried across, remapped onto the new
        /// timeline. False means the copy arrives untranscribed.
        var keptTranscript: Bool
        var duration: TimeInterval
    }

    /// Write the kept frames as a new recording. The original is untouched.
    ///
    /// Ordering here is load-bearing, and the reasons are in
    /// `docs/architecture.md`: the MP3 must exist on disk *before* the
    /// `Recording` is persisted, because `audioFilename != nil` is the only thing
    /// that stops `SyncManager.handleFileList` — which runs on every BLE
    /// reconnect, entirely outside the user's control — from wiping the row.
    func save(title: String, transcribe: Bool) async throws -> SaveResult {
        guard let index, canSave else { throw MP3Frames.Failure.nothingKept }
        progress = .saving
        defer { progress = nil }

        // A fresh UUID rather than anything derived from the source: two
        // recordings sharing an `audioFilename` means `RecordingStore.delete`
        // on either removes the other's audio *and* its cached waveform, since
        // both are keyed by bare filename.
        let filename = "edit-\(UUID().uuidString).mp3"
        let destination = RecordingStore.shared.audioDirectory.appendingPathComponent(filename)
        let source = sourceURL
        let ranges = kept

        let output = try await Task.detached(priority: .userInitiated) {
            try MP3Frames.write(source: source, index: index, keeping: ranges, to: destination)
        }.value

        // `keptRanges` from the writer, not `kept`: the writer snapped every
        // boundary to a frame, so these are what the new file actually contains.
        // Remapping against the requested ranges would drift each cut by up to a
        // frame and put the transcript progressively out of step.
        let map = TimelineMap(kept: output.keptRanges)
        let remappedTranscript = recording.transcript.flatMap { map.remap($0) }

        let new = Recording(
            sessionId: RecordingStore.shared.syntheticSessionId(),
            deviceSN: recording.deviceSN,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultTitle(for: recording)
                : title,
            duration: output.duration,
            // The original's date, not now: this is the same meeting, so
            // "Recorded" should say when it happened, and the copy files
            // directly beside its source where the user will look for it.
            createdAt: recording.createdAt,
            syncedAt: Date(),
            audioFilename: filename,
            transcript: remappedTranscript,
            // Deliberately dropped: a live draft's timings describe the original
            // audio and there is no reason to carry an archived preview onto a
            // derived file.
            livePreview: nil,
            highlights: map.remap(highlights: recording.highlights),
            // Also dropped. Summaries describe content that may no longer be in
            // the file, and a stale summary is worse than none.
            summaries: nil,
            speakerNames: recording.speakerNames,
            categoryName: recording.categoryName)

        RecordingStore.shared.add([new])
        // `add` filters out any `sessionId` already present and reports nothing,
        // so confirm rather than assume. If it were dropped we'd have left an
        // orphaned MP3 and told the user it saved.
        guard RecordingStore.shared.recording(id: new.id) != nil else {
            try? FileManager.default.removeItem(at: destination)
            throw MP3Frames.Failure.writeFailed("The new recording couldn't be added to the library.")
        }
        // Without this the row never reaches the UI — `AppModel.recordings` is fed
        // only from this publisher.
        SyncManager.shared.refreshLibrary()

        if transcribe {
            // `force`, because a carried-over transcript would otherwise make
            // `enqueue` skip it as already transcribed.
            TranscriptionCoordinator.shared.enqueue(recordingId: new.id, force: true)
        }

        // Warm the envelope so the new row has a sparkline immediately. List rows
        // never decode, and the once-per-launch prewarm has almost certainly
        // already run, so without this the row draws a flat line until the user
        // opens it.
        Task.detached(priority: .utility) {
            _ = await WaveformCache.shared.peaks(for: destination)
        }

        return SaveResult(
            recording: new,
            keptTranscript: remappedTranscript != nil,
            duration: output.duration)
    }

    static func defaultTitle(for recording: Recording) -> String {
        "\(recording.displayTitle) (edited)"
    }

}
