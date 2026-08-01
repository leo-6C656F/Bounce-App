import Foundation

/// The Bounce MCP server: `POST /mcp`, six read-only tools over the library.
///
/// `MCPProtocol` owns the JSON-RPC and MCP envelope rules and is Foundation-only
/// so it can be exercised on the Mac (`tools/mcp-endpoint-tests/main.swift`).
/// This file is the other half: the tools themselves, reading the app.
///
/// # Read-only is the entire security design
///
/// **Every tool here reads. None of them writes, and none of them ever should.**
/// No delete, no re-transcribe, no delivery, no title/tag/speaker/category edit.
/// The reason is blast radius: the token that reaches this endpoint is long-lived
/// and lives in an agent's config file, and the thing on the other end of it is a
/// language model acting on instructions that may themselves have come out of a
/// transcript. A confused or prompt-injected agent with `delete_recording` costs
/// the user their recordings; the same agent with only readers costs them
/// nothing it could not already have read.
///
/// Three things make that structural rather than a promise:
///
/// - **`MCPLibraryReading`.** This class holds one of those, not an `AppModel`.
///   `model.delete(recording)` does not compile here, because the protocol has no
///   such member. Adding a write tool means first widening that protocol, which
///   is a visible, deliberate act rather than a reflex.
/// - **`Tool` is an exhaustive enum**, switched over in one place. A new case
///   fails to compile until it is handled, so a tool can't be added by pasting a
///   dictionary entry and forgetting the rest.
/// - **`MCPToolProvider.call` returns `String`.** The only thing a tool can
///   express is text going back out.
///
/// # These tools return private meeting transcripts
///
/// That is what they are *for*, and the tool descriptions say so plainly — an
/// agent that doesn't know `get_transcript` returns a whole meeting will use it
/// badly. But the descriptions are also deliberately written to steer towards
/// fetching the one recording being asked about: `list_recordings` returns
/// metadata and never transcript text, `search_recordings` returns short
/// snippets, and `MCPProtocol.instructions` says not to page the library to build
/// a copy of it. None of that is enforcement — an agent with the token can read
/// everything, one recording at a time, and the Settings copy that hands the
/// token out has to say so.
///
/// # Threading
///
/// `@MainActor` throughout, per the rule at the top of `WebAPI.swift`: the HTTP
/// layer hops here once, at the edge, and never hops back off. `RecordingStore`
/// is an unsynchronised class and `SWIFT_STRICT_CONCURRENCY` is `minimal`, so a
/// tool reading the library off the main actor compiles clean and races at
/// runtime.
@MainActor
final class MCPEndpoint: MCPToolProvider {

    /// The read-only slice of the app the tools may touch. Deliberately not
    /// `AppModel` — see "Read-only is the entire security design" above.
    private unowned let library: any MCPLibraryReading

    init(library: any MCPLibraryReading) {
        self.library = library
    }

    // MARK: - HTTP entry point

    /// Handle one `POST /mcp`. The whole integration surface for `WebAPI`.
    ///
    /// A notification becomes a `202` with an **empty body**, which is the one
    /// thing that must not be got wrong: answering `notifications/initialized`
    /// with a JSON-RPC result leaves the client waiting on a response id that
    /// will never arrive.
    func respond(to body: Data) async -> HTTPResponse {
        switch await MCPProtocol.respond(to: body, provider: self) {
        case .reply(let data):
            return .json(data)
        case .accepted:
            return .empty(202)
        case .failure(let status, let data):
            return .json(data, status: status)
        }
    }

    // MARK: - Tool table

    /// The tools, and nothing else. Exhaustive, so `call` cannot silently miss one.
    ///
    /// Names are snake case to match the rest of the MCP ecosystem and the spec's
    /// allowed character set.
    ///
    /// `fileprivate`, not `private`: the descriptors live in an
    /// `extension MCPEndpoint.Tool` at the bottom of this file, and naming a
    /// `private` nested type from file scope doesn't compile.
    fileprivate enum Tool: String, CaseIterable {
        case listRecordings = "list_recordings"
        case getTranscript = "get_transcript"
        case searchRecordings = "search_recordings"
        case getSummaries = "get_summaries"
        case listActionItems = "list_action_items"
        case ask = "ask"
    }

    var tools: [MCPTool] { Tool.allCases.map(\.descriptor) }

    func call(_ name: String, _ arguments: MCPArguments) async throws -> String {
        // `MCPProtocol` has already rejected any name not in `tools`, so this can
        // only fail if the two lists drift — which they can't, since both come
        // from `Tool.allCases`.
        guard let tool = Tool(rawValue: name) else {
            throw MCPToolFailure("Unknown tool: \(name)")
        }
        switch tool {
        case .listRecordings:   return try listRecordings(arguments)
        case .getTranscript:    return try getTranscript(arguments)
        case .searchRecordings: return try searchRecordings(arguments)
        case .getSummaries:     return try getSummaries(arguments)
        case .listActionItems:  return try listActionItems(arguments)
        case .ask:              return try await ask(arguments)
        }
    }

    // MARK: - Limits
    //
    // Named rather than inline because every one of them is a judgement about how
    // much of a model's context window this server is entitled to spend.

    /// Default page for `list_recordings`. Enough to answer "what did I record
    /// this week" without a follow-up, small enough not to swamp a context.
    private static let defaultLimit = 25
    private static let limitRange = 1...200
    /// Hard ceiling on a single transcript. Roughly an eight-hour recording; past
    /// that the tail is dropped with a visible notice rather than silently.
    private static let maxTranscriptChars = 200_000
    private static let maxSearchResults = 25
    private static let snippetChars = 240
    /// Matches `WebAPI.ask`: the on-device model's context is ~4,096 tokens shared
    /// across instructions, question and answer, so a long question crowds out the
    /// transcript it is supposed to be about.
    private static let maxQuestionChars = 500

    // MARK: - list_recordings

    private func listRecordings(_ arguments: MCPArguments) throws -> String {
        let limit = try arguments.int("limit", clampedTo: Self.limitRange) ?? Self.defaultLimit
        let since = try arguments.date("since")
        let category = try arguments.string("category")

        var matched = library.recordings
        if let since {
            matched = matched.filter { $0.createdAt >= since }
        }
        if let category {
            // Case-insensitive, matching `CategoryStore.category(named:)` and
            // `AutoOrganizer` — the category name stored on a recording is
            // whatever case the model returned when it classified it.
            matched = matched.filter {
                $0.categoryName?.compare(category, options: .caseInsensitive) == .orderedSame
            }
        }
        // Newest first, which is the order every screen in the app shows and the
        // order "my last three meetings" means.
        matched.sort { $0.createdAt > $1.createdAt }

        // Report an unmatched category rather than an empty list: "no recordings"
        // and "no category by that name" lead a model to completely different next
        // moves, and an empty array says nothing about which happened.
        if let category, matched.isEmpty,
           CategoryStore.shared.category(named: category) == nil {
            let known = CategoryStore.shared.categories.map(\.name).sorted()
            throw MCPToolFailure(
                "No category named “\(category)”. Known categories: "
                + (known.isEmpty ? "none yet." : known.joined(separator: ", ") + "."))
        }

        let page = Array(matched.prefix(limit))
        return Self.jsonText([
            "total": matched.count,
            "returned": page.count,
            "recordings": page.map(row(for:)),
        ])
    }

    /// Library-list metadata for one recording. **Never transcript text** — this
    /// is the tool an agent reaches for first, and a library of long meetings
    /// would be megabytes of context per call. `WebRecordingRow` excludes it for
    /// the same reason.
    private func row(for recording: Recording) -> [String: Any] {
        var row: [String: Any] = [
            "id": recording.id,
            "title": recording.displayTitle,
            "createdAt": Self.iso8601.string(from: recording.createdAt),
            "date": recording.createdAt.formatted(date: .abbreviated, time: .shortened),
            // `Int(_:)` on a non-finite Double traps, and `duration` comes off the
            // recorder rather than from us. `timecodeText` already guards itself.
            "durationSeconds": recording.duration.isFinite ? Int(recording.duration.rounded()) : 0,
            "duration": recording.duration > 0 ? recording.duration.timecodeText : "--:--",
            "isTranscribed": recording.isTranscribed,
        ]
        if let categoryName = recording.categoryName { row["category"] = categoryName }
        let tags = tagNames(for: recording)
        if !tags.isEmpty { row["tags"] = tags }
        if let transcript = recording.transcript {
            row["wordCount"] = transcript.wordCount
            // Flagged because a live preview is the lossy first draft and is
            // replaced by the post-sync pass; quoting one as final is a mistake a
            // model can only avoid if it's told.
            if transcript.isLivePreview { row["isLivePreviewOnly"] = true }
            if !transcript.speakers.isEmpty { row["speakerCount"] = transcript.speakers.count }
        }
        if let summaries = recording.summaries, !summaries.isEmpty {
            row["summaries"] = summaries.map(\.templateName)
        }
        if let items = recording.actionItems, !items.isEmpty {
            row["actionItemCount"] = items.count
            row["openActionItemCount"] = items.filter { !$0.isDone }.count
        }
        if let status = TranscriptionCoordinator.shared.status(for: recording)?.label {
            row["status"] = status
        }
        return row
    }

    private func tagNames(for recording: Recording) -> [String] {
        guard let tagIds = recording.tagIds else { return [] }
        // Dangling ids — a tag deleted without the sweep, or a hand-edited library
        // — are dropped rather than reported as bare uuids.
        return tagIds.compactMap { CategoryStore.shared.category(id: $0)?.name }
    }

    // MARK: - get_transcript

    private func getTranscript(_ arguments: MCPArguments) throws -> String {
        let recording = try resolve(arguments)
        guard let transcript = recording.transcript else {
            throw MCPToolFailure(
                "“\(recording.displayTitle)” hasn't been transcribed yet"
                + (recording.isSynced ? "." : " — it's still on the recorder."))
        }

        var lines = [
            "# \(recording.displayTitle)",
            "",
            "Recorded: \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))",
            "Duration: \(recording.duration > 0 ? recording.duration.timecodeText : "unknown")",
        ]
        if let categoryName = recording.categoryName { lines.append("Category: \(categoryName)") }
        let tags = tagNames(for: recording)
        if !tags.isEmpty { lines.append("Tags: \(tags.joined(separator: ", "))") }
        if let calendarEventTitle = recording.calendarEventTitle {
            lines.append("Calendar event: \(calendarEventTitle)")
        }
        if transcript.isLivePreview {
            lines.append(
                "NOTE: this is the live first-draft transcript, not the final pass. "
                + "It is lossier than the transcript this recording will have once "
                + "the audio has been processed.")
        }
        if transcript.hasSpeakers {
            let names = recording.speakerNames ?? [:]
            // Anonymous diarization labels, said out loud: they are per recording
            // and mean nothing across two of them. A model that assumes "Speaker 1"
            // is the same person in two transcripts will confidently attribute a
            // quote to the wrong person.
            lines.append(
                "Speakers are labelled per recording and are not the same people "
                + "across different recordings"
                + (names.isEmpty ? "." : "; names below were assigned by the user."))
        }
        lines.append("")

        let body = transcript.timecodedText(speakerNames: recording.speakerNames)
        lines.append(Self.capped(body, at: Self.maxTranscriptChars))
        return lines.joined(separator: "\n")
    }

    // MARK: - search_recordings

    private func searchRecordings(_ arguments: MCPArguments) throws -> String {
        let query = try arguments.requiredString("query")
        let needle = query.lowercased()

        // The same title-or-transcript match `LibraryView.matching` does, so the
        // agent and the phone find the same recordings for the same words. Two
        // independent predicates would diverge, which is the class of bug
        // `TimeInterval.timecodeText` exists to prevent.
        var hits: [[String: Any]] = []
        var total = 0
        for recording in library.recordings.sorted(by: { $0.createdAt > $1.createdAt }) {
            let plainText = recording.transcript?.plainText
            let inTitle = recording.displayTitle.lowercased().contains(needle)
            let inTranscript = plainText?.lowercased().contains(needle) ?? false
            guard inTitle || inTranscript else { continue }
            total += 1
            guard hits.count < Self.maxSearchResults else { continue }

            var hit = row(for: recording)
            hit["matchedTitle"] = inTitle
            // A snippet rather than the transcript: enough to judge whether this is
            // the right recording, after which `get_transcript` fetches it whole.
            if inTranscript, let plainText, let snippet = Self.snippet(of: plainText, around: needle) {
                hit["snippet"] = snippet
            }
            hits.append(hit)
        }

        return Self.jsonText([
            "query": query,
            "total": total,
            "returned": hits.count,
            "recordings": hits,
        ])
    }

    /// A window of `text` centred on the first occurrence of `needle`, with
    /// ellipses where it was cut.
    private static func snippet(of text: String, around needle: String) -> String? {
        guard let range = text.range(of: needle, options: .caseInsensitive) else { return nil }
        let padding = max(0, (snippetChars - needle.count) / 2)
        let start = text.index(range.lowerBound, offsetBy: -padding, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: padding, limitedBy: text.endIndex)
            ?? text.endIndex
        var snippet = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }

    // MARK: - get_summaries

    private func getSummaries(_ arguments: MCPArguments) throws -> String {
        let recording = try resolve(arguments)
        guard let summaries = recording.summaries, !summaries.isEmpty else {
            throw MCPToolFailure(
                "“\(recording.displayTitle)” has no summaries yet"
                + (recording.isTranscribed
                    ? ". Summaries are generated on the iPhone; use get_transcript to read it instead."
                    : " because it hasn't been transcribed."))
        }
        return Self.jsonText([
            "id": recording.id,
            "title": recording.displayTitle,
            "summaries": summaries
                .sorted { $0.createdAt < $1.createdAt }
                .map { summary in
                    [
                        "template": summary.templateName,
                        "templateId": summary.templateId,
                        "createdAt": Self.iso8601.string(from: summary.createdAt),
                        "text": summary.text,
                    ]
                },
        ])
    }

    // MARK: - list_action_items

    private func listActionItems(_ arguments: MCPArguments) throws -> String {
        // Defaults to open-only. "What do I still have to do" is the question this
        // tool exists to answer, and a list including everything ticked off since
        // January answers it worse the longer the library gets.
        let openOnly = try arguments.bool("open_only") ?? true

        var groups: [[String: Any]] = []
        var count = 0
        for (recording, items) in itemsByRecording(openOnly: openOnly) {
            count += items.count
            groups.append([
                "recordingId": recording.id,
                "recordingTitle": recording.displayTitle,
                "recordedAt": Self.iso8601.string(from: recording.createdAt),
                "items": items.map { item -> [String: Any] in
                    var json: [String: Any] = ["text": item.text, "isDone": item.isDone]
                    if let owner = item.owner { json["owner"] = owner }
                    // The deadline as spoken, never resolved to a date — see
                    // `ActionItem.dueText`. A model must not "helpfully" turn
                    // "by Friday" into a calendar date; the phrase is all the
                    // evidence there is.
                    if let dueText = item.dueText { json["due"] = dueText }
                    if let offset = item.sourceOffset { json["atTimecode"] = offset.timecodeText }
                    return json
                },
            ])
        }

        return Self.jsonText([
            "openOnly": openOnly,
            "total": count,
            "byRecording": groups,
        ])
    }

    /// The library's action items grouped by recording, newest recording first,
    /// preserving each recording's own item order (which `ActionItemMerge` keeps
    /// stable on purpose — re-sorting would reshuffle the user's list).
    private func itemsByRecording(openOnly: Bool) -> [(Recording, [ActionItem])] {
        var order: [String] = []
        var byId: [String: (Recording, [ActionItem])] = [:]
        for (recording, item) in library.allActionItems {
            if openOnly && item.isDone { continue }
            if var existing = byId[recording.id] {
                existing.1.append(item)
                byId[recording.id] = existing
            } else {
                byId[recording.id] = (recording, [item])
                order.append(recording.id)
            }
        }
        return order
            .compactMap { byId[$0] }
            .sorted { $0.0.createdAt > $1.0.createdAt }
    }

    // MARK: - ask

    /// Ask the **on-device** model about one recording, or about the library.
    ///
    /// Same engine, same corpus and same privacy posture as the phone's Ask and
    /// the desktop view's: Apple Intelligence, on this iPhone, nothing uploaded.
    /// `AskCorpus` picks the sources so all three clients answer identically —
    /// two independent keyword matchers would give different answers to the same
    /// words.
    ///
    /// Note the asymmetry this creates and don't try to "fix" it: the calling
    /// agent is a cloud model, but the answer it gets back was composed on the
    /// phone. That is the point. The alternative — shipping the corpus to the
    /// agent — is what `get_transcript` already does, explicitly, one recording
    /// at a time.
    private func ask(_ arguments: MCPArguments) async throws -> String {
        let question = try arguments.requiredString("question")
        guard question.count <= Self.maxQuestionChars else {
            throw MCPToolFailure(
                "That question is too long (\(question.count) characters, limit "
                + "\(Self.maxQuestionChars)). The on-device model has a small context "
                + "window and a long question crowds out the transcript.")
        }

        let qa = TranscriptQA()
        guard case .ready = qa.readiness else {
            if case .unavailable(let reason) = qa.readiness { throw MCPToolFailure(reason) }
            throw MCPToolFailure("Apple Intelligence isn't available on this iPhone.")
        }

        let corpus: String
        var sources: [Recording] = []
        if arguments.keys.contains("id") {
            let recording = try resolve(arguments)
            guard let text = recording.transcript?.plainText, !text.isEmpty else {
                throw MCPToolFailure("“\(recording.displayTitle)” has no transcript to ask about.")
            }
            corpus = text
            sources = [recording]
        } else {
            let grounding = AskCorpus.grounding(for: question, in: library.recordings)
            guard !grounding.corpus.isEmpty else {
                throw MCPToolFailure("Nothing in this library is transcribed yet.")
            }
            corpus = grounding.corpus
            sources = grounding.sources
        }

        qa.ground(on: corpus)

        // Foundation Models streams **cumulative snapshots, not deltas**, so the
        // last one is the whole answer — assign, never append.
        var answer = ""
        for await snapshot in qa.answer(to: question) {
            answer = snapshot
        }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPToolFailure(
                "The on-device model returned nothing. It may still be downloading; try again shortly.")
        }

        var lines = [trimmed]
        if !sources.isEmpty {
            lines.append("")
            lines.append("Answered from: " + sources.map { recording in
                "\(recording.displayTitle) (\(recording.id))"
            }.joined(separator: "; "))
        }
        // Stated every time rather than once in the tool description, because a
        // model reading a long tool result will act on what's in front of it: the
        // answer came from a small on-device model over a capped slice of text,
        // and treating it as authoritative over the transcript itself is wrong.
        lines.append(
            "This answer was generated on the iPhone by Apple Intelligence from a "
            + "capped excerpt of the transcript(s) above. Use get_transcript to read "
            + "the source directly.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared

    /// The recording named by the `id` argument.
    ///
    /// A wrong id fails with the count of what *is* there rather than a bare "not
    /// found", because the commonest cause is an agent inventing an id instead of
    /// calling `list_recordings` — and saying so is what redirects it.
    private func resolve(_ arguments: MCPArguments) throws -> Recording {
        let id = try arguments.requiredString("id")
        guard let recording = library.recordings.first(where: { $0.id == id }) else {
            throw MCPToolFailure(
                "No recording with id “\(id)”. Ids come from list_recordings or "
                + "search_recordings; this library currently has "
                + "\(library.recordings.count) recording(s).")
        }
        return recording
    }

    private static func capped(_ text: String, at limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
            + "\n\n[Truncated at \(limit) characters — this recording's transcript is "
            + "\(text.count) characters long.]"
    }

    /// A JSON payload as text, for a `text` content block.
    ///
    /// Pretty-printed on purpose: these results are read by a language model, and
    /// the extra whitespace buys accurate field attribution in a nested object far
    /// more cheaply than a misread `owner` costs.
    private static func jsonText(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else {
            return #"{"error":"The iPhone couldn't encode that result."}"#
        }
        return text
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Descriptors

private extension MCPEndpoint.Tool {

    /// The `tools/list` entry.
    ///
    /// The descriptions are the whole interface as far as the model is concerned —
    /// it picks the tool and fills the arguments from these words alone. Two rules
    /// they all follow: say what comes back (so the model doesn't call
    /// `get_transcript` on ten recordings to find out), and say what the data
    /// *is* (a private recording), without inviting a sweep of the library.
    var descriptor: MCPTool {
        switch self {
        case .listRecordings:
            return MCPTool(
                name: rawValue,
                title: "List recordings",
                description: """
                    List recordings in the user's Bounce library, newest first. Returns \
                    metadata only — id, title, date, duration, category, tags, speaker and \
                    word counts, and which summaries exist — and never transcript text. \
                    Start here to find the id of a recording, then use get_transcript, \
                    get_summaries or ask for its contents.
                    """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": [
                            "type": "integer",
                            "description":
                                "How many recordings to return, 1–200. Defaults to 25. "
                                + "Values outside the range are clamped.",
                            "minimum": 1,
                            "maximum": 200,
                        ],
                        "since": [
                            "type": "string",
                            "description":
                                "Only recordings made at or after this moment. An ISO 8601 "
                                + "timestamp, or a bare YYYY-MM-DD day (interpreted as "
                                + "midnight UTC).",
                        ],
                        "category": [
                            "type": "string",
                            "description":
                                "Only recordings in this category, matched case-insensitively "
                                + "by name (for example \"Meeting\"). Fails with the list of "
                                + "known categories if the name doesn't exist.",
                        ],
                    ],
                    "additionalProperties": false,
                ])

        case .getTranscript:
            return MCPTool(
                name: rawValue,
                title: "Get a transcript",
                description: """
                    Read the full transcript of one recording, with timecodes and speaker \
                    labels. This is a verbatim record of a private conversation or meeting, \
                    so fetch the specific recording being asked about rather than several \
                    speculatively. Speaker labels are per recording — "Speaker 1" in two \
                    different recordings is not the same person.
                    """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "Recording id, from list_recordings or search_recordings.",
                        ],
                    ],
                    "required": ["id"],
                    "additionalProperties": false,
                ])

        case .searchRecordings:
            return MCPTool(
                name: rawValue,
                title: "Search recordings",
                description: """
                    Find recordings whose title or transcript contains the query, \
                    case-insensitively. Returns the same metadata as list_recordings plus a \
                    short snippet around the match — enough to pick the right recording, \
                    after which get_transcript reads it in full. Use this rather than \
                    listing everything and scanning it yourself.
                    """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Text to look for in titles and transcripts.",
                        ],
                    ],
                    "required": ["query"],
                    "additionalProperties": false,
                ])

        case .getSummaries:
            return MCPTool(
                name: rawValue,
                title: "Get summaries",
                description: """
                    Read the AI summaries already generated on the iPhone for one recording \
                    — typically an overview, key points, or extracted actions, depending on \
                    which templates ran. Much shorter than the transcript, so prefer this \
                    when the question is about what a meeting concluded rather than what \
                    was said word for word.
                    """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "Recording id, from list_recordings or search_recordings.",
                        ],
                    ],
                    "required": ["id"],
                    "additionalProperties": false,
                ])

        case .listActionItems:
            return MCPTool(
                name: rawValue,
                title: "List action items",
                description: """
                    List the tasks extracted from recordings across the whole library, \
                    grouped by recording. Each item has its text, the owner named in the \
                    recording if there was one, and the deadline exactly as it was spoken \
                    ("by Friday") — that phrase is never resolved to a date and must not be \
                    treated as one. Read-only: items cannot be ticked off or added here.
                    """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "open_only": [
                            "type": "boolean",
                            "description":
                                "True (the default) returns only items not yet ticked off. "
                                + "False returns completed ones too.",
                        ],
                    ],
                    "additionalProperties": false,
                ])

        case .ask:
            return MCPTool(
                name: rawValue,
                title: "Ask about a recording",
                description: """
                    Ask a natural-language question and have the iPhone's own on-device \
                    model answer it from the transcripts, without sending them anywhere. \
                    Pass a recording id to ask about one recording; omit it to ask across \
                    the library, in which case the most relevant transcripts are chosen \
                    automatically. The answer comes from a small on-device model reading a \
                    capped excerpt, so it is a summary rather than a source — use \
                    get_transcript when precision matters. Requires Apple Intelligence to be \
                    available on the iPhone.
                    """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "question": [
                            "type": "string",
                            "description": "The question, 500 characters or fewer.",
                            "maxLength": 500,
                        ],
                        "id": [
                            "type": "string",
                            "description":
                                "Optional recording id to scope the question to one "
                                + "recording. Omit to ask across the library.",
                        ],
                    ],
                    "required": ["question"],
                    "additionalProperties": false,
                ])
        }
    }
}

// MARK: - The read-only view onto the app

/// What `MCPEndpoint` is allowed to see.
///
/// This exists to make a write tool hard to add **by accident**. `MCPEndpoint`
/// holds one of these rather than an `AppModel`, so `delete`, `rename`,
/// `setCategory`, `retranscribe` and the rest are simply not reachable from the
/// endpoint — they don't compile. Widening this protocol is the deliberate act
/// that would be required first, and it should not happen: see the security note
/// at the top of this file.
///
/// The conformance is declared here rather than in `AppModel.swift` so the whole
/// arrangement — the narrow view and the type it narrows — reads in one place.
@MainActor
protocol MCPLibraryReading: AnyObject {
    /// The library, as `AppModel` republishes it. Read through this rather than
    /// `RecordingStore.shared` for the reason in `WebAPI.swift`'s header: the
    /// store is the persistence layer, `AppModel` is what the rest of the app
    /// actually agrees with.
    var recordings: [Recording] { get }
    /// Every action item in the library, paired with the recording it came from.
    var allActionItems: [(recording: Recording, item: ActionItem)] { get }
}

extension AppModel: MCPLibraryReading {}
