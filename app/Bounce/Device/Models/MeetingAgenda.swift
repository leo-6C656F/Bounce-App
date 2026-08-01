import Foundation

/// A checklist of topics the user meant to cover in a recording, with automatic
/// detection of which ones actually came up in the transcript.
///
/// Foundation-only and in `Device/Models/` rather than next to
/// `MeetingAgendaView`, because `Recording` stores one — and `Recording.swift`
/// has to keep compiling standalone for `tools/library-decode-tests/main.swift`.
/// A SwiftUI import anywhere in that dependency tree breaks the gate that stops
/// a bad stored field taking down the whole library.
struct AgendaItem: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var text: String
    /// Whether the topic came up. Set by the user, or by `evaluate` — and once
    /// the user has touched it, only by the user. See `isPinnedByUser`.
    var isDiscussed: Bool = false
    /// Set when the user checks or unchecks the row by hand.
    ///
    /// Without this, `evaluate` fights the user: it only ever sets `isDiscussed`
    /// to `true`, and it runs on every appearance, so unchecking a row that the
    /// matcher likes silently reverts the next time the screen is opened.
    var isPinnedByUser: Bool = false
}

struct MeetingAgenda: Codable, Hashable {
    var items: [AgendaItem] = []

    var isEmpty: Bool { items.isEmpty }

    var discussedCount: Int { items.filter(\.isDiscussed).count }

    var progress: Double {
        items.isEmpty ? 0 : Double(discussedCount) / Double(items.count)
    }

    /// Marks items whose wording appears in the transcript.
    ///
    /// Matching is **whole-word and requires every significant word** in the item.
    /// The looser rule this replaced — *any* word of four-plus characters appearing
    /// as a substring — matched "Review Objectives" against the word "reviewing"
    /// and "Discuss Action Items" against a bare "action", so a typical transcript
    /// marked most of an agenda covered without discussing any of it.
    ///
    /// Never clears a flag: absence of a phrase is not evidence a topic went
    /// uncovered, and the user's own checkmarks are authoritative anyway.
    mutating func evaluate(transcript: String) {
        let haystack = Set(MeetingAgenda.words(in: transcript))
        guard !haystack.isEmpty else { return }
        for index in items.indices where !items[index].isPinnedByUser {
            let needles = MeetingAgenda.words(in: items[index].text).filter { $0.count >= 4 }
            guard !needles.isEmpty else { continue }
            if needles.allSatisfy(haystack.contains) {
                items[index].isDiscussed = true
            }
        }
    }

    /// Lowercased word tokens, split on anything that isn't a letter or number —
    /// the same rule `AskCorpus.keywords` uses, so the two agree about what a
    /// word is.
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
