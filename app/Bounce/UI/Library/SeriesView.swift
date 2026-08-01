import SwiftUI

/// The library indexed by meeting series — the fourth way into the same
/// recordings, alongside the list, the month grid and the map.
struct SeriesListView: View {

    @State private var store = MeetingSeriesStore.shared

    var body: some View {
        Group {
            if store.series.isEmpty { empty } else { list }
        }
    }

    private var list: some View {
        List {
            ForEach(store.series) { series in
                NavigationLink {
                    SeriesDetailView(seriesId: series.id)
                } label: {
                    SeriesRow(series: series)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        store.remove(id: series.id)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var empty: some View {
        EmptyHint(
            symbol: "repeat",
            title: "No meeting series",
            message: "A series groups the sessions of a recurring meeting so each one can be read against the ones before it. Recordings that match a repeating event in your calendar are grouped automatically — or open any recording and choose “Meeting series” from its Actions menu.")
    }
}

private struct SeriesRow: View {

    let series: MeetingSeries
    @State private var store = MeetingSeriesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(series.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                // Marks a series the calendar keeps in step, which is also the
                // explanation for why one appeared without the user making it.
                if series.calendarKey != nil {
                    Image(systemName: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("From your calendar")
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let count = store.sessionCount(in: series.id)
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        guard let last = store.recordings(in: series.id).first else { return sessions }
        return "\(sessions) · last \(last.createdAt.formatted(.dateTime.day().month(.abbreviated)))"
    }
}

/// One series: where it stands, and every session in it.
struct SeriesDetailView: View {

    let seriesId: String

    @Environment(\.dismiss) private var dismiss
    @State private var store = MeetingSeriesStore.shared
    /// Not `@State`: `SeriesContinuity` isn't `@Observable`, and only its
    /// availability is read here — which can't change while the screen is open.
    private var continuity: SeriesContinuity { .shared }
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var rebuild: RebuildState?
    @State private var rebuildTask: Task<Void, Never>?
    @Namespace private var zoom

    private var series: MeetingSeries? { store.series(id: seriesId) }
    private var sessions: [Recording] { store.recordings(in: seriesId) }

    /// Progress of a running rebuild. A struct rather than two `@State`s so the
    /// "is it running" and "how far" questions can't disagree.
    private struct RebuildState {
        var done: Int
        var total: Int
    }

    var body: some View {
        Group {
            if let series {
                content(series)
            } else {
                // Reachable: the series can be deleted from the list behind this
                // screen, or by a sweep. Better than an empty shell.
                EmptyHint(
                    symbol: "repeat",
                    title: "Series deleted",
                    message: "This meeting series no longer exists. Its recordings are untouched and still in your library.")
            }
        }
        .navigationTitle(series?.name ?? "Series")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("Rename series", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Save") { store.rename(id: seriesId, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear { rebuildTask?.cancel() }
    }

    private func content(_ series: MeetingSeries) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                digestCard(series)

                if sessions.isEmpty {
                    EmptyHint(
                        symbol: "waveform",
                        title: "No recordings yet",
                        message: "Recordings you add to this series appear here, newest first.")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sessions.count == 1 ? "1 session" : "\(sessions.count) sessions")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(sessions) { recording in
                            NavigationLink {
                                RecordingDetailView(
                                    recording: recording,
                                    zoomSource: ZoomTransitionSource(id: recording.id, namespace: zoom))
                            } label: {
                                RecordingRow(recording: recording)
                            }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: recording.id, in: zoom)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    /// "Where this stands" — the running carry-forward the next session is read
    /// against.
    ///
    /// Shown at the top and not hidden behind a disclosure: it is the answer to
    /// the question someone opens a recurring meeting's folder to ask.
    @ViewBuilder
    private func digestCard(_ series: MeetingSeries) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Where this stands", systemImage: "text.append")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let rebuild {
                    ProgressView(value: Double(rebuild.done), total: Double(max(1, rebuild.total)))
                    Text("Reading session \(rebuild.done) of \(rebuild.total)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let digest = series.digest, !digest.isEmpty {
                    Text(digest)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let updated = series.digestUpdatedAt {
                        Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(emptyDigestMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Three different reasons for an empty digest, and they need different
    /// answers — "nothing here yet" would read as broken in the first two cases.
    private var emptyDigestMessage: String {
        if !continuity.isAvailable {
            return "This needs Apple Intelligence, which isn't available on this iPhone. The sessions below are all still here to read."
        }
        if sessions.contains(where: { $0.isTranscribed }) {
            return "These sessions were transcribed before the series existed. Choose “Read all sessions” to build this up from them."
        }
        return "After the next session in this series is transcribed, a running summary of where things stand appears here."
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Rename", systemImage: "pencil") {
                    draftName = series?.name ?? ""
                    isRenaming = true
                }

                // Only offered when there is something to read and a model to
                // read it with. Rebuilding is N model calls, so it is never
                // automatic — see `SeriesContinuity.rebuild`.
                if continuity.isAvailable, sessions.contains(where: { $0.isTranscribed }) {
                    Button("Read all sessions", systemImage: "arrow.clockwise") {
                        startRebuild()
                    }
                    .disabled(rebuild != nil)
                }

                Divider()
                Button("Delete series", systemImage: "trash", role: .destructive) {
                    store.remove(id: seriesId)
                    dismiss()
                }
            } label: {
                Label("Actions", systemImage: "ellipsis")
            }
        }
    }

    private func startRebuild() {
        rebuildTask?.cancel()
        rebuild = RebuildState(done: 0, total: sessions.count)
        rebuildTask = Task {
            await continuity.rebuild(seriesId: seriesId) { done, total in
                rebuild = RebuildState(done: done, total: total)
            }
            rebuild = nil
        }
    }
}
