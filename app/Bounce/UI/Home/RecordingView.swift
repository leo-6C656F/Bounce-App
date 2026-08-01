import SwiftUI

/// The live recorder, as a console.
///
/// Dark, fixed-scheme, and built around three things: how long it has been
/// running, what the audio is doing, and what has been said. The recorder is the
/// source of truth throughout — the buttons send BLE commands and the UI follows
/// the state that comes back, rather than assuming success.
///
/// **The colour scheme is forced, not inherited.** Everything on this screen is
/// laid over one near-black surface, so in Light Mode the system's `.primary`
/// and `.secondary` would resolve dark-on-dark and the transcript would vanish.
/// `.preferredColorScheme(.dark)` is what lets `TranscriptBlockRow` — shared
/// verbatim with the detail screen — render correctly here without a single
/// hardcoded white.
struct RecordingView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ticks the elapsed label without a Timer.
    @State private var now = Date()
    @State private var isAsking = false
    @State private var isPickingContinuation = false
    /// Observed so the "Continuing…" line updates the moment a target is picked.
    @State private var continuations = ContinuationStore.shared

    /// Recent level samples, oldest first, for the history ribbon.
    ///
    /// Accumulated here rather than in `RecordingManager` because it is purely a
    /// display artefact: the manager publishes an instantaneous level at 10 Hz
    /// and has no reason to remember it.
    @State private var levelHistory: [Float] = []

    @ScaledMetric private var transportSize: CGFloat = 64
    @ScaledMetric private var stopSize: CGFloat = 74
    @ScaledMetric private var ribbonHeight: CGFloat = 92

    /// How much history the ribbon holds. At the publisher's 10 Hz this is about
    /// twelve seconds — enough to read as motion, short enough that the bars
    /// stay wide enough to see.
    private static let historyLength = 120

    private var isPaused: Bool { if case .paused = model.recordingState { return true }; return false }

    /// The level meter only exists when live transcription is decoding real
    /// audio — see `RecordingManager.updateLevel`, which is fed from
    /// `LiveTranscriber.pumpSlice`. With it off, `blePcmData` never fires for
    /// E2EE recordings and there is nothing to draw. An honest absence beats a
    /// fake pulse, so the ribbon is simply not built.
    private var hasLevelData: Bool { DeliverySettings.shared.liveTranscription }

    var body: some View {
        ZStack {
            Color.consoleBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                topBar
                readout
                continuationBar

                if hasLevelData {
                    LevelRibbon(samples: levelHistory, isPaused: isPaused)
                        .frame(height: ribbonHeight)
                }

                Divider().opacity(0.25)

                LiveTranscriptView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if LiveTranscriber.shared.hasContent {
                    askPill
                }

                transport
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(0.2))
            }
        }
        .onChange(of: model.micLevel) { _, level in
            guard hasLevelData else { return }
            levelHistory.append(level)
            if levelHistory.count > Self.historyLength {
                levelHistory.removeFirst(levelHistory.count - Self.historyLength)
            }
        }
        .onChange(of: model.isRecording) { _, isRecording in
            if !isRecording { dismiss() }
        }
        .sheet(isPresented: $isAsking) {
            AskSheet(transcript: LiveTranscriber.shared.displayText)
        }
        .sheet(isPresented: $isPickingContinuation) {
            if let sessionId = model.recordingState.currentSessionId {
                ContinuationPicker(sessionId: sessionId)
            }
        }
    }

    // MARK: - Continuation

    /// "This is the rest of that recording."
    ///
    /// Offered while recording because that is when the user knows — the recorder
    /// closed a file when they last stopped, and they are picking up the same
    /// train of thought now. Nothing can actually be joined yet: the audio is
    /// still on the recorder. `ContinuationStore` parks the intent and
    /// `TranscriptionCoordinator` redeems it once both halves have synced and
    /// been transcribed, so the two arrive as one recording with one transcript.
    @ViewBuilder
    private var continuationBar: some View {
        if let sessionId = model.recordingState.currentSessionId {
            if let target = continuations.target(forSessionId: sessionId) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.caption2)
                    Text("Continuing “\(target.displayTitle)”")
                        .font(.caption)
                        .lineLimit(1)
                    Button {
                        continuations.unlink(sessionId: sessionId)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop continuing this recording")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .adaptiveGlass(in: .capsule, variant: .clear)
                .accessibilityElement(children: .combine)
            } else if !RecordingMerge.eligibleTargets(in: model.recordings).isEmpty {
                // Hidden when there is nothing to continue, which is most of the
                // time on a fresh library — an affordance that can only ever open
                // an empty list is worse than no affordance.
                Button {
                    isPickingContinuation = true
                } label: {
                    Label("Continue a recording…", systemImage: "link")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .padding(10)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Minimise")

            Spacer()

            HStack(spacing: 7) {
                StatusDot(isPaused ? .orange : .red, diameter: 8)
                    .pulseWhenActive(!isPaused)
                SectionLabel(statusText, tint: isPaused ? .orange : .red)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            // Balances the dismiss button so the status sits centred. An
            // `EmptyView` here would let the status drift left.
            Color.clear.frame(width: 44, height: 44)
        }
    }

    /// The number that matters, and the hardware it's running on.
    private var readout: some View {
        VStack(spacing: 4) {
            Text(elapsedText)
                .font(.system(size: 64, weight: .light, design: .default))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .default, value: elapsedText)

            Text(deviceLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording for \(elapsed.spokenTimecode)")
    }

    private var deviceLine: String {
        guard let device = model.device else { return "Recording on your Plaud" }
        var parts = [device.name, "\(device.batteryLevel)%"]
        if device.storageTotal > 0 {
            let free = ByteCountFormatter.string(
                fromByteCount: max(device.storageTotal - device.storageUsed, 0), countStyle: .file)
            parts.append("\(free) free")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Ask

    private var askPill: some View {
        Button {
            isAsking = true
        } label: {
            Label("Ask about this", systemImage: "sparkles")
                .font(.subheadline)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.glass)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Transport

    /// Three physical-feeling controls rather than one segmented pill: this is
    /// the screen where a mis-tap costs a recording, and separated targets with
    /// labels under them are harder to hit by accident than three thirds of a
    /// capsule.
    private var transport: some View {
        HStack(spacing: 0) {
            transportButton(
                symbol: isPaused ? "play.fill" : "pause.fill",
                label: isPaused ? "Resume" : "Pause",
                size: transportSize
            ) {
                isPaused ? model.resumeRecording() : model.pauseRecording()
            }

            transportButton(
                symbol: "stop.fill",
                label: "Stop",
                size: stopSize,
                fill: AnyShapeStyle(Color.red),
                foreground: .white,
                glow: .red
            ) {
                model.stopRecording()
            }

            transportButton(
                symbol: "star.fill",
                label: model.currentHighlightCount > 0
                    ? "\(model.currentHighlightCount) highlight\(model.currentHighlightCount == 1 ? "" : "s")"
                    : "Highlight",
                size: transportSize,
                foreground: .bounceGold,
                labelTint: model.currentHighlightCount > 0 ? .bounceGold : nil
            ) {
                model.addHighlight()
            }
            .disabled(isPaused)
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(
        symbol: String,
        label: String,
        size: CGFloat,
        fill: AnyShapeStyle = AnyShapeStyle(.white.opacity(0.12)),
        foreground: Color = .white,
        glow: Color? = nil,
        labelTint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle().fill(fill)
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.34))
                        .foregroundStyle(foreground)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: size, height: size)
            }
            .buttonStyle(.plain)
            .shadow(color: (glow ?? .clear).opacity(0.45), radius: 18, y: 4)

            Text(label)
                .font(.caption2)
                .foregroundStyle(labelTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    // MARK: - Derived

    private var elapsed: TimeInterval {
        guard let startedAt = model.recordingState.startedAt else { return 0 }
        return max(now.timeIntervalSince(startedAt), 0)
    }

    private var elapsedText: String { elapsed.timecodeText }

    private var statusText: String {
        switch model.recordingState {
        case .recording: return "Recording · on device"
        case .paused: return "Paused"
        case .idle: return model.connectionState.isConnected ? "Ready" : "Not connected"
        }
    }
}

// MARK: - Level ribbon

/// The last few seconds of input level, scrolling right to left.
///
/// Drawn in a `Canvas` for the same reason `WaveformView` is: this repaints ten
/// times a second for the length of a recording, and 120 `Capsule` views doing
/// that is exactly the kind of thing that makes a screen feel hot.
///
/// The live edge is red and the history fades back into blue, so "now" is
/// findable without a playhead.
private struct LevelRibbon: View {

    let samples: [Float]
    let isPaused: Bool

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard !samples.isEmpty else { return }
            let stride: CGFloat = 5.5
            let barWidth: CGFloat = 3
            let count = max(1, Int(size.width / stride))
            // Right-aligned: the newest sample is at the live edge, and a short
            // history grows leftward from it rather than stretching to fill.
            let visible = samples.suffix(count)
            let offset = size.width - CGFloat(visible.count) * stride

            for (index, sample) in visible.enumerated() {
                let magnitude = CGFloat(min(max(sample, 0), 1))
                let height = max(3, magnitude * size.height)
                let rect = CGRect(
                    x: offset + CGFloat(index) * stride,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height)
                let position = Double(index) / Double(max(visible.count - 1, 1))
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(colour(at: position)))
            }
        }
        .opacity(isPaused ? 0.35 : 1)
        .animation(.easeOut(duration: 0.12), value: isPaused)
        .accessibilityHidden(true)
    }

    private func colour(at position: Double) -> Color {
        // The last ~14% is "now".
        position > 0.86 ? .red : Color.bounce.opacity(0.35 + position * 0.5)
    }
}

// MARK: - Continuation picker

/// Choose which recording the session in progress is a continuation of.
///
/// Deliberately a plain list of the most recent joinable recordings rather than
/// a search: the thing being continued was almost certainly made minutes ago,
/// and this sheet is opened mid-recording, when nobody wants to type.
private struct ContinuationPicker: View {

    let sessionId: Int

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(RecordingMerge.eligibleTargets(in: model.recordings)) { recording in
                Button {
                    ContinuationStore.shared.link(sessionId: sessionId, to: recording.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.displayTitle)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text("\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(recording.durationText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Continue a recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("When this recording syncs, the two are joined into one recording with one transcript. The originals are removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Ask sheet

/// The AI Q&A, presented as a pull-up sheet so it never competes with the live
/// transcript for space. Reused for both the live screen and, later, the detail.
private struct AskSheet: View {

    let transcript: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                TranscriptQAView(transcript: transcript)
                    .padding(20)
            }
            .navigationTitle("Ask about this")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}
