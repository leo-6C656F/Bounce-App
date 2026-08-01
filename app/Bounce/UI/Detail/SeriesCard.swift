import SwiftUI

/// A recording's place in its meeting series, and what changed since the last
/// session.
///
/// Renders nothing when the recording is in no series — which is most of them.
/// Joining one is offered from the detail view's Actions menu rather than by an
/// empty card on every screen, the same call `PlaceCard` makes.
struct SeriesCard: View {

    let recording: Recording

    @State private var store = MeetingSeriesStore.shared
    @State private var isRecapExpanded = true

    private var series: MeetingSeries? { store.series(id: recording.seriesId) }

    var body: some View {
        if let series {
            ContentCard {
                VStack(alignment: .leading, spacing: 10) {
                    NavigationLink {
                        SeriesDetailView(seriesId: series.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "repeat")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(series.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(sessionLine)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    if let recap = recording.seriesRecap, !recap.isEmpty {
                        Divider()
                        DisclosureGroup(isExpanded: $isRecapExpanded) {
                            Text(recap)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                                // Selectable for the same reason the summaries
                                // are: this is the paragraph someone pastes into
                                // a status update.
                                .textSelection(.enabled)
                        } label: {
                            Label("Since last time", systemImage: "arrow.turn.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// "Session 4 of 7", or just the count for a session whose position can't be
    /// resolved. Both halves are useful: which one this is, and how long the
    /// series has been running.
    private var sessionLine: String {
        let total = store.sessionCount(in: recording.seriesId ?? "")
        guard let number = store.sessionNumber(of: recording) else {
            return total == 1 ? "1 session" : "\(total) sessions"
        }
        return "Session \(number) of \(total)"
    }
}

/// Put a recording into a series, move it, or take it out.
///
/// Deliberately allows creating a series from here rather than only from a
/// settings screen: the moment someone realises two recordings belong together
/// is while looking at one of them.
struct SeriesPicker: View {

    let recording: Recording

    @Environment(\.dismiss) private var dismiss
    @State private var store = MeetingSeriesStore.shared
    @State private var newName = ""
    @FocusState private var isNaming: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("New series name", text: $newName)
                            .focused($isNaming)
                            .submitLabel(.done)
                            .onSubmit { create() }
                        Button("Add", action: create)
                            .disabled(trimmedName.isEmpty)
                    }
                } footer: {
                    Text("A series groups recurring sessions of the same meeting so each one can be read against the ones before it. Recordings that match a repeating calendar event are grouped for you.")
                }

                if !store.series.isEmpty {
                    Section("Series") {
                        ForEach(store.series) { series in
                            Button {
                                store.assign(recording, to: series.id)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(series.name)
                                        Text(countLine(for: series))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if recording.seriesId == series.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if recording.seriesId != nil {
                    Section {
                        Button("Remove from series", systemImage: "minus.circle", role: .destructive) {
                            store.assign(recording, to: nil)
                            dismiss()
                        }
                    } footer: {
                        // Said plainly, because it is the one destructive part of
                        // an otherwise reversible screen.
                        Text("The recording and its transcript are kept. Only its place in the series and the “since last time” recap are cleared — that recap describes this series' history and would be wrong anywhere else.")
                    }
                }
            }
            .navigationTitle("Meeting series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func countLine(for series: MeetingSeries) -> String {
        let count = store.sessionCount(in: series.id)
        return count == 1 ? "1 recording" : "\(count) recordings"
    }

    private func create() {
        guard let series = store.add(name: trimmedName) else { return }
        store.assign(recording, to: series.id)
        newName = ""
        dismiss()
    }
}
