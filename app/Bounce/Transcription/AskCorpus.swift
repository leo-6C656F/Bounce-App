import Foundation

/// Picks which recordings a question is about, and builds the text the on-device
/// model is grounded on.
///
/// Extracted from `AskView` so the phone and the desktop view ask the same
/// question of the same corpus. Two clients keyword-matching independently would
/// give different answers to the same words, which is exactly the kind of quiet
/// divergence `TimeInterval.timecodeText` exists to prevent.
enum AskCorpus {

    /// `TranscriptQA` caps what it grounds on, so more than this many
    /// transcripts is wasted work — and dilutes the grounding besides.
    static let maxSources = 20

    /// Common words that shouldn't drive recording matching. "what did I say
    /// about the budget" has to match on *budget*, not on "what/did/say", which
    /// appear in every transcript and would make every recording a match.
    static let stopwords: Set<String> = [
        "what", "when", "where", "which", "who", "why", "how", "was", "were",
        "about", "there", "their", "would", "could", "should", "that", "this",
        "with", "from", "have", "has", "had", "does", "did", "the", "and",
        "for", "you", "say", "said", "tell", "find", "meeting", "recordings",
        "recording", "today", "todays", "yesterday", "yesterdays", "week",
    ]

    static func keywords(in question: String) -> [String] {
        question.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 3 && !stopwords.contains(String($0)) }
            .map(String.init)
    }

    /// Recordings in the window a question names, or `nil` when it names none.
    ///
    /// **`nil` and `[]` mean different things and the caller must keep them
    /// apart.** `nil` is "the question wasn't about a date, search everything";
    /// `[]` is "the question asked about today and nothing was recorded today".
    /// Collapsing them — which an earlier version did by returning `[]` for both —
    /// makes *"what happened in today's meeting"* silently fall back to the whole
    /// library and answer from the wrong day, presented as if it were today's.
    ///
    /// All three windows are calendar-based. A rolling `now - 7×86400` would make
    /// "this week" mean something different at 9am Monday than the calendar week
    /// the user is thinking of, and disagree with `isDateInToday` right beside it.
    static func dateWindow(for question: String, in recordings: [Recording]) -> [Recording]? {
        let q = question.lowercased()
        let calendar = Calendar.current
        if q.contains("today") {
            return recordings.filter { calendar.isDateInToday($0.createdAt) }
        }
        if q.contains("yesterday") {
            return recordings.filter { calendar.isDateInYesterday($0.createdAt) }
        }
        if q.contains("this week") || q.contains("past week") || q.contains("last week") {
            return recordings.filter {
                calendar.isDate($0.createdAt, equalTo: Date(), toGranularity: .weekOfYear)
            }
        }
        return nil
    }

    /// The recordings a question is about: those inside any date window it names,
    /// narrowed to those whose transcripts mention its keywords.
    ///
    /// Empty when nothing matches — the caller decides what to fall back to. A
    /// date window that matched nothing stays empty rather than widening, so the
    /// fallback is visibly "no recordings from then" rather than a confident
    /// answer about the wrong day.
    static func matches(for question: String, in recordings: [Recording]) -> [Recording] {
        let window = dateWindow(for: question, in: recordings)
        let candidates = window ?? recordings
        // A named window that caught nothing is the answer. Falling through to a
        // keyword sweep here is the bug this function exists to avoid.
        guard !candidates.isEmpty else { return [] }

        let words = keywords(in: question)
        // "what did I record yesterday" has no keywords left after stopwords — the
        // window alone is the match.
        guard !words.isEmpty else { return window ?? [] }

        let keywordMatches = candidates.filter { recording in
            // Reuses the same cached lowercased haystack as library search
            // (S-8/S-9), instead of re-joining and re-lowercasing every
            // transcript on each Ask.
            let text = RecordingSearchIndex.shared.haystack(for: recording)
            return words.contains { text.contains($0) }
        }
        // Inside a named window, no keyword hit still means "these are the
        // recordings from then" — better grounding than the whole library.
        return keywordMatches.isEmpty ? (window ?? []) : keywordMatches
    }

    /// Sources the answer will draw on, and the text to ground the model with.
    ///
    /// Falls back to the most recent transcripts when nothing matches, so the
    /// model always has something real to work from rather than answering from
    /// its own priors. Always sorted newest-first.
    ///
    /// **`sources` is exactly what went into `corpus`.** Returning the full match
    /// list while grounding on only the first `maxSources` of it makes the UI cite
    /// recordings the model never read — the one thing a citation must not do.
    static func grounding(
        for question: String,
        in recordings: [Recording]
    ) -> (sources: [Recording], corpus: String) {
        let transcribed = recordings.filter(\.isTranscribed).sorted(by: { $0.createdAt > $1.createdAt })
        let matched = matches(for: question, in: transcribed).sorted(by: { $0.createdAt > $1.createdAt })
        let chosen = Array((matched.isEmpty ? transcribed : matched).prefix(maxSources))

        let corpus = chosen.map { recording in
            let date = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
            return "[\(recording.displayTitle) — \(date)]\n\(recording.transcript?.plainText ?? "")"
        }.joined(separator: "\n\n")

        return (chosen, corpus)
    }
}
