import SwiftUI

/// Pick the recordings that were really one session, and join them.
///
/// Presented from a recording's context menu, which is why it opens with that
/// recording already selected: the user has pointed at one half of the thing and
/// is here to say what the other half is.
///
/// The order is not editable and the sheet says so — `RecordingMerge` always
/// joins oldest first, because a merge asserts these are one recording and a
/// recording happens in time. Everything else here is a decision the user has to
/// make: which parts, what to call it, and whether the originals stay.
struct MergeRecordingsSheet: View {

    let anchor: Recording

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<String> = []
    @State private var title = ""
    /// Off by default. Merging copies audio rather than moving it, so the parts
    /// are still perfectly good recordings — throwing them away should be the
    /// user's word, not ours. The continuation path sets it, because there the
    /// user already said the two are one recording.
    @State private var deleteSources = false
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                partsSection
                if !isWorking { detailsSection }
            }
            .navigationTitle("Join recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") { join() }
                        .disabled(selection.count < 2 || isWorking)
                }
            }
            .alert(
                "Couldn't join these",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
            .onAppear {
                if selection.isEmpty { selection = [anchor.id] }
            }
        }
    }

    // MARK: - Sections

    private var partsSection: some View {
        Section {
            ForEach(candidates) { recording in
                Button {
                    toggle(recording)
                } label: {
                    row(for: recording)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            }
        } header: {
            Text("Parts")
        } footer: {
            // The running total is the answer to "is this the session I think it
            // is" — a half-hour of dictation reads very differently from four
            // minutes, and it's the cheapest way to catch a mis-tap before
            // committing.
            Text(partsFooter)
        }
    }

    private var partsFooter: String {
        guard selection.count >= 2 else {
            return "Pick at least two. They're joined oldest first, into one recording "
                + "with one transcript."
        }
        return "\(selection.count) recordings · \(totalDuration.timecodeText) total, "
            + "joined oldest first."
    }

    @ViewBuilder
    private var detailsSection: some View {
        Section("Title") {
            TextField(RecordingMergePlan.defaultTitle(for: selectedRecordings), text: $title)
                .textInputAutocapitalization(.sentences)
        }

        Section {
            Toggle("Delete the originals", isOn: $deleteSources)
        } footer: {
            Text(deleteFooter)
        }

        if !stitchesCleanly {
            Section {
                Label(retranscribeNotice, systemImage: "text.badge.plus")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var deleteFooter: String {
        deleteSources
            ? "The parts are removed once the joined recording is safely saved. Their "
                + "audio is copied into it first."
            : "The parts stay in your library. The joined recording is a new copy — "
                + "deleting either one later won't affect the other."
    }

    private var retranscribeNotice: String {
        "Some of these haven't been transcribed yet. The joined recording will be "
            + "transcribed from scratch once it's saved."
    }

    private func row(for recording: Recording) -> some View {
        let isSelected = selection.contains(recording.id)
        return HStack(spacing: 12) {
            // The join position, not a tick: the whole question this sheet
            // answers is what order the session ran in, and a checkmark can't
            // say "this one is second".
            ZStack {
                Circle()
                    .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary))
                    .frame(width: 26, height: 26)
                if let position = position(of: recording) {
                    Text("\(position)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text("\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · "
                    + recording.durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if !recording.isTranscribed {
                Image(systemName: "text.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Not transcribed")
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Data

    /// Everything joinable, oldest first — the order they'd be written in, so the
    /// list reads the same way the result will.
    ///
    /// Unsynced recordings are absent rather than disabled: there is no audio on
    /// the phone to join, and a row that can never be tapped is noise.
    private var candidates: [Recording] {
        model.recordings
            .filter { RecordingMerge.canMerge($0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var selectedRecordings: [Recording] {
        candidates.filter { selection.contains($0.id) }
    }

    private var totalDuration: TimeInterval {
        selectedRecordings.reduce(0) { $0 + $1.duration }
    }

    /// Whether every part brings a finished transcript, so the joined transcript
    /// is complete the moment it's written.
    private var stitchesCleanly: Bool {
        selectedRecordings.allSatisfy {
            $0.isTranscribed && $0.transcript?.isLivePreview != true
        }
    }

    private func position(of recording: Recording) -> Int? {
        selectedRecordings.firstIndex(where: { $0.id == recording.id }).map { $0 + 1 }
    }

    private func toggle(_ recording: Recording) {
        if selection.contains(recording.id) {
            selection.remove(recording.id)
        } else {
            selection.insert(recording.id)
        }
    }

    // MARK: - Action

    private func join() {
        let parts = selectedRecordings
        guard parts.count >= 2 else { return }
        isWorking = true
        Task {
            do {
                _ = try await RecordingMerge.merge(
                    parts,
                    title: title,
                    deletingSources: deleteSources)
                isWorking = false
                dismiss()
            } catch {
                isWorking = false
                failure = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
