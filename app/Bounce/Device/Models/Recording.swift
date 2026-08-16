import Foundation

extension TimeInterval {
    /// `h:mm:ss` past the hour, `m:ss` below it.
    ///
    /// One definition, because there were four, all of them `m:ss` only — so a
    /// 92-minute meeting rendered as "92:14" in the transcript, the player and
    /// the highlight chips alike.
    var timecodeText: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(rounded(.down))
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// The same instant, spoken. **Not** a second display formatter — the rule
    /// above is about what's drawn on screen, and this is never drawn.
    ///
    /// VoiceOver reads `timecodeText` character by character ("zero colon
    /// one two"), which is unusable as a position in a recording. This is what
    /// `accessibilityLabel` uses; keep the two side by side so it's obvious
    /// why there are two and neither gets deleted as a duplicate.
    var spokenTimecode: String {
        guard isFinite, self >= 0 else { return "0 seconds" }
        let total = Int(rounded(.down))
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        // Suppress a bare "0 seconds" only when something larger was said.
        if seconds > 0 || parts.isEmpty {
            parts.append("\(seconds) second\(seconds == 1 ? "" : "s")")
        }
        return parts.joined(separator: " ")
    }
}

/// One phrase of transcribed speech, timed against the source audio.
///
/// Produced by `LocalTranscriber` from a `SpeechTranscriber.Result`; `start`
/// and `end` are seconds into the recording, which is what the player needs
/// for tap-to-seek.
struct TranscriptSegment: Codable, Hashable, Identifiable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    /// Speaker label when the engine diarizes (Soniox); nil for the on-device
    /// engine, which doesn't separate speakers. Optional so older transcripts
    /// still decode.
    var speaker: String?

    init(text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }

    var id: String { "\(start)-\(end)" }

    var timecode: String { start.timecodeText }
}

/// A run of transcript grouped for reading: roughly a minute of speech, broken
/// early whenever the speaker changes (so each block is one speaker). This is a
/// display grouping over `TranscriptSegment`s — the segments keep their own
/// timings for tap-to-seek.
struct TranscriptBlock: Identifiable {
    let id: Int
    let speaker: String?
    /// User-assigned display name for the speaker, when one is stored on the
    /// recording (see `Recording.speakerNames`).
    let name: String?
    let start: TimeInterval
    let text: String
    /// The phrases this block was joined from, kept so the detail view can
    /// highlight the one under the playhead rather than the whole minute. The
    /// grouping is for reading; the timings stay per phrase.
    let segments: [TranscriptSegment]

    var timecode: String { start.timecodeText }

    /// The user's name for the speaker, a "Speaker 1"-style fallback, or nil
    /// when the transcript isn't diarized.
    var speakerLabel: String? {
        if let name, !name.isEmpty { return name }
        guard let speaker, !speaker.isEmpty else { return nil }
        // Soniox returns bare ids like "1"; make them read as "Speaker 1".
        return Int(speaker) != nil ? "Speaker \(speaker)" : speaker
    }
}

/// A completed on-device transcription.
struct Transcript: Codable, Hashable {
    let segments: [TranscriptSegment]
    /// BCP-47 identifier of the locale actually used, e.g. "en-US".
    let localeIdentifier: String
    let createdAt: Date

    /// True when this came from the live Bluetooth stream rather than the
    /// complete audio file. A preview is lossier, and is deliberately replaced
    /// by the post-sync pass — `TranscriptionCoordinator` treats a preview as
    /// "still needs transcribing".
    ///
    /// Optional rather than defaulted: Swift's synthesised `Decodable` requires
    /// every non-optional key to be present, so a plain `Bool = false` would fail
    /// to decode transcripts written before this field existed and take the whole
    /// library with it.
    var isPreview: Bool?

    var isLivePreview: Bool { isPreview == true }

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Timestamped form, grouped into ~minute/speaker blocks, for pasting into
    /// notes or sending to a webhook.
    var timecodedText: String { timecodedText(speakerNames: nil) }

    /// Timestamped form with the user's speaker names applied — pass
    /// `Recording.speakerNames` so exports read "Leo:" rather than "Speaker 1:".
    func timecodedText(speakerNames: [String: String]?) -> String {
        blocks(speakerNames: speakerNames).map { block in
            if let speaker = block.speakerLabel {
                return "[\(block.timecode)] \(speaker): \(block.text)"
            }
            return "[\(block.timecode)] \(block.text)"
        }.joined(separator: "\n")
    }

    var wordCount: Int {
        plainText.split { $0 == " " || $0.isNewline }.count
    }

    /// Whether any segment carries a speaker label (i.e. it was diarized).
    var hasSpeakers: Bool { segments.contains { $0.speaker != nil } }

    /// Distinct speaker ids in order of first appearance, for the naming UI.
    var speakers: [String] {
        var seen = Set<String>()
        return segments.compactMap { segment in
            guard let speaker = segment.speaker, seen.insert(speaker).inserted else { return nil }
            return speaker
        }
    }

    /// Group the segments for reading: roughly `grouping.maxDuration` seconds
    /// per block, broken early whenever the speaker changes so each block is one
    /// speaker. `speakerNames` maps diarized ids ("1") to display names.
    func blocks(
        _ grouping: BlockGrouping = .reading,
        speakerNames: [String: String]? = nil
    ) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var current: [TranscriptSegment] = []
        var blockStart: TimeInterval = 0
        var blockEnd: TimeInterval = 0
        var blockSpeaker: String?

        func flush() {
            guard let first = current.first else { return }
            blocks.append(TranscriptBlock(
                id: blocks.count,
                speaker: blockSpeaker,
                name: blockSpeaker.flatMap { speakerNames?[$0] },
                start: first.start,
                text: current.map(\.text).joined(separator: " "),
                segments: current))
            current = []
        }

        for segment in segments {
            let speakerChanged = !current.isEmpty && segment.speaker != blockSpeaker
            let overLength = !current.isEmpty && (segment.end - blockStart) >= grouping.maxDuration
            // A pause long enough to be a turn in the conversation. Engine-
            // agnostic on purpose: Soniox's `<end>` marker is a crisper
            // boundary, but the on-device engine has no equivalent, and live
            // grouping must not look structurally different depending on which
            // engine is selected.
            let afterPause = if let maxGap = grouping.maxGap, !current.isEmpty {
                (segment.start - blockEnd) >= maxGap
            } else {
                false
            }
            if speakerChanged || overLength || afterPause { flush() }
            if current.isEmpty {
                blockStart = segment.start
                blockSpeaker = segment.speaker
            }
            blockEnd = max(blockEnd, segment.end)
            current.append(segment)
        }
        flush()
        return blocks
    }
}

/// How `Transcript.blocks` breaks a transcript into readable blocks.
///
/// Two presets rather than loose parameters, because the live screen and the
/// detail screen want different cadences and the difference should be named
/// somewhere rather than re-derived at each call site.
struct BlockGrouping: Hashable {
    /// Hard cap on a block's span, so one uninterrupted speaker still gets
    /// paragraphs.
    var maxDuration: TimeInterval
    /// Silence between phrases that ends a block, or nil to ignore pauses.
    var maxGap: TimeInterval?

    /// The detail view, exports and the web client. Deliberately identical to
    /// the pre-`BlockGrouping` behaviour — no pause splitting — so adopting this
    /// type changed no stored or delivered output.
    static let reading = BlockGrouping(maxDuration: 60, maxGap: nil)

    /// The live screen. Shorter blocks and pause splitting, because text is
    /// arriving and a minute-long paragraph growing at its tail is unreadable.
    /// Both numbers are judgement calls pending a real two-speaker recording.
    static let live = BlockGrouping(maxDuration: 30, maxGap: 2.0)
}

/// A named span of a recording, written by `ChapterGenerator` from the
/// transcript. Drives the chaptered transcript view and its jump chips.
///
/// **Only a start.** A chapter's end is the next chapter's start, or the
/// recording's duration for the last one — deriving it means the two can never
/// disagree, which a stored `end` would eventually manage after a re-transcribe
/// or an audio edit shifted the timeline.
struct TranscriptChapter: Codable, Hashable, Identifiable {
    /// Three or four words, sentence case — see `ChapterGenerator`.
    let title: String
    /// Seconds into the recording.
    let start: TimeInterval

    /// Composite rather than the title alone: two chapters can legitimately
    /// share a title in a long recording, and a duplicate `id` makes `ForEach`
    /// diffing undefined — the same failure the Soniox control-token bug caused.
    var id: String { "\(start)-\(title)" }

    var timecode: String { start.timecodeText }
}

extension Array where Element == TranscriptChapter {
    /// The chapters, sorted and de-duplicated, with anything out of range
    /// dropped. Applied on read rather than on write so a stored list from an
    /// older or sloppier pass still renders sensibly.
    func sanitized(duration: TimeInterval) -> [TranscriptChapter] {
        var seen = Set<TimeInterval>()
        return filter { chapter in
            guard chapter.start >= 0, !chapter.title.isEmpty else { return false }
            // A zero duration means "unknown", not "empty" — `Recording.duration`
            // is 0 until the file lands, and dropping every chapter then would
            // make them vanish on a recording that is still syncing.
            guard duration <= 0 || chapter.start < duration else { return false }
            return seen.insert(chapter.start).inserted
        }
        .sorted { $0.start < $1.start }
    }
}

/// One source recording folded into a merged one, and where it landed on the
/// merged timeline.
///
/// Recorded so a merged recording can say what it is made of, and so the
/// transcript can show the seams. A part is a *description of a span*, not a
/// link: merging copies the audio, and the sources are usually deleted
/// afterwards, so anything resolved lazily through an id would dangle. The title
/// and date are therefore snapshots, kept verbatim.
struct RecordingPart: Codable, Hashable, Identifiable {
    /// The source's recorder-side session id, which is also its start timestamp.
    /// Stored rather than `Recording.id` because it is the handle that appears in
    /// logs and on the device, and it stays meaningful after the source row is
    /// gone.
    let sessionId: Int
    /// The source's title at the moment of the merge.
    let title: String
    /// Where this part begins on the merged recording's timeline.
    let start: TimeInterval
    /// How much of the merged recording this part accounts for. Taken from the
    /// frames actually written, so it can differ from the source's stored
    /// `duration` by up to a frame.
    let duration: TimeInterval
    /// When the source was recorded.
    let recordedAt: Date

    init(
        sessionId: Int,
        title: String,
        start: TimeInterval,
        duration: TimeInterval,
        recordedAt: Date
    ) {
        self.sessionId = sessionId
        self.title = title
        self.start = start
        self.duration = duration
        self.recordedAt = recordedAt
    }

    /// Composite for the same reason `TranscriptChapter.id` is: two parts can
    /// share a session id only if something has gone wrong, but a duplicate id
    /// makes `ForEach` diffing undefined and the failure is silent.
    var id: String { "\(sessionId)-\(start)" }
}

/// An AI summary produced by running a template over a recording's transcript.
/// Keyed by the template so re-running that template replaces it rather than
/// piling up.
struct Summary: Codable, Hashable, Identifiable {
    let templateId: String
    var templateName: String
    var text: String
    var createdAt: Date

    var id: String { templateId }
}

/// A recording that lives on this iPhone.
///
/// `audioFilename` is stored **relative** to the Documents directory on
/// purpose: the sandbox container path changes between installs and OS
/// upgrades, so an absolute path goes stale. Resolve through
/// `RecordingStore.audioURL(for:)`.
struct Recording: Identifiable, Codable, Hashable {
    let id: String
    /// Recorder-side session id, which is also the start timestamp.
    let sessionId: Int
    let deviceSN: String
    var title: String
    var duration: TimeInterval
    let createdAt: Date
    var syncedAt: Date?
    var audioFilename: String?
    var transcript: Transcript?
    /// The live-while-recording transcript, kept after the authoritative post-sync
    /// pass replaces it as `transcript`. Retained rather than discarded so the
    /// first-draft can be compared or referred back to. Optional and absent on
    /// recordings that were never live-transcribed or predate this field.
    var livePreview: Transcript?
    /// Seconds-into-the-recording marks the user flagged live with the Highlight
    /// button. Optional/absent on recordings made before the feature or never
    /// highlighted. Tap one in the detail view to seek there.
    var highlights: [TimeInterval]?
    /// AI summaries, one per template the user has run. Re-running a template
    /// replaces its entry. Optional/absent for recordings never summarized.
    var summaries: [Summary]?
    /// User-assigned names for diarized speakers, keyed by the engine's speaker
    /// id ("1" → "Leo"). Per recording on purpose: Soniox's labels aren't stable
    /// across recordings, so there is no identity to attach a name to globally.
    /// Optional so older libraries still decode.
    var speakerNames: [String: String]?
    /// The category the auto-organize pass assigned ("Meeting") — the name of a
    /// `RecordingCategory` at the time it ran. Optional so older libraries
    /// decode; nil when the pass hasn't run, was off, or didn't match.
    var categoryName: String?
    /// Tasks extracted from the transcript by the auto-organize pass, plus any the
    /// user added by hand. Optional so older libraries decode.
    ///
    /// Re-running extraction **merges** on normalised text rather than replacing,
    /// so an item the user ticked off is never resurrected — see `ActionItemMerge`.
    var actionItems: [ActionItem]?
    /// User-applied tags, as `RecordingCategory.id` values — **ids, not names.**
    ///
    /// Deliberately different from `categoryName` above, which stores a name and
    /// therefore silently detaches every recording tagged with a category the user
    /// later renames. Storing ids here means a rename keeps the tag attached.
    ///
    /// Additive to `categoryName`, not a replacement: category stays singular and
    /// AI-assigned, tags are plural and user-applied. Deleting a tag must sweep
    /// its id out of every recording, or the library fills with ids that render as
    /// nothing and can't be cleared.
    var tagIds: [String]?
    /// Title of the calendar event this recording overlapped, if any. Recorded so
    /// the detail view can show where a calendar-derived title came from.
    var calendarEventTitle: String?
    /// Display names of that event's attendees, used to seed speaker naming.
    ///
    /// **Personal data.** It stays in `library.json` with everything else, is never
    /// logged, and must not be added to the webhook payload without a settings
    /// toggle — that payload's shape is a contract for whatever the user has wired
    /// downstream.
    var calendarAttendees: [String]?
    /// Whether the user has taken manual control of this recording's calendar
    /// meeting link — by picking a meeting, or by clearing one — via the detail
    /// view's Meeting card.
    ///
    /// **The stickiness guarantee.** When true, `AutoOrganizer` must never write
    /// any calendar-derived field (`calendarEventTitle`, `calendarAttendees`, a
    /// calendar-sourced `seriesId` or `place`, or a calendar-sourced title): the
    /// user's choice outranks whatever a re-transcribe would match, so a manual
    /// link — or a deliberate unlink — survives every later pass. Without it a
    /// re-transcribe silently re-guessed the link, which is why a correct manual
    /// pick previously didn't stick.
    ///
    /// Optional for the usual decode-compat reason; `nil` and `false` both mean
    /// "auto is free to fill this in".
    var calendarLinkConfirmed: Bool?
    /// The meeting agenda the user typed for this recording, if any.
    ///
    /// Optional for the same reason as every other field added after v1 — see
    /// `deliveredToRaw` below. `nil` and "an agenda with no items" are the same
    /// thing to the UI, and `nil` is the representation written for both.
    var agenda: MeetingAgenda?
    /// Where this was recorded, when Bounce could work that out.
    ///
    /// Optional for the usual decode-compat reason, and also because "no
    /// location" is the honest answer far more often than not: a Plaud records
    /// standalone, so unless the phone was in range at the time — or the
    /// recording matched a calendar event with coordinates — there is nothing
    /// trustworthy to store. `RecordingPlace.source` records *which* of those it
    /// was; see that type. Never write a place without checking
    /// `shouldBeReplaced(by:)` first, or a weak sync-time fix will overwrite a
    /// good one on the next pass.
    ///
    /// **Personal data**, in the same class as `calendarAttendees`: it stays in
    /// `library.json`, is never logged, and must not be added to the webhook
    /// payload without its own settings toggle.
    var place: RecordingPlace?
    /// The `MeetingSeries` this recording belongs to, by **id**.
    ///
    /// An id rather than a name — the same choice `tagIds` makes and the opposite
    /// of `categoryName` — so renaming a series keeps every session attached to
    /// it. Deleting a series must sweep this out of every recording, or the
    /// library fills with ids that resolve to nothing and can't be cleared.
    var seriesId: String?
    /// Named spans of the transcript, written by `ChapterGenerator` during the
    /// auto-organize pass. Drives the chaptered transcript and its jump chips.
    ///
    /// Optional for the usual decode-compat reason, and absent is a real state
    /// worth distinguishing: a recording too short to chapter, one transcribed
    /// before this existed, or a device with no Apple Intelligence all have no
    /// chapters, and the transcript falls back to flat blocks for all three.
    var chapters: [TranscriptChapter]?
    /// "What's changed since the last session", written by `SeriesContinuity`
    /// from the series' carry-forward digest plus this transcript.
    ///
    /// Stored on the recording rather than as a `Summary`, because it isn't one:
    /// a summary is derived from this recording alone and can be regenerated from
    /// it, while this depends on every session before it and cannot. Absent on a
    /// recording that opened a series, arrived out of order, or was never in one.
    var seriesRecap: String?
    /// The recordings this one was merged from, in order, or nil when it wasn't
    /// merged.
    ///
    /// Present on a recording produced by `RecordingMerge` — which is how a
    /// session split across several files (a pause the recorder handled by
    /// closing the file, or a continuation linked while recording) becomes one
    /// transcript. Absent on everything else, including a recording that merely
    /// *was* a part: merging copies audio forward and never writes back to its
    /// sources.
    ///
    /// Optional for the usual decode-compat reason. It also drives one behaviour
    /// worth knowing about: `AutoOrganizer` leaves `chapters` alone when this is
    /// set, because the seams between parts are better headings than anything the
    /// model would invent, and regenerating would erase them.
    var parts: [RecordingPart]?
    /// Backing store for `deliveredTo`. **Optional, and that is not cosmetic.**
    ///
    /// This was `var deliveredTo: [String] = []`, and a default value does **not**
    /// make Swift's synthesised `Decodable` tolerate a missing key — the default
    /// applies to the memberwise initialiser only, while `init(from:)` still calls
    /// `decode(_:forKey:)` and throws `keyNotFound`. So every `library.json`
    /// written before this field existed failed to decode *in its entirety*,
    /// because `RecordingStore.load` decodes the whole array in one call.
    ///
    /// Optional properties are the only shape synthesis decodes with
    /// `decodeIfPresent`. The `CodingKeys` below map this back to `"deliveredTo"`
    /// so libraries that *do* carry the key keep their data.
    ///
    /// Caught by `tools/library-decode-tests/main.swift`, which is the regression
    /// gate for this whole class of bug.
    private var deliveredToRaw: [String]?

    /// Destination ids this recording has already been delivered to.
    ///
    /// Non-optional at the API surface because five call sites read and mutate it
    /// as a plain array; the optionality is a storage detail.
    var deliveredTo: [String] {
        get { deliveredToRaw ?? [] }
        // Normalised back to nil when empty, so "never delivered" has one
        // representation rather than two that compare unequal.
        set { deliveredToRaw = newValue.isEmpty ? nil : newValue }
    }

    /// Spelled out because `deliveredToRaw` must persist under its original key.
    /// **Every stored property has to be listed here** — add new ones as you add
    /// fields, or they silently stop being saved.
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, deviceSN, title, duration, createdAt, syncedAt
        case audioFilename, transcript, livePreview, highlights, summaries
        case speakerNames, categoryName, actionItems, tagIds
        case calendarEventTitle, calendarAttendees, calendarLinkConfirmed, agenda, place
        case chapters, seriesId, seriesRecap, parts
        case deliveredToRaw = "deliveredTo"
    }

    var isSynced: Bool { audioFilename != nil }
    var isTranscribed: Bool { transcript != nil }

    static let untitled = "Untitled Recording"

    init(
        id: String = UUID().uuidString,
        sessionId: Int,
        deviceSN: String,
        title: String = Recording.untitled,
        duration: TimeInterval = 0,
        createdAt: Date,
        syncedAt: Date? = nil,
        audioFilename: String? = nil,
        transcript: Transcript? = nil,
        livePreview: Transcript? = nil,
        highlights: [TimeInterval]? = nil,
        summaries: [Summary]? = nil,
        speakerNames: [String: String]? = nil,
        categoryName: String? = nil,
        actionItems: [ActionItem]? = nil,
        tagIds: [String]? = nil,
        calendarEventTitle: String? = nil,
        calendarAttendees: [String]? = nil,
        calendarLinkConfirmed: Bool? = nil,
        agenda: MeetingAgenda? = nil,
        place: RecordingPlace? = nil,
        chapters: [TranscriptChapter]? = nil,
        seriesId: String? = nil,
        seriesRecap: String? = nil,
        parts: [RecordingPart]? = nil,
        deliveredTo: [String] = []
    ) {
        self.id = id
        self.sessionId = sessionId
        self.deviceSN = deviceSN
        self.title = title
        self.duration = duration
        self.createdAt = createdAt
        self.syncedAt = syncedAt
        self.audioFilename = audioFilename
        self.transcript = transcript
        self.livePreview = livePreview
        self.highlights = highlights
        self.summaries = summaries
        self.speakerNames = speakerNames
        self.categoryName = categoryName
        self.actionItems = actionItems
        self.tagIds = tagIds
        self.calendarEventTitle = calendarEventTitle
        self.calendarAttendees = calendarAttendees
        self.calendarLinkConfirmed = calendarLinkConfirmed
        self.agenda = agenda
        self.place = place
        self.chapters = chapters
        self.seriesId = seriesId
        self.seriesRecap = seriesRecap
        self.parts = parts
        self.deliveredToRaw = deliveredTo.isEmpty ? nil : deliveredTo
    }

    /// True when this recording was assembled from others, so the UI can label it
    /// and `AutoOrganizer` can leave its seam chapters alone.
    var isMerged: Bool { (parts?.count ?? 0) > 1 }

    /// A human title: the first few words of the transcript beat "Untitled".
    var displayTitle: String {
        if title != Recording.untitled, !title.isEmpty { return title }
        guard let first = transcript?.plainText, !first.isEmpty else { return title }
        let words = first.split(separator: " ").prefix(7).joined(separator: " ")
        return words.isEmpty ? title : words
    }

    var durationText: String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
