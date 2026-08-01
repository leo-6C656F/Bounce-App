import Foundation
import Observation

/// A reusable prompt that turns a transcript into a structured summary — e.g.
/// "Action items", "Meeting notes". Built-ins ship with the app; the user can add
/// their own.
struct SummaryTemplate: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    /// The instruction handed to the on-device model, applied over the transcript.
    var prompt: String
    var isBuiltIn: Bool
    /// Run this template automatically on every new transcript, whatever its
    /// category — see `AutoOrganizer`. Optional so templates saved before this
    /// field existed still decode.
    var autoRun: Bool?

    var runsAutomatically: Bool { autoRun == true }

    init(
        id: String = UUID().uuidString,
        name: String,
        prompt: String,
        isBuiltIn: Bool = false,
        autoRun: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
        self.autoRun = autoRun
    }
}

/// Holds the summary templates — the built-in set plus any the user creates,
/// which persist in `UserDefaults`. `@Observable` so the template picker updates
/// live as the user edits.
@MainActor
@Observable
final class TemplateStore {

    static let shared = TemplateStore()

    private let defaultsKey = "customSummaryTemplates"
    private let overridesKey = "builtinTemplateOverrides"
    private let deletedKey = "deletedBuiltinTemplates"

    /// Shipped templates, always present and not editable/deletable.
    static let builtIns: [SummaryTemplate] = [
        SummaryTemplate(
            id: "builtin.summary", name: "Summary",
            prompt: "Write a concise summary of the recording in a short paragraph or two, capturing the main points.",
            isBuiltIn: true),
        SummaryTemplate(
            id: "builtin.actions", name: "Action items",
            prompt: "List the action items and follow-ups mentioned, one per line as a bullet starting with \"- \". Include who owns each one if it's stated. If there are none, say so.",
            isBuiltIn: true),
        SummaryTemplate(
            id: "builtin.decisions", name: "Key decisions",
            prompt: "List the key decisions made, one per line as a bullet starting with \"- \". If no decisions were made, say so.",
            isBuiltIn: true),
        SummaryTemplate(
            id: "builtin.notes", name: "Meeting notes",
            prompt: "Write clean meeting notes: a one-line overview, then the main topics discussed as short bullets, then any action items. Keep it tight.",
            isBuiltIn: true),
    ]

    private(set) var custom: [SummaryTemplate]
    /// User edits to built-in templates, keyed by the built-in's id. An entry
    /// shadows the shipped version; removing it is "reset to default".
    private(set) var builtInOverrides: [String: SummaryTemplate]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([SummaryTemplate].self, from: data) {
            custom = saved
        } else {
            custom = []
        }
        if let data = UserDefaults.standard.data(forKey: overridesKey),
           let saved = try? JSONDecoder().decode([String: SummaryTemplate].self, from: data) {
            builtInOverrides = saved
        } else {
            builtInOverrides = [:]
        }
        // A plain string array, so an absent key reads as "nothing deleted" without
        // a decode step that could fail and silently resurrect everything.
        deletedBuiltIns = Set(UserDefaults.standard.stringArray(forKey: deletedKey) ?? [])
    }

    /// Built-ins first (with any user edits applied, and any the user deleted left
    /// out), then the user's own.
    var all: [SummaryTemplate] {
        Self.builtIns
            .filter { !deletedBuiltIns.contains($0.id) }
            .map { builtInOverrides[$0.id] ?? $0 }
            + custom
    }

    /// Shipped templates the user has deleted.
    ///
    /// Stored as a set of ids rather than by removing them from `builtIns`, which is
    /// a `static let` — the shipped list is code, so "deleted" has to be recorded
    /// alongside it. That's also what makes `restoreStarterSet()` possible: nothing
    /// is actually gone.
    ///
    /// Mirrors `CategoryStore`, where the same delete-and-restore pair already
    /// exists. Two stores solving one problem two different ways would be worse than
    /// either solution.
    private var deletedBuiltIns: Set<String> = []

    /// Whether any shipped template is currently deleted, so the UI can offer to
    /// bring them back only when there's something to bring back.
    var hasDeletedBuiltIns: Bool { !deletedBuiltIns.isEmpty }

    /// Restore every shipped template the user deleted, leaving their own
    /// templates and their edits to built-ins untouched.
    ///
    /// Edits survive because they live in `builtInOverrides`, which deletion never
    /// clears — restoring brings back a template as the user last had it, not as it
    /// shipped. `resetBuiltIn(id:)` is the separate control for that.
    func restoreStarterSet() {
        guard !deletedBuiltIns.isEmpty else { return }
        deletedBuiltIns.removeAll()
        persist()
    }

    func template(id: String) -> SummaryTemplate? {
        all.first { $0.id == id }
    }

    // MARK: - Editing

    func add(name: String, prompt: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        custom.append(SummaryTemplate(name: trimmedName, prompt: trimmedPrompt))
        persist()
    }

    /// Save an edit to any template. A built-in edit is stored as an override so
    /// it can be reset; a custom edit replaces the stored template.
    func update(_ template: SummaryTemplate) {
        if Self.builtIns.contains(where: { $0.id == template.id }) {
            var edited = template
            edited.isBuiltIn = true
            builtInOverrides[template.id] = edited
        } else if let index = custom.firstIndex(where: { $0.id == template.id }) {
            custom[index] = template
        } else {
            return
        }
        persist()
    }

    /// Whether a built-in currently carries user edits.
    func isOverridden(id: String) -> Bool {
        builtInOverrides[id] != nil
    }

    /// Discard the user's edits to a built-in, restoring the shipped version.
    func resetBuiltIn(id: String) {
        builtInOverrides[id] = nil
        persist()
    }

    /// Delete a template — the user's own, or a shipped one.
    ///
    /// A shipped template is remembered as deleted rather than erased, so
    /// `restoreStarterSet()` can bring it back. Its edits are deliberately kept: a
    /// user who deleted a template they'd customised and then restores it wants
    /// their version back, not the shipped one.
    func remove(id: String) {
        if Self.builtIns.contains(where: { $0.id == id }) {
            deletedBuiltIns.insert(id)
        } else {
            custom.removeAll { $0.id == id }
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(custom), forKey: defaultsKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(builtInOverrides), forKey: overridesKey)
        UserDefaults.standard.set(Array(deletedBuiltIns), forKey: deletedKey)
    }
}
