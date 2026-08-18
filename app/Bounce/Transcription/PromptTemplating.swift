import Foundation

// The pure half of user-editable prompts: the placeholder grammar, the shipped
// default texts, and the catalogue describing them.
//
// Split out of `PromptStore` deliberately. Everything here is plain Foundation —
// no `@MainActor`, no `Observation`, no `UserDefaults` — so `tools/prompt-store-tests`
// can compile and drive it standalone on the Mac, which the app target itself can
// never do (the Plaud frameworks ship an arm64-iOS slice only). `PromptStore` is
// the thin persistence layer on top; it holds no text and no parsing.

// MARK: - Placeholder grammar

/// Filling and validating prompt templates.
///
/// ## Syntax
///
/// A placeholder is `{snake_case}` — an opening brace, one or more ASCII letters,
/// digits or underscores, a closing brace. Chosen because it reads clearly inside
/// English prose, doesn't collide with Swift's own `\(…)` interpolation in the
/// source, and is unlikely to occur by accident in a prompt someone types.
/// Anything that isn't a well-formed placeholder — `{}`, `{two words}`, `{unclosed`,
/// a lone `}` — is left exactly as written.
///
/// ## Why substitution is a single scan
///
/// `filled` walks the template once and copies each substituted value into the
/// output **verbatim, without re-scanning it**. A naïve loop of
/// `replacingOccurrences` over an accumulating string would re-substitute
/// placeholder-shaped text that arrived *inside* a value — and values here are
/// transcripts of whatever the user recorded, so `{transcript}` spoken aloud, or a
/// category named `{today}`, would rewrite the prompt. That is an injection-shaped
/// bug, and the scan is what prevents it.
///
/// ## Validation is advisory
///
/// `missingPlaceholders` returns what's absent rather than throwing, so the UI can
/// warn and still let the user save a prompt it doesn't like. Nothing downstream
/// fails: a prompt that has lost `{transcript}` still runs, the model just answers
/// with no transcript in front of it. **A bad prompt degrades quality without
/// erroring.** Where the model's output is read back through guided generation
/// (`@Generable` — the classifier and the action-item extractor), the framework
/// still enforces the output *shape*, so the worst case there is poor content in a
/// well-formed structure, never a parse failure or a crash.
enum PromptTemplating {

    /// `"transcript"` → `"{transcript}"`. Accepts an already-braced name, so a
    /// caller can't double-wrap it.
    static func token(_ name: String) -> String { "{\(bare(name))}" }

    /// Every placeholder the text contains, in order of first appearance, deduped.
    static func placeholders(in text: String) -> [String] {
        rewrite(text) { _ in nil }.names
    }

    /// The `required` placeholders that `text` no longer contains.
    ///
    /// Empty means the prompt is well-formed. Names may be given bare
    /// (`"transcript"`) or braced (`"{transcript}"`); both are understood.
    static func missingPlaceholders(in text: String, required: [String]) -> [String] {
        let present = Set(placeholders(in: text))
        var missing: [String] = []
        for name in required.map(bare) where !present.contains(name) && !missing.contains(name) {
            missing.append(name)
        }
        return missing
    }

    /// Substitute `values` into `template`.
    ///
    /// A placeholder with no matching value is left **literally intact** — a
    /// visible `{typo}` in the prompt is debuggable, whereas a silent blank looks
    /// like the feature simply stopped working.
    static func filled(_ template: String, with values: [String: String]) -> String {
        rewrite(template) { values[$0] }.result
    }

    // MARK: - Scanner

    /// One left-to-right pass. `replacement` returns the text to emit for a
    /// placeholder, or nil to leave `{name}` as written.
    private static func rewrite(
        _ text: String, _ replacement: (String) -> String?
    ) -> (result: String, names: [String]) {
        var result = ""
        result.reserveCapacity(text.count)
        var names: [String] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard character == "{" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }

            // Try to read a well-formed `{name}` from here.
            var cursor = text.index(after: index)
            var name = ""
            var closed = false
            while cursor < text.endIndex {
                let next = text[cursor]
                if next == "}" { closed = true; break }
                guard next.isASCII, next.isLetter || next.isNumber || next == "_" else { break }
                name.append(next)
                cursor = text.index(after: cursor)
            }
            guard closed, !name.isEmpty else {
                // Not a placeholder — emit the brace and carry on from the next
                // character, so `{{transcript}` still finds the inner one.
                result.append(character)
                index = text.index(after: index)
                continue
            }

            if !names.contains(name) { names.append(name) }
            // Appended, never re-scanned: `index` jumps past the closing brace, so
            // a value containing `{...}` is inert.
            result.append(replacement(name) ?? "{\(name)}")
            index = text.index(after: cursor)
        }
        return (result, names)
    }

    private static func bare(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { trimmed.removeFirst() }
        if trimmed.hasSuffix("}") { trimmed.removeLast() }
        return trimmed
    }
}

// MARK: - Catalogue

/// One prompt the user is allowed to rewrite.
///
/// The text itself lives in `PromptDefaults` and the user's version in
/// `PromptStore`; this is the description the settings UI renders.
struct EditablePrompt: Identifiable, Hashable {
    let id: String
    let name: String
    /// One line telling the user what editing this changes.
    let detail: String
    let defaultText: String
    /// Placeholders the text MUST still contain to work. Missing one doesn't
    /// error — it quietly costs the model the information — so the UI warns.
    let requiredPlaceholders: [String]
    /// Placeholders the text may use but can live without. Dropping one loses a
    /// refinement rather than the feature, so it isn't worth a warning; the editor
    /// still offers them for insertion.
    let optionalPlaceholders: [String]

    init(
        id: String,
        name: String,
        detail: String,
        defaultText: String,
        requiredPlaceholders: [String],
        optionalPlaceholders: [String] = []
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.defaultText = defaultText
        self.requiredPlaceholders = requiredPlaceholders
        self.optionalPlaceholders = optionalPlaceholders
    }

    /// Everything the editor can offer to insert, required first.
    var allPlaceholders: [String] { requiredPlaceholders + optionalPlaceholders }

    /// Required placeholders `text` has lost. Empty is good.
    func missingPlaceholders(in text: String) -> [String] {
        PromptTemplating.missingPlaceholders(in: text, required: requiredPlaceholders)
    }
}

/// The ids, as constants rather than string literals scattered over call sites.
///
/// An id is persisted as a `UserDefaults` dictionary key, so renaming one silently
/// discards that prompt's user edits. Add; don't rename.
enum PromptID {
    static let qaGrounding = "qa.grounding"
    static let summaryGrounding = "summary.grounding"
    static let organizeClassify = "organize.classify"
    static let organizeRequest = "organize.request"
    static let actionsExtract = "actions.extract"
    static let actionsRequest = "actions.request"
    static let dueDateRules = "duedates.rules"
    static let seriesContinuity = "series.continuity"
}

/// The shipped text of every prompt, and the single source of it.
///
/// The owning types (`TranscriptQA`, `SummaryGenerator`, `AutoOrganizer`,
/// `ActionItemExtractor`) read their prompt from `PromptStore.text(for:)`/`filled(_:with:)`
/// rather than holding a literal, so what the user sees in Settings is exactly what
/// runs; each falls back to the matching `PromptDefaults` entry only for the
/// impossible case of the catalogue having lost the id. The one indirection is
/// `dueDateRules`: `DueDateResolver` stays pure Foundation (no `PromptStore`, so
/// `tools/due-date-tests` can drive it), so `ActionItemExtractor` — its caller —
/// does the `PromptStore` routing, filling this template with the date anchors
/// `DueDateResolver.ruleValues(recordedAt:calendar:)` computes. Keeping the text
/// here rather than in each type is what makes "what you see is what runs" true —
/// two copies would drift the moment one is edited.
enum PromptDefaults {

    /// `TranscriptQA.ground(on:)`. One transcript in the detail view, several
    /// concatenated in library-wide Ask — hence "transcript(s)".
    static let qaGrounding = """
        You answer questions about the transcript(s) below from the user's recordings. \
        Base your answer on what the transcripts say. You may quote, summarize, or draw \
        reasonable conclusions or inferences (for example, inferring the overall reason or purpose \
        for a meeting from its main discussion points). Only say you don't know \
        if the transcripts genuinely contain no relevant information.

        Reply in plain, natural sentences — never JSON, key–value pairs, code, or \
        markdown. Keep it concise and speak directly to the user.

        TRANSCRIPT:
        {transcript}
        """

    /// `SummaryGenerator.generate(transcript:template:)`. Wraps the *template's* own
    /// prompt, which the user edits separately in `TemplateStore`.
    static let summaryGrounding = """
        You summarize a transcript of a recording the user made. Follow the \
        user's instruction exactly, basing everything only on the transcript. \
        Reply in plain text — you may use simple "- " bullet lines where the \
        instruction asks for a list, but never JSON or code.

        TRANSCRIPT:
        {transcript}
        """

    /// `AutoOrganizer.classify(_:into:)`. `{categories}` is the user's own category
    /// list, rendered one per line as `- Name: guidance`.
    static let organizeClassify = """
        You organize the user's voice recordings. Read the transcript of one \
        recording and decide which single category fits it best. The categories, \
        with guidance on when each applies:
        {categories}

        TRANSCRIPT:
        {transcript}
        """

    /// The user turn that accompanies `organizeClassify`.
    static let organizeRequest =
        "Pick the single best category and write a title of at most six words."

    /// `ActionItemExtractor.instructions(for:)`.
    static let actionsExtract = """
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
        {deadline_rules}

        TRANSCRIPT:
        {transcript}
        """

    /// The user turn that accompanies `actionsExtract`.
    static let actionsRequest =
        "List the action items. Return an empty list if there are none."

    /// `DueDateResolver.instructions(recordedAt:calendar:)` — the fragment that
    /// turns "by Friday" into a date, spliced into `actionsExtract` as
    /// `{deadline_rules}`.
    ///
    /// Every placeholder here is computed from the recording's own `createdAt`, so
    /// the worked examples can never contradict the anchor. `{recorded_date}` is
    /// spelled out with its weekday ("Friday, 31 July 2026") and `{today}` is the
    /// same day in ISO form: the model needs the first to resolve relative weekday
    /// wording and the second as the exact string shape it must produce.
    static let dueDateRules = """
        This conversation took place on {recorded_date}. Work every deadline out from \
        that day.

        When the transcript states a deadline, give it as a calendar date in \
        exactly one of these two formats and nothing else:
        - {next_week} — a day on its own, when no time of day was spoken.
        - {next_week}T14:00 — a day and a 24-hour time, when a time of day was \
        actually spoken.

        Return an empty string when no deadline is spoken. Never invent one, and \
        never return a date before {today}.

        For this recording:
        - "tomorrow" is {tomorrow}.
        - "next week" or "in a week" is {next_week}.
        - "by the end of the month" is {month_end}.
        - "tomorrow at two in the afternoon" is {tomorrow}T14:00.
        - "by Friday" is the first Friday falling on or after {today}.
        """

    /// `SeriesContinuity.update(for:)`.
    ///
    /// One call produces both halves — the recap the user reads and the
    /// carry-forward the *next* session reads — because they are two views of the
    /// same reasoning and generating them separately let them disagree.
    ///
    /// The instructions lean hard on "only what the transcript says" for the same
    /// reason the action-item prompt does: a running document that quietly
    /// accumulates invented continuity is worse than no continuity at all, and it
    /// compounds — an invention carried forward is indistinguishable from a fact
    /// by the session after next.
    static let seriesContinuity = """
        You keep a running record of a recurring meeting called "{series_name}", so \
        that each session can be read as a continuation of the ones before it.

        You are given WHERE THINGS STOOD — your own notes after the previous \
        session — and the TRANSCRIPT of the session that just happened. Produce two \
        things:

        1. A recap of this session **in relation to the previous ones**: what moved \
        on, what was decided, what was raised again, what is still open. Write it \
        for someone who was at the earlier sessions. Three to six short "- " bullet \
        lines. If nothing connects to the earlier notes, say what is new instead — \
        do not force a link that isn't there.

        2. Replacement notes for WHERE THINGS STOOD, folding this session into \
        them: the decisions that stand, the threads still open, who owes what, and \
        anything recurring. Keep it under 200 words — it is rewritten after every \
        session and has to stay short enough to carry forward indefinitely. Drop \
        anything that has been settled and is no longer live.

        Both must come only from the notes and the transcript. Never invent a \
        decision, a name, a date, or a link between sessions. If the previous notes \
        are empty, this is the first session in the series — treat it as the \
        starting point rather than describing it as a continuation.

        WHERE THINGS STOOD:
        {previous}

        TRANSCRIPT:
        {transcript}
        """
}

/// Every editable prompt, in the order the settings list shows them.
enum PromptCatalog {

    static let all: [EditablePrompt] = [
        EditablePrompt(
            id: PromptID.seriesContinuity,
            name: "Continue a meeting series",
            detail: "How each session of a recurring meeting is read against the ones before it.",
            defaultText: PromptDefaults.seriesContinuity,
            requiredPlaceholders: ["series_name", "previous", "transcript"]),
        EditablePrompt(
            id: PromptID.organizeClassify,
            name: "Categorise and title",
            detail: "How recordings are sorted into your categories and given a title.",
            defaultText: PromptDefaults.organizeClassify,
            requiredPlaceholders: ["categories", "transcript"]),
        EditablePrompt(
            id: PromptID.organizeRequest,
            name: "Categorise and title — request",
            detail: "The one-line instruction sent alongside the categorising prompt.",
            defaultText: PromptDefaults.organizeRequest,
            requiredPlaceholders: []),
        EditablePrompt(
            id: PromptID.actionsExtract,
            name: "Find action items",
            detail: "What counts as a task, and how owners and deadlines are read.",
            defaultText: PromptDefaults.actionsExtract,
            requiredPlaceholders: ["transcript"],
            optionalPlaceholders: ["deadline_rules"]),
        EditablePrompt(
            id: PromptID.actionsRequest,
            name: "Find action items — request",
            detail: "The one-line instruction sent alongside the action-items prompt.",
            defaultText: PromptDefaults.actionsRequest,
            requiredPlaceholders: []),
        EditablePrompt(
            id: PromptID.dueDateRules,
            name: "Resolve spoken deadlines",
            detail: "How a spoken deadline becomes a real date on a reminder.",
            defaultText: PromptDefaults.dueDateRules,
            requiredPlaceholders: ["recorded_date", "today"],
            optionalPlaceholders: ["tomorrow", "next_week", "month_end"]),
        EditablePrompt(
            id: PromptID.summaryGrounding,
            name: "Summaries",
            detail: "The rules every summary template runs under. Edit a template for its own wording.",
            defaultText: PromptDefaults.summaryGrounding,
            requiredPlaceholders: ["transcript"]),
        EditablePrompt(
            id: PromptID.qaGrounding,
            name: "Ask about a recording",
            detail: "How questions about a transcript are answered.",
            defaultText: PromptDefaults.qaGrounding,
            requiredPlaceholders: ["transcript"]),
    ]

    static func prompt(id: String) -> EditablePrompt? {
        all.first { $0.id == id }
    }

    static func defaultText(for id: String) -> String {
        prompt(id: id)?.defaultText ?? ""
    }
}

// MARK: - Persistence helpers

/// The pure half of `PromptStore`'s persistence: decoding what was stored, and
/// deciding whether an override is worth using.
///
/// Separate so both halves are testable without `UserDefaults` or the main actor.
enum PromptOverrides {

    /// Stored overrides, or empty for absent *or* corrupt data.
    ///
    /// Never throws and never crashes: a `UserDefaults` blob that fails to decode
    /// means the user's edits are lost, which is recoverable, whereas a trap at
    /// launch is not. Same defensive decode as `TemplateStore`.
    static func decode(_ data: Data?) -> [String: String] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    static func encode(_ overrides: [String: String]) -> Data? {
        try? JSONEncoder().encode(overrides)
    }

    /// The text to actually send: the override when it says something, otherwise
    /// the shipped default.
    ///
    /// An override that is empty or whitespace-only is treated as no override.
    /// Clearing the editor and saving is how a user "removes" a prompt, and an
    /// empty system prompt is strictly worse than the default — the model is left
    /// with a bare transcript and no idea what to do with it.
    static func resolve(override: String?, default fallback: String) -> String {
        guard let override,
              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fallback }
        return override
    }
}
