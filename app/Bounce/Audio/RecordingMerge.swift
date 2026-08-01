import Foundation

/// Joins several recordings into one, audio and all.
///
/// This exists because a session and a *file* are not the same thing. A Plaud
/// closes a file whenever recording stops, so a half-hour of dictation captured
/// in bursts arrives as thirty rows that can't be read, summarised or searched as
/// the one train of thought they are. Merging produces the artifact the session
/// actually was.
///
/// ## It always writes a new recording
///
/// Nothing is mutated in place, exactly as `AudioEditModel.save` never touches
/// the recording it edits. Rewriting a source's audio underneath it would put a
/// row in the library whose `audioFilename` changes while `SyncManager` is
/// reconciling against the device — and `handleFileList` runs on *every* BLE
/// reconnect, not just when the user asks. A fresh file and a fresh row is the
/// only shape with no window in it.
///
/// The sources are then deleted if the caller asked, which is what makes a
/// continuation feel like continuation rather than like accumulating copies.
///
/// ## Ordering, and why it is not the caller's choice
///
/// Parts are always joined oldest first. A merge asserts "these are one
/// recording", and a recording is a thing that happened in time; an arbitrary
/// order would produce a transcript whose timestamps ascend while its content
/// jumps backwards, which reads as corruption.
@MainActor
enum RecordingMerge {

    struct Result {
        var recording: Recording
        var partCount: Int
        var duration: TimeInterval
        /// True when the merged file was queued for a full transcription pass
        /// because the stitched transcript had a hole in it.
        var queuedForTranscription: Bool
        /// Sources removed afterwards.
        var deletedSources: Int
    }

    enum Failure: LocalizedError {
        case tooFew
        case audioMissing(String)
        case notAdded

        var errorDescription: String? {
            switch self {
            case .tooFew:
                "Pick at least two recordings to join."
            case .audioMissing(let title):
                "“\(title)” has no audio on this iPhone yet, so it can't be joined. "
                    + "Sync it first."
            case .notAdded:
                "The joined recording couldn't be added to the library."
            }
        }
    }

    /// Whether a recording can take part in a merge at all.
    ///
    /// Audio on the phone is the whole requirement: the transcript, the
    /// highlights and the chapters are all optional passengers, but there is
    /// nothing to join without the file.
    static func canMerge(_ recording: Recording) -> Bool { recording.isSynced }

    /// Recordings worth offering as "the one this continues", newest first.
    ///
    /// Capped, and capped deliberately: this list is opened mid-recording, and
    /// the thing being continued was made minutes ago. A full library scroll is a
    /// worse answer than the last handful, and the user can still join anything
    /// afterwards from the library.
    static func eligibleTargets(in recordings: [Recording], limit: Int = 12) -> [Recording] {
        Array(recordings
            .filter(canMerge)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit))
    }

    // MARK: - Merging

    /// Join `recordings` into a new one.
    ///
    /// - Parameters:
    ///   - title: the merged recording's title; the default is used when empty.
    ///   - deletingSources: remove the parts once the merge is safely in the
    ///     library. Off for a merge the user asked for by hand — they can still
    ///     delete them — and on for a continuation, where leaving both halves
    ///     behind would defeat the point.
    ///   - organize: run the AI pass over the merged whole. Worth it because
    ///     category, title and summaries all describe the combined recording now,
    ///     and each part's own were written about a fragment. Skipped
    ///     automatically when a transcription pass is queued, since that pass runs
    ///     the organizer itself when it lands.
    ///   - deliver: honour `DeliverySettings.autoDeliver` for the result. Only
    ///     the continuation path sets this: it stands in for the delivery the
    ///     part's own transcription would have triggered. A hand-made merge is
    ///     something the user is looking at, and firing a webhook at it
    ///     unprompted would be a surprise.
    @discardableResult
    static func merge(
        _ recordings: [Recording],
        title: String? = nil,
        deletingSources: Bool = false,
        organize: Bool = true,
        deliver: Bool = false
    ) async throws -> Result {
        // De-duplicated by id before counting: the sheet pre-selects the recording
        // it was opened from, and a caller that adds it again would otherwise
        // splice the same audio in twice.
        var seen: Set<String> = []
        let ordered = recordings
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt < $1.createdAt }
        guard ordered.count >= 2 else { throw Failure.tooFew }

        var urls: [URL] = []
        for recording in ordered {
            guard let url = RecordingStore.shared.audioURL(for: recording) else {
                throw Failure.audioMissing(recording.displayTitle)
            }
            urls.append(url)
        }

        // A fresh UUID rather than anything derived from the sources:
        // `RecordingStore.delete` removes audio and the `.peaks` envelope by bare
        // filename, so two recordings sharing one cross-delete.
        let filename = "merged-\(UUID().uuidString).mp3"
        let destination = RecordingStore.shared.audioDirectory.appendingPathComponent(filename)

        // Indexing is a byte walk per file and the copy is the whole payload;
        // neither belongs on the main actor.
        let sourceURLs = urls
        let output = try await Task.detached(priority: .userInitiated) {
            let sources = try sourceURLs.map {
                MP3Frames.MergeSource(url: $0, index: try MP3Frames.index(of: $0))
            }
            return try MP3Frames.merge(sources: sources, to: destination)
        }.value

        // Placements, not the sources' stored durations — see `RecordingMergePlan`.
        let parts = zip(ordered, output.placements).map { recording, placement in
            RecordingMergePlan.Part(
                recording: recording,
                start: placement.start,
                duration: placement.duration)
        }
        let stitched = RecordingMergePlan.stitch(parts, mergedAt: Date())

        let chosenTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = Recording(
            sessionId: RecordingStore.shared.syntheticSessionId(),
            deviceSN: ordered[0].deviceSN,
            title: chosenTitle.isEmpty
                ? RecordingMergePlan.defaultTitle(for: ordered)
                : chosenTitle,
            duration: output.duration,
            // The first part's date. This is when the session started, which is
            // where the user will look for it in the library and on the calendar —
            // not the moment they got around to joining it up.
            createdAt: ordered[0].createdAt,
            syncedAt: Date(),
            audioFilename: filename,
            transcript: stitched.transcript,
            // The parts' live drafts describe the parts' timelines and there is no
            // reason to carry an archived preview onto a derived file — the same
            // call `AudioEditModel.save` makes.
            livePreview: nil,
            highlights: stitched.highlights,
            // Dropped: a summary describes one part, and the merged whole is a
            // different document. `organize` writes fresh ones.
            summaries: nil,
            speakerNames: stitched.speakerNames,
            categoryName: stitched.categoryName,
            actionItems: stitched.actionItems,
            tagIds: stitched.tagIds,
            calendarEventTitle: stitched.calendarEventTitle,
            calendarAttendees: stitched.calendarAttendees,
            agenda: stitched.agenda,
            place: stitched.place,
            chapters: stitched.chapters,
            seriesId: stitched.seriesId,
            // Deliberately not carried: a recap describes a position in a series'
            // history, and the merged recording occupies a different one.
            seriesRecap: nil,
            parts: stitched.parts)

        RecordingStore.shared.add([merged])
        // `add` filters out any `sessionId` already present and reports nothing,
        // so confirm rather than assume — otherwise a dropped insert leaves an
        // orphaned MP3 and, if `deletingSources` is set, deletes the originals
        // that were about to become the only copy.
        guard RecordingStore.shared.recording(id: merged.id) != nil else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.notAdded
        }
        SyncManager.shared.refreshLibrary()

        var deleted = 0
        if deletingSources {
            for recording in ordered {
                TranscriptionCoordinator.shared.clearStatus(for: recording.id)
                RecordingStore.shared.delete(id: recording.id)
                deleted += 1
            }
            SyncManager.shared.refreshLibrary()
        }

        // Warm the envelope so the new row has a sparkline immediately: list rows
        // only ever read the cache, and the once-per-launch prewarm has long since
        // run.
        Task.detached(priority: .utility) {
            _ = await WaveformCache.shared.peaks(for: destination)
        }

        let queued = stitched.needsAuthoritativePass
        if queued {
            // A stitched transcript with a hole in it is marked `isPreview`, which
            // is exactly what `enqueue` treats as "not transcribed" — no `force`
            // needed, and a complete stitch is correctly left alone.
            TranscriptionCoordinator.shared.enqueue(recordingId: merged.id)
        } else if organize {
            // Only when nothing is queued: the transcription pass runs the
            // organizer itself, and two on-device model jobs racing over one
            // recording is how a title gets written twice.
            await AutoOrganizer.shared.process(recordingId: merged.id)
        }

        if deliver, !queued, DeliverySettings.shared.autoDeliver,
           let updated = RecordingStore.shared.recording(id: merged.id) {
            _ = await DeliveryService.shared.deliverToAllDestinations(updated)
        }

        let stored = RecordingStore.shared.recording(id: merged.id) ?? merged
        return Result(
            recording: stored,
            partCount: ordered.count,
            duration: output.duration,
            queuedForTranscription: queued,
            deletedSources: deleted)
    }
}
