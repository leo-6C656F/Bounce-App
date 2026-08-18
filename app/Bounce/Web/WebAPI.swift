import Foundation

/// Routes for the desktop view.
///
/// **Every handler runs on the main actor.** `HTTPServer` calls in on its own
/// queue; `handle` hops once, at the edge, and never hops back off. This is not
/// tidiness — `RecordingStore` is a plain class with an unsynchronised
/// `[Recording]` cache and no lock, and `SWIFT_STRICT_CONCURRENCY: minimal`
/// means a handler touching it from the network queue compiles clean and races
/// at runtime.
///
/// **Every write goes through `AppModel`, never `RecordingStore` directly.**
/// `AppModel.rename` and friends write *and then* call
/// `SyncManager.refreshLibrary()`, which is what republishes the library to
/// SwiftUI. A handler that skips that persists correctly and leaves the phone
/// showing stale data — and if the user then edits on the phone, the phone
/// writes its stale copy back over the browser's edit.
@MainActor
final class WebAPI {

    private unowned let model: AppModel
    private let session: WebSession
    private let live: LiveChannel
    /// In-flight summary jobs, keyed `recordingId|templateId`.
    private var summarizing: Set<String> = []
    /// How long a `summarize` job may hold its key before the safety net frees
    /// it. Generous — real on-device generation finishes in tens of seconds —
    /// because the only thing it guards is a permanently-wedged model session.
    private static let summaryJobTimeout: TimeInterval = 180

    /// The MCP server. Built here rather than injected because its only dependency
    /// is the same `AppModel` this type already holds, and it has no lifecycle of
    /// its own.
    private lazy var mcp = MCPEndpoint(library: model)

    init(model: AppModel, session: WebSession, live: LiveChannel) {
        self.model = model
        self.session = session
        self.live = live
    }

    // MARK: - Entry point

    nonisolated func handle(_ request: HTTPRequest, respond: @escaping @Sendable (HTTPResponse) -> Void) {
        Task { @MainActor in
            respond(await self.route(request))
        }
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        // Gate 1: Host. Before anything else, including the login page — a
        // request that lies about the host gets nothing at all to work with.
        guard session.isAllowedHost(request.hostName) else {
            return .error(403, "Unrecognised host.")
        }

        let path = request.path

        // Gate 2: same-site. A `text/plain` body makes a cross-origin POST a
        // CORS "simple request" — no preflight — so without this any website
        // the user visits could spend the pairing attempt cap and switch the
        // server off remotely.
        guard !request.isCrossSite else {
            return .error(403, "Cross-site requests aren't accepted.")
        }

        // Unauthenticated surface: the page shell and the pairing exchange.
        switch (request.method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return WebClient.page()
        case ("GET", "/api/session"):
            // Both credentials, not just the cookie. This is the one route whose
            // whole job is answering "am I authenticated", so a valid bearer token
            // being told `paired: false` here is worse than useless — it's the
            // first thing a script author calls to check their setup, and it would
            // send them debugging a token that already works.
            let paired = session.isAuthorized(token: token(in: request)) || hasValidBearer(request)
            return .json(["paired": paired])
        case ("POST", "/api/pair"):
            return pair(request)
        default:
            break
        }

        // Gate 3: token — either a browser session cookie or a long-lived API
        // bearer token.
        //
        // **This is the only gate a bearer token satisfies.** Gates 1 and 2 above
        // still apply and were deliberately not relaxed to let agents in: they
        // defend against a web page the user is merely visiting driving this server
        // from inside their browser, which a token does nothing about because the
        // browser would attach the cookie automatically. Both gates already pass
        // non-browser clients — `isCrossSite` reads "no Sec-Fetch-Site and no
        // Origin" as same-site, and `isAllowedHost` accepts any private IPv4 — so
        // curl and MCP clients work without widening anything.
        let cookieAuthorized = session.isAuthorized(token: token(in: request))
        guard cookieAuthorized || hasValidBearer(request) else {
            // `EventSource` treats any non-200 as fatal — `readyState` goes to
            // CLOSED and it never retries — so an expired token on this route
            // must not be answered with a 401 or the browser's live channel is
            // dead until the page is reloaded. Open the stream and say so in
            // band instead.
            if path == "/api/live" {
                return unauthorizedStream()
            }
            return .error(401, "Not paired with this iPhone.")
        }

        // Gate 4: a bearer token is **read-only**. This is what makes the
        // documented guarantee true rather than aspirational.
        //
        // `MCPEndpoint`'s six tools are read-only by construction, but the REST
        // routes below are not, and Gate 3 admits a bearer token to all of them —
        // so until this gate existed, a token could `DELETE /api/recordings/<id>`
        // or retitle, recategorize, correct, re-transcribe and re-summarize any
        // recording. That is exactly the failure `docs/api.md` argues against when
        // it says the thing holding this token is a language model acting on
        // instructions that may have come out of a transcript: a prompt-injected
        // agent with a delete verb costs the user their recordings.
        //
        // Scoped to the *credential*, not the route, because the browser needs
        // every one of those writes — the desk view edits titles, speakers and
        // categories. Cookie sessions are therefore untouched; only bearer-only
        // requests are narrowed, which is why Gate 3 now reports which credential
        // answered. `POST /mcp` is the one write-shaped exception: it is a
        // JSON-RPC envelope over read-only tools, not a mutation.
        guard cookieAuthorized
                || request.method == "GET"
                || (request.method == "POST" && path == "/mcp") else {
            return .error(403, "This token is read-only.")
        }

        // Collection routes.
        switch (request.method, path) {
        case ("GET", "/api/library"):     return library(request)
        case ("GET", "/api/search"):      return search(request)
        case ("GET", "/api/openapi.json"): return openAPI()
        // Behind all four gates, like every other authenticated route — and the
        // one `POST` Gate 4 lets a bearer token make, because it is a JSON-RPC
        // envelope over read-only tools rather than a mutation. The tools are
        // read-only by construction — see `MCPEndpoint`.
        case ("POST", "/mcp"):            return await mcp.respond(to: request.body)
        case ("GET", "/api/categories"):  return categories()
        case ("GET", "/api/templates"):   return templates()
        // Settings are **cookie-only in both directions**, which is deliberately
        // narrower than Gate 4.
        //
        // Gate 4 already refuses a bearer token the `PATCH`, because it is neither
        // a `GET` nor `POST /mcp`. It would happily allow the `GET` — and that is
        // the problem: the snapshot carries `webhookURLString`, and an internal
        // delivery endpoint is not nothing to hand to whatever is holding a
        // long-lived token out of a config file.
        //
        // The alternative was per-credential response shaping — threading
        // `cookieAuthorized` into the handler and redacting a field for one caller
        // — which means a payload whose shape depends on who asked, and a
        // redaction that has to be remembered every time a field is added. A whole
        // resource that one credential cannot reach is a rule that holds without
        // anyone maintaining it.
        //
        // The token's contract is "read the recordings", not "read the
        // configuration". Nothing in `docs/api.md` ever promised an agent this.
        case ("GET", "/api/settings"), ("PATCH", "/api/settings"):
            guard cookieAuthorized else {
                return .error(403, "Settings are only available to a paired browser.")
            }
            if request.method == "GET" { return .json(WebSettings.snapshotData()) }
            do {
                return .json(try WebSettings.applyData(patch: request.jsonBody() ?? [:]))
            } catch let error as WebSettingsError {
                return .error(error.status, error.message)
            } catch {
                return .error(500, "Couldn't save settings.")
            }
        case ("GET", "/api/live"):
            // Registered under the credential that opened it, so revoking that
            // credential can find and close it. Falling back to `""` — as this did
            // — put every bearer client in one bucket that no revoke ever matched,
            // so an agent's stream outlived its token for as long as the app stayed
            // open. Gate 3 has already passed, so a nil here is not reachable in
            // practice; it 401s in band rather than silently opening an unclosable
            // stream.
            guard let identity = streamIdentity(request) else { return unauthorizedStream() }
            return liveStream(token: identity)
        case ("GET", "/api/ask"):         return ask(request, recording: nil)
        default:                          break
        }

        // Per-recording routes: /api/recordings/<id>[/<action>]
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api", parts[1] == "recordings" else {
            return .error(404, "No such endpoint.")
        }
        let id = parts[2]
        let action = parts.count > 3 ? parts[3] : ""

        // The recording in progress. Readable, askable, and its voices can be
        // named — mid-meeting is when you actually know who is speaking, so those
        // names are parked by session id and attached when the file syncs.
        // Everything else needs a store entry that doesn't exist yet: there is no
        // file to play, and nothing to retitle, recategorize, or delete.
        if id == Self.liveId {
            guard let live = liveRecording() else {
                return .error(404, "Nothing is recording.")
            }
            switch (request.method, action) {
            case ("GET", ""):          return .json(WebRecordingDetail(live))
            case ("GET", "ask"):       return ask(request, recording: live)
            case ("POST", "speakers"): return setLiveSpeakers(live, request)
            default:
                return .error(400, "That isn't available until the recording finishes.")
            }
        }

        guard let recording = RecordingStore.shared.recording(id: id) else {
            return .error(404, "No such recording.")
        }

        switch (request.method, action) {
        case ("GET", ""):           return .json(WebRecordingDetail(recording))
        case ("GET", "audio"):      return audio(for: recording, request: request)
        case ("GET", "waveform"):   return await waveform(for: recording)
        case ("POST", "title"):     return setTitle(recording, request)
        case ("POST", "speakers"):  return setSpeakers(recording, request)
        case ("POST", "correct"):   return correctWord(recording, request)
        case ("POST", "category"):  return setCategory(recording, request)
        case ("POST", "transcribe"): return transcribe(recording, request)
        case ("POST", "summarize"): return summarize(recording, request)
        case ("GET", "ask"):        return ask(request, recording: recording)
        case ("DELETE", ""):        return delete(recording)
        default:                    return .error(405, "Not allowed on this resource.")
        }
    }

    private func token(in request: HTTPRequest) -> String? {
        request.cookies["bounce_session"]
    }

    /// The credential a long-lived stream is registered under, so revocation can
    /// find it again.
    ///
    /// The token is checked when a stream opens and never again — that's what makes
    /// `closeStreams(token:)` the only way to cut one off, and why the key has to be
    /// the actual credential rather than a placeholder. Cookie first, since a
    /// browser is the common case and `WebSession.onRevoke` already fires for it;
    /// bearer second, revoked via `DesktopServer.revokeAPIToken()`.
    ///
    /// Never logged. `LiveChannel` doesn't log subscriber keys, and it must not
    /// start — this is a credential.
    private func streamIdentity(_ request: HTTPRequest) -> String? {
        if let cookie = token(in: request), session.isAuthorized(token: cookie) { return cookie }
        guard hasValidBearer(request) else { return nil }
        return APITokenFormat.bearer(in: request.header("authorization"))
    }

    /// Whether the request carries a valid `Authorization: Bearer <token>`.
    ///
    /// Compared in constant time by `APITokenFormat.matches` — a plain `==` on the
    /// stored token leaks its length and matching prefix through timing, which is
    /// enough to recover it a character at a time. Never logged, even redacted, on
    /// the success path: a per-request log line naming the credential is how a
    /// token ends up in a support thread.
    private func hasValidBearer(_ request: HTTPRequest) -> Bool {
        APITokenStore.matches(APITokenFormat.bearer(in: request.header("authorization")))
    }

    // MARK: - The recording in progress

    /// Id the in-progress recording is addressed by.
    ///
    /// It needs a synthetic one because **a live recording is not a `Recording`
    /// yet** — the file is still on the recorder, so there is no store entry and
    /// no real id until it syncs. `LiveTranscriptStore` parks the transcript by
    /// session id in the meantime.
    static let liveId = "live"

    /// The recording in progress, shaped as a `Recording` so it flows through
    /// `WebRecordingRow`/`WebRecordingDetail` unchanged.
    ///
    /// Modelling it as the same type is the whole point: the browser then gets a
    /// live recording as an ordinary library item it can read and ask about,
    /// rather than needing a separate mode to look at it in. `hasAudio` comes out
    /// false on its own (no `audioFilename`), so the reader hides the transport.
    private func liveRecording() -> Recording? {
        let live = LiveTranscriber.shared
        guard let sessionId = live.sessionId, live.isRunning || live.hasContent else { return nil }

        let startedAt = RecordingManager.shared.state.startedAt ?? Date()
        return Recording(
            id: Self.liveId,
            sessionId: sessionId,
            deviceSN: DeviceManager.shared.device?.serialNumber ?? "",
            title: "Recording in progress",
            duration: max(0, Date().timeIntervalSince(startedAt)),
            createdAt: startedAt,
            transcript: Transcript(
                segments: live.segments,
                localeIdentifier: Locale.current.identifier,
                createdAt: Date(),
                isPreview: true),
            speakerNames: LiveSpeakerNameStore.shared.names(forSessionId: sessionId))
    }

    /// Name the voices in the recording that's still running.
    ///
    /// Parked by session id rather than written to a recording, because there
    /// isn't one yet — `LiveSpeakerNameStore` attaches them when the file lands,
    /// the same way the live transcript and highlight marks are handled.
    private func setLiveSpeakers(_ live: Recording, _ request: HTTPRequest) -> HTTPResponse {
        guard let raw = request.jsonBody()?["names"] as? [String: Any] else {
            return .error(400, "Missing names.")
        }
        LiveSpeakerNameStore.shared.set(
            raw.compactMapValues { $0 as? String }, forSessionId: live.sessionId)
        guard let updated = liveRecording() else {
            return .error(404, "Nothing is recording.")
        }
        return .json(WebRecordingDetail(updated))
    }

    // MARK: - Pairing

    private func pair(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.jsonBody(), let code = body["code"] as? String else {
            return .error(400, "Missing code.")
        }
        switch session.pair(
            code: code,
            address: request.client,
            userAgent: request.header("user-agent") ?? ""
        ) {
        case .paired(let token):
            // HttpOnly so page script can't read it; SameSite=Strict so a
            // cross-site request can't carry it even if one gets through. No
            // Max-Age deliberately — a session cookie, because the state it
            // authenticates lives in memory and dies with the app, and cookies
            // ignore port, so a long-lived one would be offered to whatever
            // host holds this DHCP address next.
            //
            // `Secure` when the server is serving HTTPS (the default), so the
            // cookie is never sent back over cleartext. It is *conditional*: with
            // TLS switched off the origin is plain `http://192.168.x.x`, and a
            // `Secure` cookie there would never be sent at all, silently breaking
            // every authenticated request. `SameSite=Strict` already covers the
            // cross-site case regardless of scheme.
            let secure = DesktopServer.shared.useTLS ? "; Secure" : ""
            let cookie = "bounce_session=\(token); Path=/; HttpOnly; SameSite=Strict\(secure)"
            let data = (try? JSONSerialization.data(withJSONObject: ["paired": true])) ?? Data()
            return .json(data, status: 200, extraHeaders: ["Set-Cookie": cookie])

        case .wrongCode(let remaining):
            let payload: [String: Any] = [
                "error": "That code doesn't match.",
                "remainingAttempts": remaining,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return .json(data, status: 401)

        case .lockedOut:
            // Not "desktop view has been switched off" — that was true when a
            // lockout tore down the whole listener; now `WebSession` scopes it
            // per source address, so the server (and every other paired
            // browser) keeps running. This message is specific to the client
            // that tripped the cap.
            return .error(429, "Too many attempts from this device. Desktop view is still running for other devices.")
        }
    }

    // MARK: - Reads

    /// `GET /api/openapi.json` — a machine-readable schema of the read surface.
    ///
    /// **Hand-maintained, and therefore a drift liability**: nothing checks it
    /// against `route`'s dispatch table, so a route added without touching this is
    /// silently absent. Kept deliberately narrow for that reason — the read routes
    /// an external client actually needs, described well, rather than an exhaustive
    /// mirror that will rot. `docs/api.md` is the full reference for humans; the MCP
    /// endpoint is the richer surface for agents.
    ///
    /// Response shapes are described loosely (`type: object`) on purpose: pinning
    /// every field of `WebRecordingDetail` here would guarantee the two disagree the
    /// first time that type changes.
    private func openAPI() -> HTTPResponse {
        func path(_ summary: String, params: [[String: Any]] = []) -> [String: Any] {
            var get: [String: Any] = [
                "summary": summary,
                "responses": [
                    "200": ["description": "Success"],
                    "401": ["description": "Missing or invalid credentials"],
                ],
            ]
            if !params.isEmpty { get["parameters"] = params }
            return ["get": get]
        }
        func query(_ name: String, _ description: String, required: Bool) -> [String: Any] {
            [
                "name": name, "in": "query", "required": required,
                "description": description, "schema": ["type": "string"],
            ]
        }
        let idParam: [String: Any] = [
            "name": "id", "in": "path", "required": true,
            "description": "Recording id, or \"live\" for the recording in progress.",
            "schema": ["type": "string"],
        ]

        let schema: [String: Any] = [
            "openapi": "3.1.0",
            "info": [
                "title": "Bounce local API",
                // Read from the bundle rather than hardcoded, so the schema can't
                // claim a version the app isn't.
                "version": Bundle.main
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                "description": """
                    Read access to one iPhone's recording library, served by the \
                    Bounce app over the local network. The phone must be running \
                    Bounce with Desktop view switched on. Nothing here reaches a \
                    cloud service. See docs/api.md for the full reference, \
                    including the write routes the browser client uses.
                    """,
            ],
            "components": [
                "securitySchemes": [
                    "bearerAuth": ["type": "http", "scheme": "bearer"],
                ],
            ],
            "security": [["bearerAuth": [String]()]],
            "paths": [
                "/api/library": path(
                    "A page of recordings, newest first. Returns "
                        + "{items, total, offset, limit}; page with offset/limit.",
                    params: [
                        query("offset", "Row to start at (default 0).", required: false),
                        query("limit", "Max rows to return (default 200, max 500).", required: false),
                    ]),
                "/api/search": path(
                    "A page of recordings whose title or transcript contains a "
                        + "string. Returns {items, total, offset, limit}.",
                    params: [
                        query("q", "Search text.", required: true),
                        query("offset", "Row to start at (default 0).", required: false),
                        query("limit", "Max rows to return (default 200, max 500).", required: false),
                    ]),
                "/api/recordings/{id}": ["get": [
                    "summary": "One recording, with its transcript and summaries.",
                    "parameters": [idParam],
                    "responses": [
                        "200": ["description": "Success"],
                        "404": ["description": "No such recording"],
                    ],
                ]],
                "/api/recordings/{id}/audio": ["get": [
                    "summary": "The recording's MP3. Supports Range requests.",
                    "parameters": [idParam],
                    "responses": [
                        "200": ["description": "Audio"],
                        "206": ["description": "Partial content"],
                        "404": ["description": "No audio for this recording"],
                    ],
                ]],
                "/api/categories": path("Categories the user has defined."),
                "/api/templates": path("Summary templates available."),
                // Both verbs are documented as `403` for a bearer token rather
                // than given a `security: []` override. An empty security array
                // in OpenAPI means "no credential required", which is the
                // opposite of what is true here — this needs a *stronger*
                // credential than the rest of the document, and the spec has no
                // vocabulary for "cookie only" that a generated client would
                // honour. Saying it in the description and the response is the
                // honest encoding.
                "/api/settings": [
                    "get": [
                        "summary": """
                            Current settings. Requires a paired browser session — \
                            a bearer token is refused, because the payload carries \
                            the delivery webhook URL. Secrets are never returned; \
                            the snapshot reports only whether each is set.
                            """,
                        "responses": [
                            "200": ["description": "Success"],
                            "403": ["description": "Bearer tokens cannot read settings"],
                        ],
                    ],
                    "patch": [
                        "summary": """
                            Change settings. Sparse — only the keys present are \
                            applied, and nothing is written unless every field \
                            validates. Returns the full fresh snapshot. Requires a \
                            paired browser session.
                            """,
                        "responses": [
                            "200": ["description": "Saved; returns the new snapshot"],
                            "400": ["description": "Unknown key, wrong type, or a value the phone can't display"],
                            "403": ["description": "Bearer tokens are read-only"],
                        ],
                    ],
                ],
                "/api/ask": path(
                    "Ask a question across the library. Streams as server-sent events.",
                    params: [query("q", "The question. Max 500 characters.", required: true)]),
            ],
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
        else { return .error(500, "Couldn't build the schema.") }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: .data(data))
    }

    /// `GET /api/search?q=` — the same title-and-transcript match the Library's
    /// search field does.
    ///
    /// Exists so an agent can find one recording without pulling the entire library
    /// and matching client-side. That matters more than it sounds: the full library
    /// payload carries every transcript, so "search" over MCP without this would
    /// mean shipping every private meeting to the caller to answer one question.
    ///
    /// Returns rows, not details — the caller follows up with
    /// `/api/recordings/<id>` for the transcript it actually wants.
    /// Default page size, and the ceiling a client can ask for. Generous — the
    /// rows are small (no transcript text) — but bounded so one request can't
    /// serialize the whole library on the main actor, which is A12's whole point.
    private static let defaultPageLimit = 200
    private static let maxPageLimit = 500
    /// Hard ceiling on how many search matches are ever collected across all
    /// pages, so a one-character query (`q=e`) can't build a result set the size
    /// of the library.
    private static let searchCeiling = 1000

    /// `?offset=&limit=`, clamped. A missing or unparseable value falls back to
    /// the default rather than erroring — pagination is an optimisation, and a
    /// client that ignores it should still get a (bounded) first page.
    private func pageBounds(_ request: HTTPRequest) -> (offset: Int, limit: Int) {
        let requested = request.query["limit"].flatMap(Int.init) ?? Self.defaultPageLimit
        let limit = min(max(1, requested), Self.maxPageLimit)
        let offset = max(0, request.query["offset"].flatMap(Int.init) ?? 0)
        return (offset, limit)
    }

    private func search(_ request: HTTPRequest) -> HTTPResponse {
        let needle = (request.query["q"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return .error(400, "Missing q.") }

        // The lowercase-per-transcript scan is gone: `WebSearchIndex` keeps a
        // cached lowercased haystack per recording and caps the match set, so a
        // search is a `contains` over pre-lowercased strings rather than tens of
        // megabytes re-cased on the main actor per request (A13).
        let (offset, limit) = pageBounds(request)
        let matches = WebSearchIndex.shared.matches(needle, ceiling: Self.searchCeiling)
        let total = matches.count
        let window = offset < total ? matches[offset..<min(offset + limit, total)] : matches[0..<0]
        let items = window.map { recording in
            WebRecordingRow(
                recording,
                status: TranscriptionCoordinator.shared.status(for: recording)?.label)
        }
        return .json(WebLibraryPage(items: items, total: total, offset: offset, limit: limit))
    }

    private func library(_ request: HTTPRequest) -> HTTPResponse {
        let (offset, limit) = pageBounds(request)
        let recordings = RecordingStore.shared.recordings
        // Pinned at the top while it happens, so there is one list to look at
        // rather than a separate mode for "the one that's happening now". It
        // occupies global index 0; stored recordings follow.
        let live = liveRecording()
        let hasLive = live != nil
        let total = recordings.count + (hasLive ? 1 : 0)

        // Map ONLY the requested window to rows. A12's point is to bound the
        // serialize, so a WebRecordingRow is never built for a row outside the
        // page.
        let upper = min(offset + limit, total)
        var items: [WebRecordingRow] = []
        if offset < upper {
            items.reserveCapacity(upper - offset)
            for index in offset..<upper {
                if hasLive, index == 0, let live {
                    items.append(WebRecordingRow(live, status: "Recording"))
                } else {
                    let recording = recordings[index - (hasLive ? 1 : 0)]
                    items.append(WebRecordingRow(
                        recording,
                        status: TranscriptionCoordinator.shared.status(for: recording)?.label))
                }
            }
        }
        return .json(WebLibraryPage(items: items, total: total, offset: offset, limit: limit))
    }

    private func categories() -> HTTPResponse {
        .json(CategoryStore.shared.categories.map(WebCategory.init))
    }

    private func templates() -> HTTPResponse {
        .json(TemplateStore.shared.all.map(WebTemplate.init))
    }

    private func liveStream(token: String) -> HTTPResponse {
        let channel = live
        return HTTPResponse(
            status: 200,
            body: .eventStream(onOpen: { sink in
                Task { @MainActor in channel.add(sink, token: token) }
            }))
    }

    // MARK: - Ask

    /// Ask the on-device model about one recording, or about the whole library.
    ///
    /// A `GET` returning `text/event-stream` rather than a POST, because the
    /// answer streams and `EventSource` is the only thing in a browser that
    /// consumes a stream with no plumbing. The question rides in `?q=`.
    ///
    /// Same engine and same privacy posture as the phone's Ask: Apple
    /// Intelligence, on device, nothing uploaded. `AskCorpus` picks the sources
    /// so the two clients answer identically.
    private func ask(_ request: HTTPRequest, recording: Recording?) -> HTTPResponse {
        let question = (request.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return .error(400, "Ask a question.") }
        // The model's context window is small and the question is prepended to
        // the grounded transcript; an essay-length question just crowds it out.
        guard question.count <= 500 else { return .error(400, "That question is too long.") }

        let model = self.model
        return HTTPResponse(
            status: 200,
            body: .eventStream(onOpen: { sink in
                Task { @MainActor in
                    await Self.streamAnswer(
                        question: question, recording: recording, model: model, to: sink)
                }
            }))
    }

    @MainActor
    private static func streamAnswer(
        question: String,
        recording: Recording?,
        model: AppModel,
        to sink: any EventStreamSink
    ) async {
        func send(_ payload: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8)
            else { return }
            sink.sendEvent(text)
        }

        let qa = TranscriptQA()
        guard case .ready = qa.readiness else {
            if case .unavailable(let reason) = qa.readiness {
                send(["type": "unavailable", "reason": reason])
            }
            sink.close()
            return
        }

        let corpus: String
        var sources: [[String: Any]] = []

        if let recording {
            guard let transcript = recording.transcript?.plainText, !transcript.isEmpty else {
                send(["type": "unavailable", "reason": "This recording has no transcript yet."])
                sink.close()
                return
            }
            corpus = transcript
        } else {
            let grounding = AskCorpus.grounding(for: question, in: model.recordings)
            guard !grounding.corpus.isEmpty else {
                send(["type": "unavailable",
                      "reason": "Nothing in your library is transcribed yet."])
                sink.close()
                return
            }
            corpus = grounding.corpus
            sources = grounding.sources.map {
                ["id": $0.id, "title": $0.displayTitle,
                 "durationText": $0.duration.timecodeText]
            }
        }

        send(["type": "sources", "sources": sources])
        qa.ground(on: corpus)

        // Snapshots are cumulative strings, not deltas — the client assigns
        // rather than appends.
        for await partial in qa.answer(to: question) {
            guard sink.isOpen else { return }   // reader navigated away
            send(["type": "answer", "text": partial])
        }
        send(["type": "done"])
        sink.close()
    }

    /// A 200 event stream whose only message is "you're not paired", then close.
    /// See the token gate for why this can't just be a 401.
    private func unauthorizedStream() -> HTTPResponse {
        HTTPResponse(
            status: 200,
            body: .eventStream(onOpen: { sink in
                sink.sendEvent(#"{"type":"unauthorized"}"#)
                sink.close()
            }))
    }

    /// Range-aware audio. Safari will not scrub an `<audio>` element against a
    /// server that ignores `Range`, and the symptom looks like a broken file
    /// rather than a missing header.
    private func audio(for recording: Recording, request: HTTPRequest) -> HTTPResponse {
        guard let url = RecordingStore.shared.audioURL(for: recording) else {
            return .error(404, "This recording hasn't been synced to the iPhone yet.")
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > 0
        else {
            return .error(404, "The audio file is missing.")
        }

        // MP3 throughout, which the "audio must stay MP3" invariant already
        // guarantees for `AVAudioPlayer`/`AVAudioFile` — browsers play it with
        // no transcoding as a side effect.
        var headers = [
            "Content-Type": "audio/mpeg",
            "Accept-Ranges": "bytes",
        ]

        guard let range = request.byteRange else {
            return HTTPResponse(status: 200, headers: headers, body: .file(url: url, offset: 0, length: size))
        }

        let start: Int
        let end: Int
        switch (range.start, range.end) {
        case (let s?, let e?):
            start = s
            end = min(e, size - 1)
        case (let s?, nil):
            start = s
            end = size - 1
        case (nil, let suffix?):
            // `bytes=-500` means the last 500 bytes.
            start = max(0, size - suffix)
            end = size - 1
        default:
            return .error(400, "Malformed range.")
        }

        guard start >= 0, start <= end, start < size else {
            return HTTPResponse(
                status: 416,
                headers: ["Content-Range": "bytes */\(size)"],
                body: .data(Data()))
        }

        headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        return HTTPResponse(
            status: 206,
            headers: headers,
            body: .file(url: url, offset: start, length: end - start + 1))
    }

    /// `peaks(for:)`, which decodes on a miss — the detail-view entry point, not
    /// the list one.
    ///
    /// That looks like it violates the cache's two-entry-point rule, so: the
    /// rule is about *context*, not about which caller is remote. This route is
    /// reached only from the browser's detail pane, one recording at a time,
    /// exactly as `RecordingDetailView` calls `peaks(for:)` on the phone. The
    /// library list never asks for a waveform. Using `cached(for:)` here would
    /// return `[]` for every recording the user hasn't already opened *on the
    /// phone* — `prewarm` covers only the first 20 — so the desktop waveform
    /// would be blank almost always.
    private func waveform(for recording: Recording) async -> HTTPResponse {
        guard let url = RecordingStore.shared.audioURL(for: recording) else {
            return .json([UInt8]())
        }
        return .json(await WaveformCache.shared.peaks(for: url) ?? [])
    }

    // MARK: - Writes

    private func setTitle(_ recording: Recording, _ request: HTTPRequest) -> HTTPResponse {
        guard let title = request.jsonBody()?["title"] as? String else {
            return .error(400, "Missing title.")
        }
        model.rename(recording, to: title)
        return refreshed(recording.id)
    }

    /// `POST /api/recordings/<id>/correct` — `{"from": "sonics", "to": "Soniox"}`,
    /// optionally `"caseSensitive"` and `"addToVocabulary"` (both default false).
    ///
    /// `addToVocabulary` defaults **off** here while the phone's sheet defaults it
    /// on: a browser correcting one word shouldn't quietly reshape a
    /// transcription setting that affects every future recording. Opting in is
    /// explicit over the wire.
    private func correctWord(_ recording: Recording, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.jsonBody(),
              let needle = body["from"] as? String,
              let replacement = body["to"] as? String else {
            return .error(400, "Missing from/to.")
        }
        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(400, "“from” can't be empty.")
        }
        guard recording.transcript != nil else {
            return .error(409, "This recording has no transcript to correct.")
        }
        model.correctWord(
            in: recording,
            from: needle,
            to: replacement,
            caseSensitive: body["caseSensitive"] as? Bool ?? false,
            addToVocabulary: body["addToVocabulary"] as? Bool ?? false)
        // Returns the updated recording, like every other write route, rather than
        // a bespoke `{"changed": n}` shape — the client already refreshes from this
        // payload, and the corrected transcript is in it. Note that zero matches is
        // a 200, not a 404: a correctly-executed replace that matched nothing is a
        // successful request.
        return refreshed(recording.id)
    }

    private func setSpeakers(_ recording: Recording, _ request: HTTPRequest) -> HTTPResponse {
        guard let raw = request.jsonBody()?["names"] as? [String: Any] else {
            return .error(400, "Missing names.")
        }
        let names = raw.compactMapValues { $0 as? String }
        model.setSpeakerNames(recording, names: names)
        return refreshed(recording.id)
    }

    private func setCategory(_ recording: Recording, _ request: HTTPRequest) -> HTTPResponse {
        let body = request.jsonBody()
        // An explicit JSON null clears the category; a missing key is an error.
        guard let body, body.keys.contains("name") else {
            return .error(400, "Missing name.")
        }
        // Report an unresolvable name rather than silently doing nothing —
        // `setCategory` refuses a name no category matches, and without this the
        // browser would toast "Saved" over a write that never happened.
        guard model.setCategory(recording, name: body["name"] as? String) else {
            return .error(400, "No category by that name — it may have been renamed on the iPhone.")
        }
        return refreshed(recording.id)
    }

    private func transcribe(_ recording: Recording, _ request: HTTPRequest) -> HTTPResponse {
        guard recording.isSynced else {
            return .error(400, "This recording hasn't been synced to the iPhone yet.")
        }
        if request.jsonBody()?["force"] as? Bool == true {
            model.retranscribe(recording)
        } else {
            model.transcribe(recording)
        }
        return .json(["queued": true])
    }

    /// Returns immediately. Generation runs on the on-device model and can take
    /// tens of seconds; the browser learns it landed from the `library` event on
    /// the live channel rather than by holding a request open that long.
    private func summarize(_ recording: Recording, _ request: HTTPRequest) -> HTTPResponse {
        guard let templateId = request.jsonBody()?["templateId"] as? String,
              let template = TemplateStore.shared.template(id: templateId)
        else {
            return .error(400, "Unknown template.")
        }
        guard recording.transcript != nil else {
            return .error(400, "This recording has no transcript to summarize.")
        }
        // Foundation Models only exists on Apple-Intelligence-capable hardware.
        // Without this the stream finishes instantly, nothing is written, and
        // the browser sits on a 202 waiting for a result that never comes.
        guard SummaryGenerator().isAvailable else {
            return .error(503, "Apple Intelligence isn't available on this iPhone.")
        }
        // One job per recording+template. Two clicks, or two browsers, would
        // otherwise start concurrent `LanguageModelSession`s that also race
        // `AutoOrganizer` — the on-device model work is meant to stay serialized
        // with the transcription queue.
        let job = "\(recording.id)|\(template.id)"
        guard !summarizing.contains(job) else {
            return .error(409, "That summary is already being generated.")
        }
        summarizing.insert(job)
        Task { [weak self] in
            // `defer` so the key is freed on *every* exit — a future throwing
            // `generateSummary`, an early return, a cancellation — not only the
            // clean-return path. Otherwise the recording+template pair returns
            // 409 "already being generated" for the rest of the app's life.
            defer { self?.summarizing.remove(job) }
            await self?.model.generateSummary(for: recording.id, template: template)
        }
        // Safety net for the one exit `defer` can't cover: an on-device model
        // that wedges and never returns at all. Without this the key would stay
        // in `summarizing` permanently. Idempotent with the removal above — a
        // `Set.remove` of an absent key is a no-op — so a normal finish just
        // clears it early and this fires against an empty set.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.summaryJobTimeout))
            self?.summarizing.remove(job)
        }
        return .json(["started": true], status: 202)
    }

    private func delete(_ recording: Recording) -> HTTPResponse {
        model.delete(recording)
        return .json(["deleted": true])
    }

    /// Every write replies with the recording as it now stands, so the browser
    /// replaces its copy from the server rather than trusting its own optimistic
    /// update. Cheapest workable answer to phone-and-browser editing at once.
    private func refreshed(_ id: String) -> HTTPResponse {
        guard let updated = RecordingStore.shared.recording(id: id) else {
            return .error(404, "No such recording.")
        }
        return .json(WebRecordingDetail(updated))
    }
}
