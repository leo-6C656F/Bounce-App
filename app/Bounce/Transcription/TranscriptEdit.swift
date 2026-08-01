import Foundation

/// Text edits over a `Transcript`, as pure functions.
///
/// The one the user asks for constantly: a name or a term was misheard, they
/// correct it once, and every other occurrence in the same transcript should
/// follow. That is a string operation and nothing more — no audio, no
/// re-transcription, no model — which is why this type has no dependency beyond
/// Foundation and the two model structs, and why it is the only logic in the
/// transcript pipeline that can be compiled and exercised on the Mac. See
/// `tools/transcript-edit-tests/main.swift`.
///
/// ## Timings are never touched
///
/// Only `TranscriptSegment.text` changes. `start`, `end` and `speaker` are copied
/// through verbatim, so tap-to-seek keeps landing where it did and a diarized
/// transcript keeps its speaker attribution. A correction that shifted timings
/// would look like the fix broke the player.
///
/// ## Matching is word-bounded, and the boundary is conditional
///
/// Substring matching is wrong here and wrong in a way that is hard to undo:
/// correcting "AI" would rewrite "said" and "again". So each occurrence has to be
/// a whole word.
///
/// `\b` is the usual tool and it misbehaves for needles whose own first or last
/// character isn't a word character. `\b` asserts a *transition* between a word
/// and a non-word character, so `\bC\+\+\b` demands a word character after the
/// final `+` — "C++ is fun" doesn't match, and neither does anything else a user
/// would type. Same failure at the head for `'til`, `.NET`, `+1`. It fails
/// silently: no error, zero occurrences, and a correction sheet that looks broken.
///
/// So the boundary is applied **per edge, only where that edge is a word
/// character**:
///
/// | needle | pattern | matches |
/// |---|---|---|
/// | `AI` | `(?<!\w)AI(?!\w)` | "the AI", not "said" or "again" |
/// | `machine lerning` | `(?<!\w)machine\ lerning(?!\w)` | multi-word, whole-phrase |
/// | `C++` | `(?<!\w)C\+\+` | "C++ is fun" |
/// | `'til` | `'til(?!\w)` | "wait 'til noon" |
/// | `...` | `\.\.\.` | plain substring — no word edges to anchor to |
///
/// The bias is deliberate: dropping a guard makes matching *looser*, never
/// tighter. A needle ending in punctuation can therefore match inside a longer
/// token ("C++" inside "C++x"), which is a far better failure than not matching
/// the thing the user is looking at.
///
/// Lookarounds rather than `\b` because they say which side they constrain, and
/// because omitting one is then just omitting one — with `\b` the same character
/// means different things at different ends of the pattern.
///
/// ## A needle can't span two segments
///
/// Segments are separate strings, matched independently. A two-word needle whose
/// words fall either side of a segment boundary is not found. Both engines cut
/// segments at phrase level, so this is uncommon but real; joining segments to
/// match across them would mean re-splitting the result and inventing timings for
/// the pieces, which breaks the rule above. Counted as a known limitation, not
/// worked around.
enum TranscriptEdit {

    // MARK: - Replacement

    /// Replace every whole-word occurrence of `needle` with `replacement`.
    ///
    /// - Returns: the edited transcript and how many occurrences were replaced.
    ///   With no matches, the *original* transcript value comes back untouched —
    ///   no new segment array is built — so a caller can compare and skip a
    ///   pointless store write.
    ///
    /// `count` is the occurrence count, which is the same number
    /// `occurrences(of:in:caseSensitive:)` reports for the same arguments: both go
    /// through one matcher. It is **not** a count of segments changed, and it can
    /// be non-zero while the transcript comes back identical — replacing a word
    /// with itself is a legitimate no-op that still found matches.
    ///
    /// An empty `needle` is a no-op. Whitespace in a needle is significant, so
    /// trim user input before calling if that's what the field means.
    static func replacing(
        _ needle: String,
        with replacement: String,
        in transcript: Transcript,
        caseSensitive: Bool
    ) -> (transcript: Transcript, count: Int) {
        guard let matcher = matcher(for: needle, caseSensitive: caseSensitive) else {
            return (transcript, 0)
        }

        // Whether a capitalised occurrence is *evidence of anything*. See
        // `capitalisationMatched`: it only is when the needle itself was typed
        // lower case, because then the capital is something the transcript added
        // rather than something the user asked for.
        let liftsCapital = !(needle.first?.isUppercase ?? false)

        // Built lazily: nil until a segment actually changes, so the zero-match
        // case — which is what a live "will change N occurrences" count hits on
        // every keystroke until the needle is complete — allocates nothing.
        var edited: [TranscriptSegment]?
        var total = 0

        for (index, segment) in transcript.segments.enumerated() {
            let (text, count) = replacingMatches(
                of: matcher, in: segment.text, with: replacement, liftingCapital: liftsCapital)
            guard count > 0 else { continue }
            total += count
            // Matched but produced identical text (needle == replacement, or a
            // case-only difference the capitalisation rule then undid). Nothing to
            // write, so leave the array alone and let the original value stand.
            guard text != segment.text else { continue }
            if edited == nil { edited = transcript.segments }
            edited?[index] = TranscriptSegment(
                text: text,
                start: segment.start,
                end: segment.end,
                speaker: segment.speaker)
        }

        guard let edited else { return (transcript, total) }

        var result = Transcript(
            segments: edited,
            localeIdentifier: transcript.localeIdentifier,
            createdAt: transcript.createdAt)
        // `isPreview` is set after construction rather than passed, matching
        // `TimelineMap.remap` — it must survive the edit or the coordinator would
        // stop treating an archived live draft as a draft.
        result.isPreview = transcript.isPreview
        return (result, total)
    }

    /// How many whole-word occurrences of `needle` the transcript contains.
    ///
    /// Drives the sheet's "will change N occurrences" line without doing the
    /// replacement. Guaranteed to equal the `count` that
    /// `replacing(_:with:in:caseSensitive:)` returns for the same needle and
    /// case option — the replacement value can't change how many matches there
    /// are, so the count is independent of it.
    static func occurrences(of needle: String, in transcript: Transcript, caseSensitive: Bool) -> Int {
        guard let matcher = matcher(for: needle, caseSensitive: caseSensitive) else { return 0 }
        return transcript.segments.reduce(0) { total, segment in
            let text = segment.text as NSString
            return total + matcher.numberOfMatches(
                in: segment.text,
                range: NSRange(location: 0, length: text.length))
        }
    }

    // MARK: - Matching

    /// The compiled matcher for `needle`, or nil when there is nothing to match.
    ///
    /// Nil covers both the empty needle and — in theory only — a pattern the regex
    /// engine rejects. `escapedPattern(for:)` means every character of the needle
    /// is a literal, so there is no user input that can produce an invalid
    /// pattern; the `try?` is there so that if one ever did, the correction is a
    /// silent no-op rather than a crash in the middle of the user's transcript.
    private static func matcher(for needle: String, caseSensitive: Bool) -> NSRegularExpression? {
        guard let first = needle.first, let last = needle.last else { return nil }

        var pattern = NSRegularExpression.escapedPattern(for: needle)
        if isWordCharacter(first) { pattern = "(?<!\\w)" + pattern }
        if isWordCharacter(last) { pattern += "(?!\\w)" }

        return try? NSRegularExpression(
            pattern: pattern,
            options: caseSensitive ? [] : [.caseInsensitive])
    }

    /// Whether a character would be matched by the pattern's own `\w`.
    ///
    /// An approximation of ICU's `\w`, which is
    /// `[\p{Alphabetic}\p{M}\p{Nd}\p{Pc}]` plus U+200C and U+200D — close enough
    /// that the two only disagree on needles beginning or ending in a bare
    /// combining mark or a zero-width joiner, where the consequence is one guard
    /// too few and so a looser match. Erring loose is the documented direction.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Rewrite every match in `text`, preserving each occurrence's leading capital.
    ///
    /// Walks the match list rather than using `stringByReplacingMatches`: the
    /// template form would read `$1`-style escapes out of what the user typed, and
    /// it has no hook for deciding the replacement's case per occurrence.
    private static func replacingMatches(
        of matcher: NSRegularExpression,
        in text: String,
        with replacement: String,
        liftingCapital: Bool
    ) -> (text: String, count: Int) {
        // `NSString` throughout, because `NSRegularExpression` reports UTF-16
        // offsets and converting each one to a `String.Index` costs more than it
        // buys here.
        let source = text as NSString
        let matches = matcher.matches(
            in: text,
            range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return (text, 0) }

        var result = ""
        result.reserveCapacity(source.length)
        var cursor = 0

        for match in matches {
            // Matches arrive in order and never overlap, so this copies the run
            // between the previous match and this one, then the replacement. The
            // `max` only guards against a negative length reaching `NSRange`.
            let gap = NSRange(location: cursor, length: max(0, match.range.location - cursor))
            result += source.substring(with: gap)
            result += liftingCapital
                ? capitalisationMatched(replacement, to: source.substring(with: match.range))
                : replacement
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)

        return (result, matches.count)
    }

    /// `replacement`, capitalised if the occurrence it replaces was and it wasn't.
    ///
    /// Corrections get typed in lower case — a user fixing "sonics" types "soniox"
    /// once and expects the sentence-initial "Sonics" to become "Soniox", not
    /// "soniox". The rule is deliberately narrow in three directions:
    ///
    /// - Only the **first** character is considered, so "the meeting" →
    ///   "the standup" doesn't get spuriously capitalised mid-sentence.
    /// - Only when the replacement is *lower* case, so a replacement the user
    ///   capitalised on purpose ("Soniox") is never lower-cased to match a
    ///   lower-case occurrence.
    /// - Only when the **needle** was typed lower case, which is the caller's
    ///   `liftingCapital` gate. A capital is only informative when it is more than
    ///   the user asked for. Correcting "AI" → "artificial intelligence" matches
    ///   an occurrence that is capitalised *because the needle is* — reading that
    ///   as a sentence capital produced "The Artificial intelligence said…"
    ///   mid-sentence, which is how this gate came to exist.
    ///
    /// All-caps occurrences are **not** mirrored: "SONICS" becomes "Soniox", not
    /// "SONIOX". Detecting an intentional shout is unreliable — single-letter and
    /// acronym matches ("I", "AI", "OK") are indistinguishable from it — and
    /// guessing wrong rewrites text the user didn't ask about.
    private static func capitalisationMatched(_ replacement: String, to matched: String) -> String {
        guard let matchedFirst = matched.first, matchedFirst.isUppercase,
              let replacementFirst = replacement.first, replacementFirst.isLowercase
        else { return replacement }
        return replacementFirst.uppercased() + replacement.dropFirst()
    }
}
