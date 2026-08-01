import SwiftUI

/// Trim, cut and de-silence a recording, saving the result as a new recording.
///
/// Presented as a sheet from the detail view's actions menu. The original is
/// never modified: Save writes a new MP3 and adds a new `Recording`, so there is
/// nothing to undo after the fact and no way for an edit to lose the source.
///
/// One waveform rather than the overview-plus-zoom pair a desktop editor would
/// use. The primary flow here is segment-driven — run "Remove silence", tap a
/// segment, trim or delete it — so pixel-precise dragging isn't the main
/// interaction. The handles cover coarse manual selection and the nudge rows
/// cover precision, which together do the job of a zoom without a zoomable
/// canvas whose gesture conflicts can only be judged on device.
struct AudioEditorView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var editor: AudioEditModel
    @State private var player = AudioPlayerModel()
    @State private var draftTitle = ""
    @State private var isNamingSave = false
    @State private var shouldTranscribe = false
    @State private var saveError: String?
    @State private var isConfirmingDiscard = false

    @ScaledMetric(relativeTo: .body) private var waveformHeight: CGFloat = 120
    @ScaledMetric(relativeTo: .body) private var stripHeight: CGFloat = 26

    init(recording: Recording, sourceURL: URL) {
        _editor = State(initialValue: AudioEditModel(recording: recording, sourceURL: sourceURL))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let failure = editor.loadFailure {
                    EmptyHint(
                        symbol: "waveform.slash",
                        title: "Can't edit this recording",
                        message: failure)
                } else if editor.isLoaded {
                    content
                } else {
                    ProgressView("Reading audio…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Edit audio")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .task {
            // Opted out of the Lock Screen: the detail view underneath is still
            // alive and owns the now-playing slot, and an editor auditioning a
            // two-second segment has no business becoming the now-playing app.
            player.usesRemoteControls = false
            await editor.load()
            guard editor.isLoaded else { return }
            player.load(url: editor.sourceURL, title: editor.recording.displayTitle)
            player.playbackRanges = editor.auditionRanges
        }
        // Playback follows the edit: after a trim or a delete, auditioning must
        // skip what was just removed or the transport plays audio the user has
        // already discarded.
        .onChange(of: editor.auditionRanges) { _, ranges in
            player.playbackRanges = ranges
        }
        .onDisappear { player.stop() }
        .interactiveDismissDisabled(editor.isBusy || editor.hasEdits)
        .sheet(isPresented: $isNamingSave) {
            SaveEditSheet(
                title: $draftTitle,
                shouldTranscribe: $shouldTranscribe,
                keptDuration: editor.keptDuration,
                removedDuration: editor.removedDuration,
                segmentCount: editor.kept.count,
                carriesTranscript: editor.recording.transcript != nil,
                onSave: save)
        }
        .alert("Couldn't save", isPresented: .init(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .confirmationDialog(
            "Discard these edits?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard edits", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Nothing has been written yet, so leaving loses the \(editor.kept.count > 1 ? "segments" : "trim") you've set up. The original recording is unaffected either way.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { cancel() }
                .disabled(editor.isBusy)
        }
        // Icon-only labels, or the titles crowd out the Save action on a narrow
        // phone. `labelStyle` can't be applied to a `ToolbarItemGroup`, so it goes
        // on the buttons.
        ToolbarItemGroup(placement: .principal) {
            Button {
                editor.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .disabled(!editor.canUndo || editor.isBusy)

            Button {
                editor.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .labelStyle(.iconOnly)
            .disabled(!editor.canRedo || editor.isBusy)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save as") {
                draftTitle = AudioEditModel.defaultTitle(for: editor.recording)
                // Default the transcription toggle to whatever the copy would
                // otherwise lack: with a transcript carried across there's
                // nothing to gain, without one there is.
                shouldTranscribe = editor.recording.transcript == nil
                isNamingSave = true
            }
            .disabled(!editor.canSave)
        }
    }

    // MARK: - Body

    private var content: some View {
        ScrollView {
            VStack(spacing: Metrics.sectionSpacing) {
                Text(editor.recording.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                waveformCard
                transport
                selectionCard
                actionRow
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .safeAreaInset(edge: .bottom) {
            if let progress = editor.progress { progressBar(progress) }
        }
    }

    private var waveformCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 8) {
                TimeRuler(duration: editor.duration)
                EditWaveform(
                    peaks: editor.peaks,
                    duration: editor.duration,
                    kept: editor.kept,
                    selection: editor.selection,
                    playhead: player.currentTime,
                    onSeek: { player.seek(to: $0) },
                    onMoveStart: { editor.moveSelectionStart(to: $0) },
                    onMoveEnd: { editor.moveSelectionEnd(to: $0) })
                    .frame(height: waveformHeight)

                SegmentStrip(
                    duration: editor.duration,
                    segments: editor.kept,
                    selection: editor.selection,
                    onSelect: { segment in
                        editor.select(segment)
                        player.seek(to: segment.lowerBound)
                    })
                    .frame(height: stripHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(player.currentTime.timecodeText)
                    .monospacedDigit()
                Text("/")
                    .foregroundStyle(.tertiary)
                Text(editor.duration.timecodeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            HStack(spacing: 28) {
                Button {
                    player.seek(to: editor.selection.lowerBound)
                } label: {
                    Label("Selection start", systemImage: "arrow.left.to.line")
                }
                .accessibilityLabel("Jump to selection start")

                Button {
                    player.togglePlayback()
                } label: {
                    Label(
                        player.isPlaying ? "Pause" : "Play",
                        systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button {
                    // One frame back from the boundary: seeking exactly to the
                    // upper bound puts the playhead outside the audition range,
                    // which the player would immediately treat as "past the end"
                    // and stop — so the button would look like it did nothing.
                    player.seek(to: max(
                        editor.selection.lowerBound,
                        editor.selection.upperBound - 0.05))
                } label: {
                    Label("Selection end", systemImage: "arrow.right.to.line")
                }
                .accessibilityLabel("Jump to selection end")
            }
            .labelStyle(.iconOnly)
            .font(.title3)

            if let message = player.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var selectionCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Selection")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(selectionSummary)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                NudgeRow(
                    label: "Start",
                    value: editor.selection.lowerBound,
                    onNudge: { editor.moveSelectionStart(to: editor.selection.lowerBound + $0) })
                NudgeRow(
                    label: "End",
                    value: editor.selection.upperBound,
                    onNudge: { editor.moveSelectionEnd(to: editor.selection.upperBound + $0) })

                HStack(spacing: 10) {
                    Button("Select all") { editor.selectAll() }
                    Button("Start here") { editor.moveSelectionStart(to: player.currentTime) }
                    Button("End here") { editor.moveSelectionEnd(to: player.currentTime) }
                }
                .font(.footnote)
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                EditAction(
                    title: "Remove silence",
                    systemImage: "wand.and.sparkles",
                    isEnabled: editor.canRemoveSilence
                ) {
                    Task { await editor.removeSilence() }
                }
                EditAction(
                    title: "Trim",
                    systemImage: "scissors",
                    isEnabled: editor.canTrim
                ) {
                    editor.trim()
                }
                EditAction(
                    title: "Delete",
                    systemImage: "delete.left",
                    isEnabled: editor.canDelete
                ) {
                    editor.deleteSelection()
                }
            }

            if let notice = editor.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if editor.hasEdits {
                Text(editSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if editor.frameDuration > 0 {
                Text("Cuts land on MP3 frame boundaries, so they're accurate to about \(Int((editor.frameDuration * 1000).rounded())) ms. Audio is copied, never re-encoded.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: editor.hasEdits)
    }

    private func progressBar(_ progress: AudioEditModel.Progress) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress.label)
                    .font(.footnote)
                Spacer()
            }
            if case .analysing(let fraction) = progress {
                ProgressView(value: fraction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Text

    private var selectionSummary: String {
        let range = editor.selection
        return "\(range.lowerBound.timecodeText) – \(range.upperBound.timecodeText)"
    }

    private var editSummary: String {
        let kept = editor.keptDuration.timecodeText
        let removed = editor.removedDuration.timecodeText
        let pieces = editor.kept.count
        let shape = pieces > 1 ? "\(pieces) segments" : "one segment"
        return "Keeps \(kept) as \(shape), removing \(removed)."
    }


    // MARK: - Actions

    private func save() {
        let title = draftTitle
        let transcribe = shouldTranscribe
        Task {
            do {
                let result = try await editor.save(title: title, transcribe: transcribe)
                // Reported through `AppModel.alert` — the app's one error/success
                // surface, presented from `RootView` — rather than in this screen,
                // which is about to be dismissed and so could never show it.
                var message = "“\(result.recording.displayTitle)” is \(result.duration.timecodeText) long "
                    + "and sits next to the original in your library."
                if result.keptTranscript {
                    message += " Its transcript was carried over and re-timed."
                } else if transcribe {
                    message += " It's queued for transcription."
                }
                model.alert = .init(title: "Saved edited copy", message: message)
                dismiss()
            } catch {
                saveError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func cancel() {
        // Edits live only in memory, so leaving really does lose them. Cheap to
        // confirm, and the alternative is a stray swipe discarding a de-silenced
        // hour of audio that took a full decode pass to compute.
        if editor.hasEdits {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }
}

// MARK: - Save sheet

/// Names the copy and decides whether to transcribe it, with a summary of what
/// is about to be written.
///
/// A sheet rather than an `.alert` with a text field, because the transcription
/// choice is a `Toggle` and alerts can only hold text fields and buttons — and
/// that choice matters: re-transcribing an hour of audio is minutes of work that
/// is pure waste when the carried-over transcript is already correct.
private struct SaveEditSheet: View {

    @Binding var title: String
    @Binding var shouldTranscribe: Bool
    let keptDuration: TimeInterval
    let removedDuration: TimeInterval
    let segmentCount: Int
    let carriesTranscript: Bool
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    LabeledContent("Length", value: keptDuration.timecodeText)
                    LabeledContent("Removed", value: removedDuration.timecodeText)
                    if segmentCount > 1 {
                        LabeledContent("Joined from", value: "\(segmentCount) segments")
                    }
                } header: {
                    Text("New recording")
                } footer: {
                    Text(carriesTranscript
                        ? "The transcript is carried over and re-timed to the edited audio. Phrases whose audio was mostly removed are dropped. Summaries aren't carried over, since they describe content that may be gone."
                        : "The original recording is left exactly as it is.")
                }

                Section {
                    Toggle("Transcribe now", isOn: $shouldTranscribe)
                } footer: {
                    Text(carriesTranscript
                        ? "Only needed if you'd rather transcribe the edited audio from scratch than re-time the existing transcript."
                        : "Queues the new recording for transcription straight away.")
                }
            }
            .navigationTitle("Save as new recording")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        dismiss()
                        onSave()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Ruler

/// Sparse time labels across the top of the waveform. Five at most: more than
/// that on a phone width overlaps, and the point is orientation rather than
/// measurement — the exact figures are in the selection card.
private struct TimeRuler: View {
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { step in
                Text((duration * Double(step) / 4).timecodeText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: step == 0
                        ? .leading
                        : (step == 4 ? .trailing : .center))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Waveform

/// The recording's envelope with the kept regions, the selection and the
/// playhead drawn over it, plus two draggable selection handles.
///
/// Bars are drawn in a `Canvas` for the same reason as `WaveformView`: a
/// phone-width waveform is 100+ bars and 100 SwiftUI views re-rendering on every
/// playback tick makes the screen feel heavy. The handles are real views rather
/// than canvas drawing, because they need their own hit-testing, their own drag
/// gestures and their own accessibility elements.
private struct EditWaveform: View {

    let peaks: [UInt8]
    let duration: TimeInterval
    let kept: [ClosedRange<TimeInterval>]
    let selection: ClosedRange<TimeInterval>
    let playhead: TimeInterval
    var onSeek: (TimeInterval) -> Void
    var onMoveStart: (TimeInterval) -> Void
    var onMoveEnd: (TimeInterval) -> Void

    /// Half the handle's width. The bar area is inset by this on both sides so a
    /// handle parked at 0 or at the very end is still fully visible and grabbable
    /// rather than half off the edge of the card.
    private let inset: CGFloat = 11

    @State private var width: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(.rect)
            .gesture(seekGesture)

            SelectionHandle(
                time: selection.lowerBound,
                label: "Selection start",
                x: x(for: selection.lowerBound),
                secondsPerPoint: secondsPerPoint,
                onMove: onMoveStart)
            SelectionHandle(
                time: selection.upperBound,
                label: "Selection end",
                x: x(for: selection.upperBound),
                secondsPerPoint: secondsPerPoint,
                onMove: onMoveEnd)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
    }

    // MARK: Geometry

    private var span: CGFloat { max(1, width - inset * 2) }

    private var secondsPerPoint: TimeInterval { duration / Double(span) }

    private func x(for time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return inset }
        return inset + CGFloat(min(max(time / duration, 0), 1)) * span
    }

    private func time(forX position: CGFloat) -> TimeInterval {
        guard duration > 0 else { return 0 }
        return min(max(Double((position - inset) / span), 0), 1) * duration
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 2
        let stride = barWidth + spacing
        let barCount = max(1, Int(span / stride))

        // Selection backdrop first, so bars sit on top of it.
        let selectionRect = CGRect(
            x: x(for: selection.lowerBound),
            y: 0,
            width: max(1, x(for: selection.upperBound) - x(for: selection.lowerBound)),
            height: size.height)
        context.fill(
            Path(roundedRect: selectionRect, cornerRadius: 6),
            with: .style(.tint.opacity(0.16)))

        for index in 0..<barCount {
            let centre = time(forX: inset + (CGFloat(index) + 0.5) * stride)
            let isKept = kept.contains { $0.contains(centre) }
            let height = max(2, CGFloat(amplitude(at: index, of: barCount)) * size.height)
            let rect = CGRect(
                x: inset + CGFloat(index) * stride,
                y: (size.height - height) / 2,
                width: barWidth,
                height: height)
            // Removed audio stays visible but recedes — it has to still be
            // legible, because the user needs to see *what* was cut in order to
            // judge whether to undo it. Hiding it entirely makes a delete look
            // like the file got shorter.
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .style(isKept ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
        }

        // Playhead last, over everything.
        let playheadRect = CGRect(x: x(for: playhead) - 1, y: 0, width: 2, height: size.height)
        context.fill(Path(roundedRect: playheadRect, cornerRadius: 1), with: .style(.primary))
    }

    private func amplitude(at index: Int, of barCount: Int) -> Double {
        guard !peaks.isEmpty else { return 0.06 }
        let lower = index * peaks.count / barCount
        let upper = max(lower + 1, (index + 1) * peaks.count / barCount)
        var loudest: UInt8 = 0
        for position in lower..<min(upper, peaks.count) where peaks[position] > loudest {
            loudest = peaks[position]
        }
        return Double(loudest) / 255
    }

    // MARK: Gestures

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                onSeek(time(forX: value.location.x))
            }
    }

}

/// One end of the selection.
///
/// Drags are resolved from `translation` against the time the drag *started* at,
/// not from `location`. `DragGesture.location` is reported in the gesture view's
/// own coordinate space, and this view moves as the selection updates — so a
/// location-based reading feeds the view's own movement back into the next event.
/// It converges rather than running away, but it jitters, and it drifts whenever
/// a clamp in the model refuses part of a move. Translation is immune to both.
private struct SelectionHandle: View {

    let time: TimeInterval
    let label: String
    /// Centre position, in points, within the parent.
    let x: CGFloat
    let secondsPerPoint: TimeInterval
    var onMove: (TimeInterval) -> Void

    /// Where the drag began. Nil when not dragging.
    @State private var anchor: TimeInterval?
    /// `@GestureState` resets on **cancellation**, which `onEnded` doesn't cover —
    /// a competing system gesture or the view tearing down mid-drag. Without
    /// observing it the anchor stays latched and the next drag starts from a stale
    /// origin, so the handle jumps.
    @GestureState private var isDragging = false

    var body: some View {
        Capsule()
            .fill(.tint)
            .frame(width: 6)
            .overlay {
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2, height: 14)
            }
            // A 44pt transparent target around a 6pt capsule: the visual
            // affordance can be slim, the touch target can't be.
            .frame(width: 44)
            .contentShape(.rect)
            .offset(x: x - 22)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        let start = anchor ?? time
                        if anchor == nil { anchor = start }
                        onMove(start + Double(value.translation.width) * secondsPerPoint)
                    }
                    .onEnded { _ in anchor = nil })
            .onChange(of: isDragging) { _, dragging in
                if !dragging { anchor = nil }
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(time.timecodeText)
            .accessibilityAdjustableAction { direction in
                onMove(time + (direction == .increment ? 1 : -1))
            }
    }
}

// MARK: - Segment strip

/// The kept regions as tappable blocks under the waveform. This is the editor's
/// primary navigation once "Remove silence" has run: tap a block to select it,
/// then trim, delete or audition it.
private struct SegmentStrip: View {

    let duration: TimeInterval
    let segments: [ClosedRange<TimeInterval>]
    let selection: ClosedRange<TimeInterval>
    var onSelect: (ClosedRange<TimeInterval>) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary.opacity(0.4))

                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    let start = fraction(segment.lowerBound) * geometry.size.width
                    let end = fraction(segment.upperBound) * geometry.size.width
                    let isSelected = overlapsSelection(segment)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.tint.opacity(isSelected ? 0.85 : 0.35))
                        // A one-second segment of a one-hour recording is a third
                        // of a point wide and would vanish entirely. Three points
                        // keeps every block visible.
                        .frame(width: max(3, end - start))
                        .offset(x: start)
                        .accessibilityElement()
                        .accessibilityLabel("Segment \(segment.lowerBound.timecodeText) to \(segment.upperBound.timecodeText)")
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { onSelect(segment) }
                }
            }
            // Selection is by *nearest* segment to the tap, handled once for the
            // whole strip, rather than a tap gesture per block. Those blocks are
            // as narrow as three points after removing silence from a long
            // recording — far below the 44pt minimum — so per-block hit testing
            // would make most of them unselectable by touch. VoiceOver still
            // addresses each block directly through the elements above, where a
            // small frame is not a problem.
            .contentShape(.rect)
            .onTapGesture { location in
                guard duration > 0, geometry.size.width > 0 else { return }
                let tapped = Double(location.x / geometry.size.width) * duration
                guard let nearest = segments.min(by: {
                    distance(from: $0, to: tapped) < distance(from: $1, to: tapped)
                }) else { return }
                onSelect(nearest)
            }
        }
    }

    private func fraction(_ time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1))
    }

    /// Zero when `time` is inside the segment, otherwise the gap to its nearer end.
    private func distance(from segment: ClosedRange<TimeInterval>, to time: TimeInterval) -> TimeInterval {
        if segment.contains(time) { return 0 }
        return min(abs(segment.lowerBound - time), abs(segment.upperBound - time))
    }

    private func overlapsSelection(_ segment: ClosedRange<TimeInterval>) -> Bool {
        segment.lowerBound < selection.upperBound && selection.lowerBound < segment.upperBound
    }
}

// MARK: - Small parts

/// Coarse and fine adjustment for one selection handle. This is what stands in
/// for a zoomable timeline: dragging a handle across a phone-width waveform of a
/// one-hour recording moves it by about ten seconds per point, which is useless
/// for placing a cut, so the actual placing happens here.
private struct NudgeRow: View {
    let label: String
    let value: TimeInterval
    var onNudge: (TimeInterval) -> Void

    private static let steps: [TimeInterval] = [-5, -0.5, 0.5, 5]

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Text(value.timecodeText)
                .font(.footnote)
                .monospacedDigit()
                .frame(width: 62, alignment: .leading)
            Spacer(minLength: 0)
            ForEach(Self.steps, id: \.self) { step in
                Button {
                    onNudge(step)
                } label: {
                    Text(Self.title(step))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 30)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("\(label) \(step > 0 ? "forward" : "back") \(abs(step).formatted()) seconds")
            }
        }
    }

    private static func title(_ step: TimeInterval) -> String {
        let magnitude = abs(step) < 1
            ? String(format: "%.1f", abs(step))
            : String(Int(abs(step)))
        return "\(step < 0 ? "−" : "+")\(magnitude)"
    }
}

private struct EditAction: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .disabled(!isEnabled)
    }
}
