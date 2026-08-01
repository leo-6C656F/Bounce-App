import Foundation

/// Renders a recording as a Markdown note with YAML frontmatter — the shape an
/// Obsidian or Logseq vault expects, so the existing folder destination drops
/// files straight into one.
///
/// Pure, and Foundation-only on purpose: `Recording` in, `String` out, touching
/// no store, no settings and no main actor. That is what lets it be compiled and
/// exercised standalone on the Mac (`tools/markdown-export-tests/main.swift`),
/// which is the only automatable coverage this feature can have — there is no
/// test target.
///
/// Two entry points, and they are not equivalent:
///
/// - `render(_ recording:speakerNames:)` is the real one. It is the only one that
///   can fill the frontmatter, because title, date, duration and category live on
///   the `Recording`, not on the `Transcript`.
/// - `render(_ transcript:speakerNames:)` renders the transcript body alone, for
///   the `TranscriptFormat.render(_ transcript:speakerNames:)` branch, which is
///   handed a bare transcript and has nothing to put in a frontmatter block.
///
/// Timecodes come from `TimeInterval.timecodeText` throughout. There is exactly
/// one timecode formatter in this app and this is not a second one.
enum MarkdownTranscript {

    // MARK: - Entry points

    /// A complete note: frontmatter, summaries, transcript.
    static func render(_ recording: Recording, speakerNames: [String: String]? = nil) -> String {
        let blocks = recording.transcript?.blocks(speakerNames: speakerNames) ?? []

        var chunks = [frontmatter(for: recording, speakerLabels: speakerLabels(in: blocks))]

        if let summaries = recording.summaries {
            let section = summarySection(summaries)
            if !section.isEmpty { chunks.append(section) }
        }

        // Phase 2 (action items) slots in here: a `## Action items` section of
        // `- [ ]` / `- [x]` lines built from `recording.actionItems`, after the
        // summaries and before the transcript. Each item's text is speech-derived
        // and so must go through `escapedBodyLine` like transcript text does.

        if !blocks.isEmpty { chunks.append(transcriptSection(blocks)) }

        return chunks.joined(separator: "\n\n") + "\n"
    }

    /// The transcript body only — no frontmatter, since a bare `Transcript`
    /// carries none of the metadata that would go in one.
    static func render(_ transcript: Transcript, speakerNames: [String: String]? = nil) -> String {
        let blocks = transcript.blocks(speakerNames: speakerNames)
        guard !blocks.isEmpty else { return "" }
        return transcriptSection(blocks) + "\n"
    }

    // MARK: - Frontmatter

    /// Keys whose value is absent are omitted rather than emitted empty: an
    /// Obsidian property with a blank value shows up in the vault's property
    /// index as a real, empty property, which is worse than no property.
    private static func frontmatter(for recording: Recording, speakerLabels: [String]) -> String {
        var lines = ["---"]

        func put(_ key: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            lines.append("\(key): \(yamlString(value))")
        }

        put("title", trimmed(recording.displayTitle))
        put("date", iso8601String(recording.createdAt))
        put("duration", recording.duration > 0 ? recording.duration.timecodeText : nil)
        put("category", recording.categoryName.map(trimmed))

        // Phase 6 (tags) slots in here: a `tags:` sequence of the recording's tag
        // names, emitted exactly like `speakers` below — every element through
        // `yamlString`, since a tag name is user-typed.

        if !speakerLabels.isEmpty {
            lines.append("speakers:")
            lines.append(contentsOf: speakerLabels.map { "  - \(yamlString($0))" })
        }

        put("source", "bounce")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// A YAML double-quoted scalar, **always** quoted.
    ///
    /// Unconditional quoting rather than "quote when it looks like it needs it",
    /// because the list of values that need it is longer than it appears and
    /// getting it wrong is silent. A title routinely contains a colon ("Meeting:
    /// Budget review"), which ends the key. A `#` starts a comment. A title that
    /// is entirely digits, or `true`, or `null`, decodes as a number, a bool or
    /// nil rather than a string. And a duration like `1:02:14` is a *sexagesimal
    /// integer* in YAML 1.1 — it would come back as `3734`. Quoting everything
    /// removes the whole class of judgement call; the cost is a few quote marks
    /// in the raw file.
    ///
    /// Escapes are the double-quoted YAML set, so the value round-trips exactly,
    /// including embedded quotes, backslashes, newlines and edge whitespace.
    private static func yamlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Summaries

    private static func summarySection(_ summaries: [Summary]) -> String {
        var parts: [String] = []
        for summary in summaries {
            let text = trimmed(summary.text)
            guard !text.isEmpty else { continue }
            let name = trimmed(summary.templateName)
            let heading = name.isEmpty ? "### Summary" : "### \(escapedInline(name))"
            // Summary text is passed through verbatim. It comes out of the
            // on-device model as Markdown-ish prose, and escaping line starts
            // here would break exactly the bullet lists that make it useful in a
            // vault. It sits after the closing `---`, so a horizontal rule inside
            // it is a horizontal rule, not a delimiter.
            parts.append("\(heading)\n\n\(text)")
        }
        guard !parts.isEmpty else { return "" }
        return (["## Summary"] + parts).joined(separator: "\n\n")
    }

    // MARK: - Transcript

    private static func transcriptSection(_ blocks: [TranscriptBlock]) -> String {
        var parts = ["## Transcript"]
        for block in blocks {
            let heading = block.speakerLabel
                .map { "**\(escapedInline($0))** (\(block.timecode))" }
                ?? "(\(block.timecode))"
            let body = block.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { escapedBodyLine(String($0)) }
                .joined(separator: "\n")
            parts.append(trimmed(body).isEmpty ? heading : "\(heading)\n\(body)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Distinct speaker display names in order of first appearance, taken from
    /// the blocks so the "Speaker 1" fallback stays defined in exactly one place
    /// (`TranscriptBlock.speakerLabel`).
    private static func speakerLabels(in blocks: [TranscriptBlock]) -> [String] {
        var seen = Set<String>()
        return blocks.compactMap { block in
            guard let label = block.speakerLabel, seen.insert(label).inserted else { return nil }
            return label
        }
    }

    // MARK: - Markdown escaping

    /// Characters that mean something structural at the start of a line: ATX
    /// headings, thematic breaks, setext underlines, list bullets, blockquotes.
    private static let lineStarters: Set<Character> = ["#", "-", "*", "_", "=", "+", ">", "~"]

    /// Neutralise Markdown block structure at the start of a line of speech.
    ///
    /// The one that actually breaks notes is `---`. A transcript line starting
    /// with it reads as a frontmatter delimiter to a lenient parser, and as a
    /// *setext underline* to every parser — which silently promotes the line
    /// above it to a heading, so a sentence of speech becomes a section title. A
    /// line starting `#` becomes a heading outright and corrupts the note's
    /// outline.
    ///
    /// Escaping the first character fixes both: `\-` and `\#` are ASCII
    /// punctuation escapes, so CommonMark renders them as the bare character with
    /// no structural meaning. Leading whitespace is dropped rather than escaped,
    /// because four spaces would make the line an indented code block.
    private static func escapedBodyLine(_ line: String) -> String {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard let first = line.first, lineStarters.contains(first) else { return line }
        return "\\" + line
    }

    /// Escape the inline emphasis characters in a user-typed name, so a speaker
    /// called "A*B" can't unbalance the `**bold**` it sits inside.
    private static func escapedInline(_ text: String) -> String {
        var out = ""
        for character in text {
            if character == "\\" || character == "*" || character == "_" || character == "`" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    // MARK: - Small helpers

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// UTC, matching the webhook metadata's `JSONEncoder.iso8601`, so the two
    /// payloads never disagree about when a recording happened. Built per call
    /// rather than held in a `static let`, following `JSONEncoder.iso8601`'s own
    /// pattern — it runs once per delivery.
    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
