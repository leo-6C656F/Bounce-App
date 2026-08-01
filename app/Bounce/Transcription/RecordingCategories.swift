import Foundation
import Observation

/// A kind of recording the user makes — "Meeting", "Reminder" — that the
/// auto-organize pass (`AutoOrganizer`) classifies each new transcript into.
///
/// Each category carries the guidance that teaches the on-device model when it
/// applies, the prefix used when auto-titling ("Meeting: Budget review"), and
/// which summary templates run automatically for recordings of that kind.
struct RecordingCategory: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    /// Prepended to the AI title, e.g. "Meeting:". Empty for no prefix.
    var titlePrefix: String
    /// Tells the classifier when this category applies.
    var guidance: String
    /// Ids of summary templates auto-run for recordings in this category.
    var templateIds: [String]
    /// A `CategoryStyle.swatches` name ("teal"). **Optional so categories saved
    /// before this field existed still decode** — Swift's synthesised `Decodable`
    /// requires every non-optional key to be present, and a missing one would
    /// take the whole stored list with it. Nil falls back to a stable colour
    /// derived from `id`.
    var colorName: String?
    /// An SF Symbol name. Optional for the same decode reason; nil renders
    /// `CategoryStyle.fallbackSymbol`.
    var symbolName: String?
    /// Whether a recording in this category may be named after an overlapping
    /// calendar event. Optional for the same decode reason; **nil means yes**, so
    /// existing categories keep behaving as they did.
    ///
    /// This exists because a note to yourself recorded during a meeting is not a
    /// recording *of* that meeting. An 8-second "remember to take out the trash"
    /// was being titled "Test Meeting Calendar". The duration guards in
    /// `RecordingTitleSelection` catch most of that automatically; this is the
    /// explicit control for categories where it should never happen at all —
    /// Reminder and Note being the obvious ones.
    var usesCalendarTitle: Bool?

    /// Resolved with the nil-means-yes default applied.
    var allowsCalendarTitle: Bool { usesCalendarTitle ?? true }

    init(
        id: String = UUID().uuidString,
        name: String,
        titlePrefix: String,
        guidance: String,
        templateIds: [String] = [],
        colorName: String? = nil,
        symbolName: String? = nil,
        usesCalendarTitle: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.titlePrefix = titlePrefix
        self.guidance = guidance
        self.templateIds = templateIds
        self.colorName = colorName
        self.symbolName = symbolName
        self.usesCalendarTitle = usesCalendarTitle
    }
}

/// Holds the user's recording categories, persisted in `UserDefaults`. Seeded
/// with a starter set on first launch; after that the user owns the list —
/// every category can be edited, deleted, or added to, and deleting them all
/// sticks (classification is simply skipped when the list is empty).
@MainActor
@Observable
final class CategoryStore {

    static let shared = CategoryStore()

    private let defaultsKey = "recordingCategories"

    /// The starter set, also restorable from Settings.
    static let starterSet: [RecordingCategory] = [
        RecordingCategory(
            id: "starter.meeting", name: "Meeting", titlePrefix: "Meeting:",
            guidance: "A conversation or discussion between people — standups, syncs, calls, interviews, or anything with back-and-forth.",
            templateIds: ["builtin.notes"],
            colorName: "blue", symbolName: "person.2.fill"),
        RecordingCategory(
            id: "starter.task", name: "Task", titlePrefix: "Task:",
            guidance: "The user describes work they need to do — errands, to-dos, things to get done.",
            templateIds: ["builtin.actions"],
            colorName: "green", symbolName: "checklist"),
        RecordingCategory(
            id: "starter.reminder", name: "Reminder", titlePrefix: "Reminder:",
            guidance: "The user reminds themself of something tied to a day or time — appointments, pickups, deadlines.",
            templateIds: ["builtin.actions"],
            colorName: "orange", symbolName: "bell.fill"),
        RecordingCategory(
            id: "starter.note", name: "Note", titlePrefix: "Note:",
            guidance: "A thought, idea, or memo to self that isn't a meeting, task, or reminder.",
            templateIds: ["builtin.summary"],
            colorName: "purple", symbolName: "note.text"),
    ]

    private(set) var categories: [RecordingCategory]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([RecordingCategory].self, from: data) {
            categories = saved
        } else {
            // First launch: seed and persist immediately, so an emptied list is
            // distinguishable from a never-seeded one.
            categories = Self.starterSet
            persist()
        }
    }

    func category(id: String) -> RecordingCategory? {
        categories.first { $0.id == id }
    }

    /// Look a category up the way a `Recording` refers to one: by **name**.
    /// `Recording.categoryName` stores the name the auto-organize pass matched,
    /// not an id, so renaming a category detaches recordings already tagged with
    /// the old name — they render neutrally rather than incorrectly.
    /// Case-insensitive, mirroring `AutoOrganizer`'s own matching.
    func category(named name: String) -> RecordingCategory? {
        categories.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    // MARK: - Editing

    func add(_ category: RecordingCategory) {
        guard !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        categories.append(category)
        persist()
    }

    func update(_ category: RecordingCategory) {
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        categories[index] = category
        persist()
    }

    func remove(id: String) {
        categories.removeAll { $0.id == id }
        persist()
        sweepTag(id)
    }

    /// Clear a deleted tag's id out of every recording.
    ///
    /// Without this the library fills with ids that resolve to no category, so they
    /// render as nothing and there is no control that can clear them — the
    /// recording looks untagged but still fails an intersection filter for a tag
    /// that no longer exists.
    ///
    /// Only `tagIds` is swept. `Recording.categoryName` stores a *name*, not an id,
    /// and is deliberately left alone: a recording keeps reading as "Meeting" after
    /// the category is deleted, which is the documented behaviour and is better
    /// than silently erasing the classification.
    private func sweepTag(_ tagId: String) {
        let affected = RecordingStore.shared.recordings.filter {
            $0.tagIds?.contains(tagId) == true
        }
        guard !affected.isEmpty else { return }
        for recording in affected {
            RecordingStore.shared.update(id: recording.id) {
                $0.tagIds = RecordingTags.removing(tagId, from: $0.tagIds)
            }
        }
        SyncManager.shared.refreshLibrary()
    }

    /// Bring back any starter categories the user deleted, without touching
    /// ones they kept or created.
    func restoreStarterSet() {
        let existing = Set(categories.map(\.id))
        categories.append(contentsOf: Self.starterSet.filter { !existing.contains($0.id) })
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(categories), forKey: defaultsKey)
    }
}
