import SwiftUI

/// The day's recordings as a deck you flick through, over a compact device
/// strip and one record control.
///
/// **The device is no longer the hero.** It used to open with a 130pt status
/// card whose largest line was flash usage, above a full-width slab whose
/// subtitle explained a limitation — three stacked rectangles of near-identical
/// mass with no focal point, and rows carrying nothing but a date. The card each
/// recording gets here is big enough to show what the app actually produced: its
/// shape, its category, its length, how many tasks came out of it. The device
/// collapses to one line, because "connected, 95%" is all there is to say.
struct HomeView: View {

    @Environment(AppModel.self) private var model

    /// Which card the deck is showing, for the page dots. Nil until the first
    /// scroll settles, which is why the dots fall back to the first card.
    @State private var deckSelection: String?

    /// Home's own zoom namespace. A namespace can't be shared across navigation
    /// contexts — Library pushes into a different `NavigationStack` — so each
    /// place a card opens a detail screen declares one.
    @Namespace private var zoom

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    deviceStrip

                    if model.syncState.isActive { SyncCard() }

                    deckHeader

                    if deck.isEmpty {
                        EmptyHint(
                            symbol: "waveform",
                            title: "Nothing here yet",
                            message: "Record on your Plaud device, then sync. Recordings show up here.")
                            .padding(.top, 24)
                    } else {
                        cardDeck
                        pageDots
                    }

                    RecordButton { model.isRecorderPresented = true }

                    if model.untranscribedCount > 0 { pendingTranscriptions }

                    openTasksLink
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .navigationTitle("Recorder")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { transferMenu }
            .refreshable { model.sync() }
            .fullScreenCover(isPresented: $model.isRecorderPresented) {
                RecordingView()
            }
            // Recording started from a button on the device itself — follow it.
            .onChange(of: model.isRecording) { _, isRecording in
                if isRecording { model.isRecorderPresented = true }
            }
            // The deck's cards are the biggest waveforms in the app, so Home
            // warms the cache rather than waiting for the Library tab to be
            // opened. `prewarm` is once-per-launch and serial, so whichever tab
            // gets there first pays for it and the other is a no-op.
            .task {
                await WaveformCache.shared.prewarm(
                    model.recordings.compactMap { RecordingStore.shared.audioURL(for: $0) })
            }
        }
    }

    // MARK: - Deck

    /// Today's recordings, or the most recent handful when today is empty.
    ///
    /// A deck of one day is the intent, but a deck that is empty for most of any
    /// given day is a worse screen than one showing the last few — so the
    /// heading changes rather than the deck emptying.
    private var deck: [Recording] {
        let today = model.recordings.filter { Calendar.current.isDateInToday($0.createdAt) }
        return today.isEmpty ? Array(model.recordings.prefix(6)) : today
    }

    private var isShowingToday: Bool {
        model.recordings.contains { Calendar.current.isDateInToday($0.createdAt) }
    }

    private var deckHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isShowingToday ? "Today" : "Recent")
                .font(.largeTitle.weight(.bold))
            Text(deckSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var deckSubtitle: String {
        let count = deck.count
        guard count > 0 else { return "No recordings yet" }
        let minutes = Int((deck.reduce(0) { $0 + $1.duration } / 60).rounded())
        let recordings = "\(count) recording\(count == 1 ? "" : "s")"
        return minutes > 0 ? "\(recordings) · \(minutes) min" : recordings
    }

    private var cardDeck: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(deck) { recording in
                    NavigationLink {
                        RecordingDetailView(
                            recording: recording,
                            zoomSource: ZoomTransitionSource(id: recording.id, namespace: zoom))
                    } label: {
                        DeckCard(recording: recording)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: recording.id, in: zoom)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.delete(recording)
                        }
                        if recording.isSynced, !recording.isTranscribed {
                            Button("Transcribe", systemImage: "text.quote") {
                                model.transcribe(recording)
                            }
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        // Card-at-a-time paging, and the peek of the next card is what tells the
        // user there is one. Both halves matter: without `viewAligned` the deck
        // free-scrolls and the dots below lie.
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $deckSelection)
        .scrollIndicators(.hidden)
        // Cards are inset from the screen edge by the container's padding, so
        // the peek has to be given back here or the second card starts off-screen.
        .padding(.horizontal, -20)
        .contentMargins(.horizontal, 20, for: .scrollContent)
    }

    /// Which card you're on. Hidden at one card, where a single dot says nothing.
    @ViewBuilder
    private var pageDots: some View {
        if deck.count > 1 {
            let currentIndex = deck.firstIndex { $0.id == deckSelection } ?? 0
            HStack(spacing: 7) {
                ForEach(Array(deck.enumerated()), id: \.element.id) { index, _ in
                    Circle()
                        .fill(index == currentIndex ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: index == currentIndex ? 8 : 6,
                               height: index == currentIndex ? 8 : 6)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.2), value: currentIndex)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Chrome

    /// The whole device card, reduced to one line. Everything it used to say —
    /// firmware, flash usage, a progress bar — lives in Settings ▸ Recorder
    /// Hardware, which is where you go when you care.
    private var deviceStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: model.device?.model.symbolName ?? "waveform.circle")
                .font(.subheadline)
                .foregroundStyle(model.connectionState.isConnected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            Text(deviceName)
                .font(.subheadline.weight(.semibold))
            StatusDot(model.connectionState.indicatorColor)
            Text(deviceStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let device = model.device {
                Text("\(device.batteryLevel)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(device.batteryLevel < 15 ? .red : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.background.secondary, in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var deviceName: String {
        model.device?.name ?? model.pairedDevices.first?.name ?? "Recorder"
    }

    private var deviceStatus: String {
        switch model.connectionState {
        case .connected:
            let waiting = model.recordings.filter { !$0.isSynced }.count
            return waiting == 0 ? "connected" : "\(waiting) waiting to sync"
        case .scanning: return "looking…"
        case .connecting: return "connecting…"
        case .failed(let message): return message
        case .disconnected: return "not connected"
        }
    }

    @ToolbarContentBuilder
    private var transferMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Sync now", systemImage: "arrow.trianglehead.2.clockwise") {
                    model.sync()
                }
                .disabled(!model.connectionState.isConnected || model.syncState.isActive)

                // Hidden rather than disabled unless it's actually usable — a
                // permanently greyed row is just noise. Same `canUseWiFiTransfer`
                // guard Settings uses, so the two entry points never disagree.
                if model.canUseWiFiTransfer {
                    Button("WiFi Fast Transfer", systemImage: "bolt.horizontal") {
                        model.startWiFiTransfer()
                    }
                    .disabled(model.syncState.isActive)
                }

                if model.syncState.isActive {
                    Divider()
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        if model.syncState.isWiFi { model.stopWiFiTransfer() } else { model.stopSync() }
                    }
                }
            } label: {
                Label("Transfer", systemImage: "ellipsis")
            }
        }
    }

    private var pendingTranscriptions: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.untranscribedCount) waiting to transcribe")
                    .font(.subheadline.weight(.medium))
                Text("Runs on this iPhone. Nothing is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Start") { model.transcribeAllPending() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(Metrics.contentSpacing)
        .background(.background.secondary, in: .rect(cornerRadius: Metrics.cardRadius))
    }

    /// One line to the Tasks tab. Absent rather than zeroed — "0 open tasks" is
    /// a row that exists only to say nothing.
    @ViewBuilder
    private var openTasksLink: some View {
        let open = model.openActionItems.count
        if open > 0 {
            let sources = Set(model.openActionItems.map(\.recording.id)).count
            Label(
                "\(open) open task\(open == 1 ? "" : "s") across \(sources) recording\(sources == 1 ? "" : "s")",
                systemImage: "checklist")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tint)
                .padding(.top, 4)
        }
    }
}

// MARK: - Deck card

/// One recording, as a card in the deck: its waveform over a category-tinted
/// panel, then what it is and how long it ran.
///
/// Fixed width on purpose — `viewAligned` scroll paging needs a stable card
/// width to snap to, and a card that sized itself to its title would make the
/// snap points uneven.
private struct DeckCard: View {

    let recording: Recording

    @ScaledMetric private var cardWidth: CGFloat = 236
    @ScaledMetric private var cardHeight: CGFloat = 340
    @ScaledMetric private var panelHeight: CGFloat = 178

    private var category: RecordingCategory? {
        guard let name = recording.categoryName else { return nil }
        return CategoryStore.shared.category(named: name)
    }

    /// Uncategorized cards take the brand blue rather than grey: a deck is the
    /// front door, and a grey card there reads as broken rather than as unfiled.
    private var tint: Color {
        recording.categoryName == nil ? .bounce : CategoryStyle.color(for: category)
    }

    private var taskCount: Int {
        recording.actionItems?.filter { !$0.isDone }.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panel
            details
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .top)
        .background(tint.gradient, in: .rect(cornerRadius: 26))
        .containerShape(.rect(cornerRadius: 26))
        .shadow(color: tint.opacity(0.28), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var panel: some View {
        ZStack(alignment: .topLeading) {
            // A darkened wash rather than a second colour, so the panel is
            // obviously the same card and not a stacked surface.
            Color.black.opacity(0.10)

            SparklineLoader(recording: recording) { peaks in
                if peaks.isEmpty {
                    // No fabricated waveform. Until the envelope exists there is
                    // nothing true to draw, and a decorative one here would be a
                    // claim about audio nobody has decoded.
                    Image(systemName: "waveform")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WaveformView(
                        peaks: peaks,
                        progress: 1,
                        barWidth: 3,
                        barSpacing: 2,
                        playedStyle: AnyShapeStyle(.white.opacity(0.9)))
                    .padding(.horizontal, 20)
                    .padding(.top, 46)
                    .padding(.bottom, 18)
                }
            }

            if let name = category?.name {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white, in: .capsule)
                    .padding(16)
            }
        }
        .frame(height: panelHeight)
        .clipShape(.rect(corners: .concentric))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recording.displayTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text(recording.createdAt.formatted(date: .omitted, time: .shortened))
                Text("·")
                Text(recording.durationText).monospacedDigit()
                if taskCount > 0 {
                    Text("·")
                    Text("\(taskCount) task\(taskCount == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))

            statusLine
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Only when there's something to say. A card that reads "Transcribed" on
    /// every recording teaches the user to stop reading the line.
    @ViewBuilder
    private var statusLine: some View {
        if !recording.isSynced {
            Label("On the recorder", systemImage: "icloud.and.arrow.down")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
        } else if !recording.isTranscribed {
            Label("Not transcribed", systemImage: "text.quote")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var accessibilityLabel: String {
        var parts = [recording.displayTitle]
        if let name = category?.name { parts.append(name) }
        parts.append(recording.createdAt.formatted(date: .omitted, time: .shortened))
        if recording.duration > 0 { parts.append(recording.duration.spokenTimecode) }
        if taskCount > 0 { parts.append("\(taskCount) open task\(taskCount == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Sync card

private struct SyncCard: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.syncState.isWiFi ? "bolt.horizontal.circle.fill" : "arrow.trianglehead.2.clockwise")
                    .foregroundStyle(.tint)
                Text(headline)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                if let speed = model.syncState.progress?.speedText {
                    Text(speed)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = model.syncState.progress, progress.totalFiles > 0 {
                ProgressView(value: progress.fraction)
                Text("\(progress.syncedFiles) of \(progress.totalFiles) transferred")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(Metrics.contentSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: Metrics.cardRadius))
    }

    private var headline: String {
        switch model.syncState {
        case .wifiConnecting(let phase): return phase.label
        case .wifiTransferring: return "WiFi Fast Transfer"
        case .syncing(let progress): return progress.currentFileName ?? "Syncing over Bluetooth"
        default: return "Syncing"
        }
    }
}

// MARK: - Record control

/// The record control, anchored under the deck.
///
/// A light capsule with a red disc rather than the old full-width navy slab: the
/// slab was the heaviest object on the screen and the least interesting thing on
/// it, and a red disc is the one shape that needs no label to be understood.
private struct RecordButton: View {

    @Environment(AppModel.self) private var model
    let onOpen: () -> Void

    @ScaledMetric private var discSize: CGFloat = 32

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                ZStack {
                    if model.isRecording {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.red)
                            .frame(width: discSize * 0.62, height: discSize * 0.62)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: discSize, height: discSize)
                    }
                }
                .frame(width: discSize, height: discSize)
                .pulseWhenActive(model.isRecording)

                Text(model.isRecording ? "Recording" : "Record")
                    .font(.headline)

                Spacer(minLength: 0)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .disabled(!model.connectionState.isConnected)
    }

    private var subtitle: String {
        if model.isRecording { return "tap to open" }
        return model.connectionState.isConnected ? "on the \(deviceName)" : "connect your recorder"
    }

    private var deviceName: String {
        model.device?.name ?? "recorder"
    }
}
