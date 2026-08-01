import Foundation

/// Pure set logic for a recording's tags.
///
/// **Tags store ids, not names.** `Recording.categoryName` stores a *name*, and
/// the documented consequence is that renaming a category silently detaches
/// every recording tagged with the old one. Tags deliberately reference
/// `RecordingCategory.id` so a rename is invisible to them. Nothing here knows
/// what a tag is *called* — resolution to a `RecordingCategory` (and therefore
/// to a colour and a glyph) belongs to `CategoryStore` and `CategoryStyle`.
///
/// Every function takes plain values rather than reaching for `CategoryStore` or
/// `RecordingStore`, so this file is Foundation-only, off any actor, and can be
/// compiled and exercised standalone on the Mac — see
/// `tools/recording-tags-tests/main.swift`.
///
/// Two rules run through all of it:
///
/// - **`nil`, never `[]`, means "no tags".** `Recording.tagIds` is optional for
///   the decode-compatibility reason every other added field is (a non-optional
///   key missing from stored JSON fails the whole `Decodable`), and persisting
///   `[]` where `nil` means the same thing creates two representations of one
///   state that then compare unequal — which defeats change detection and writes
///   the library for no reason.
/// - **Nothing here reorders.** Tag arrays keep insertion order end to end;
///   sorting is a display concern and happens in the view (`TagChipRow`). A
///   sort-on-read that gets persisted rewrites every recording the first time
///   the sort rule changes.
enum RecordingTags {

    // MARK: - Filtering

    /// Whether a recording satisfies a tag filter.
    ///
    /// **AND semantics**: the recording must carry *every* selected tag. The
    /// board request is explicit about wanting the intersection — "meeting AND
    /// urgent", not "meeting OR urgent" — and OR over several tags degenerates
    /// into showing almost the whole library, which is the opposite of a filter.
    ///
    /// An empty selection matches everything, so "no filter" needs no special
    /// case at the call site.
    static func matches(recordingTagIds: [String]?, selected: Set<String>) -> Bool {
        guard !selected.isEmpty else { return true }
        guard let recordingTagIds, !recordingTagIds.isEmpty else { return false }
        return selected.isSubset(of: Set(recordingTagIds))
    }

    // MARK: - Integrity

    /// Ids the recording carries that no longer exist in the store.
    ///
    /// A dangling id renders as nothing and can't be tapped off, so it is
    /// invisible *and* unremovable — hence the sweep in
    /// `CategoryStore.remove(id:)`. This is the read side of that: report what a
    /// recording is holding onto so it can be cleaned or diagnosed.
    ///
    /// Order follows `recordingTagIds`, and duplicates (which `adding` prevents,
    /// but a hand-edited or externally-written library could contain) are
    /// reported as they appear.
    static func danglingIds(in recordingTagIds: [String]?, knownIds: Set<String>) -> [String] {
        guard let recordingTagIds else { return [] }
        return recordingTagIds.filter { !knownIds.contains($0) }
    }

    // MARK: - Editing

    /// `recordingTagIds` with `tagId` removed — the per-recording half of the
    /// delete sweep, and what the detail view's tag toggle calls to unset one.
    ///
    /// Returns `nil` rather than `[]` when the last tag goes, per the rule above.
    /// Removing an id that isn't there returns the input unchanged (still `nil`
    /// if it was `nil`), so a redundant call is a genuine no-op and change
    /// detection stays honest.
    static func removing(_ tagId: String, from recordingTagIds: [String]?) -> [String]? {
        guard let recordingTagIds else { return nil }
        let remaining = recordingTagIds.filter { $0 != tagId }
        return remaining.isEmpty ? nil : remaining
    }

    /// `recordingTagIds` with `tagId` appended.
    ///
    /// Adding an id already present is a no-op, not a duplicate. Appends rather
    /// than inserting or sorting: insertion order is the stored order.
    ///
    /// Non-optional return — the result always holds at least `tagId`.
    static func adding(_ tagId: String, to recordingTagIds: [String]?) -> [String] {
        guard let recordingTagIds else { return [tagId] }
        guard !recordingTagIds.contains(tagId) else { return recordingTagIds }
        return recordingTagIds + [tagId]
    }

    /// Adds `tagId` if absent, removes it if present — what a tag row's tap does.
    ///
    /// Optional return because the toggle that clears the last tag has to be able
    /// to express "none".
    static func toggling(_ tagId: String, in recordingTagIds: [String]?) -> [String]? {
        if recordingTagIds?.contains(tagId) == true {
            return removing(tagId, from: recordingTagIds)
        }
        return adding(tagId, to: recordingTagIds)
    }
}
