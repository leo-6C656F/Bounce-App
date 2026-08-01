import Foundation
import FoundationModels

/// Splits a transcript into named chapters, on device.
///
/// The chaptered transcript view needs somewhere to put its headings, and a
/// transcript carries no structure of its own — `Transcript.blocks` groups by
/// time and speaker, which is a *reading* rhythm, not a set of topics. So this
/// asks the on-device model to name the topics and say where each starts.
///
/// Runs inside `AutoOrganizer.process`, serialised behind the transcription
/// queue with every other model job. Every guard here exits silently: no Apple
/// Intelligence, too short a recording, or a model answer that can't be parsed
/// all leave `Recording.chapters` nil, and the transcript falls back to flat
/// blocks — which is the view it had before this existed, so absence costs
/// nothing.
@MainActor
final class ChapterGenerator {

    static let shared = ChapterGenerator()

    private let model = SystemLanguageModel.default

    private init() {}

    /// Below this there is nothing to chapter — a 40-second note has one topic,
    /// and headings over it are noise pretending to be structure.
    static let minimumDuration: TimeInterval = 120
    static let minimumCharacters = 500

    /// The context window is ~4k tokens shared across instructions, question and
    /// answer, and the timecoded form is bulkier than plain text. Capped well
    /// under the Q&A budget for that reason.
    private static let maxTranscriptChars = 7_000

    /// A model answer is only useful if it produces at least this many sections;
    /// one chapter is the same as none.
    private static let minimumChapters = 2
    private static let maximumChapters = 8

    /// How far a returned timecode may be from a real phrase boundary before it
    /// is treated as invented rather than approximate.
    private static let snapTolerance: TimeInterval = 30

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    // MARK: - Generation

    @Generable
    struct Draft {
        @Guide(description: "Three or four words naming what this stretch of the conversation is about. Sentence case, no trailing punctuation, no numbering.")
        let title: String
        @Guide(description: "The timecode this section starts at, copied exactly from one of the [m:ss] markers in the transcript.")
        let start: String
    }

    @Generable
    struct DraftList {
        @Guide(description: "The sections of the conversation, in the order they occur, between two and eight of them.")
        let chapters: [Draft]
    }

    /// Chapters for this transcript, or nil when the recording shouldn't or
    /// can't be chaptered.
    func chapters(for transcript: Transcript, duration: TimeInterval) async -> [TranscriptChapter]? {
        guard isAvailable else { return nil }
        guard !transcript.isLivePreview else { return nil }
        guard duration >= Self.minimumDuration else { return nil }

        let blocks = transcript.blocks()
        guard blocks.count >= Self.minimumChapters else { return nil }

        let timecoded = Self.cap(Self.timecodedForChaptering(blocks))
        guard timecoded.count >= Self.minimumCharacters else { return nil }

        let instructions = """
        You divide a transcript of one recording into a small number of sections, \
        so a reader can jump to the part they want.

        Rules:
        - Between \(Self.minimumChapters) and \(Self.maximumChapters) sections, whatever the length.
        - A section is a topic, not a speaker turn. Do not start a new one every time \
        the speaker changes.
        - Each section's start must be copied from one of the [m:ss] markers below. \
        Never invent a timecode.
        - Sections must be in order and must not repeat a timecode.
        - Title each one in three or four words describing what is discussed.

        TRANSCRIPT:
        \(timecoded)
        """

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: "List the sections of this recording.",
                generating: DraftList.self)
            return resolve(response.content.chapters, against: transcript, duration: duration)
        } catch {
            TranscribeLog.log("chapters failed: "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            return nil
        }
    }

    // MARK: - Resolution

    /// Turn the model's answer into chapters that actually line up with the
    /// transcript, or nil if too few survive.
    ///
    /// **Every returned timecode is snapped to a real phrase boundary.** The model
    /// is asked to copy a marker and mostly does, but a start that falls in the
    /// middle of a block would render a heading mid-paragraph — so anything that
    /// can't be snapped to a segment within `snapTolerance` is dropped as
    /// invented rather than nudged into place.
    private func resolve(
        _ drafts: [Draft], against transcript: Transcript, duration: TimeInterval
    ) -> [TranscriptChapter]? {
        let starts = transcript.blocks().map(\.start)
        guard !starts.isEmpty else { return nil }

        var resolved: [TranscriptChapter] = []
        for draft in drafts {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            guard let parsed = Self.seconds(fromTimecode: draft.start) else { continue }
            guard let snapped = Self.nearest(parsed, in: starts),
                  abs(snapped - parsed) <= Self.snapTolerance
            else { continue }
            resolved.append(TranscriptChapter(title: title, start: snapped))
        }

        var chapters = resolved.sanitized(duration: duration)
        guard chapters.count >= Self.minimumChapters else { return nil }
        chapters = Array(chapters.prefix(Self.maximumChapters))

        // The first chapter has to own everything before it, or the blocks above
        // it render under no heading at all. Rewriting its start is safer than
        // synthesising an "Introduction" the model didn't name.
        if let first = chapters.first, first.start > 0 {
            chapters[0] = TranscriptChapter(title: first.title, start: 0)
        }
        return chapters
    }

    /// Nearest phrase boundary to `time`, in either direction.
    private static func nearest(_ time: TimeInterval, in starts: [TimeInterval]) -> TimeInterval? {
        starts.min { abs($0 - time) < abs($1 - time) }
    }

    /// `m:ss` or `h:mm:ss`, with or without surrounding brackets and spaces.
    /// Anything else is nil rather than a guess — a misparsed timecode puts a
    /// heading in the wrong place, which is worse than no heading.
    static func seconds(fromTimecode text: String) -> TimeInterval? {
        let cleaned = text
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] \n\t"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + TimeInterval(value)
        }
        // Minutes and seconds must be real clock values, or "1:75" silently
        // becomes 135 seconds and lands a chapter somewhere nobody asked for.
        guard let last = parts.last, let seconds = Int(last), seconds < 60 else { return nil }
        if parts.count == 3, let minutes = Int(parts[1]), minutes >= 60 { return nil }
        return total
    }

    // MARK: - Input

    /// The transcript as `[m:ss] text`, one block per line — the form the
    /// instructions tell the model to copy its timecodes from.
    ///
    /// Speaker labels are left out on purpose: they push the model toward one
    /// section per turn, which is the failure mode the instructions above spend
    /// a bullet arguing against.
    private static func timecodedForChaptering(_ blocks: [TranscriptBlock]) -> String {
        blocks.map { "[\($0.timecode)] \($0.text)" }.joined(separator: "\n")
    }

    /// Head and tail, halves derived rather than hardcoded — same shape and same
    /// reasoning as `AutoOrganizer.cap`.
    private static func cap(_ text: String) -> String {
        guard text.count > maxTranscriptChars else { return text }
        let half = maxTranscriptChars / 2
        let omitted = text.count - 2 * half
        return "\(text.prefix(half))\n\n[… \(omitted) characters omitted …]\n\n\(text.suffix(half))"
    }
}

// MARK: - Slicing a transcript by chapter

extension Transcript {

    /// One chapter's heading and the blocks that fall under it.
    struct ChapteredSection: Identifiable {
        let chapter: TranscriptChapter
        let blocks: [TranscriptBlock]
        /// Where this chapter ends — the next one's start, or the end of the
        /// recording. Derived, never stored; see `TranscriptChapter`.
        let end: TimeInterval

        var id: String { chapter.id }

        var rangeText: String {
            "\(chapter.start.timecodeText) – \(end.timecodeText)"
        }
    }

    /// Group the reading blocks under the supplied chapters.
    ///
    /// Returns nil when there are no chapters, which is the signal to render the
    /// flat block list instead. A chapter that ends up with no blocks is dropped
    /// rather than rendered empty — two chapters snapped to the same block would
    /// otherwise leave a heading with nothing under it.
    func chapteredSections(
        _ chapters: [TranscriptChapter],
        duration: TimeInterval,
        speakerNames: [String: String]? = nil
    ) -> [ChapteredSection]? {
        let ordered = chapters.sanitized(duration: duration)
        guard !ordered.isEmpty else { return nil }
        let blocks = self.blocks(speakerNames: speakerNames)
        guard !blocks.isEmpty else { return nil }

        let lastEnd = max(duration, blocks.last?.start ?? 0)
        var sections: [ChapteredSection] = []
        for (index, chapter) in ordered.enumerated() {
            let next = index + 1 < ordered.count ? ordered[index + 1].start : TimeInterval.infinity
            let slice = blocks.filter { $0.start >= chapter.start && $0.start < next }
            guard !slice.isEmpty else { continue }
            sections.append(ChapteredSection(
                chapter: chapter,
                blocks: slice,
                end: next.isFinite ? next : lastEnd))
        }
        return sections.isEmpty ? nil : sections
    }
}
