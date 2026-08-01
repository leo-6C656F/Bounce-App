import SwiftUI

/// Ask questions across **all** transcribed recordings, answered on device by
/// Apple Intelligence, as a conversation.
///
/// The library-wide counterpart to the per-recording "Ask about this" sheet —
/// same on-device engine (`TranscriptQA`), wider scope. A question first
/// keyword-filters to the recordings it likely concerns, then grounds the model
/// on those transcripts and streams an answer.
///
/// **It keeps the thread now.** The previous version held exactly one answer and
/// replaced it on the next question, so the screen spent most of its life as a
/// hero card and a row of chips over ~300pt of nothing, and asking a follow-up
/// destroyed the answer that prompted it. Turns accumulate here instead, each
/// carrying the sources it was grounded on.
///
/// The on-device model's ~4,096-token window means the whole library can't be
/// fed at once, so grounding is limited to the matched (or most recent)
/// recordings, capped by `TranscriptQA`. That limit is stated in the UI rather
/// than hidden.
///
/// **Each turn is grounded independently.** `TranscriptQA.ground` replaces the
/// session's corpus, so this is not a chat with memory — a follow-up that says
/// "and what about the other one" has no antecedent. The placeholder says "Ask
/// another question" rather than "Ask a follow-up" for that reason.
struct AskView: View {

    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var turns: [Turn] = []
    @State private var qa = TranscriptQA()
    @State private var answerTask: Task<Void, Never>?
    /// Ask's own zoom namespace — one per navigation context, see `HomeView`.
    @Namespace private var zoom
    @FocusState private var isInputFocused: Bool
    @State private var copiedTurnId: UUID?

    /// One question and the answer it got.
    private struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String = ""
        var sources: [Recording] = []
        var isAnswering = true
    }

    private var transcribed: [Recording] {
        model.recordings.filter(\.isTranscribed)
    }

    private struct SuggestedPrompt: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let queryText: String
    }

    private let suggestions: [SuggestedPrompt] = [
        SuggestedPrompt(icon: "checkmark.circle.fill", label: "Action items", queryText: "What action items were assigned?"),
        SuggestedPrompt(icon: "lightbulb.fill", label: "Key decisions", queryText: "What were the key decisions made?"),
        SuggestedPrompt(icon: "doc.text.fill", label: "Meeting summary", queryText: "Summarize recent discussions"),
        SuggestedPrompt(icon: "calendar.badge.clock", label: "Deadlines & dates", queryText: "Were any deadlines or dates mentioned?")
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch qa.readiness {
                case .ready:
                    content
                case .unavailable(let reason):
                    ContentUnavailableView {
                        Label("Ask isn't available", systemImage: "sparkles")
                    } description: {
                        Text(reason)
                    }
                }
            }
            .navigationTitle("Ask")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if !turns.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") {
                            answerTask?.cancel()
                            turns.removeAll()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if transcribed.isEmpty {
            ContentUnavailableView {
                Label("Nothing to ask about yet", systemImage: "text.magnifyingglass")
            } description: {
                Text("Transcribe some recordings and you can ask questions across all of them here.")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if turns.isEmpty {
                            opening
                        }
                        ForEach(turns) { turn in
                            turnView(turn).id(turn.id)
                        }
                        if !turns.isEmpty {
                            footnote
                        }
                    }
                    .padding(20)
                }
                // `scrollDismissesKeyboard` alone — an `onTapGesture` on the
                // scroll view competes with the suggestion chips and source
                // links inside it for the same tap, and it buys nothing this
                // doesn't already do.
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: turns.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .safeAreaBar(edge: .bottom) {
                askField
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Opening

    /// What the screen says before anything has been asked. Deliberately short:
    /// the field is the feature, and a paragraph explaining that you can type in
    /// it is furniture.
    private var opening: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.tint.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask across \(transcribed.count) recording\(transcribed.count == 1 ? "" : "s")")
                        .font(.headline)
                    Text("On device · nothing is uploaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Try asking")
                ForEach(suggestions) { prompt in
                    Button {
                        query = prompt.queryText
                        ask()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: prompt.icon)
                                .font(.footnote)
                                .foregroundStyle(.tint)
                                .frame(width: 20)
                            Text(prompt.queryText)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(.background.secondary, in: .rect(cornerRadius: Metrics.fieldRadius))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Turns

    private func turnView(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The question, as the user asked it.
            Text(turn.question)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.tint, in: .rect(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SectionLabel("Answer", tint: .accentColor)
                    if turn.isAnswering, turn.answer.isEmpty {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                    if !turn.answer.isEmpty {
                        Button {
                            UIPasteboard.general.string = turn.answer
                            copiedTurnId = turn.id
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                if copiedTurnId == turn.id { copiedTurnId = nil }
                            }
                        } label: {
                            Image(systemName: copiedTurnId == turn.id ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Copy answer")
                    }
                }

                if turn.answer.isEmpty, turn.isAnswering {
                    Text("Thinking with Apple Intelligence…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(turn.answer)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !turn.isAnswering { sources(for: turn) }
            }
        }
    }

    /// Where the answer came from, as chips that open the recording.
    ///
    /// One source list per turn, and none anywhere else on the screen: two
    /// source lists read as two different sets of sources.
    @ViewBuilder
    private func sources(for turn: Turn) -> some View {
        if turn.sources.isEmpty {
            Text("No recordings matched that. Try different words.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("From")
                FlowRow(spacing: 8) {
                    ForEach(turn.sources) { recording in
                        NavigationLink {
                            RecordingDetailView(
                                recording: recording,
                                zoomSource: ZoomTransitionSource(id: recording.id, namespace: zoom))
                        } label: {
                            SourceChip(
                                title: recording.displayTitle,
                                categoryName: recording.categoryName)
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: recording.id, in: zoom)
                    }
                }
            }
        }
    }

    private var footnote: some View {
        Text("Answered on device by Apple Intelligence, from your recordings' transcripts. Long libraries are answered from the closest matches, not all of them.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Field

    private var askField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.body)
                .foregroundStyle(.tint)

            TextField(turns.isEmpty ? "Ask across your recordings…" : "Ask another question…", text: $query)
                .focused($isInputFocused)
                .onSubmit(ask)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear question")
            }

            Button(action: ask) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canAsk ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .disabled(!canAsk)
            .accessibilityLabel("Ask")
        }
        .padding(12)
        .background(.background.secondary, in: .rect(corners: .concentric))
    }

    private var canAsk: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty && !qa.isAnswering
    }

    // MARK: - Asking

    private func ask() {
        isInputFocused = false
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !qa.isAnswering else { return }

        // Which recordings the question is about, and the text to ground on.
        // Shared with the desktop view via `AskCorpus` so both ask the same
        // question of the same corpus.
        let grounding = AskCorpus.grounding(for: question, in: model.recordings)
        var turn = Turn(question: question)
        turn.sources = grounding.sources
        turns.append(turn)
        let id = turn.id
        query = ""

        qa.ground(on: grounding.corpus)
        answerTask?.cancel()
        answerTask = Task {
            // No animation: the snapshots are cumulative, so animating each one
            // cross-fades the whole paragraph ~20x/second on a long answer,
            // which reads as flicker rather than a smooth stream.
            for await partial in qa.answer(to: question) {
                update(id) { $0.answer = partial }
            }
            update(id) { $0.isAnswering = false }
        }
    }

    /// Mutate a turn in place. By id rather than by index: `Clear` can empty the
    /// array while a stream is still arriving, and an index captured before that
    /// would either crash or write into a different turn.
    private func update(_ id: UUID, _ mutate: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        mutate(&turns[index])
    }
}
