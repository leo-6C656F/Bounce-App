import Foundation
import FoundationModels

/// The automatic AI pass that runs after each transcription: classify the
/// recording into one of the user's categories (`CategoryStore`), title it
/// ("Meeting: Budget review") if it's still untitled, then run the category's
/// summary templates plus any marked "run for every recording".
///
/// Entirely on device — same model, availability rules, and ~4k-token context
/// constraint as the Q&A and summary features, so classification and titles are
/// drawn from the transcript's most recent portion on long recordings.
/// `TranscriptionCoordinator` awaits this *before* auto-delivery, so the
/// delivered payload carries the final title and summaries. Every guard here
/// skips silently: an unavailable model or a failed classification leaves the
/// recording exactly as the transcription pass left it.
@MainActor
final class AutoOrganizer {

    static let shared = AutoOrganizer()

    private static let maxTranscriptChars = 10_000
    /// Below this much transcript there's nothing meaningful to organize.
    private static let minTranscriptChars = 12

    private let model = SystemLanguageModel.default
    private let generator = SummaryGenerator()

    private init() {}

    /// What the classifier returns — guided generation, so the shape is
    /// enforced by the framework rather than parsed out of prose.
    @Generable
    struct Classification {
        @Guide(description: "Exactly one of the category names listed in the instructions.")
        let category: String
        @Guide(description: "A short, specific title for the recording — at most six words, no trailing punctuation.")
        let title: String
    }

    func process(recordingId: String) async {
        guard DeliverySettings.shared.autoOrganize else { return }
        guard case .available = model.availability else { return }
        guard let recording = RecordingStore.shared.recording(id: recordingId),
              let transcript = recording.transcript, !transcript.isLivePreview
        else { return }
        let text = transcript.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minTranscriptChars else { return }

        // **Classification runs before the title is chosen**, and the order matters:
        // whether a calendar event may name this recording depends on its category
        // ("never name a Reminder after a meeting"), so the category has to be known
        // first. This used to run calendar-first, which is why an 8-second note
        // recorded during a meeting was titled after that meeting.
        var matched: RecordingCategory?
        var aiTitle: String?
        let categories = CategoryStore.shared.categories
        if !categories.isEmpty, let result = await classify(text, into: categories) {
            matched = Self.match(result.category, in: categories)
            if let matched {
                TranscribeLog.log("auto-organize: \(matched.name) — \(result.title)")
                aiTitle = Self.compose(prefix: matched.titlePrefix, title: result.title)
            } else {
                TranscribeLog.log("auto-organize: model answered \"\(result.category)\", not a known category — skipping")
            }
        }

        // A calendar link the user set or cleared by hand is authoritative and
        // must survive this re-run untouched — so skip the lookup entirely rather
        // than re-guess it. See `Recording.calendarLinkConfirmed`.
        let userOwnsCalendarLink = recording.calendarLinkConfirmed == true

        // Look up the calendar. Only a *high-confidence*, unambiguous match links
        // automatically; a weaker one is left for the manual picker (the detail
        // view's Meeting card) so a wrong guess never lands silently. Silent when
        // access was never granted or nothing overlapped.
        //
        // Nothing overlapping is common and expected here: the recording's
        // timestamp is the *recorder's* clock, which drifts from the phone, so a
        // real meeting can fall outside the match window. That is precisely the
        // case the picker recovers — see `CalendarMatching.defaultTolerance`.
        let match = userOwnsCalendarLink ? nil : await matchingCalendarEvent(for: recording)
        let confidentEvent = match?.confidence == .high ? match?.event : nil

        // A recurring calendar event *is* a meeting series, and its external
        // identifier is the same for every occurrence — so this groups sessions
        // months apart with nothing asked of the user. Resolved before `persist`
        // because creating the series is a separate write; the closure below only
        // stores the id.
        //
        // Never reassigns: a recording the user has already filed into a series by
        // hand keeps that series, even if the calendar disagrees. Only a confident
        // match auto-groups — a low-confidence guess would fork a series wrongly.
        var seriesId = recording.seriesId
        if seriesId == nil, let confidentEvent, let key = confidentEvent.seriesKey {
            let name = confidentEvent.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty,
               let series = MeetingSeriesStore.shared.ensureSeries(calendarKey: key, name: name) {
                seriesId = series.id
            }
        }

        // One decision, one write. `select` owns the precedence — a title the user
        // typed always wins, then a calendar event that passes the coverage guards
        // and the category's opt-out, then the AI's suggestion.
        let source = RecordingTitleSelection.select(
            currentTitle: recording.title,
            untitledPlaceholder: Recording.untitled,
            recordingStart: recording.createdAt,
            recordingDuration: recording.duration,
            event: confidentEvent,
            categoryAllowsCalendarTitles: matched?.allowsCalendarTitle ?? true,
            aiTitle: aiTitle,
            existingTitles: RecordingStore.shared.recordings
                .filter { $0.id != recordingId }
                .map(\.title))

        TranscribeLog.log("auto-organize: title source \(source)")
        persist(recordingId) { rec in
            if let matched { rec.categoryName = matched.name }
            if let seriesId { rec.seriesId = seriesId }
            if let confidentEvent {
                let eventTitle = confidentEvent.title.trimmingCharacters(in: .whitespacesAndNewlines)
                rec.calendarEventTitle = eventTitle.isEmpty ? nil : eventTitle
                rec.calendarAttendees = confidentEvent.attendees.isEmpty ? nil : confidentEvent.attendees
                // The meeting's own coordinates beat a sync-time fix and cost
                // nothing — but never beat a fix taken while it was recording,
                // which is what `shouldBeReplaced(by:)` enforces. Gated on the
                // geotag setting: an event's location is still the user's
                // whereabouts, and calendar matching is not consent for that.
                if DeliverySettings.shared.geotagRecordings, let place = confidentEvent.place {
                    if rec.place?.shouldBeReplaced(by: place) ?? true { rec.place = place }
                }
            }
            switch source {
            case .calendar(let title), .ai(let title):
                if !title.isEmpty {
                    rec.title = title
                    // The app chose this title, so a later manual meeting link is
                    // free to adopt the meeting's name over it. `.userTyped` never
                    // reaches here (see `select`), so the user's own title keeps
                    // its source untouched.
                    rec.titleSource = .auto
                }
            case .userTyped, .none:
                break
            }
        }

        // The category's templates first, then any "run for every recording"
        // templates that aren't already in the list.
        var templateIds = matched?.templateIds ?? []
        for template in TemplateStore.shared.all
        where template.runsAutomatically && !templateIds.contains(template.id) {
            templateIds.append(template.id)
        }
        for id in templateIds {
            guard let template = TemplateStore.shared.template(id: id) else { continue }
            await run(template, over: text, recordingId: recordingId)
        }

        // Last, and inside this pass rather than in a detached task: the ordering
        // `TranscriptionCoordinator` documents is transcript → auto-organize →
        // deliver, so extracting here means a delivered payload carries the items
        // and every model job stays serialised behind the transcription queue.
        await extractActionItems(
            recordingId: recordingId, transcript: transcript, recordedAt: recording.createdAt)

        // Chapters for the transcript view's headings and jump chips. Silent on
        // every exit — a recording under two minutes, or a device without Apple
        // Intelligence, simply keeps `chapters` nil and reads as flat blocks.
        await generateChapters(
            recordingId: recordingId, transcript: transcript, duration: recording.duration)

        // Last, and inside this pass for the same reason as the line above: the
        // recap it writes has to be on the recording before auto-delivery sends
        // it. No-ops unless this recording is in a series — which is why there is
        // no setting gating it: a series only exists because the user made one or
        // has a recurring meeting in their calendar with matching switched on.
        await SeriesContinuity.shared.update(for: recordingId)
    }

    /// Recordings that already have a transcript but were never scanned for tasks.
    ///
    /// Extraction runs automatically after each transcription, so this only ever
    /// finds recordings transcribed *before* the feature existed. Without it those
    /// stay permanently empty and the Tasks tab looks broken on an established
    /// library — which is exactly the impression a new feature must not give.
    ///
    /// `actionItems == nil` means "never scanned"; an empty array would mean
    /// "scanned, found nothing", which is why the model normalises to nil only when
    /// a scan produced nothing *and* there was nothing before. Re-scanning a
    /// recording that genuinely has no tasks is cheap and idempotent.
    static func recordingsNeedingActionItemScan() -> [Recording] {
        RecordingStore.shared.recordings.filter {
            $0.transcript != nil && $0.transcript?.isLivePreview != true && $0.actionItems == nil
        }
    }

    /// Scan already-transcribed recordings for tasks, oldest first.
    ///
    /// **Serial, deliberately.** Each pass is a `LanguageModelSession` over a
    /// transcript; running them concurrently would contend for the same on-device
    /// model and, on a large library, is a real thermal and battery cost. `progress`
    /// is called on the main actor after each recording so the UI can count up, and
    /// the whole thing honours cancellation between recordings.
    func scanForActionItems(progress: @MainActor (Int, Int) -> Void) async {
        guard case .available = model.availability else { return }
        let pending = Self.recordingsNeedingActionItemScan()
        guard !pending.isEmpty else { return }

        for (index, recording) in pending.enumerated() {
            if Task.isCancelled { return }
            if let transcript = recording.transcript {
                await extractActionItems(
                    recordingId: recording.id, transcript: transcript,
                    recordedAt: recording.createdAt)
            }
            progress(index + 1, pending.count)
        }
        // No refresh here: `persist` republishes after each recording, so the list
        // fills in as the scan runs rather than all at once at the end.
    }

    /// Pull tasks out of the transcript and fold them into whatever the recording
    /// already carries.
    ///
    /// **Merges, never replaces.** Re-transcribing a recording must not resurrect an
    /// item the user has ticked off — `ActionItemMerge.merged` keys on normalised
    /// text and preserves `isDone`, `id`, `createdAt` and `reminderId`.
    private func extractActionItems(
        recordingId: String, transcript: Transcript, recordedAt: Date
    ) async {
        // `recordedAt` is the recording's own date, not the transcript's `createdAt`
        // (which is when transcription ran, possibly days later). It anchors every
        // relative deadline — "by Friday" is meaningless without it.
        let extracted = await ActionItemExtractor.shared.extract(
            from: transcript, recordedAt: recordedAt)
        // Empty is the model's "nothing actionable here", and also what every guard
        // inside the extractor returns. Either way there is nothing to merge, and
        // writing would republish the library for no change.
        guard !extracted.isEmpty else { return }

        persist(recordingId) { rec in
            let merged = ActionItemMerge.merged(
                existing: rec.actionItems ?? [], extracted: extracted)
            // nil rather than [] for "none", so the two don't both exist as
            // representations of the same state.
            rec.actionItems = merged.isEmpty ? nil : merged
        }
        TranscribeLog.log("auto-organize: \(extracted.count) action item(s) extracted")
    }

    /// Name the sections of the transcript, for the chaptered transcript view.
    ///
    /// `nil` back from the generator means "not chapterable" — too short, no
    /// model, or an answer that didn't survive validation — and is written
    /// through rather than skipped, so a re-transcribe that shortens a recording
    /// clears stale chapters instead of leaving headings pointing at audio that
    /// no longer exists.
    func generateChapters(recordingId: String, transcript: Transcript, duration: TimeInterval) async {
        // A merged recording already has headings that mean something — one per
        // part, written by `RecordingMergePlan` — and they are the structure the
        // user created by joining the sessions up. Regenerating would replace them
        // with the model's own, and the write-through below would erase them for
        // good on a device that can't chapter at all.
        if RecordingStore.shared.recording(id: recordingId)?.isMerged == true { return }
        let chapters = await ChapterGenerator.shared.chapters(for: transcript, duration: duration)
        // Nothing before, nothing after: skip the write so the library isn't
        // republished for a no-op on every short recording.
        let existing = RecordingStore.shared.recording(id: recordingId)?.chapters
        guard chapters != nil || existing != nil else { return }
        persist(recordingId) { rec in
            rec.chapters = chapters
        }
        if let chapters {
            TranscribeLog.log("auto-organize: \(chapters.count) chapter(s)")
        }
    }

    // MARK: - Calendar

    /// The calendar event this recording overlapped, if any.
    ///
    /// Read-only and side-effect free — it no longer writes. Deciding what to do
    /// with the event belongs to `RecordingTitleSelection`, and separating the
    /// lookup from the decision is what let the category opt-out exist at all.
    ///
    /// Silent on every exit, matching every other guard here: the setting off,
    /// access never granted, or no overlapping event all simply return nil.
    /// Attendee names are personal data and are never logged.
    private func matchingCalendarEvent(
        for recording: Recording
    ) async -> (event: CandidateEvent, confidence: CalendarMatching.MatchConfidence)? {
        guard DeliverySettings.shared.calendarTitles else { return nil }
        guard CalendarMatcher.shared.canReadEvents else { return nil }
        return await CalendarMatcher.shared.evaluate(
            recordingStart: recording.createdAt,
            duration: recording.duration)
    }

    // MARK: - Classification

    private func classify(
        _ text: String, into categories: [RecordingCategory]
    ) async -> Classification? {
        let list = categories
            .map { "- \($0.name): \($0.guidance)" }
            .joined(separator: "\n")
        // Routed through `PromptStore` so Settings › AI › Prompts can edit both the
        // classifier instructions and its one-line request; the matching
        // `PromptDefaults` entries are the fallback for the impossible case of the
        // catalogue having lost an id.
        let values = ["categories": list, "transcript": Self.cap(text)]
        let editedInstructions = PromptStore.shared.filled(PromptID.organizeClassify, with: values)
        let instructions = editedInstructions.isEmpty
            ? PromptTemplating.filled(PromptDefaults.organizeClassify, with: values)
            : editedInstructions
        let editedRequest = PromptStore.shared.text(for: PromptID.organizeRequest)
        let request = editedRequest.isEmpty ? PromptDefaults.organizeRequest : editedRequest
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: request,
                generating: Classification.self)
            return response.content
        } catch {
            TranscribeLog.log("auto-organize classification failed: "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            return nil
        }
    }

    /// Exact case-insensitive name match first; failing that, accept an answer
    /// that merely contains the category name ("a Meeting" → Meeting).
    private static func match(
        _ answer: String, in categories: [RecordingCategory]
    ) -> RecordingCategory? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return categories.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
            ?? categories.first { trimmed.localizedCaseInsensitiveContains($0.name) }
    }

    // MARK: - Summaries

    /// Run one template over the transcript and save the result, replacing any
    /// previous run of that template — same persistence as the Summary tab.
    private func run(_ template: SummaryTemplate, over transcript: String, recordingId: String) async {
        var final = ""
        for await partial in generator.generate(transcript: transcript, template: template) {
            final = partial
        }
        // A failed run yields its apology ("Couldn't generate this summary…")
        // into the stream, so `final` is non-empty and would otherwise be stored
        // as a real summary *and* delivered to the webhook. `lastError` is the
        // documented guard for any caller that persists the stream's last value.
        guard generator.lastError == nil else { return }
        guard !final.isEmpty else { return }
        let summary = Summary(
            templateId: template.id,
            templateName: template.name,
            text: final,
            createdAt: Date())
        persist(recordingId) { rec in
            var list = rec.summaries ?? []
            list.removeAll { $0.templateId == template.id }
            list.append(summary)
            rec.summaries = list
        }
    }

    // MARK: - Helpers

    /// Write to the store **and republish**, as one step.
    ///
    /// Every write in this type must go through here. `RecordingStore.update` alone
    /// persists correctly and leaves every screen stale, because `AppModel.recordings`
    /// — which Home's recents and the Library render from — is fed only by
    /// `SyncManager.refreshLibrary()`.
    ///
    /// That was a real bug: `TranscriptionCoordinator` refreshes *before* calling
    /// `process`, so everything written here landed after the last refresh. The
    /// recording kept its old title in the list until a pull-to-refresh, while
    /// opening it showed the new one — `AppModel.current` reads the store directly,
    /// so the detail view was right and the list was wrong. It affected the AI title,
    /// the category and every summary, not just the calendar title that made it
    /// visible.
    ///
    /// Refreshing per write rather than once at the end is deliberate: templates run
    /// one at a time and each takes seconds, so a single refresh at the end would
    /// leave the list stale for the whole run instead of filling in as it goes.
    /// `refreshLibrary` just re-sends the cached array, so the cost is a SwiftUI
    /// diff, not I/O.
    private func persist(_ recordingId: String, _ mutate: (inout Recording) -> Void) {
        RecordingStore.shared.update(id: recordingId, mutate)
        SyncManager.shared.refreshLibrary()
    }

    static func isUntitled(_ title: String) -> Bool {
        title.isEmpty || title == Recording.untitled
    }

    static func compose(prefix: String, title: String) -> String {
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { return title }
        if title.isEmpty { return "" }
        return "\(prefix) \(title)"
    }

    private static func cap(_ transcript: String) -> String {
        guard transcript.count > maxTranscriptChars else { return transcript }
        // Halves of the budget, derived rather than written as literals: with a
        // hardcoded 4,500/4,500 against a `maxTranscriptChars` anyone is free to
        // lower, a budget under 9,000 makes the two slices overlap — duplicating
        // text and rendering a negative count as "[… -2000 characters omitted …]".
        let half = maxTranscriptChars / 2
        let head = transcript.prefix(half)
        let tail = transcript.suffix(half)
        let omitted = transcript.count - 2 * half
        return "\(head)\n\n[… \(omitted) characters omitted …]\n\n\(tail)"
    }
}
