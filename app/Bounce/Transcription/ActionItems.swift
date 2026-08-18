import Foundation
import FoundationModels

/// Pulls action items out of a finished transcript using Apple Intelligence's
/// on-device model.
///
/// Same shape, same rules and the same silence as `AutoOrganizer`, which is what
/// calls it: one `LanguageModelSession` per run, the availability check is a
/// runtime property rather than an OS version, the transcript is capped to the
/// tail because the context window is ~4,096 tokens shared across instructions,
/// question and answer — and **every guard returns an empty array rather than
/// signalling failure**. An unavailable model, a refusal and a recording with
/// genuinely no tasks in it are indistinguishable to the caller by design:
/// `ActionItemMerge.merged` treats an empty extraction as "change nothing", so
/// all three collapse to the same correct behaviour and there is no error path
/// for the caller to get wrong.
@MainActor
final class ActionItemExtractor {

    static let shared = ActionItemExtractor()

    /// The same cap as `AutoOrganizer` and `TranscriptQA`, for the same reason.
    private static let maxTranscriptChars = 10_000
    /// Below this much transcript there is nothing to extract.
    private static let minTranscriptChars = 12
    /// A guard against a model that starts listing every sentence. Twenty tasks
    /// from one recording is already implausible; a hundred would make the Tasks
    /// tab useless and the merge slow.
    private static let maxItems = 20

    private let model = SystemLanguageModel.default

    private init() {}

    /// What the model returns — guided generation, so the shape is enforced by
    /// the framework rather than parsed out of prose. `AutoOrganizer.Classification`
    /// is `@Generable` for exactly this reason: reading a list of tasks out of
    /// free text was unreliable in a way that failed quietly.
    @Generable
    struct ExtractedActions {
        @Guide(description: "Every task, commitment or follow-up the transcript states. Empty when it states none.")
        let items: [ExtractedAction]
    }

    @Generable
    struct ExtractedAction {
        @Guide(description: "The task as one short imperative sentence, at most twelve words. For example: Send Ana the revised budget.")
        let text: String
        @Guide(description: "The name of the person who owes the task, exactly as it is spoken in the transcript. An empty string if the transcript does not say who.")
        let owner: String
        @Guide(description: "The deadline word-for-word as it is spoken, such as by Friday or end of the month. An empty string if none is spoken. Never invent one.")
        let due: String
        @Guide(description: "The same deadline as a calendar date in the format given in the instructions, worked out from the date the conversation took place. An empty string if no deadline is spoken.")
        let dueDate: String
    }

    // MARK: - Extraction

    /// The action items stated in `transcript`.
    ///
    /// Empty when the model is unavailable, the transcript is too short to hold a
    /// task, or generation failed — see the type comment for why those aren't
    /// distinguished. Never throws.
    ///
    /// Takes the whole `Transcript` rather than its text because the segments are
    /// what `sourceOffset` is recovered from.
    /// - Parameter recordedAt: when the recording was made. **Not** the
    ///   transcript's `createdAt`, which is when transcription ran and can be days
    ///   later. This is the anchor every relative deadline is resolved against, so
    ///   passing the wrong one shifts every date by that gap.
    func extract(from transcript: Transcript, recordedAt: Date) async -> [ActionItem] {
        guard case .available = model.availability else { return [] }
        let text = transcript.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minTranscriptChars else { return [] }

        let session = LanguageModelSession(
            instructions: Self.instructions(for: text, recordedAt: recordedAt))
        do {
            let response = try await session.respond(
                to: Self.request(),
                generating: ExtractedActions.self)
            let items = Self.convert(
                response.content.items,
                segments: transcript.segments,
                recordedAt: recordedAt)
            TranscribeLog.log("action items: extracted \(items.count)")
            return items
        } catch {
            TranscribeLog.log("action items: extraction failed: "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            return []
        }
    }

    /// The grounding prompt.
    ///
    /// Two things it works hard to prevent, both of which produce a task list the
    /// user has to clean up by hand and therefore stops trusting: inventing tasks
    /// out of discussion that committed to nothing, and inventing an owner for a
    /// task nobody claimed.
    /// The grounding prompt, with the user's edits applied if they've made any.
    ///
    /// Routed through `PromptStore` rather than being a literal, so Settings › AI ›
    /// Prompts can edit it. The default lives in `PromptDefaults.actionsExtract`;
    /// what follows is only the fallback for the impossible case of the catalogue
    /// having lost this id, kept so a missing prompt degrades to shipped behaviour
    /// rather than to an empty instruction.
    private static func instructions(for transcript: String, recordedAt: Date) -> String {
        let deadlineRules = deadlineRules(recordedAt: recordedAt)
        let values = [
            "transcript": cap(transcript),
            "deadline_rules": deadlineRules,
        ]
        let edited = PromptStore.shared.filled(PromptID.actionsExtract, with: values)
        if !edited.isEmpty { return edited }

        return fallbackInstructions(for: transcript, deadlineRules: deadlineRules)
    }

    /// The one-line user turn, with the user's edit applied if they've made one.
    ///
    /// Routed through `PromptStore` so Settings › AI › Prompts can edit it; the
    /// shipped default is the fallback for the impossible case of the catalogue
    /// having lost this id. `actionsRequest` has no placeholders, so this is a bare
    /// `text(for:)` rather than a `filled(_:with:)`.
    private static func request() -> String {
        let edited = PromptStore.shared.text(for: PromptID.actionsRequest)
        return edited.isEmpty ? PromptDefaults.actionsRequest : edited
    }

    /// The `{deadline_rules}` fragment spliced into the extraction prompt, with the
    /// user's edit applied if they've made one.
    ///
    /// `DueDateResolver` stays pure Foundation and never touches `PromptStore`, so
    /// its caller owns the routing: the editable `dueDateRules` template is filled
    /// with the date anchors the resolver computes, and the resolver's own literal
    /// is the fallback for the catalogue-lost-the-id case.
    private static func deadlineRules(recordedAt: Date) -> String {
        let values = DueDateResolver.ruleValues(recordedAt: recordedAt, calendar: .current)
        let edited = PromptStore.shared.filled(PromptID.dueDateRules, with: values)
        if !edited.isEmpty { return edited }

        return DueDateResolver.instructions(recordedAt: recordedAt, calendar: .current)
    }

    private static func fallbackInstructions(
        for transcript: String, deadlineRules: String
    ) -> String {
        """
        You read the transcript of one of the user's voice recordings and pull out \
        the action items: things somebody committed to doing, was asked to do, or \
        needs to follow up on.

        The recording may be a meeting, or it may be the user talking to \
        themselves. Both kinds contain action items.

        Rules:
        - A note the user records for themselves IS an action item. "Remember to \
        take out the trash", "don't forget to call the dentist", "I need to book \
        the flights" are all action items with no owner. A recording that is \
        nothing but one such sentence yields exactly one action item.
        - Only include something the transcript actually commits to. Ideas that \
        were discussed and dropped, opinions, and background are not action items.
        - Write each item as a short instruction starting with a verb.
        - Give an owner only when the transcript names the person responsible. A \
        note the user made for themselves has no owner — leave it empty rather \
        than writing "me" or "the user". Never guess.
        - Give a deadline only when one is spoken, and copy the wording used.
        - Do not repeat the same task twice in different words.
        - If the transcript contains no action items, return an empty list. An \
        empty list is a correct answer.

        DEADLINES:
        \(deadlineRules)

        TRANSCRIPT:
        \(cap(transcript))
        """
    }

    /// Model output → stored items: trimmed, blank-dropped, capped, and located
    /// in the audio.
    ///
    /// `owner` and `due` come back as **empty strings rather than nil** because
    /// that is the one shape guided generation can't fail to produce — an
    /// optional field invites the model to omit the key, and a required one
    /// invites it to fill the gap with "unknown" or "N/A". So the prompt asks for
    /// an empty string and the emptiness is turned into nil here, along with the
    /// literal placeholders a model reaches for anyway.
    private static func convert(
        _ extracted: [ExtractedAction],
        segments: [TranscriptSegment],
        recordedAt: Date
    ) -> [ActionItem] {
        let now = Date()
        let calendar = Calendar.current
        return extracted.prefix(maxItems).compactMap { action -> ActionItem? in
            let text = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ActionItemMerge.normalisedKey(text).isEmpty else { return nil }
            return ActionItem(
                text: text,
                owner: value(action.owner),
                dueText: value(action.due),
                createdAt: now,
                sourceOffset: ActionItemMerge.offset(matching: text, in: segments),
                // Validated hard, and nil on anything doubtful — a wrong date in
                // someone's Reminders is worse than no date. The spoken phrase in
                // `dueText` survives either way, so a rejected resolution costs
                // the reminder its alarm, not its meaning.
                dueDate: DueDateResolver.resolve(
                    action.dueDate, recordedAt: recordedAt, calendar: calendar))
        }
    }

    /// A model-supplied field, or nil when it's empty or one of the stock
    /// placeholders that mean empty.
    private static func value(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let placeholders: Set<String> = [
            "n/a", "na", "none", "unknown", "unspecified", "not specified",
            "no owner", "nobody", "no deadline", "no due date", "-", "—",
        ]
        return placeholders.contains(trimmed.lowercased()) ? nil : trimmed
    }

    private static func cap(_ transcript: String) -> String {
        guard transcript.count > maxTranscriptChars else { return transcript }
        // Halves of the budget, derived rather than written as literals: with a
        // hardcoded 4,500/4,500 against a `maxTranscriptChars` anyone is free to
        // lower, a budget under 9,000 makes the two slices overlap — duplicating
        // text and rendering a negative count as "[… -2000 characters omitted …]".
        let half = maxTranscriptChars / 2
        let head = transcript.prefix(half)
        let tail = transcript.suffix(half)
        let omitted = transcript.count - 2 * half
        return "\(head)\n\n[… \(omitted) characters omitted …]\n\n\(tail)"
    }
}
