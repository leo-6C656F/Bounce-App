import SwiftUI

/// Ask Apple Intelligence questions about a transcript, answered on device.
///
/// Grounds a `TranscriptQA` session on the given transcript text and streams the
/// answer as it generates. Shown only where a transcript exists; when the model
/// isn't available it explains why rather than vanishing, so the feature is
/// discoverable. Reused for both a finished recording and the live transcript.
struct TranscriptQAView: View {

    /// Plain transcript text to answer against. Re-grounds when it changes, so a
    /// growing live transcript stays current.
    let transcript: String

    @State private var qa = TranscriptQA()
    @State private var question = ""
    @State private var answer = ""
    @State private var answerTask: Task<Void, Never>?
    @State private var copiedAnswer = false
    @FocusState private var isInputFocused: Bool

    private struct SuggestedPrompt: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let queryText: String
    }

    private let suggestions: [SuggestedPrompt] = [
        SuggestedPrompt(icon: "checkmark.circle.fill", label: "Action items", queryText: "What are the action items and follow-ups?"),
        SuggestedPrompt(icon: "lightbulb.fill", label: "Key decisions", queryText: "What were the key decisions made?"),
        SuggestedPrompt(icon: "doc.text.fill", label: "Summary", queryText: "Give me a concise 3-bullet summary"),
        SuggestedPrompt(icon: "questionmark.circle.fill", label: "Open questions", queryText: "What questions were asked or left unresolved?")
    ]

    var body: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Ask about this recording", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(.tint)
                    Spacer()
                }

                switch qa.readiness {
                case .ready:
                    ready
                case .unavailable(let reason):
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                isInputFocused = false
            }
        }
        // Ground once on appear to prewarm; ask() re-grounds with the latest text,
        // which is a no-op unless it changed — so a growing live transcript stays
        // current without rebuilding the session on every keystroke of speech.
        .task { qa.ground(on: transcript) }
        .onDisappear { answerTask?.cancel() }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            promptChips

            HStack(spacing: 8) {
                TextField("What was decided? Who owns follow-ups?", text: $question)
                    .focused($isInputFocused)
                    .padding(10)
                    .background(.background.secondary, in: .rect(corners: .concentric))
                    .onSubmit(ask)

                Button(action: ask) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(question.trimmingCharacters(in: .whitespaces).isEmpty || qa.isAnswering ? Color.secondary.opacity(0.4) : Color.accentColor)
                }
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || qa.isAnswering)
            }

            if qa.isAnswering && answer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking with Apple Intelligence…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !answer.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Answer")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = answer
                            copiedAnswer = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copiedAnswer = false
                            }
                        } label: {
                            Label(copiedAnswer ? "Copied" : "Copy", systemImage: copiedAnswer ? "checkmark" : "doc.on.doc")
                                .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                    }

                    Text(answer)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(.background.secondary.opacity(0.6), in: .rect(cornerRadius: 12))
            }

            Text("Answered on device by Apple Intelligence. Nothing is uploaded.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var promptChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { prompt in
                    Button {
                        question = prompt.queryText
                        ask()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: prompt.icon)
                                .font(.caption2)
                                .foregroundStyle(.tint)
                            Text(prompt.label)
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.background.secondary, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func ask() {
        isInputFocused = false
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !qa.isAnswering else { return }
        qa.ground(on: transcript)
        answerTask?.cancel()
        answer = ""
        answerTask = Task {
            // No animation: cumulative snapshots would cross-fade the whole
            // paragraph on every update, which reads as flicker on a long answer.
            for await partial in qa.answer(to: q) {
                answer = partial
            }
        }
    }
}
