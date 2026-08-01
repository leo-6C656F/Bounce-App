import Foundation

/// Everything that has to be rewritten when several recordings become one, with
/// no I/O and no app state involved.
///
/// `MP3Frames.merge` moves the audio; this moves everything attached to it.
/// Splitting them is deliberate: the audio side is verified by decoding real
/// output through `AVAudioFile`, while this side is pure arithmetic over the
/// stored model, and keeping it Foundation-only means
/// `tools/library-decode-tests` can compile and exercise it against the *real*
/// `Recording` rather than a stub that drifts.
///
/// ## The one rule
///
/// Every timestamp on a part refers to that part's own timeline, which starts at
/// zero. On the merged timeline the part starts at `Placement.start`, so every
/// one of its timings shifts by that much: transcript segments, highlight marks,
/// chapter starts, action-item offsets. Miss one and it points at the wrong
/// audio — silently, and further out the deeper into the recording you go, which
/// is the same failure mode `TimelineMap` exists to prevent for edits.
enum RecordingMergePlan {

    /// A source recording and the span it occupies on the merged timeline.
    ///
    /// `start` and `duration` come from `MP3Frames.MergeOutput.placements`, not
    /// from `Recording.duration`: the writer snaps to frame boundaries, so the
    /// stored duration is up to a frame out, and accumulating that error across
    /// parts walks the whole tail of the transcript off its audio.
    struct Part {
        var recording: Recording
        var start: TimeInterval
        var duration: TimeInterval
    }

    /// The merged recording's derived fields.
    struct Stitched {
        var transcript: Transcript?
        var chapters: [TranscriptChapter]?
        var highlights: [TimeInterval]?
        var speakerNames: [String: String]?
        var actionItems: [ActionItem]?
        var tagIds: [String]?
        var categoryName: String?
        var calendarEventTitle: String?
        var calendarAttendees: [String]?
        var agenda: MeetingAgenda?
        var place: RecordingPlace?
        var seriesId: String?
        var parts: [RecordingPart]
        /// True when the stitched transcript has a hole in it — a part with no
        /// transcript, or one still holding a live preview. The caller should
        /// queue the merged file for a real pass; the stitched text stands in
        /// until it lands.
        var needsAuthoritativePass: Bool
    }

    // MARK: - Stitching

    static func stitch(_ parts: [Part], mergedAt: Date) -> Stitched {
        var segments: [TranscriptSegment] = []
        var chapters: [TranscriptChapter] = []
        var highlights: [TimeInterval] = []
        var speakerNames: [String: String] = [:]
        var actionItems: [ActionItem] = []
        var seenActionKeys: Set<String> = []
        var tagIds: [String] = []
        var descriptors: [RecordingPart] = []
        var locale: String?
        var needsPass = false
        // Diarization labels are per recording — "1" in the second part is not the
        // person "1" in the first, and no engine here has enrollment — so labels
        // are renumbered into one sequence across the merge rather than collided
        // together. Two rows for the same human is a wrong guess the user can fix
        // by naming them; one row for two humans is a wrong transcript.
        var nextSpeaker = 1

        for (offset, part) in parts.enumerated() {
            let recording = part.recording
            let shift = part.start

            descriptors.append(RecordingPart(
                sessionId: recording.sessionId,
                title: recording.displayTitle,
                start: shift,
                duration: part.duration,
                recordedAt: recording.createdAt))

            // The seam. Emitted for every part, including the first, so the
            // chaptered transcript reads as a list of sessions rather than a
            // headless first block followed by headed ones.
            chapters.append(TranscriptChapter(
                title: partTitle(for: recording, position: offset), start: shift))

            if let transcript = recording.transcript {
                if transcript.isLivePreview { needsPass = true }
                if locale == nil { locale = transcript.localeIdentifier }

                var labels: [String: String] = [:]
                for speaker in transcript.speakers {
                    labels[speaker] = "\(nextSpeaker)"
                    if let name = recording.speakerNames?[speaker] {
                        speakerNames["\(nextSpeaker)"] = name
                    }
                    nextSpeaker += 1
                }

                for segment in transcript.segments {
                    segments.append(TranscriptSegment(
                        text: segment.text,
                        start: segment.start + shift,
                        end: max(segment.start, segment.end) + shift,
                        speaker: segment.speaker.flatMap { labels[$0] }))
                }
            } else {
                // Audio with no words under it. The merged transcript is still
                // worth having, but it is incomplete and must not be presented as
                // final.
                needsPass = true
            }

            // A part's own chapters, shifted. Dropped when they land on the seam
            // this loop just wrote: `sanitized` de-duplicates by start, so the
            // first survivor wins and it should be the part's title, not an AI
            // heading for the same instant.
            for chapter in recording.chapters ?? [] where chapter.start > 0.5 {
                chapters.append(TranscriptChapter(
                    title: chapter.title, start: chapter.start + shift))
            }

            highlights.append(contentsOf: (recording.highlights ?? []).map { $0 + shift })

            for item in recording.actionItems ?? [] {
                let key = normalisedKey(item.text)
                guard !key.isEmpty, seenActionKeys.insert(key).inserted else { continue }
                var shifted = item
                shifted.sourceOffset = item.sourceOffset.map { $0 + shift }
                actionItems.append(shifted)
            }

            for tag in recording.tagIds ?? [] where !tagIds.contains(tag) {
                tagIds.append(tag)
            }
        }

        var transcript: Transcript?
        if !segments.isEmpty {
            transcript = Transcript(
                segments: segments,
                localeIdentifier: locale ?? Locale.current.identifier,
                createdAt: mergedAt,
                // Marked a preview precisely when it has a hole, which makes
                // `TranscriptionCoordinator.enqueue` pick the merged file up
                // without a second mechanism: a preview already means "stand-in,
                // replace me with a pass over the whole file".
                isPreview: needsPass ? true : nil)
        }

        let sources = parts.map(\.recording)
        return Stitched(
            transcript: transcript,
            chapters: chapters.isEmpty ? nil : chapters,
            highlights: highlights.isEmpty ? nil : highlights.sorted(),
            speakerNames: speakerNames.isEmpty ? nil : speakerNames,
            actionItems: actionItems.isEmpty ? nil : actionItems,
            tagIds: tagIds.isEmpty ? nil : tagIds,
            // Category and series are single-valued, so they carry over only when
            // the parts agree. Picking the first would quietly file a merge of a
            // "Meeting" and a "Note" as whichever happened to be recorded first.
            categoryName: unanimous(sources.map(\.categoryName)),
            calendarEventTitle: sources.compactMap(\.calendarEventTitle).first,
            calendarAttendees: sources.compactMap(\.calendarAttendees).first,
            agenda: sources.compactMap(\.agenda).first,
            // The earliest part's place: for a continued session that is the fix
            // taken when recording actually started, which is the most trustworthy
            // one available (see `RecordingPlace.Source`).
            place: sources.compactMap(\.place).first,
            seriesId: unanimous(sources.map(\.seriesId)),
            parts: descriptors,
            needsAuthoritativePass: needsPass || transcript == nil)
    }

    // MARK: - Titles

    /// The default title for a merge: the first part's, marked as combined.
    ///
    /// Deliberately derived from the first part rather than being generic —
    /// a merge is usually a session that got split, so the first part's title is
    /// the session's title.
    static func defaultTitle(for recordings: [Recording]) -> String {
        guard let first = recordings.first else { return Recording.untitled }
        let base = first.displayTitle
        guard base != Recording.untitled, !base.isEmpty else {
            return "Combined recording"
        }
        return "\(base) (combined)"
    }

    /// The heading for one part's seam.
    private static func partTitle(for recording: Recording, position: Int) -> String {
        let title = recording.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != Recording.untitled else {
            return "Part \(position + 1)"
        }
        // Chapter headings are three or four words elsewhere (`ChapterGenerator`),
        // and a heading long enough to wrap stops reading as a heading.
        guard title.count > 42 else { return title }
        return title.prefix(41).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Helpers

    /// The one value they all agree on, or nil when they don't.
    ///
    /// Absent values abstain rather than dissent: a part with no category doesn't
    /// stop the merge inheriting the category the other parts share.
    private static func unanimous(_ values: [String?]) -> String? {
        let present = values.compactMap { $0 }
        guard let first = present.first else { return nil }
        return present.allSatisfy { $0 == first } ? first : nil
    }

    /// Case- and whitespace-insensitive key for de-duplicating action items
    /// across parts, so the same task said twice in one session arrives once.
    ///
    /// Deliberately its own small rule rather than a call into `ActionItemMerge`:
    /// that type resolves items against a transcript and carries the app's
    /// completion-preserving merge semantics, none of which apply to two lists
    /// that are both already final.
    private static func normalisedKey(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
