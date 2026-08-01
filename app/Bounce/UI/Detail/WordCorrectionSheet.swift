import SwiftUI

/// Correct a misheard word across a whole transcript, and optionally teach the
/// correction to Soniox so future recordings get it right.
///
/// The live occurrence count is the point of this screen. Find-and-replace over a
/// transcript you can't fully see is a leap of faith otherwise — a name that
/// appears 40 times and one that appears once want different amounts of
/// confidence before you tap Replace.
struct WordCorrectionSheet: View {

    let recording: Recording

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Prefilled by the caller when the user had a word selected.
    @State private var needle: String
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var addToVocabulary: Bool
    @FocusState private var focus: Field?

    private enum Field { case needle, replacement }

    init(recording: Recording, initialWord: String = "") {
        self.recording = recording
        _needle = State(initialValue: initialWord)
        // Default on when it can actually do something — the whole reason this is
        // worth more than a one-off edit is that it stops the mistake recurring.
        _addToVocabulary = State(
            initialValue: DeliverySettings.shared.effectiveTranscriptionEngine == .soniox)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Misheard word", text: $needle)
                        .focused($focus, equals: .needle)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.next)
                        .onSubmit { focus = .replacement }
                    TextField("Correct spelling", text: $replacement)
                        .focused($focus, equals: .replacement)
                        .autocorrectionDisabled()
                } header: {
                    Text("Replace")
                } footer: {
                    Text(matchFooter)
                }

                Section {
                    Toggle("Match capitalisation exactly", isOn: $caseSensitive)
                } footer: {
                    Text(caseSensitive
                        ? "Only occurrences with this exact capitalisation change."
                        : "Any capitalisation matches. A capitalised occurrence stays capitalised, so a word at the start of a sentence isn't lowercased.")
                }

                if isSonioxSelected {
                    Section {
                        Toggle("Teach this to Soniox", isOn: $addToVocabulary)
                    } footer: {
                        Text("Adds the correct spelling to your custom vocabulary, so future recordings transcribe it correctly. You can see and edit the list in Settings › Transcription.")
                    }
                }

                if hasSummaries {
                    Section {
                        Label(
                            "Summaries aren't changed. They were written from the old text — rerun them from the Summary tab if the word mattered.",
                            systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Correct a word")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Replace") { apply() }
                        .disabled(!canApply)
                }
            }
            .task {
                // Straight into the field the user is most likely to fill. When a
                // word was preselected, that's the replacement.
                focus = needle.isEmpty ? .needle : .replacement
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Derived

    private var trimmedNeedle: String {
        needle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplacement: String {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Counted through the same code that performs the replacement, so the number
    /// shown is the number that will change — not an approximation from a
    /// substring search that would over-count "AI" inside "said".
    private var matchCount: Int {
        guard !trimmedNeedle.isEmpty, let transcript = recording.transcript else { return 0 }
        return TranscriptEdit.occurrences(
            of: trimmedNeedle, in: transcript, caseSensitive: caseSensitive)
    }

    private var matchFooter: String {
        guard !trimmedNeedle.isEmpty else {
            return "Type a word as it was transcribed, and what it should say."
        }
        switch matchCount {
        case 0:
            // The cross-phrase limit is named only here, on the zero-match path,
            // because that's the one time it explains something confusing: a phrase
            // the user can plainly see on screen reporting no matches. Stating it
            // up front would be noise for the single-word case that is 95% of use.
            return trimmedNeedle.contains(" ")
                ? "No matches for “\(trimmedNeedle)”. Matching is by whole word, and a phrase split across two spoken paragraphs isn't found — try just the wrong word on its own."
                : "No whole-word matches for “\(trimmedNeedle)”. Matching is by whole word, so “AI” won't match inside “said”."
        case 1:
            return "Will change 1 occurrence."
        case let count:
            return "Will change \(count) occurrences."
        }
    }

    private var isSonioxSelected: Bool {
        DeliverySettings.shared.effectiveTranscriptionEngine == .soniox
    }

    private var hasSummaries: Bool {
        !(recording.summaries ?? []).isEmpty
    }

    private var canApply: Bool {
        !trimmedNeedle.isEmpty
            && !trimmedReplacement.isEmpty
            && trimmedNeedle != trimmedReplacement
            && matchCount > 0
    }

    // MARK: - Actions

    private func apply() {
        let changed = model.correctWord(
            in: recording,
            from: trimmedNeedle,
            to: trimmedReplacement,
            caseSensitive: caseSensitive,
            addToVocabulary: addToVocabulary && isSonioxSelected)

        // Reported through the app's one alert surface rather than inline, since
        // this screen is dismissing. Silence after a destructive-feeling bulk edit
        // leaves the user scrolling to check it worked.
        var message = changed == 1
            ? "Changed 1 occurrence of “\(trimmedNeedle)” to “\(trimmedReplacement)”."
            : "Changed \(changed) occurrences of “\(trimmedNeedle)” to “\(trimmedReplacement)”."
        if addToVocabulary && isSonioxSelected {
            message += " “\(trimmedReplacement)” was added to your Soniox vocabulary."
        }
        model.alert = .init(title: "Transcript corrected", message: message)
        dismiss()
    }
}
