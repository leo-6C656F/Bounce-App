import Foundation
import Observation

/// The user's edits to the app's AI prompts.
///
/// Every prompt Bounce sends to a model is described in `PromptCatalog` and shipped
/// in `PromptDefaults`; this holds the versions the user has rewritten and hands the
/// owning type whichever is current. `@Observable`, so the Advanced prompts screen
/// updates live as it's edited.
///
/// **Same shape as `TemplateStore`, on purpose.** One `[String: String]` overrides
/// dictionary in `UserDefaults` keyed by prompt id, `text(for:)` merging an override
/// over the shipped default, `reset(_:)` removing the entry. There is no second
/// pattern for the same problem, and no copy of any prompt's text: the defaults live
/// once, in `PromptDefaults`.
///
/// ## What a broken prompt costs
///
/// Nothing errors. A prompt that has lost `{transcript}` still runs — the model just
/// never sees the recording, and answers from nothing. Where output is read back
/// through guided generation (`@Generable`: the classifier, the action-item
/// extractor) the framework still enforces the output *shape*, so a mangled prompt
/// yields poor content in a well-formed structure rather than a parse failure or a
/// crash. That's why `EditablePrompt.missingPlaceholders(in:)` is advisory: the UI
/// warns, the user may save anyway, and `reset(_:)` is always one tap away.
///
/// ## Not in here
///
/// - **Summary templates** — already user-editable in their own right, via
///   `TemplateStore`. `PromptID.summaryGrounding` is only the wrapper they run
///   inside.
/// - **`@Guide(description:)` strings** on the `@Generable` types. They're prompt
///   text, but the attribute takes a compile-time literal, so they cannot be read
///   from storage at all.
/// - **The MCP tool descriptions** (`MCPProtocol.instructions`, `MCPEndpoint`).
///   Those address a *remote* client's model and form a protocol contract, not the
///   app's own AI behaviour.
@MainActor
@Observable
final class PromptStore {

    static let shared = PromptStore()

    private let overridesKey = "aiPromptOverrides"

    /// The user's rewrites, keyed by prompt id. An entry shadows the shipped text;
    /// removing it is "reset to default".
    private(set) var overrides: [String: String]

    private init() {
        overrides = PromptOverrides.decode(UserDefaults.standard.data(forKey: overridesKey))
    }

    /// Every editable prompt, in display order. The definitions are fixed; the text
    /// each one currently uses comes from `text(for:)`.
    var all: [EditablePrompt] { PromptCatalog.all }

    func prompt(id: String) -> EditablePrompt? { PromptCatalog.prompt(id: id) }

    // MARK: - Reading

    /// The text to send for `id`: the user's version when they have one, otherwise
    /// the shipped default.
    ///
    /// An override that is empty or whitespace-only falls back to the default — see
    /// `PromptOverrides.resolve`. An unknown id returns "", which is the correct
    /// answer to a question about a prompt that doesn't exist and keeps this
    /// non-optional for call sites.
    func text(for id: String) -> String {
        PromptOverrides.resolve(
            override: overrides[id], default: PromptCatalog.defaultText(for: id))
    }

    /// `text(for:)` with its placeholders substituted, which is what every call site
    /// actually wants. Unknown placeholders survive verbatim.
    func filled(_ id: String, with values: [String: String]) -> String {
        PromptTemplating.filled(text(for: id), with: values)
    }

    /// Whether this prompt currently differs from the shipped text.
    ///
    /// A whitespace-only override doesn't count: it isn't used, so showing "Custom"
    /// and a Reset button for it would be a lie.
    func isCustomised(_ id: String) -> Bool {
        text(for: id) != PromptCatalog.defaultText(for: id)
    }

    var customisedCount: Int { all.filter { isCustomised($0.id) }.count }

    var hasCustomisations: Bool { customisedCount > 0 }

    /// Required placeholders this prompt's current text has lost. Empty is good.
    func missingPlaceholders(_ id: String) -> [String] {
        guard let prompt = PromptCatalog.prompt(id: id) else { return [] }
        return prompt.missingPlaceholders(in: text(for: id))
    }

    // MARK: - Editing

    /// Save the user's version of a prompt.
    ///
    /// Text identical to the default clears the override instead of storing a
    /// duplicate, so "edit it back by hand" and "tap Reset" leave the same state —
    /// otherwise the screen would keep claiming the prompt was customised.
    /// Validation is the caller's business; anything is accepted.
    func update(_ id: String, to text: String) {
        guard PromptCatalog.prompt(id: id) != nil else { return }
        if text == PromptCatalog.defaultText(for: id) {
            overrides[id] = nil
        } else {
            overrides[id] = text
        }
        persist()
    }

    /// Discard the user's version, restoring the shipped text.
    func reset(_ id: String) {
        guard overrides[id] != nil else { return }
        overrides[id] = nil
        persist()
    }

    /// Restore every shipped prompt at once — the escape hatch when editing has
    /// made the AI features worse and it isn't obvious which prompt did it.
    func resetAll() {
        guard !overrides.isEmpty else { return }
        overrides = [:]
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(PromptOverrides.encode(overrides), forKey: overridesKey)
    }
}
