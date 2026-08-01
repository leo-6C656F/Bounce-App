import Foundation

/// The JSON shapes the desktop client sees.
///
/// Deliberately *not* `Recording` and `Transcript` straight off the wire, even
/// though both are already `Codable`. Two reasons:
///
/// - **Formatting stays in Swift.** `TimeInterval.timecodeText` is the only
///   timecode formatter in the app, after four divergent copies once made a
///   92-minute recording read "92:14" in four places at once. Sending raw
///   seconds and formatting them in JavaScript would add a fifth. Every
///   user-visible duration here is preformatted.
/// - **Grouping stays in Swift.** `Transcript.blocks(speakerNames:)` decides
///   where blocks break and how a speaker is labelled; the browser renders what
///   it is given rather than reimplementing that.

// MARK: - Transcript

struct WebBlock: Encodable {

    /// One phrase of the block, with the time it began.
    ///
    /// Only `start` is sent, and that is deliberate: the browser picks the most
    /// recent phrase that has *started* rather than the one whose `start..<end`
    /// contains the playhead. Segments don't abut — both Apple's phrase ranges
    /// and Soniox's token spans leave gaps at pauses — so interval matching
    /// unhighlights the paragraph several times per block and reliably at its
    /// tail. `RecordingDetailView` learned this the same way.
    struct Phrase: Encodable {
        let start: TimeInterval
        let text: String
    }

    let id: Int
    let start: TimeInterval
    let timecode: String
    /// Display label — the user's name for the speaker, "Speaker 1", or nil when
    /// the transcript isn't diarized. Already resolved.
    let speaker: String?
    /// Raw diarization id, so the browser can offer to name this speaker.
    let speakerId: String?
    let text: String
    /// The phrases this block was joined from, so the browser can lift the one
    /// being spoken to full contrast as the audio plays — the same
    /// follow-along the phone's detail view does.
    let phrases: [Phrase]

    init(_ block: TranscriptBlock) {
        id = block.id
        start = block.start
        timecode = block.timecode
        speaker = block.speakerLabel
        speakerId = block.speaker
        text = block.text
        phrases = block.segments.map { Phrase(start: $0.start, text: $0.text) }
    }
}

// MARK: - Library

/// One row in the desktop library list. Deliberately excludes transcript text —
/// a library of long meetings would otherwise be megabytes per refresh.
struct WebRecordingRow: Encodable {
    let id: String
    let title: String
    let categoryName: String?
    let createdAt: Date
    let duration: TimeInterval
    let durationText: String
    let isSynced: Bool
    let isTranscribed: Bool
    let isPreview: Bool
    let wordCount: Int
    let summaryCount: Int
    let highlightCount: Int
    let speakerCount: Int
    /// Live transcription status from `TranscriptionCoordinator`, when busy.
    let status: String?

    init(_ recording: Recording, status: String?) {
        id = recording.id
        title = recording.displayTitle
        categoryName = recording.categoryName
        createdAt = recording.createdAt
        duration = recording.duration
        durationText = recording.duration > 0 ? recording.duration.timecodeText : "--:--"
        isSynced = recording.isSynced
        isTranscribed = recording.isTranscribed
        isPreview = recording.transcript?.isLivePreview ?? false
        wordCount = recording.transcript?.wordCount ?? 0
        summaryCount = recording.summaries?.count ?? 0
        highlightCount = recording.highlights?.count ?? 0
        speakerCount = recording.transcript?.speakers.count ?? 0
        self.status = status
    }
}

struct WebRecordingDetail: Encodable {

    struct Highlight: Encodable {
        let seconds: TimeInterval
        let timecode: String
    }

    struct Speaker: Encodable {
        let id: String
        /// "Speaker 1", or the raw label when diarization didn't use integers.
        let label: String
        /// The user's name for them, when set.
        let name: String?
    }

    struct SummaryItem: Encodable {
        let templateId: String
        let templateName: String
        let text: String
        let createdAt: Date
    }

    let id: String
    let title: String
    /// The stored title, which may be the "Untitled Recording" sentinel — the
    /// edit field needs this rather than the derived `displayTitle`, or editing
    /// an untitled recording silently adopts the first words of its transcript.
    let rawTitle: String
    let categoryName: String?
    let createdAt: Date
    let syncedAt: Date?
    let duration: TimeInterval
    let durationText: String
    let deviceSN: String
    let isSynced: Bool
    let hasAudio: Bool

    let blocks: [WebBlock]
    let plainText: String
    let localeIdentifier: String?
    let isPreview: Bool
    let wordCount: Int
    /// Diarization ids in order of first appearance, for the naming UI.
    /// Diarization ids in order of first appearance, each with the label the
    /// transcript renders for it.
    ///
    /// The label is resolved here rather than in the browser for the same reason
    /// timecodes are: `TranscriptBlock.speakerLabel` only prefixes "Speaker "
    /// when the id parses as an integer, so a client that hardcoded
    /// `"Speaker " + id` would show "spk_a" in the transcript and "Speaker spk_a"
    /// in the naming row beside it.
    let speakers: [Speaker]
    let speakerNames: [String: String]
    /// The archived live draft, shown collapsed — kept rather than discarded so
    /// the first pass can still be referred back to.
    let livePreviewText: String?
    let highlights: [Highlight]
    let summaries: [SummaryItem]
    /// Tags, resolved to names here rather than shipped as ids: `Recording.tagIds`
    /// stores `RecordingCategory.id`, which is meaningless to a client that has no
    /// way to resolve it, and making the browser fetch `/api/categories` to render
    /// a chip would be a round trip for nothing.
    let tags: [Tag]
    /// Action items. Present because the MCP tools already expose them, and a
    /// surface where an agent can read something the browser can't is a surprise
    /// waiting to happen — the two clients should see the same recording.
    let actionItems: [Task]

    struct Tag: Codable, Hashable {
        let id: String
        let name: String
    }

    struct Task: Codable, Hashable {
        let id: String
        let text: String
        let owner: String?
        /// The deadline **as spoken** ("by Friday"), not a date. See `ActionItem`.
        let dueText: String?
        let isDone: Bool
        let sourceOffset: TimeInterval?
    }

    /// `@MainActor` because resolving tag ids reads `CategoryStore`, which is
    /// main-actor isolated. That costs nothing: `WebAPI`'s header rule is that every
    /// handler runs on the main actor and hops once at the edge, and `RecordingStore`
    /// — read two lines below — has no lock and would race off it anyway.
    @MainActor
    init(_ recording: Recording) {
        id = recording.id
        title = recording.displayTitle
        rawTitle = recording.title
        categoryName = recording.categoryName
        createdAt = recording.createdAt
        syncedAt = recording.syncedAt
        duration = recording.duration
        durationText = recording.duration > 0 ? recording.duration.timecodeText : "--:--"
        deviceSN = recording.deviceSN
        isSynced = recording.isSynced
        hasAudio = RecordingStore.shared.audioURL(for: recording) != nil

        let transcript = recording.transcript
        blocks = (transcript?.blocks(speakerNames: recording.speakerNames) ?? []).map(WebBlock.init)
        plainText = transcript?.plainText ?? ""
        localeIdentifier = transcript?.localeIdentifier
        isPreview = transcript?.isLivePreview ?? false
        wordCount = transcript?.wordCount ?? 0
        let names = recording.speakerNames ?? [:]
        speakers = (transcript?.speakers ?? []).map { id in
            // Route through the same `speakerLabel` the transcript uses, by
            // building a one-segment block, so the two can't drift.
            let label = TranscriptBlock(
                id: 0, speaker: id, name: nil, start: 0, text: "", segments: []
            ).speakerLabel ?? id
            return Speaker(id: id, label: label, name: names[id])
        }
        speakerNames = names
        livePreviewText = recording.livePreview?.plainText

        highlights = (recording.highlights ?? []).map {
            Highlight(seconds: $0, timecode: $0.timecodeText)
        }
        summaries = (recording.summaries ?? []).map {
            SummaryItem(
                templateId: $0.templateId,
                templateName: $0.templateName,
                text: $0.text,
                createdAt: $0.createdAt)
        }
        // Dangling ids are dropped rather than rendered as blanks — the same choice
        // `AppModel.tags(for:)` makes. `CategoryStore.remove` sweeps them, so one
        // surviving here means something went wrong.
        let categories = CategoryStore.shared.categories
        tags = (recording.tagIds ?? []).compactMap { id in
            categories.first { $0.id == id }.map { Tag(id: $0.id, name: $0.name) }
        }
        actionItems = (recording.actionItems ?? []).map {
            Task(
                id: $0.id,
                text: $0.text,
                owner: $0.owner,
                dueText: $0.dueText,
                isDone: $0.isDone,
                sourceOffset: $0.sourceOffset)
        }
    }
}

// MARK: - Organizing

struct WebCategory: Encodable {
    let id: String
    let name: String
    let colorName: String?
    let symbolName: String?

    init(_ category: RecordingCategory) {
        id = category.id
        name = category.name
        colorName = category.colorName
        symbolName = category.symbolName
    }
}

struct WebTemplate: Encodable {
    let id: String
    let name: String
    let isBuiltIn: Bool

    init(_ template: SummaryTemplate) {
        id = template.id
        name = template.name
        isBuiltIn = template.isBuiltIn
    }
}
