import SwiftUI

/// Agenda checklist for one recording: topics the user typed, ticked off
/// automatically as they turn up in the transcript.
///
/// The model lives in `Device/Models/MeetingAgenda.swift` and is persisted on
/// `Recording` — this view owns none of it. An earlier version held the agenda in
/// `@State` seeded with two placeholder topics, which put a fake agenda on every
/// recording in the library and threw away every edit on navigation.
///
/// Renders nothing until there is something to show, so a voice memo doesn't
/// carry a meeting UI.
struct MeetingAgendaView: View {

    let recording: Recording
    let transcriptText: String?

    @State private var newItemText = ""
    @FocusState private var isAdding: Bool

    private var agenda: MeetingAgenda { recording.agenda ?? MeetingAgenda() }

    var body: some View {
        if !agenda.isEmpty || isAdding {
            card
        } else {
            addButton
        }
    }

    private var card: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                header

                if !agenda.isEmpty {
                    ProgressView(value: agenda.progress)
                        .tint(.accentColor)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(agenda.items) { item in
                            row(item)
                        }
                    }
                }

                addField
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { evaluate() }
        .onChange(of: transcriptText) { _, _ in evaluate() }
    }

    private var header: some View {
        HStack {
            Label("Agenda", systemImage: "list.bullet.rectangle.portrait.fill")
                .font(.headline)
                .foregroundStyle(.tint)
            Spacer()
            if !agenda.isEmpty {
                Text("\(agenda.discussedCount)/\(agenda.items.count) covered")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ item: AgendaItem) -> some View {
        HStack(spacing: 10) {
            Button {
                // Both flags: ticking by hand is what makes the row the user's,
                // so `evaluate` stops overriding it.
                update { agenda in
                    guard let index = agenda.items.firstIndex(where: { $0.id == item.id }) else { return }
                    agenda.items[index].isDiscussed.toggle()
                    agenda.items[index].isPinnedByUser = true
                }
            } label: {
                Image(systemName: item.isDiscussed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDiscussed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.text)
            .accessibilityValue(item.isDiscussed ? "Covered" : "Not covered")

            Text(item.text)
                .font(.subheadline)
                .strikethrough(item.isDiscussed)
                .foregroundStyle(item.isDiscussed ? .secondary : .primary)

            Spacer()

            Button(role: .destructive) {
                update { $0.items.removeAll { $0.id == item.id } }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.text)")
        }
    }

    private var addField: some View {
        HStack(spacing: 8) {
            // Not `.roundedBorder` — that's a macOS-flavoured style that renders
            // as a thin box matching nothing else in the app. Same reasoning as
            // `TranscriptQAView`'s compose field.
            TextField("Add a topic", text: $newItemText)
                .focused($isAdding)
                .textFieldStyle(.plain)
                .onSubmit(add)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.background.secondary, in: .rect(cornerRadius: Metrics.fieldRadius))

            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(trimmedNewItem.isEmpty)
            .accessibilityLabel("Add topic")
        }
        .padding(.top, 4)
    }

    private var addButton: some View {
        Button {
            isAdding = true
        } label: {
            Label("Add an agenda", systemImage: "list.bullet.rectangle.portrait")
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.glass)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trimmedNewItem: String {
        newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let text = trimmedNewItem
        guard !text.isEmpty else { return }
        update { $0.items.append(AgendaItem(text: text)) }
        newItemText = ""
        evaluate()
    }

    private func evaluate() {
        guard let transcriptText, !agenda.isEmpty else { return }
        update { $0.evaluate(transcript: transcriptText) }
    }

    /// Read-modify-write through the store, which is the only owner of the
    /// library. Writes nothing when the mutation was a no-op — `evaluate` runs on
    /// every appearance and would otherwise rewrite `library.json` each time.
    private func update(_ mutate: (inout MeetingAgenda) -> Void) {
        var updated = agenda
        mutate(&updated)
        guard updated != agenda else { return }
        RecordingStore.shared.update(id: recording.id) { stored in
            stored.agenda = updated.isEmpty ? nil : updated
        }
        SyncManager.shared.refreshLibrary()
    }
}
