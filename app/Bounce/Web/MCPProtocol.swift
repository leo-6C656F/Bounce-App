import Foundation

/// The Model Context Protocol wire layer: JSON-RPC 2.0 in, JSON-RPC 2.0 out.
///
/// Split out of `MCPEndpoint.swift` and kept **Foundation-only** — no `AppModel`,
/// no `RecordingStore`, no `HTTPRequest`/`HTTPResponse` — so the envelope rules
/// can be compiled and exercised on the Mac. There is no test target and no
/// simulator, so protocol logic that *can* be checked off-device should live
/// somewhere it can be. Same arrangement as `TranscriptEdit`, `ActionItemMerge`
/// and `TimelineMap`, and for the same reason. See
/// `tools/mcp-endpoint-tests/main.swift`.
///
/// ## What this implements, and against which revision
///
/// MCP's **legacy** era: the `initialize` handshake, `notifications/initialized`,
/// `tools/list` and `tools/call`, as specified for revisions `2024-11-05`
/// through `2025-11-25`. `preferredVersion` is `2025-11-25`; the handshake echoes
/// whichever of `supportedVersions` the client asked for, per the rule that a
/// server "**MUST** respond with the same version" when it supports the requested
/// one and "another protocol version it supports" otherwise
/// (<https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle>).
///
/// It deliberately does **not** implement the **modern** era (`2026-07-28`),
/// which replaces the handshake with a per-request
/// `_meta["io.modelcontextprotocol/protocolVersion"]` and a mandatory
/// `server/discover` RPC. Every shipping client that can reach a self-signed LAN
/// host today — `mcp-remote` in particular — speaks the legacy handshake, and the
/// modern era brings header/body validation rules (`Mcp-Method`, `Mcp-Name`,
/// `MCP-Protocol-Version`, error `-32020`) that belong to the HTTP layer rather
/// than here. A dual-era client probing us with `server/discover` gets a plain
/// `-32601`, which is *not* a recognized modern error, and the spec's
/// compatibility matrix says such a client then falls back to `initialize` —
/// which is exactly right, because a legacy server is what we are.
/// (<https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning>.)
///
/// ## Three deliberate simplifications
///
/// 1. **Stateless.** Nothing here remembers that `initialize` happened. There is
///    no session to hang that on: `HTTPServer` has no session concept, the
///    optional `Mcp-Session-Id` mechanism isn't implemented, and `mcp-remote`
///    posts each message as its own request. So `tools/list` and `tools/call` are
///    answered whether or not a handshake preceded them. The auth gate in
///    `WebAPI`, not the handshake, is what decides who may call.
/// 2. **No batching.** JSON-RPC batching was **removed from MCP in `2025-06-18`**
///    (<https://modelcontextprotocol.io/specification/2025-06-18/changelog>,
///    "Remove support for JSON-RPC batching"). A top-level JSON array is
///    therefore rejected with `-32600` and a message saying so, rather than
///    silently answering only its first element.
/// 3. **No server-initiated messages.** `tools.listChanged` is advertised as
///    `false` and is honest: this endpoint answers POSTs and holds nothing open,
///    so there is no channel to push `notifications/tools/list_changed` down.
///
/// ## Notifications must not be answered
///
/// A JSON-RPC *notification* is a message with **no `id`**. It gets **no
/// response body at all** — `Outcome.accepted`, which `WebAPI` must turn into an
/// HTTP `202` with an empty body, per the Streamable HTTP transport ("If the
/// server accepts it, the server **MUST** return HTTP status code `202 Accepted`
/// with no body"). Answering `notifications/initialized` with a JSON-RPC result
/// is the classic way to hang a client: it is waiting on a response id that will
/// never come while holding one it never asked for.
@MainActor
enum MCPProtocol {

    // MARK: - Identity

    static let serverName = "bounce"
    /// Version of *this MCP surface*, not of the app. Bumped when the tool set or
    /// a tool's shape changes, so an agent's cached `tools/list` can be spotted as
    /// stale; the app's own version is deliberately not leaked over the wire.
    static let serverVersion = "1.0.0"

    /// Protocol revisions this server will speak, newest first.
    ///
    /// All four are listed because a tools-only server's surface is unchanged
    /// across them — structured output, resource links, elicitation and tasks are
    /// all optional additions we don't use — so echoing an older client's version
    /// back costs nothing and keeps it connected.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static var preferredVersion: String { supportedVersions[0] }

    /// Sent in the handshake as `instructions`. Read by the client's model, so it
    /// is written for one: what the tools are for, and the two constraints that
    /// change how they should be used.
    static let instructions = """
        Bounce is a personal voice-recorder app on the user's iPhone. These tools \
        read its library of recordings, transcripts, AI summaries and action items.

        Everything here is read-only — nothing can be created, edited or deleted \
        through this server.

        The transcripts are recordings of the user's own meetings and \
        conversations, and often those of other people who were present. Fetch the \
        specific recording the user is asking about; do not page through the whole \
        library to build a copy of it.
        """

    // MARK: - Outcome

    /// What the HTTP layer should send back.
    ///
    /// Three cases rather than one `HTTPResponse` because this file must not know
    /// what an `HTTPResponse` is — and because the notification case genuinely has
    /// no body, which a "here is your JSON" return type can't express.
    enum Outcome: Equatable {
        /// A JSON-RPC response (result *or* error). HTTP 200, `application/json`.
        ///
        /// An in-band JSON-RPC error still rides a 200: that is what the reference
        /// SDKs do and what every client tolerates. The HTTP status is about the
        /// envelope, the `error` member is about the call.
        case reply(Data)
        /// A notification the server accepted. HTTP 202, **empty body**.
        case accepted
        /// The body was not a usable JSON-RPC message. HTTP `status` with a
        /// JSON-RPC error body whose `id` is null.
        ///
        /// A 4xx here is also the signal a dual-era client uses to conclude we are
        /// a legacy server and fall back to `initialize`.
        case failure(status: Int, body: Data)
    }

    // MARK: - Entry point

    /// Handle one POSTed JSON-RPC message.
    ///
    /// `@MainActor` throughout, and `WebAPI` will already have hopped here — the
    /// rule at the top of `WebAPI.swift` is one hop at the edge and no hop back,
    /// because `RecordingStore` has no lock and `SWIFT_STRICT_CONCURRENCY` is
    /// `minimal`, so a tool touching it off the main actor compiles clean and
    /// races at runtime.
    static func respond(to body: Data, provider: any MCPToolProvider) async -> Outcome {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        } catch {
            return .failure(
                status: 400,
                body: errorEnvelope(id: nil, error: .parseError("The request body isn't valid JSON.")))
        }

        if json is [Any] {
            return .failure(
                status: 400,
                body: errorEnvelope(id: nil, error: .invalidRequest(
                    "JSON-RPC batching isn't supported — it was removed from MCP in "
                    + "revision 2025-06-18. Send one message per request.")))
        }

        guard let object = json as? [String: Any] else {
            return .failure(
                status: 400,
                body: errorEnvelope(id: nil, error: .invalidRequest(
                    "A JSON-RPC message must be a JSON object.")))
        }

        // `jsonrpc` must be exactly "2.0". Checked before `id`, because a message
        // that isn't JSON-RPC at all has no id worth echoing.
        guard let version = object["jsonrpc"] as? String, version == "2.0" else {
            return .failure(
                status: 400,
                body: errorEnvelope(id: nil, error: .invalidRequest(
                    #"Missing or unsupported "jsonrpc" — this server speaks JSON-RPC 2.0."#)))
        }

        // Presence of `id` is what separates a request from a notification. An
        // explicit JSON null is *not* a present id: `MCPRequestID(json:)` returns
        // nil for it, so `{"id": null}` is treated as a notification. That matches
        // JSON-RPC 2.0, which reserves null ids for error responses.
        let id = MCPRequestID(json: object["id"])

        guard let method = object["method"] as? String, !method.isEmpty else {
            guard let id else {
                return .failure(
                    status: 400,
                    body: errorEnvelope(id: nil, error: .invalidRequest(
                        #"Missing "method"."#)))
            }
            return .reply(errorEnvelope(id: id, error: .invalidRequest(#"Missing "method"."#)))
        }

        // Params are optional; a non-object `params` is malformed.
        let params: [String: Any]
        switch object["params"] {
        case nil, is NSNull:
            params = [:]
        case let dictionary as [String: Any]:
            params = dictionary
        default:
            let error = MCPProtocolError.invalidParams(#""params" must be a JSON object."#)
            guard let id else { return .accepted }
            return .reply(errorEnvelope(id: id, error: error))
        }

        // No id → notification. Accept it and say nothing. Unknown notifications
        // are swallowed too: a client is entitled to send `notifications/cancelled`
        // or anything else it likes, and erroring on one would be noisier than
        // ignoring it, with no upside for a stateless read-only server.
        guard let id else { return .accepted }

        do {
            let result = try await dispatch(method: method, params: params, provider: provider)
            return .reply(resultEnvelope(id: id, result: result))
        } catch let error as MCPProtocolError {
            return .reply(errorEnvelope(id: id, error: error))
        } catch {
            return .reply(errorEnvelope(
                id: id,
                error: .internalError("The iPhone couldn't complete that request.")))
        }
    }

    // MARK: - Dispatch

    private static func dispatch(
        method: String,
        params: [String: Any],
        provider: any MCPToolProvider
    ) async throws -> [String: Any] {
        switch method {
        case "initialize":
            return initializeResult(params: params)

        case "ping":
            // The spec's ping is an empty request with an empty result. Cheap, and
            // some clients use it as a liveness probe before anything else.
            return [:]

        case "tools/list":
            return ["tools": provider.tools.map(\.json)]

        case "tools/call":
            return try await callTool(params: params, provider: provider)

        default:
            // Includes `server/discover`, `resources/list`, `prompts/list` and
            // friends. `-32601` is the correct answer and is also what makes a
            // dual-era client fall back to the legacy handshake — see the type's
            // doc comment.
            throw MCPProtocolError.methodNotFound("Unknown method: \(method)")
        }
    }

    /// The handshake reply.
    ///
    /// Note what is *not* here: any check that this is the first message, or any
    /// state written as a result of it. See "Stateless" above.
    static func initializeResult(params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let negotiated = requested.flatMap { supportedVersions.contains($0) ? $0 : nil }
            ?? preferredVersion

        return [
            "protocolVersion": negotiated,
            "capabilities": [
                // `listChanged: false` is honest, not conservative — see the doc
                // comment. `resources` and `prompts` are absent because we offer
                // neither, and advertising an empty capability invites a client to
                // call `resources/list` and get a -32601 for its trouble.
                "tools": ["listChanged": false],
            ],
            "serverInfo": [
                "name": serverName,
                "title": "Bounce",
                "version": serverVersion,
            ],
            "instructions": instructions,
        ]
    }

    private static func callTool(
        params: [String: Any],
        provider: any MCPToolProvider
    ) async throws -> [String: Any] {
        // A missing or non-string `name` fails the `CallToolRequest` schema, which
        // the spec classifies as a **protocol** error rather than a tool error.
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPProtocolError.invalidParams(#"Missing tool name in "params.name"."#)
        }
        // `arguments` is optional (a no-argument tool omits it) but must be an
        // object when present.
        let arguments: [String: Any]
        switch params["arguments"] {
        case nil, is NSNull:
            arguments = [:]
        case let dictionary as [String: Any]:
            arguments = dictionary
        default:
            throw MCPProtocolError.invalidParams(#""arguments" must be a JSON object."#)
        }

        // Unknown tool is `-32602`, per the spec's own example
        // (`{"code": -32602, "message": "Unknown tool: invalid_tool_name"}`).
        guard provider.tools.contains(where: { $0.name == name }) else {
            throw MCPProtocolError.invalidParams("Unknown tool: \(name)")
        }

        do {
            let text = try await provider.call(name, MCPArguments(arguments))
            return toolResult(text: text, isError: false)
        } catch let failure as MCPToolFailure {
            // **Tool execution errors are results, not JSON-RPC errors.** The spec
            // puts input validation ("date in wrong format, value out of range")
            // and business-logic failures in this bucket precisely so the model
            // sees the message and can retry with better arguments; a `-32602`
            // is handed to the client, and clients only *MAY* pass those on.
            return toolResult(text: failure.text, isError: true)
        }
    }

    /// A `CallToolResult`: one text content block, plus the `isError` flag.
    static func toolResult(text: String, isError: Bool) -> [String: Any] {
        [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ]
    }

    // MARK: - Envelopes

    static func resultEnvelope(id: MCPRequestID, result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id.json, "result": result])
    }

    static func errorEnvelope(id: MCPRequestID?, error: MCPProtocolError) -> Data {
        var payload: [String: Any] = ["code": error.code, "message": error.message]
        if let data = error.data { payload["data"] = data }
        return encode([
            "jsonrpc": "2.0",
            // JSON-RPC 2.0: when the id can't be determined it **must** be null.
            "id": id?.json ?? NSNull(),
            "error": payload,
        ])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        // `.sortedKeys` for a stable byte-for-byte output (tests, and diffable
        // logs); `.withoutEscapingSlashes` so a URL in a transcript doesn't come
        // out as `http:\/\/`.
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            // Hand-built rather than re-encoded: whatever broke the encoder would
            // break a second attempt too.
            return Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Response encoding failed."}}"#.utf8)
        }
        return data
    }
}

// MARK: - Request id

/// A JSON-RPC request id: a string or a number, echoed back **with its original
/// JSON type**.
///
/// Three cases rather than one `Double`, because a client that sent `1` and gets
/// `1.0` back may fail to match the response to its request — and one that sent
/// `"abc"` certainly will.
enum MCPRequestID: Hashable {
    case string(String)
    case int(Int)
    case double(Double)

    /// Nil for an absent id **and for an explicit JSON null** — both mean "this is
    /// a notification, do not reply". JSON-RPC 2.0 reserves a null id for error
    /// responses, so a client is not entitled to use one as a request id.
    init?(json: Any?) {
        switch json {
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            // `NSNumber` is how `JSONSerialization` hands back every JSON number,
            // including booleans. A boolean id is not a number in JSON-RPC's sense.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let value = number.doubleValue
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                self = .int(number.intValue)
            } else {
                self = .double(value)
            }
        default:
            return nil
        }
    }

    var json: Any {
        switch self {
        case .string(let text): return text
        case .int(let value): return value
        case .double(let value): return value
        }
    }
}

// MARK: - Errors

/// A JSON-RPC protocol error: something was wrong with the *request*.
///
/// Distinct from `MCPToolFailure`, which is a tool that ran and couldn't do the
/// job. The split is the spec's, not ours, and it matters: protocol errors go to
/// the client, tool failures go to the model.
struct MCPProtocolError: Error {
    let code: Int
    let message: String
    let data: [String: Any]?

    private init(code: Int, message: String, data: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // The five standard JSON-RPC 2.0 codes, as re-exported by MCP's schema.
    static let parseErrorCode = -32700
    static let invalidRequestCode = -32600
    static let methodNotFoundCode = -32601
    static let invalidParamsCode = -32602
    static let internalErrorCode = -32603

    static func parseError(_ message: String) -> MCPProtocolError {
        MCPProtocolError(code: parseErrorCode, message: message)
    }
    static func invalidRequest(_ message: String) -> MCPProtocolError {
        MCPProtocolError(code: invalidRequestCode, message: message)
    }
    static func methodNotFound(_ message: String) -> MCPProtocolError {
        MCPProtocolError(code: methodNotFoundCode, message: message)
    }
    static func invalidParams(_ message: String) -> MCPProtocolError {
        MCPProtocolError(code: invalidParamsCode, message: message)
    }
    static func internalError(_ message: String) -> MCPProtocolError {
        MCPProtocolError(code: internalErrorCode, message: message)
    }
}

/// A tool ran and couldn't produce an answer — bad arguments, nothing found,
/// a capability that isn't available on this iPhone.
///
/// Surfaces as `result.isError = true` with `text` as the content, **not** as a
/// JSON-RPC error, so the model reads the message and can correct itself. Write
/// the message for a model: say what was wrong and what would work.
struct MCPToolFailure: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

// MARK: - Tool descriptor

/// One entry in the `tools/list` response.
struct MCPTool {
    /// Programmatic identifier. Snake case, matching the rest of the MCP ecosystem
    /// and the spec's allowed character set (letters, digits, `_`, `-`, `.`).
    let name: String
    /// Human-readable display name, for a client's tool picker.
    let title: String
    /// What the tool does. Read by the model, so it decides whether the tool is
    /// used at all and with what arguments.
    let description: String
    /// JSON Schema (2020-12 by default) for `arguments`. **Must be an object
    /// schema and must not be null** — a tool with no arguments uses
    /// `["type": "object", "additionalProperties": false]`.
    let inputSchema: [String: Any]

    var json: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": inputSchema,
        ]
    }

    /// The no-argument schema the spec recommends, so this isn't spelled four
    /// slightly different ways across the tool table.
    static let noArguments: [String: Any] = ["type": "object", "additionalProperties": false]
}

// MARK: - Arguments

/// Typed, validating access to a `tools/call` `arguments` object.
///
/// Every accessor throws `MCPToolFailure`, never `MCPProtocolError`: a wrongly
/// typed argument is the case the spec explicitly wants reported as a tool
/// execution error so the model can fix it and retry.
struct MCPArguments {
    private let raw: [String: Any]

    init(_ raw: [String: Any] = [:]) { self.raw = raw }

    var isEmpty: Bool { raw.isEmpty }

    var keys: Set<String> { Set(raw.keys) }

    /// A present, non-empty string. Absent, null, non-string or blank all fail.
    func requiredString(_ name: String) throws -> String {
        guard let value = try string(name) else {
            throw MCPToolFailure("Missing required argument “\(name)” (a non-empty string).")
        }
        return value
    }

    /// A non-empty trimmed string, or nil when absent/null.
    ///
    /// A blank string is treated as absent rather than as an error: a model
    /// filling in `""` for an optional filter means "no filter", and failing the
    /// call over it is unhelpful.
    func string(_ name: String) throws -> String? {
        switch raw[name] {
        case nil, is NSNull:
            return nil
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            throw MCPToolFailure("Argument “\(name)” must be a string.")
        }
    }

    func bool(_ name: String) throws -> Bool? {
        switch raw[name] {
        case nil, is NSNull:
            return nil
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return number.boolValue
        default:
            throw MCPToolFailure("Argument “\(name)” must be true or false.")
        }
    }

    /// A whole number clamped to `range`, or nil when absent/null.
    ///
    /// **Clamped, not rejected.** An out-of-range `limit` is the model guessing at
    /// a bound it was never told; answering with the largest allowed page is more
    /// useful than an error, and the tool description states the cap. A
    /// *non-numeric* or fractional value is still an error — that's a
    /// misunderstanding of the argument, not of its bounds.
    func int(_ name: String, clampedTo range: ClosedRange<Int>) throws -> Int? {
        switch raw[name] {
        case nil, is NSNull:
            return nil
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw MCPToolFailure("Argument “\(name)” must be a whole number.")
            }
            let value = number.doubleValue
            guard value == value.rounded() else {
                throw MCPToolFailure("Argument “\(name)” must be a whole number, not \(value).")
            }
            return min(max(number.intValue, range.lowerBound), range.upperBound)
        default:
            throw MCPToolFailure("Argument “\(name)” must be a whole number.")
        }
    }

    /// An ISO 8601 instant or a bare `YYYY-MM-DD` day, or nil when absent/null.
    ///
    /// A bare day is accepted because that is overwhelmingly what a model writes
    /// for "since last Tuesday", and rejecting it would make the argument
    /// unusable in practice. It resolves to midnight **UTC**, not local midnight:
    /// the alternative is a filter whose boundary moves with the phone's time
    /// zone, which is worse than one that is documented and fixed.
    func date(_ name: String) throws -> Date? {
        guard let text = try string(name) else { return nil }
        if let date = Self.iso8601WithFraction.date(from: text) { return date }
        if let date = Self.iso8601.date(from: text) { return date }
        if let date = Self.plainDay.date(from: text) { return date }
        throw MCPToolFailure(
            "Argument “\(name)” must be an ISO 8601 date or timestamp, "
            + #"such as "2026-07-01" or "2026-07-01T09:30:00Z". Got “\#(text)”."#)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainDay: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed locale and calendar: a user on a Buddhist or Japanese calendar
        // would otherwise have `yyyy` mean something else entirely.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Tool provider

/// The only surface `MCPProtocol` has onto the app.
///
/// **Read-only by construction.** There is exactly one entry point, it takes
/// arguments and returns text, and there is no way to express a mutation through
/// it. `MCPEndpoint` is the implementation; the protocol exists so this file can
/// be compiled and tested against a stub instead of against `AppModel`.
///
/// `@MainActor` because every implementation will be — `RecordingStore` has no
/// lock and `SWIFT_STRICT_CONCURRENCY` is `minimal`, so anything reading the
/// library off the main actor compiles clean and races at runtime.
@MainActor
protocol MCPToolProvider: AnyObject {
    /// Advertised by `tools/list`, and the authority on which names `tools/call`
    /// will accept — `MCPProtocol` rejects anything not in here before calling.
    var tools: [MCPTool] { get }

    /// Run one tool. Throw `MCPToolFailure` for anything the model could fix.
    func call(_ name: String, _ arguments: MCPArguments) async throws -> String
}
