import SwiftUI

/// One recording: play it, read it, send it.
struct RecordingDetailView: View {

    let recording: Recording
    /// The row this screen was pushed from, so it zooms out of it instead of
    /// sliding in. Nil where the caller has no matching source — see
    /// `ZoomTransitionSource`.
    var zoomSource: ZoomTransitionSource? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var player = AudioPlayerModel.shared
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isNamingSpeakers = false
    @State private var isEditingAudio = false
    @State private var isCorrectingWord = false
    @State private var isPickingSeries = false
    @State private var isPickingMeeting = false
    @State private var tab: DetailTab = .transcript
    /// Peak envelope for the waveform. Empty until `WaveformCache` has one —
    /// building it is a full decode pass, so the bar draws a flat baseline in
    /// the meantime rather than resizing when it arrives.
    @State private var peaks: [UInt8] = []
    /// What the transcript should bring into view, and where to put it.
    @State private var scrollTarget: ScrollRequest?
    /// Whether the navigation bar carries the title.
    ///
    /// False while the header's own title is on screen: the same string set
    /// twice, once inline and once at display size, reads as a bug. The bar
    /// picks it up as the header scrolls away, which is what
    /// `onScrollVisibilityChange` exists for. Flips at most once per direction
    /// change, so this is not a per-frame invalidation of `body`.
    @State private var showsToolbarTitle = false
    /// A hand-run chapter pass is in flight. Drives an inline spinner rather
    /// than a modal: it's a model call over the transcript and takes seconds,
    /// and the transcript stays readable while it runs.
    @State private var isFindingChapters = false

    enum DetailTab: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case summary = "Summary"
        case ask = "Ask"
        var id: String { rawValue }
    }

    /// Always read through the store so edits and transcription land here.
    private var current: Recording {
        model.current(recording)
    }

    private var audioURL: URL? {
        RecordingStore.shared.audioURL(for: current)
    }

    private var status: TranscriptionCoordinator.Status? {
        TranscriptionCoordinator.shared.status(for: current)
    }

    var body: some View {
        // Resolve the store-backed recording once per `body` rather than paying a
        // lookup at each of the ~30 references below. Every access re-reads the
        // latest value because `body` re-runs on any observed change, so this is
        // freshness-equivalent to the computed `current`, just not repeated.
        let current = current
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    switch tab {
                    case .transcript: transcriptTab
                    case .summary: SummaryTabView(recording: current)
                    case .ask: askTab
                    }
                }
                .padding(.horizontal, 20)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                // The animation wraps `scrollTo`, not the state assignment that
                // triggered this — a transaction set around the assignment may
                // or may not reach the `onChange` action, which shows up as the
                // transcript jumping rather than gliding.
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .top) {
            Picker("View", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .safeAreaBar(edge: .bottom) {
            if audioURL != nil {
                PlayerBar(
                    player: player,
                    peaks: peaks,
                    highlights: current.highlights ?? []
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(showsToolbarTitle ? current.displayTitle : "")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .zoomTransition(from: zoomSource)
        // Keyed on the filename, not a bare `.task`: a background sync can land
        // while this screen is open, at which point `audioURL` goes from nil to
        // a real file and the player bar appears. A bare `.task` never re-runs,
        // so the bar would render with an unloaded player — flat waveform, zero
        // duration, and a play button that silently does nothing.
        .task(id: current.audioFilename) {
            guard let audioURL else { return }
            player.load(url: audioURL, title: current.displayTitle)
            // Decodes on a miss, which is why this is the detail view and not a
            // list row: the user opened this screen, so the waveform is worth
            // the pass. Cached for every later appearance, here and in rows.
            peaks = await WaveformCache.shared.peaks(for: audioURL) ?? []
            // Share offers the audio file too, so it goes stale on the same
            // event this task exists for: a sync landing while the screen is
            // open. Without this, audio arriving with no transcript change
            // (auto-transcribe off, or the engine failing) leaves Share
            // disabled even though there is now a file to share.
            refreshShareItems()
        }
        .onChange(of: current.displayTitle) { _, title in player.updateTitle(title) }
        // Rendering the transcript and writing it to a temp file is far too
        // expensive to sit in `body` — see `shareItems`.
        .task(id: current.transcript) { refreshShareItems() }
        .alert("Rename recording", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Save") { model.rename(current, to: draftTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isPickingSeries) {
            SeriesPicker(recording: current)
        }
        .sheet(isPresented: $isPickingMeeting) {
            MeetingPicker(recording: current)
        }
        .sheet(isPresented: $isNamingSpeakers) {
            SpeakerNamesSheet(recording: current)
        }
        .sheet(isPresented: $isEditingAudio) {
            if let audioURL {
                AudioEditorView(recording: current, sourceURL: audioURL)
            }
        }
        .sheet(isPresented: $isCorrectingWord) {
            WordCorrectionSheet(recording: current)
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var transcriptTab: some View {
        if let error = player.errorMessage {
            ContentCard {
                Label(error, systemImage: "speaker.slash.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        MeetingAgendaView(recording: current, transcriptText: current.transcript?.plainText)
        executiveBriefCard
        highlightsRow

        if let transcript = current.transcript {
            transcriptBody(transcript)
            archivedPreview
        } else {
            transcriptPlaceholder
        }
    }

    @ViewBuilder
    private var askTab: some View {
        if let transcript = current.transcript {
            TranscriptQAView(transcript: transcript.plainText)
        } else {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "text.quote",
                description: Text("Transcribe this recording to ask questions about it."))
                .padding(.top, 40)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if current.isSynced {
                    if !current.isTranscribed || current.transcript?.isLivePreview == true {
                        Button("Transcribe", systemImage: "text.quote") {
                            model.transcribe(current)
                        }
                    } else {
                        // Re-run against the current engine (switch it in
                        // Settings → Transcription engine first, if you want).
                        Button("Transcribe again", systemImage: "arrow.clockwise") {
                            model.retranscribe(current)
                        }
                    }
                }

                Button("Rename", systemImage: "pencil") {
                    draftTitle = current.title == Recording.untitled ? "" : current.title
                    isRenaming = true
                }

                // Gated on the audio actually resolving, not just on `isSynced`:
                // the editor's whole job is rewriting that file, and there is
                // nothing to open if it isn't there.
                if audioURL != nil {
                    Button("Edit audio", systemImage: "scissors") {
                        // The editor takes the audio session for its own
                        // auditioning, and two players fighting over one session
                        // is the documented cause of "playing but stuck at 0:00".
                        player.stop()
                        isEditingAudio = true
                    }
                }

                // Only with a transcript to correct. Gated on `transcript` rather
                // than `isTranscribed` so it also covers a live preview promoted
                // into place.
                if current.transcript != nil {
                    Button("Correct a word…", systemImage: "textformat.abc.dottedunderline") {
                        isCorrectingWord = true
                    }
                }

                // Tagging is a submenu rather than a sheet: it's a toggle over a
                // short known list, and a sheet for that is a lot of ceremony for
                // one tap. Shown only when the user has categories to tag with.
                if !CategoryStore.shared.categories.isEmpty {
                    Menu("Tags", systemImage: "tag") {
                        ForEach(CategoryStore.shared.categories) { tag in
                            let isOn = current.tagIds?.contains(tag.id) == true
                            Button {
                                model.toggleTag(tag.id, on: current)
                            } label: {
                                Label(
                                    tag.name,
                                    systemImage: isOn
                                        ? "checkmark.circle.fill"
                                        : CategoryStyle.symbol(for: tag))
                            }
                        }
                    }
                }

                Button("Meeting series", systemImage: "repeat") {
                    isPickingSeries = true
                }

                Button("Link to meeting", systemImage: "calendar") {
                    isPickingMeeting = true
                }

                if current.transcript?.hasSpeakers == true {
                    Button("Name speakers", systemImage: "person.2") {
                        isNamingSpeakers = true
                    }
                }

                let destinations = DeliverySettings.shared.activeDestinations
                if !destinations.isEmpty {
                    Divider()
                    ForEach(destinations) { destination in
                        Button("Send to \(destination.label)", systemImage: destination.symbolName) {
                            model.send(current, to: destination)
                        }
                    }
                    if destinations.count > 1 {
                        Button("Send to all", systemImage: "paperplane.fill") {
                            model.sendToAll(current)
                        }
                    }
                }

                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    player.stop()
                    model.delete(current)
                    dismiss()
                }
            } label: {
                Label("Actions", systemImage: "ellipsis")
            }
        }

        // Adjacent toolbar items merge into one glass capsule on iOS 26 unless
        // separated — sharing and the destructive delete inside the actions
        // menu have no business reading as one visual pill.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        // The native share sheet is the "send it anywhere" catch-all: Mail,
        // Messages, Slack, Notion, Obsidian, AirDrop, Files — whatever the user
        // has installed.
        ToolbarItem(placement: .primaryAction) {
            ShareLink(items: shareItems) { item in
                SharePreview(current.displayTitle)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(shareItems.isEmpty)
        }
    }

    /// Audio file plus a transcript text file, when both exist.
    ///
    /// **State, not a computed property.** `ShareLink(items:)` is inside
    /// `toolbarContent`, which SwiftUI re-evaluates on every view update — and
    /// the playback ticker updates this view ten times a second. As a computed
    /// property this rendered the entire transcript and wrote a file to the
    /// temporary directory on each of those ticks. It now refreshes only when
    /// the transcript or the audio actually changes.
    @State private var shareItems: [URL] = []

    private func refreshShareItems() {
        var items: [URL] = []
        if let audioURL { items.append(audioURL) }
        if let url = transcriptFileURL { items.append(url) }
        shareItems = items
    }

    /// Written to the temporary directory so the share sheet has a real file to
    /// hand over rather than a string.
    private var transcriptFileURL: URL? {
        let format = DeliverySettings.shared.transcriptFormat
        // The recording-aware overload, so a Markdown share carries its YAML
        // frontmatter rather than a bare transcript.
        guard let text = format.render(current) else { return nil }
        let safeName = current.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
        // The extension comes from the format. iOS infers the shared file's type
        // from it, so a `.txt` full of Markdown lands in Obsidian as plain text.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(safeName.isEmpty ? "Transcript" : safeName).\(format.fileExtension)")
        guard (try? Data(text.utf8).write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    // MARK: - Sections

    /// The screen's headline: the recording's title at display size, with its
    /// provenance as one quiet line beneath.
    ///
    /// This replaces the `ContentCard` of three labelled `Stat` columns the
    /// screen used to open with. Same information, but that arrangement left the
    /// recording's own name — the one thing that identifies it — as the smallest
    /// text on the screen, sitting in the navigation bar as if it were a window
    /// label rather than the document's title.
    ///
    /// Set in the reading serif, matching the desktop client's `#title`
    /// (`WebClient/index.html`), for the reason stated there: it is the headline
    /// of a document you are about to read.
    ///
    /// It renders on every tab, not just Transcript, and it sits *below* the tab
    /// picker rather than above it — the picker is chrome and stays pinned in the
    /// top safe-area bar so it is reachable from anywhere in a long transcript,
    /// while the header is content and scrolls with the rest.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(current.displayTitle)
                    .font(.readingTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The navigation bar's title is empty while this is on
                    // screen, so without the trait there is no heading for
                    // VoiceOver's rotor to land on.
                    .accessibilityAddTraits(.isHeader)
                    // The navigation bar takes the title over exactly as this
                    // leaves, so the two are never on screen together.
                    .onScrollVisibilityChange(threshold: 0.15) { isVisible in
                        showsToolbarTitle = !isVisible
                    }

                Text(provenance(spoken: false))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    // Wraps rather than truncates: three short runs fit a phone
                    // width at ordinary sizes and fall onto a second line beyond,
                    // which is better than losing the word count entirely.
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(provenance(spoken: true))
            }

            if current.categoryName != nil {
                CategoryChip(categoryName: current.categoryName)
            }

            // Tags sit under the category, not beside it: the category is one
            // AI-assigned value and tags are an open user-applied set, so
            // interleaving them would imply they're the same kind of thing.
            let tags = model.tags(for: current)
            if !tags.isEmpty {
                TagChipRow(tags: tags) { tag in
                    model.toggleTag(tag.id, on: current)
                }
            }

            // Below the tags and above the delivery receipt: where a meeting
            // happened is provenance, like the date in the line above it, not a
            // classification the user applies.
            // Above the location card: which meeting this is one of comes before
            // where it happened, and the "since last time" recap is the first
            // thing worth reading on a recurring meeting.
            SeriesCard(recording: current)

            // Which single meeting this recording is of — set automatically when
            // matching is confident, and linked or corrected by hand here when it
            // isn't. Above the location for the same reason the series is: what a
            // recording is comes before where it happened.
            MeetingCard(recording: current)

            PlaceCard(recording: current)

            if !current.deliveredTo.isEmpty {
                Label(
                    "Sent to \(current.deliveredTo.map { Destination(rawValue: $0)?.label ?? $0 }.joined(separator: ", "))",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "28 Jul 2026 at 15:04 · 12:04 · 1,842 words".
    ///
    /// Unlabelled, mirroring the desktop client's `.head-meta`, which sets the
    /// same three values the same way. An unknown length is dropped rather than
    /// printed as `Recording.durationText`'s `--:--`: a dash was legible as an
    /// absent number under a "Length" column heading, but in a run of prose it
    /// reads as a missing word.
    ///
    /// `spoken` is the VoiceOver rendering: "12:04" straight after a time of day
    /// is announced as another clock time, so the length is spelled out instead.
    /// Same reasoning as `TimeInterval.spokenTimecode`, which is what it uses.
    private func provenance(spoken: Bool) -> String {
        var parts = [current.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if current.duration > 0 {
            parts.append(spoken ? current.duration.spokenTimecode : current.durationText)
        }
        if let transcript = current.transcript {
            let words = transcript.wordCount
            parts.append("\(words.formatted()) \(words == 1 ? "word" : "words")")
        }
        // Said here rather than in a card of its own: being joined from several
        // recordings is provenance — the same class of fact as when it was made
        // and how long it runs — and the seams themselves are already visible as
        // chapter headings in the transcript below.
        if let count = current.parts?.count, count > 1 {
            parts.append("joined from \(count) recordings")
        }
        return parts.joined(separator: spoken ? ", " : " · ")
    }

    @State private var copiedBrief = false

    @ViewBuilder
    private var executiveBriefCard: some View {
        if current.transcript != nil {
            ContentCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Executive Brief", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(.tint)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = formattedExecutiveBrief
                            copiedBrief = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copiedBrief = false
                            }
                        } label: {
                            Label(copiedBrief ? "Brief Copied" : "Copy Brief", systemImage: copiedBrief ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }

                    if let items = current.actionItems, !items.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                            Text("\(items.count) Action Item\(items.count == 1 ? "" : "s") identified")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let summary = current.summaries?.first?.text {
                        Text(summary)
                            .font(.subheadline)
                            .lineLimit(4)
                            .foregroundStyle(.primary)
                    } else if current.actionItems?.isEmpty == false {
                        Text("Action items extracted on-device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var formattedExecutiveBrief: String {
        var lines: [String] = []
        lines.append("# \(current.displayTitle)")
        lines.append("📅 Date: \(current.createdAt.formatted(date: .long, time: .shortened))")
        // `timecodeText`, not a local `%d:%02d` — that spelling has no hour
        // rollover, so a 92-minute recording exports as "92:14". See the
        // one-formatter rule on `TimeInterval.timecodeText`.
        lines.append("⏱ Duration: \(current.duration.timecodeText)")
        if let category = current.categoryName {
            lines.append("🏷 Category: \(category)")
        }
        lines.append("")

        if let summaries = current.summaries, let main = summaries.first {
            lines.append("## Summary")
            lines.append(main.text)
            lines.append("")
        }

        if let items = current.actionItems, !items.isEmpty {
            lines.append("## Action Items (\(items.count))")
            for item in items {
                let status = item.isDone ? "[x]" : "[ ]"
                lines.append("- \(status) \(item.text)")
                if let detail = item.detail {
                    lines.append("  \(detail)")
                }
            }
            lines.append("")
        }

        if let transcript = current.transcript?.plainText {
            lines.append("## Transcript Preview")
            lines.append(String(transcript.prefix(500)) + "...")
        }

        return lines.joined(separator: "\n")
    }

    /// Marks flagged with the Highlight button during recording. Tap to seek.
    @ViewBuilder
    private var highlightsRow: some View {
        if let highlights = current.highlights, !highlights.isEmpty {
            ContentCard {
                VStack(alignment: .leading, spacing: 10) {
                    // Gold on the star and the chips only — it's the app's
                    // "you marked this" accent, and these are the marks. See
                    // `Color.bounceGold`.
                    Label {
                        Text("Highlights")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Color.bounceGold)
                    }
                    .font(.subheadline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(highlights.enumerated()), id: \.offset) { _, mark in
                                Button {
                                    player.seek(to: mark)
                                } label: {
                                    Text(mark.timecodeText)
                                        .font(.caption.monospacedDigit())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.glass)
                                .tint(.bounceGold)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func transcriptBody(_ transcript: Transcript) -> some View {
        TranscriptSection(
            transcript: transcript,
            chapters: current.chapters ?? [],
            duration: current.duration,
            speakerNames: current.speakerNames,
            player: player,
            scrollTarget: $scrollTarget,
            isFindingChapters: isFindingChapters,
            onNameSpeakers: { isNamingSpeakers = true },
            onFindChapters: model.canFindChapters(current) ? { findChapters() } : nil)
    }

    /// Chapter the transcript on demand.
    ///
    /// Needed because the automatic pass runs at transcription time only, so a
    /// library transcribed before chapters existed would never get them — the
    /// same "new feature looks broken on an established library" problem the
    /// action-item backfill scan solves. The flag drives an inline spinner: this
    /// is a model call over the whole transcript and takes seconds.
    private func findChapters() {
        guard !isFindingChapters else { return }
        isFindingChapters = true
        Task {
            await model.findChapters(for: current)
            isFindingChapters = false
        }
    }

    /// The archived live-while-recording draft, once the authoritative pass has
    /// replaced it. Collapsed by default — it's a reference, not the main text.
    @ViewBuilder
    private var archivedPreview: some View {
        if let preview = current.livePreview, !preview.segments.isEmpty {
            ContentCard {
                DisclosureGroup {
                    Text(preview.plainText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 8)
                } label: {
                    Label("Live draft (archived)", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptPlaceholder: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                if let status {
                    HStack(spacing: 8) {
                        if status.isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(status.label)
                            .font(.subheadline)
                    }
                    if case .failed = status {
                        Button("Try again") { model.transcribe(current) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                } else if !current.isSynced {
                    Label("Still on the recorder", systemImage: "icloud.and.arrow.down")
                        .font(.subheadline)
                    Text("Sync from the Recorder tab to bring the audio across.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Not transcribed yet", systemImage: "text.quote")
                        .font(.subheadline)
                    Text("Transcription runs on this iPhone. Nothing is uploaded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Transcribe now") { model.transcribe(current) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Transcript

/// Something to bring into view in the transcript.
///
/// Carries the anchor because the two callers want different ones — a chapter
/// heading belongs at the top of the screen, a block being played belongs in the
/// middle — and a `nonce` so that repeating a request for the same row is still
/// an observable change.
private struct ScrollRequest: Equatable {
    let id: String
    let anchor: UnitPoint
    let nonce: Int
}

/// One row of the transcript: a chapter heading, or a block.
///
/// Exists so both can be direct children of a single `LazyVStack` — see
/// `TranscriptSection.itemList` for why that flattening is load-bearing rather
/// than tidiness.
private enum TranscriptItem: Identifiable {
    case chapter(Transcript.ChapteredSection)
    case block(TranscriptBlock, showsSpeaker: Bool)

    /// Namespaced, because a chapter and a block could otherwise collide on a
    /// bare integer, and `ForEach` diffing with duplicate ids is undefined.
    var id: String {
        switch self {
        case .chapter(let section): return "chapter-\(section.id)"
        case .block(let block, _): return Self.blockId(block.id)
        }
    }

    static func blockId(_ id: Int) -> String { "block-\(id)" }

    /// `showsSpeaker` is computed against the slice being rendered, not the whole
    /// transcript: a chapter or a result list that opens mid-conversation must
    /// print the speaker on its first row, or the first paragraph is attributed
    /// to whoever happened to be talking on the previous screen.
    static func items(for blocks: [TranscriptBlock]) -> [TranscriptItem] {
        blocks.enumerated().map { index, block in
            .block(block, showsSpeaker: blocks.showsSpeaker(at: index))
        }
    }

    static func items(for sections: [Transcript.ChapteredSection]) -> [TranscriptItem] {
        sections.flatMap { [.chapter($0)] + items(for: $0.blocks) }
    }
}

/// The transcript, in chapters, and the only thing on this screen that watches
/// the playhead.
///
/// **Its own view on purpose.** Reading `player.currentTime` registers the
/// enclosing body for `@Observable` invalidation at the ticker's 10 Hz, so
/// computing the current block inside `RecordingDetailView.body` re-ran that
/// entire body — toolbar included — ten times a second. Scoping the observation
/// here means playback invalidates the transcript and nothing else.
///
/// Blocks and sections are cached in `@State` rather than regrouped per render,
/// and laid out lazily so only visible rows are constructed. Eagerly, a long
/// recording built every row on every tick.
///
/// **Chapters are optional everywhere.** `ChapterGenerator` declines short
/// recordings, devices without Apple Intelligence, and answers that fail
/// validation, so `sections` is nil far more often than not and the flat block
/// list is the real baseline rather than a degraded mode.
private struct TranscriptSection: View {

    let transcript: Transcript
    let chapters: [TranscriptChapter]
    let duration: TimeInterval
    let speakerNames: [String: String]?
    let player: AudioPlayerModel
    @Binding var scrollTarget: ScrollRequest?
    var isFindingChapters = false
    var onNameSpeakers: (() -> Void)? = nil
    /// Nil when a chapter pass can't run — no model, or too short a recording.
    /// Absent rather than disabled: a permanently greyed control that never
    /// explains itself is worse than no control.
    var onFindChapters: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blocks: [TranscriptBlock] = []
    @State private var sections: [Transcript.ChapteredSection]?
    @State private var search = ""
    /// Bumped on every scroll request — see `ScrollRequest.nonce`.
    @State private var scrollNonce = 0

    /// Ask the detail view to bring something into view.
    ///
    /// Always allocates a fresh `nonce`, so two requests for the *same* row are
    /// still different values and `onChange` fires. Without it, tapping a chapter
    /// chip a second time — after scrolling away by hand — did nothing, because
    /// the binding already held that id.
    private func requestScroll(to id: String, anchor: UnitPoint) {
        scrollNonce += 1
        scrollTarget = ScrollRequest(id: id, anchor: anchor, nonce: scrollNonce)
    }

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Blocks matching the search, or nil when nothing is being searched.
    ///
    /// **Search flattens the chapters deliberately.** Matches scattered across
    /// six chapters rendered under six headings, most of them holding a single
    /// line, reads as a broken outline rather than as a result list.
    private var matches: [TranscriptBlock]? {
        guard !query.isEmpty else { return nil }
        return blocks.filter { $0.text.lowercased().contains(query) }
    }

    var body: some View {
        let currentId = currentBlockId

        VStack(alignment: .leading, spacing: 14) {
            titleRow

            if let sections, matches == nil {
                chapterChips(sections)
            }

            if blocks.count > 4 || !query.isEmpty {
                searchField
            }

            if let matches {
                resultList(matches, currentId: currentId)
            } else if let sections {
                itemList(TranscriptItem.items(for: sections), currentId: currentId)
            } else {
                itemList(TranscriptItem.items(for: blocks), currentId: currentId)
            }
        }
        .onAppear { rebuild() }
        .onChange(of: transcript) { rebuild() }
        .onChange(of: speakerNames) { rebuild() }
        .onChange(of: chapters) { rebuild() }
        .onChange(of: currentId) { _, newId in
            // Follow playback, but never fight a user who is reading ahead —
            // this only moves while audio is actually running. Suppressed under
            // Reduce Motion: content moving without user input is exactly what
            // that setting exists to stop. Also suppressed while searching, where
            // the rows on screen aren't the ones playback is moving through.
            guard player.isPlaying, !reduceMotion, matches == nil, let newId else { return }
            requestScroll(to: TranscriptItem.blockId(newId), anchor: .center)
        }
    }

    // MARK: - Header

    private var titleRow: some View {
        HStack(spacing: 10) {
            Text("Transcript")
                .font(.headline)

            if isFindingChapters {
                ProgressView().controlSize(.mini)
            }

            Spacer(minLength: 0)

            if transcript.hasSpeakers, let onNameSpeakers {
                Button {
                    onNameSpeakers()
                } label: {
                    Label("Name speakers", systemImage: "person.2.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            if sections == nil, let onFindChapters, !isFindingChapters {
                Button {
                    onFindChapters()
                } label: {
                    Label("Find chapters", systemImage: "list.bullet.indent")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }

    /// Jump to a chapter. Seeks *and* scrolls: seeking alone leaves the reader
    /// looking at the wrong part of the page while audio plays somewhere else.
    private func chapterChips(_ sections: [Transcript.ChapteredSection]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(sections) { section in
                    // The two styles are different types, so this is written out
                    // rather than selected with a ternary — same reason the old
                    // `DeviceChip` spelled both branches.
                    if currentSectionId == section.id {
                        chip(section).buttonStyle(.glassProminent)
                    } else {
                        chip(section).buttonStyle(.glass)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ section: Transcript.ChapteredSection) -> some View {
        Button {
            player.seek(to: section.chapter.start)
            // The heading, at the top of the screen — not the first block
            // centred, which puts the chapter title off-screen above it.
            requestScroll(to: TranscriptItem.chapter(section).id, anchor: .top)
        } label: {
            Text(section.chapter.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .accessibilityLabel("\(section.chapter.title), from \(section.chapter.start.spokenTimecode)")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search this transcript", text: $search)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background.secondary, in: .rect(cornerRadius: Metrics.fieldRadius))
    }

    // MARK: - Lists

    /// Headings and rows, interleaved, as the **direct children of one**
    /// `LazyVStack`.
    ///
    /// **This flattening is what makes the chapter chips work.** Chapters were
    /// each a `VStack` inside the lazy container, with the rows one level down
    /// inside them — so a `scrollTo(blockId)` for a chapter that hadn't been
    /// realised yet had no view to find, and the chip did nothing at all. A
    /// `LazyVStack` only knows the identities of its direct children; nesting the
    /// ids inside an unrealised container hides them. Flat, every heading and
    /// every row is addressable whether or not it has been built, and laziness is
    /// preserved — which the obvious fix of making the outer stack eager would
    /// have thrown away on a long recording.
    private func itemList(_ items: [TranscriptItem], currentId: Int?) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                switch item {
                case .chapter(let section):
                    chapterHeading(section)
                        .id(TranscriptItem.chapter(section).id)
                case .block(let block, let showsSpeaker):
                    Button {
                        player.seek(to: block.start)
                    } label: {
                        TranscriptBlockRow(
                            block: block,
                            // Only the block under the playhead needs the time,
                            // and it's the only one that re-renders per phrase.
                            emphasis: block.id == currentId
                                ? .playing(currentTime: player.currentTime)
                                : .none,
                            showsSpeaker: showsSpeaker,
                            showsAvatar: transcript.hasSpeakers)
                    }
                    .buttonStyle(.plain)
                    .id(TranscriptItem.blockId(block.id))
                }
            }
        }
    }

    private func chapterHeading(_ section: Transcript.ChapteredSection) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(.tint)
                .frame(width: 3, height: 14)
            SectionLabel(section.chapter.title, tint: .accentColor)
            Spacer(minLength: 0)
            Text(section.rangeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func resultList(_ matches: [TranscriptBlock], currentId: Int?) -> some View {
        if matches.isEmpty {
            Text("Nothing in this transcript matches “\(search)”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("\(matches.count) match\(matches.count == 1 ? "" : "es")")
                itemList(TranscriptItem.items(for: matches), currentId: currentId)
            }
        }
    }

    // MARK: - Derived

    /// Grouping allocates a `TranscriptBlock` per block and joins its text, so
    /// it is done when the transcript, the names or the chapters change — not on
    /// every playback tick.
    private func rebuild() {
        blocks = transcript.blocks(speakerNames: speakerNames)
        sections = chapters.isEmpty
            ? nil
            : transcript.chapteredSections(chapters, duration: duration, speakerNames: speakerNames)
    }

    /// The block containing the playhead. Walks the already-grouped blocks; an
    /// earlier version re-grouped the whole transcript inside a per-row
    /// predicate, so a 200-block transcript did 200 full groupings per tick.
    private var currentBlockId: Int? {
        guard player.duration > 0 else { return nil }
        let time = player.currentTime
        for (index, block) in blocks.enumerated() {
            let next = index + 1 < blocks.count ? blocks[index + 1].start : .infinity
            if time >= block.start && time < next { return block.id }
        }
        return nil
    }

    /// Which chapter the playhead is in, for the chip highlight.
    private var currentSectionId: String? {
        guard let sections, player.duration > 0 else { return nil }
        let time = player.currentTime
        return sections.last { time >= $0.chapter.start }?.id
    }
}

// MARK: - Pieces

/// Assign real names to the diarized "Speaker 1/2" labels. Names are stored on
/// this recording only: the engine's labels aren't stable across recordings, so
/// there is no voice identity for a name to follow.
private struct SpeakerNamesSheet: View {

    let recording: Recording

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]
    /// Which speaker's field the suggestion chips fill. Nil until one is focused —
    /// tapping a name with nothing focused has no unambiguous target.
    @FocusState private var focused: String?
    /// Names pre-filled from the previous same-category recording and **not yet
    /// confirmed**.
    ///
    /// Held here rather than written into `names`, because these are a guess from
    /// position and history — not voice recognition, which is impossible with
    /// anonymous diarization. A wrong name silently baked into a transcript, then
    /// carried into every share and webhook, is worse than no name. They render
    /// greyed and become real only on Confirm.
    @State private var unconfirmed: [String: String] = [:]

    private var speakers: [String] {
        recording.transcript?.speakers ?? []
    }

    /// Attendees of the linked meeting, deduped. Offered as their own group above
    /// the general history: they're evidence about *this* recording, where the
    /// directory is only a prior over every meeting. Empty when nothing is linked.
    private var attendeeSuggestions: [String] {
        var seen = Set<String>()
        return (recording.calendarAttendees ?? []).filter { name in
            !name.isEmpty && seen.insert(name.lowercased()).inserted
        }
    }

    /// Names the user has typed before, minus any already offered as an attendee
    /// so no name appears in both groups.
    private var knownSuggestions: [String] {
        var seen = Set(attendeeSuggestions.map { $0.lowercased() })
        return SpeakerDirectory.shared.suggestions.map(\.name).filter { name in
            !name.isEmpty && seen.insert(name.lowercased()).inserted
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !unconfirmed.isEmpty {
                    Section {
                        ForEach(speakers, id: \.self) { speaker in
                            if let guess = unconfirmed[speaker] {
                                HStack {
                                    Text(label(for: speaker))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(guess).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        HStack {
                            Button("Confirm") {
                                for (speaker, guess) in unconfirmed { names[speaker] = guess }
                                unconfirmed = [:]
                            }
                            .buttonStyle(.glassProminent)
                            Spacer()
                            Button("Clear") { unconfirmed = [:] }
                                .buttonStyle(.glass)
                        }
                        .controlSize(.small)
                    } header: {
                        Text("Suggested")
                    } footer: {
                        Text("Carried over from your last recording in this category, which had the same number of speakers — matched by position, not by voice. Check it before confirming.")
                    }
                }

                Section {
                    ForEach(speakers, id: \.self) { speaker in
                        TextField(
                            label(for: speaker),
                            text: Binding(
                                get: { names[speaker] ?? "" },
                                set: { names[speaker] = $0 }
                            ))
                            .focused($focused, equals: speaker)
                    }
                } footer: {
                    Text("Names apply to this recording only — the transcript can't recognize a voice across recordings.")
                }

                // Attendees of the linked meeting first — they're about this
                // recording — then the general name pool. Split into labelled
                // groups so an attendee the user has never typed isn't misfiled
                // under "Names you've used".
                chipSection(attendeeSuggestions, header: "Meeting attendees")
                chipSection(knownSuggestions, header: "Names you've used")
            }
            .navigationTitle("Name speakers")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.setSpeakerNames(recording, names: names)
                        // Only what the user actually saved feeds the directory —
                        // never an unconfirmed guess, or the pool would reinforce
                        // its own mistakes.
                        SpeakerDirectory.shared.record(names: names)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: seed)
        }
    }

    private func label(for speaker: String) -> String {
        Int(speaker) != nil ? "Speaker \(speaker)" : speaker
    }

    /// One tap-to-fill group of name chips, headed by `header`. Shared by the
    /// attendee group and the used-names group so they stay visually identical and
    /// carry the same "tap a field first" guidance — the only difference is which
    /// names they hold and what they're called.
    @ViewBuilder
    private func chipSection(_ chips: [String], header: LocalizedStringKey) -> some View {
        if !chips.isEmpty {
            Section {
                // Wraps rather than scrolls, so nothing is hidden off-edge at
                // large Dynamic Type.
                FlowRow(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Button(chip) {
                            guard let focused else { return }
                            names[focused] = chip
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(focused == nil)
                    }
                }
            } header: {
                Text(header)
            } footer: {
                Text(focused == nil
                    ? "Tap a speaker field above, then tap a name to fill it."
                    : "Filling \(label(for: focused!)).")
            }
        }
    }

    private func seed() {
        names = recording.speakerNames ?? [:]
        // Only ever offered for a recording with nothing named yet. Suggesting over
        // the user's own work would be presumptuous, and there's nothing to gain.
        guard names.isEmpty else { return }
        unconfirmed = model.suggestedSpeakerNames(for: recording) ?? [:]
    }
}

/// Floating transport controls. This is navigation-layer chrome over content,
/// which is exactly what glass is for.
///
/// Two states, because the transcript is the point of this screen and a full
/// transport permanently occupying its bottom third isn't. Collapsed shows the
/// waveform, play/pause, position and speed — enough to listen. Expanded adds
/// skips, a large play control and both timecodes.
///
/// One glass surface, everything inside it plain: a `.glassProminent` button on
/// a glass bar is glass on glass, which is exactly what the material is not for.
/// The play button gets its prominence from a filled tint circle instead.
private struct PlayerBar: View {

    let player: AudioPlayerModel
    /// Peak envelope; empty until `WaveformCache` has built one, in which case
    /// the waveform draws a flat baseline rather than jumping in later at a
    /// different height.
    let peaks: [UInt8]
    /// Highlight marks, in seconds.
    let highlights: [TimeInterval]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    /// Position under the finger while scrubbing. The ticker keeps writing
    /// `player.currentTime` at 10 Hz, so without this the playhead fights the
    /// drag and stutters backwards.
    @State private var scrubProgress: Double?

    @ScaledMetric private var waveformHeight: CGFloat = 30
    @ScaledMetric private var expandedWaveformHeight: CGFloat = 56
    @ScaledMetric private var compactPlaySize: CGFloat = 34
    @ScaledMetric private var largePlaySize: CGFloat = 52

    private var progress: Double { scrubProgress ?? player.progress }

    private var marks: [Double] {
        guard player.duration > 0 else { return [] }
        return highlights.map { $0 / player.duration }
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: isExpanded ? 14 : 10) {
                waveform

                if isExpanded {
                    timecodes
                    expandedTransport
                } else {
                    collapsedTransport
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .adaptiveGlass(in: .rect(cornerRadius: Metrics.playerBarRadius))
        }
        // Animating the bar's height animates the scroll view's bottom safe-area
        // inset, which re-lays out the transcript for the whole 0.28 s — hence
        // the `LazyVStack` in `TranscriptSection`, so that's only the visible
        // rows.
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: isExpanded)
        // The ±15 s controls only exist in the expanded state, so without these
        // a VoiceOver user has to find and toggle the chevron before they can
        // skip at all.
        .accessibilityAction(named: "Back \(Int(AudioPlayerModel.skipInterval)) seconds") {
            player.skip(by: -AudioPlayerModel.skipInterval)
        }
        .accessibilityAction(named: "Forward \(Int(AudioPlayerModel.skipInterval)) seconds") {
            player.skip(by: AudioPlayerModel.skipInterval)
        }
    }

    // MARK: Pieces

    private var waveform: some View {
        WaveformView(
            peaks: peaks,
            progress: progress,
            marks: marks,
            valueDescription: "\(AudioPlayerModel.timecode(player.currentTime)) of \(AudioPlayerModel.timecode(player.duration))",
            // One VoiceOver swipe is a 15-second skip, matching the buttons,
            // rather than a fixed 5% of however long the recording happens to be.
            accessibilityStep: player.duration > 0
                ? AudioPlayerModel.skipInterval / player.duration
                : 0.05,
            onScrub: { fraction in
                scrubProgress = fraction
                player.seek(toFraction: fraction)
            },
            onScrubEnded: { scrubProgress = nil }
        )
        .frame(height: isExpanded ? expandedWaveformHeight : waveformHeight)
    }

    private var timecodes: some View {
        HStack {
            Text(AudioPlayerModel.timecode(player.currentTime))
            Spacer()
            Text(AudioPlayerModel.timecode(player.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var collapsedTransport: some View {
        HStack(spacing: 12) {
            playPauseButton(size: compactPlaySize, glyph: .body)

            // At accessibility text sizes "1:32:14 / 2:05:00" no longer fits
            // beside the speed and expand controls, so drop the total rather
            // than truncate the position the user is actually reading.
            ViewThatFits(in: .horizontal) {
                positionText("\(AudioPlayerModel.timecode(player.currentTime)) / \(AudioPlayerModel.timecode(player.duration))")
                positionText(AudioPlayerModel.timecode(player.currentTime))
            }

            Spacer(minLength: 0)

            speedMenu
            expandButton
        }
    }

    private func positionText(_ value: String) -> some View {
        Text(value)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var expandedTransport: some View {
        HStack(spacing: 0) {
            speedMenu
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 22) {
                skipButton(by: -AudioPlayerModel.skipInterval, symbol: "gobackward.15")
                playPauseButton(size: largePlaySize, glyph: .title2)
                skipButton(by: AudioPlayerModel.skipInterval, symbol: "goforward.15")
            }
            .layoutPriority(1)

            expandButton
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func playPauseButton(size: CGFloat, glyph: Font) -> some View {
        Button {
            player.togglePlayback()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(glyph)
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(.tint, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    private func skipButton(by delta: TimeInterval, symbol: String) -> some View {
        Button {
            player.skip(by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.title3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0
            ? "Back \(Int(-delta)) seconds"
            : "Forward \(Int(delta)) seconds")
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(
                get: { player.rate },
                set: { player.setRate($0) }
            )) {
                ForEach(AudioPlayerModel.rates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
        } label: {
            Text("\(Self.rateLabel(player.rate))×")
                .font(.caption.weight(.medium).monospacedDigit())
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed")
        // Without a value, VoiceOver announces "Playback speed, button" and the
        // only way to learn the current speed is to open the menu.
        .accessibilityValue("\(Self.rateLabel(player.rate)) times")
    }

    private var expandButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: "chevron.up")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse player" : "Expand player")
    }

    /// "1", "1.5" — never "1.0", which reads as a precision the control doesn't
    /// have.
    ///
    /// `%g`, not `%.2g`: the precision in `%g` is **significant digits**, so
    /// `%.2g` rendered 1.25 as "1.2" and 1.75 as "1.8" — two of the six speeds
    /// mislabeled, and a user picking "1.8×" getting 1.75× playback.
    private static func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
    }
}
