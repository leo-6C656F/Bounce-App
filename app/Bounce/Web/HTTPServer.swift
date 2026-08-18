import Foundation
import Network

/// A small HTTP/1.1 server over `NWListener`, enough to serve the desktop view.
///
/// Deliberately hand-rolled rather than pulled in as a dependency. The subset
/// needed here — GET/POST, a handful of headers, byte ranges, and a long-lived
/// `text/event-stream` — is small and has no moving parts, whereas adding SPM
/// dependency resolution to this build means touching a `project.yml` with
/// several documented ways to fail silently (see `CLAUDE.md`).
///
/// ## Threading
///
/// **All listener and connection state lives on `queue`.** `DesktopServer` is
/// `@MainActor` and drives `start`/`stop`, so both hop onto `queue` rather than
/// mutating from the main actor — `connections` is a plain `Dictionary`, and two
/// threads writing one is heap corruption, not a lost update. The only fields
/// that legitimately cross threads are `HTTPConnection`'s two state flags, which
/// are behind a lock for that reason.
///
/// Handlers hop the other way, to the main actor, exactly once — see `WebAPI`.
/// `RecordingStore` has no synchronisation of its own, so a handler touching it
/// off the main actor is a data race the compiler will not diagnose
/// (`SWIFT_STRICT_CONCURRENCY: minimal`).
final class HTTPServer {

    /// A handler is handed a request and calls back with a response. Async on
    /// purpose: every real handler hops to the main actor and back.
    typealias Handler = @Sendable (HTTPRequest, @escaping @Sendable (HTTPResponse) -> Void) -> Void

    /// Enough for a browser's parallel connections plus a few range requests —
    /// and headroom for unsolicited probes, which on a busy network arrive in
    /// bursts and would otherwise starve the real client out of the cap.
    private static let maxConnections = 64

    /// A single source shouldn't be able to walk the *shared* cap above up to
    /// its limit by itself — that turns a global connection pool into a
    /// one-device denial-of-service knob for every other client on the LAN.
    /// 16, not 8: a single legitimate browser can plausibly hold a `/api/live`
    /// SSE stream, several ordinary fetches, and a couple of `<audio>` range
    /// requests from scrubbing at once, and a rejection here is a silent
    /// `nwConnection.cancel()` indistinguishable from a network failure to the
    /// client — `EventSource`/`<audio>` both retry with no real backoff, so a
    /// cap that's too tight risks a self-inflicted retry loop against normal,
    /// single-user, multi-tab use rather than actually stopping an attacker.
    private static let maxConnectionsPerAddress = 16

    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private var handler: Handler?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    /// Set inside `stop`, checked in `accept`. `newConnectionHandler` blocks that
    /// were already dispatched still run after `listener.cancel()`, and without
    /// this they would repopulate `connections` with sockets that have no handler
    /// to answer them — a browser spinner that never resolves, and a leaked
    /// socket per occurrence.
    private var isStopped = true

    let queue = DispatchQueue(label: "com.teampandora.Bounce.http")

    /// Connections that died before delivering a single byte — overwhelmingly
    /// TLS handshakes the peer aborted because it doesn't trust a self-signed
    /// certificate. Surfaced so Settings can tell the user that's what's
    /// happening instead of leaving them with a page that won't load.
    private(set) var rejectedConnections = 0
    /// Requests actually served. A non-zero value means at least one client got
    /// past the certificate, which is what distinguishes "nothing works" from
    /// "the network is noisy".
    private(set) var servedRequests = 0

    /// Called on `queue` if the listener fails. Passed into `start` rather than
    /// assigned afterwards: `NWListener` does **not** throw for a port already in
    /// use, it reports `.failed(EADDRINUSE)` asynchronously, and a callback
    /// installed after `listener.start` can miss it entirely.
    private var onFailure: (@Sendable (Error) -> Void)?

    // MARK: - Lifecycle

    func start(
        port desiredPort: UInt16,
        advertiseService: Bool = true,
        tlsIdentity: sec_identity_t? = nil,
        onFailure: @escaping @Sendable (Error) -> Void,
        handler: @escaping Handler
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: desiredPort) else {
            throw HTTPServerError.invalidPort
        }

        let parameters: NWParameters
        if let tlsIdentity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, tlsIdentity)
            // TLS 1.2 floor. Nothing that can render this page is older, and
            // allowing 1.0/1.1 would weaken the one property the certificate is
            // here to provide.
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }
        // Lets the port be reclaimed immediately after a stop, so toggling the
        // server off and straight back on doesn't fail with "address in use".
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        // Without keepalive, a laptop that sleeps or drops off wifi leaves its
        // event-stream socket looking open forever: SSE is one-way, so nothing
        // arrives to prove the peer is gone, and `.contentProcessed` fires when
        // bytes reach the transport rather than when they're acknowledged. The
        // idle auto-stop is keyed on the live client count, so a phantom client
        // would keep the server up — and the screen awake — indefinitely.
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
        }

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionLimit = Self.maxConnections
        // Bonjour advertisement, so the phone is discoverable on the LAN rather
        // than only reachable by typing an IP.
        //
        // Optional on purpose. Registering an mDNS service goes through the
        // local-network privacy gate and fails with `kDNSServiceErr_NoAuth`
        // (-65555) when that hasn't been granted — and `NWListener` reports it
        // by failing the **whole listener**, taking the TCP socket with it. The
        // socket itself needs no permission, so `DesktopServer` retries without
        // this rather than losing a server that would have worked.
        if advertiseService {
                listener.service = NWListener.Service(
                name: Self.bonjourName, type: tlsIdentity == nil ? "_http._tcp" : "_https._tcp")
        }

        queue.sync {
            self.stopOnQueue()
            self.handler = handler
            self.onFailure = onFailure
            self.listener = listener
            self.isStopped = false
            self.port = desiredPort
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.onFailure?(error)
            case .waiting(let error):
                // Recoverable — a path change or wifi handover. Surfacing it as
                // terminal would tear down a listener that is about to come back.
                NSLog("[Web] listener waiting: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)
    }

    /// True only while the socket is genuinely accepting connections.
    ///
    /// `.ready` and nothing else. `.waiting` is treated as recoverable by the
    /// state handler — correct for a wifi handover mid-session — but it means
    /// nothing can connect right now, which is exactly the state a listener is
    /// found in when the app was suspended out from under it. `DesktopServer`
    /// uses this to tell "survived the background" from "advertising a dead URL".
    var isListening: Bool {
        queue.sync {
            guard let state = listener?.state else { return false }
            if case .ready = state { return true }
            return false
        }
    }

    func stop() {
        queue.sync { self.stopOnQueue() }
    }

    /// Must be called on `queue`.
    private func stopOnQueue() {
        isStopped = true
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        handler = nil
        onFailure = nil
        let open = connections.values
        connections.removeAll()
        for connection in open { connection.closeOnQueue() }
    }

    static let bonjourName = "Bounce"

    // MARK: - Connections

    private func accept(_ nwConnection: NWConnection) {
        guard !isStopped, let handler else {
            nwConnection.cancel()
            return
        }
        guard connections.count < Self.maxConnections else {
            nwConnection.cancel()
            return
        }

        let address = addressDescription(for: nwConnection.endpoint)
        let fromSameAddress = connections.values.lazy.filter { $0.clientDescription == address }.count
        guard fromSameAddress < Self.maxConnectionsPerAddress else {
            nwConnection.cancel()
            return
        }

        let connection = HTTPConnection(connection: nwConnection, queue: queue, route: handler)
        connection.onClose = { [weak self] closed in
            // Already on `queue` — `closeOnQueue` is the only caller.
            guard let self else { return }
            self.connections.removeValue(forKey: ObjectIdentifier(closed))
            if closed.everReceivedData {
                self.servedRequests += 1
            } else {
                self.rejectedConnections += 1
                WebLog.log("connection closed with no data "
                    + "(\(self.rejectedConnections) so far) — probe or refused certificate")
            }
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }
}

enum HTTPServerError: LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "That port number isn't usable."
        }
    }
}

// MARK: - Request

/// One parsed HTTP/1.1 request.
struct HTTPRequest: Sendable {
    let method: String
    /// Path with the query stripped and each segment percent-decoded.
    let path: String
    let query: [String: String]
    /// Header names lowercased — clients disagree about casing and HTTP says
    /// they're case-insensitive.
    let headers: [String: String]
    let body: Data
    /// Remote address as text, shown in the connected-clients list.
    let client: String

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The `Host` header with any `:port` removed. IPv6 literals keep their
    /// brackets, which is fine — they're compared against the same form.
    var hostName: String? {
        guard let host = header("host") else { return nil }
        guard !host.hasPrefix("[") else {
            guard let end = host.firstIndex(of: "]") else { return host }
            return String(host[host.startIndex...end])
        }
        guard let colon = host.lastIndex(of: ":") else { return host }
        return String(host[host.startIndex..<colon])
    }

    var cookies: [String: String] {
        guard let raw = header("cookie") else { return [:] }
        var result: [String: String] = [:]
        for pair in raw.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            result[String(trimmed[trimmed.startIndex..<equals])]
                = String(trimmed[trimmed.index(after: equals)...])
        }
        return result
    }

    /// True when the request came from a page on some *other* origin.
    ///
    /// `Sec-Fetch-Site` is set by the browser and cannot be forged by page
    /// script. Without this check, any website the user visits can POST to the
    /// pairing endpoint — no preflight, since a `text/plain` body makes it a
    /// CORS "simple request" — and burn through the attempt cap to switch the
    /// server off from across the internet.
    var isCrossSite: Bool {
        guard let site = header("sec-fetch-site")?.lowercased() else {
            // Absent means either a non-browser client or a very old browser;
            // fall back to Origin, and treat "neither present" as same-site so
            // curl still works.
            guard let origin = header("origin"), !origin.isEmpty else { return false }
            guard let host = hostName else { return true }
            // **Host EQUALITY, never a substring match.** `.contains` reads
            // `http://192.168.1.42.attacker.com` as same-site because its host
            // *contains* `192.168.1.42` — a cross-site page slips straight
            // through the one gate that guards pre-auth `POST /api/pair`. Parse
            // the Origin and require its host equal the Host header the request
            // is already validated against. Brackets are trimmed so an IPv6
            // literal (`[::1]` in Host, `::1` from `URLComponents`) still matches.
            guard let originHost = URLComponents(string: origin)?.host else { return true }
            let brackets = CharacterSet(charactersIn: "[]")
            let originKey = originHost.lowercased().trimmingCharacters(in: brackets)
            let hostKey = host.lowercased().trimmingCharacters(in: brackets)
            return originKey != hostKey
        }
        return site != "same-origin" && site != "none"
    }

    /// Parsed `Range: bytes=start-end`. Nil when absent or unparseable, which
    /// RFC 9110 §14.2 says to treat as no range at all rather than an error.
    var byteRange: (start: Int?, end: Int?)? {
        guard let raw = header("range"), raw.hasPrefix("bytes=") else { return nil }
        let spec = raw.dropFirst("bytes=".count)
        // Only a single range is supported; multipart/byteranges is not worth
        // the complexity for an audio element, and a full 200 is a legal answer.
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        // An unparseable bound is not the same as an absent one: "bytes=999…9-"
        // with an overflowing first bound must not be read as a suffix range,
        // which would silently serve the wrong bytes with a 206.
        let start = parts[0].isEmpty ? nil : Int(parts[0])
        let end = parts[1].isEmpty ? nil : Int(parts[1])
        if start == nil && !parts[0].isEmpty { return nil }
        if end == nil && !parts[1].isEmpty { return nil }
        if start == nil && end == nil { return nil }
        return (start, end)
    }

    func jsonBody() -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

// MARK: - Response

struct HTTPResponse: Sendable {

    enum Body: Sendable {
        case data(Data)
        /// Stream a byte range out of a file without loading it into memory.
        case file(url: URL, offset: Int, length: Int)
        /// Hand the socket to the live channel and keep it open. `onOpen` fires
        /// once the response headers are away, with the sink to push through.
        case eventStream(onOpen: @Sendable (any EventStreamSink) -> Void)
    }

    var status: Int
    var headers: [String: String]
    var body: Body
    /// Set when the response ends the connection regardless of keep-alive.
    var closeAfterWrite: Bool

    init(
        status: Int = 200,
        headers: [String: String] = [:],
        body: Body = .data(Data()),
        closeAfterWrite: Bool = false
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.closeAfterWrite = closeAfterWrite
    }

    // MARK: Convenience

    static func json(_ data: Data, status: Int = 200, extraHeaders: [String: String] = [:]) -> HTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] = "application/json; charset=utf-8"
        // These carry whole transcripts. Without an explicit no-store they land
        // in the desktop browser's disk cache and outlive the session — and
        // Safari will happily answer a later request from cache, so the browser
        // would show pre-edit data straight after a change event told it to
        // refresh.
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        return HTTPResponse(status: status, headers: headers, body: .data(data))
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else {
            return .error(500, "Couldn't encode the response.")
        }
        return .json(data, status: status)
    }

    static func html(_ markup: String) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
                // Everything is served from this origin and inlined; blocking
                // outside loads costs nothing and shuts down a class of
                // injection through transcript text rendered into the page.
                // `frame-ancestors` keeps another site from framing it.
                "Content-Security-Policy":
                    "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                    + "style-src 'self' 'unsafe-inline'; media-src 'self'; "
                    + "img-src 'self' data:; frame-ancestors 'none'",
            ],
            body: .data(Data(markup.utf8)))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let payload = ["error": message]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return .json(data, status: status)
    }

    static func empty(_ status: Int) -> HTTPResponse {
        HTTPResponse(status: status)
    }
}

private let statusReasons: [Int: String] = [
    200: "OK", 202: "Accepted", 204: "No Content", 206: "Partial Content",
    400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
    405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
    416: "Range Not Satisfiable", 429: "Too Many Requests",
    500: "Internal Server Error", 503: "Service Unavailable",
]

// MARK: - Event stream

/// A socket that has been upgraded to `text/event-stream` and is now write-only.
/// `LiveChannel` holds these; it has no reason to know about `NWConnection`.
protocol EventStreamSink: AnyObject, Sendable {
    /// Push one event. Multi-line payloads are framed correctly.
    func sendEvent(_ payload: String)
    func close()
    var isOpen: Bool { get }
}

/// Shared by `HTTPServer.accept` (checking a not-yet-wrapped `NWConnection`
/// against the per-address cap) and `HTTPConnection.clientDescription` (an
/// already-open one), so the two can't drift into recognizing the same
/// address two different ways.
fileprivate func addressDescription(for endpoint: NWEndpoint) -> String {
    switch endpoint {
    case .hostPort(let host, _):
        // Strip the IPv6 scope suffix ("fe80::1%en0") — noise in the UI, and
        // would otherwise make one client look like several to the cap below.
        let text = "\(host)"
        return text.split(separator: "%").first.map(String.init) ?? text
    default:
        return "\(endpoint)"
    }
}

// MARK: - Connection

/// One client socket: parse a request, write a response, repeat while the
/// client keeps the connection alive.
final class HTTPConnection: @unchecked Sendable {

    /// Guards against a client streaming an unbounded body into memory. The
    /// largest legitimate POST here is a speaker-name map.
    private static let maxBodyBytes = 1 << 20      // 1 MB
    private static let maxHeaderBytes = 64 << 10   // 64 KB
    private static let fileChunkBytes = 256 << 10  // 256 KB
    /// A socket that connects and then says nothing (or dribbles a request out
    /// forever) is reaped rather than held. Rearmed per request, cancelled once
    /// the socket becomes an event stream.
    private static let requestTimeout: TimeInterval = 20

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let route: (HTTPRequest, @escaping @Sendable (HTTPResponse) -> Void) -> Void

    // MARK: Queue-confined state

    private var buffer = Data()
    /// One response at a time. Without this, a second pipelined request is
    /// routed while the first is still in flight and the two replies can be
    /// written out of order — the client would pair response #2 with request #1.
    /// It also stops the malformed-request paths, which write without consuming
    /// the buffer, from answering the same bytes repeatedly.
    private var isResponding = false
    private var isHeadRequest = false
    private var timeout: DispatchWorkItem?
    /// False for a connection that never got past the TLS handshake, which is
    /// how a refused certificate is distinguished from a served request.
    private(set) var everReceivedData = false

    // MARK: Cross-thread state

    /// `close()` and `isOpen` are reachable from the main actor via
    /// `EventStreamSink`, so these two can't be plain queue-confined vars.
    private let stateLock = NSLock()
    private var _isClosed = false
    private var _isEventStream = false
    /// True while a live frame is handed to the transport but not yet processed.
    /// The backpressure gate for `sendEvent`: a second frame arriving while one
    /// is in flight is dropped rather than enqueued. See `sendEvent`.
    private var _sendInFlight = false

    private var isClosed: Bool { stateLock.withLock { _isClosed } }
    private var isEventStream: Bool { stateLock.withLock { _isEventStream } }

    /// Called on `queue`.
    var onClose: ((HTTPConnection) -> Void)?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        route: @escaping (HTTPRequest, @escaping @Sendable (HTTPResponse) -> Void) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.route = route
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.closeOnQueue()
            default:
                break
            }
        }
        connection.start(queue: queue)
        armTimeout()
        receive()
    }

    /// `EventStreamSink` conformance — safe from any thread.
    func close() {
        queue.async { self.closeOnQueue() }
    }

    /// Must be called on `queue`.
    func closeOnQueue() {
        let alreadyClosed: Bool = stateLock.withLock {
            defer { _isClosed = true }
            return _isClosed
        }
        guard !alreadyClosed else { return }
        timeout?.cancel()
        timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(self)
        onClose = nil
    }

    private func armTimeout() {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.closeOnQueue() }
        timeout = item
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: item)
    }

    fileprivate var clientDescription: String { addressDescription(for: connection.endpoint) }

    // MARK: Reading

    private func receive() {
        guard !isClosed, !isEventStream else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.closeOnQueue()
                return
            }
            if let data, !data.isEmpty {
                self.everReceivedData = true
                self.buffer.append(data)
                self.drainBuffer()
            }
            if isComplete {
                self.closeOnQueue()
                return
            }
            self.receive()
        }
    }

    /// Parse as many complete requests as the buffer holds, one response at a
    /// time.
    private func drainBuffer() {
        guard !isClosed, !isEventStream, !isResponding else { return }

        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.firstRange(of: separator) else {
            if buffer.count > Self.maxHeaderBytes {
                write(.error(413, "Headers too large."), keepAlive: false)
            }
            return
        }

        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            write(.error(400, "Malformed request."), keepAlive: false)
            return
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            write(.error(400, "Malformed request."), keepAlive: false)
            return
        }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else {
            write(.error(400, "Malformed request line."), keepAlive: false)
            return
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // No proxy sits in front of this, so chunked bodies aren't a smuggling
        // vector — but framing one as zero-length would re-parse its payload as
        // the next request, which is a confusing failure. Refuse instead.
        if headers["transfer-encoding"] != nil {
            write(.error(400, "Chunked requests aren't supported."), keepAlive: false)
            return
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= Self.maxBodyBytes else {
            write(.error(413, "Request body too large."), keepAlive: false)
            return
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return }   // wait for the rest

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        // `Data`'s slices keep the parent's index base, so this must be rebased
        // through `Data(...)` before anything treats it as 0-based.
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        let target = String(requestLine[1])
        let (path, query) = Self.splitTarget(target)
        let keepAlive = headers["connection"]?.lowercased() != "close"
        let method = String(requestLine[0]).uppercased()

        // A HEAD is routed as its GET and the body suppressed at write time —
        // this is the only place that knows both the method and the length.
        isHeadRequest = method == "HEAD"

        let request = HTTPRequest(
            method: isHeadRequest ? "GET" : method,
            path: path,
            query: query,
            headers: headers,
            body: body,
            client: clientDescription)

        isResponding = true
        armTimeout()
        route(request) { [weak self] response in
            guard let self else { return }
            // Handlers finish on the main actor; hop back before touching the
            // socket so all connection state stays on one queue.
            self.queue.async { self.write(response, keepAlive: keepAlive) }
        }
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        let pathPart: Substring
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            pathPart = target[target.startIndex..<mark]
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = parts.count > 1
                    ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
                    : ""
                query[name] = value
            }
        } else {
            pathPart = target[...]
        }
        // Decode **per segment**, after splitting. Decoding the whole path first
        // would make an encoded `%2F` inside a recording id indistinguishable
        // from a real separator.
        let decoded = pathPart
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? String($0) }
            .joined(separator: "/")
        return (decoded, query)
    }

    // MARK: Writing

    private func write(_ response: HTTPResponse, keepAlive: Bool) {
        guard !isClosed else { return }
        isResponding = true

        switch response.body {
        case .data(let data):
            var headers = response.headers
            headers["Content-Length"] = "\(data.count)"
            let shouldKeepAlive = keepAlive && !response.closeAfterWrite
            headers["Connection"] = shouldKeepAlive ? "keep-alive" : "close"
            var out = Self.headerBlock(status: response.status, headers: headers)
            // A HEAD reply carries the headers the GET would have, and no body.
            if !isHeadRequest { out.append(data) }
            send(out, thenClose: !shouldKeepAlive) { [weak self] in
                guard let self else { return }
                self.isResponding = false
                guard shouldKeepAlive else { return }
                // Another pipelined request may already be buffered.
                self.drainBuffer()
            }

        case .file(let url, let offset, let length):
            sendFile(url: url, offset: offset, length: length,
                     response: response, keepAlive: keepAlive && !response.closeAfterWrite)

        case .eventStream(let onOpen):
            var headers = response.headers
            headers["Content-Type"] = "text/event-stream"
            headers["Cache-Control"] = "no-store"
            headers["X-Accel-Buffering"] = "no"
            // No Content-Length and no chunked encoding, so the body is
            // close-delimited; saying keep-alive would contradict that.
            headers["Connection"] = "close"
            let block = Self.headerBlock(status: response.status, headers: headers)
            stateLock.withLock { _isEventStream = true }
            // An event stream is open-ended by design, so the request deadline
            // must not reap it.
            timeout?.cancel()
            timeout = nil
            send(block, thenClose: false) { [weak self] in
                guard let self else { return }
                self.isResponding = false
                onOpen(self)
            }
        }
    }

    private static func headerBlock(status: Int, headers: [String: String]) -> Data {
        let reason = statusReasons[status] ?? "OK"
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        // Every value here is a literal, an integer, or a hex token. If one ever
        // comes from user data — a `Content-Disposition` built from a recording
        // title, say — it must have CR/LF stripped first or it is header
        // injection.
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    private func send(_ data: Data, thenClose: Bool, completion: (() -> Void)?) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || thenClose {
                self.closeOnQueue()
                return
            }
            completion?()
        })
    }

    /// Push one `data:` frame down an already-upgraded event stream. Safe from
    /// any thread: it reads the two locked flags and then calls
    /// `NWConnection.send`, which is itself thread-safe.
    func sendEvent(_ payload: String) {
        guard isEventStream, !isClosed else { return }
        // Backpressure. At most one live frame is in flight at a time: if the
        // previous send hasn't reached the transport yet, DROP this one instead
        // of enqueuing it. `LiveChannel` pushes up to 4 Hz, and every frame is an
        // idempotent snapshot (live/status) or a refetch signal (library), so the
        // next tick carries the freshest state regardless. Without this, a laptop
        // on congested wifi lets frames pile up unacknowledged inside
        // `NWConnection` and the phone's memory climbs until keepalive kills the
        // peer. This is the same "wait for the previous chunk" discipline `pump`
        // uses for file streaming, reduced to a drop because a live frame is
        // disposable where a file byte is not.
        let mayScheduleSend: Bool = stateLock.withLock {
            guard !_sendInFlight else { return false }
            _sendInFlight = true
            return true
        }
        guard mayScheduleSend else { return }

        // Every line of a multi-line payload needs its own `data:` prefix, and
        // a blank line terminates the event.
        let framed = payload
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "data: \($0)" }
            .joined(separator: "\n") + "\n\n"
        connection.send(content: Data(framed.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.stateLock.withLock { self._sendInFlight = false }
            if error != nil { self.close() }
        })
    }

    // MARK: File streaming

    /// Chunked read/send with real backpressure: the next chunk is only read
    /// once the previous one has been handed to the transport. Recordings are
    /// whole meetings, so loading one into memory to answer a range request is
    /// not an option.
    private func sendFile(
        url: URL, offset: Int, length: Int, response: HTTPResponse, keepAlive: Bool
    ) {
        // Open and measure the file *before* committing to a Content-Length.
        // The handler stat'd it on the main actor and the recording can be
        // deleted in between — concurrent phone/browser editing is the premise
        // of this whole feature — and a short body against a declared length
        // surfaces in Safari as a media *decode* error, which is near
        // impossible to attribute.
        let opened = try? FileHandle(forReadingFrom: url)
        guard let handle = opened,
              let actualSize = try? handle.seekToEnd(),
              offset >= 0, length >= 0,
              UInt64(offset) < actualSize,
              UInt64(offset + length) <= actualSize,
              (try? handle.seek(toOffset: UInt64(offset))) != nil
        else {
            try? opened?.close()
            write(.error(404, "The audio file is no longer available."), keepAlive: false)
            return
        }

        var headers = response.headers
        headers["Content-Length"] = "\(length)"
        // Keep-alive matters here more than anywhere else: Safari's `<audio>`
        // opens with a small probe range and then issues a fresh range request
        // on every scrub, so closing after each one costs a TCP handshake to the
        // phone per seek — audible as a stall.
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        let block = Self.headerBlock(status: response.status, headers: headers)

        guard !isHeadRequest else {
            try? handle.close()
            send(block, thenClose: !keepAlive) { [weak self] in
                guard let self else { return }
                self.isResponding = false
                self.drainBuffer()
            }
            return
        }

        // A whole-file 200 for an hour-long recording streams for longer than
        // the per-request deadline, which would otherwise reap the download
        // mid-flight. Backpressure in `pump` is what bounds this instead: the
        // next chunk is only read once the previous one is away, so a stalled
        // peer stops progressing rather than buffering.
        timeout?.cancel()
        timeout = nil

        send(block, thenClose: false) { [weak self] in
            self?.pump(handle: handle, remaining: length, keepAlive: keepAlive)
        }
    }

    private func pump(handle: FileHandle, remaining: Int, keepAlive: Bool) {
        guard !isClosed else {
            try? handle.close()
            return
        }
        guard remaining > 0 else {
            try? handle.close()
            // The declared Content-Length has been delivered in full, so the
            // socket can be reused rather than torn down.
            guard keepAlive else {
                closeOnQueue()
                return
            }
            isResponding = false
            armTimeout()   // reaps the socket if no further request arrives
            drainBuffer()
            return
        }
        let wanted = min(remaining, Self.fileChunkBytes)
        guard let chunk = try? handle.read(upToCount: wanted), !chunk.isEmpty else {
            try? handle.close()
            closeOnQueue()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else {
                try? handle.close()
                return
            }
            if error != nil {
                try? handle.close()
                self.closeOnQueue()
                return
            }
            self.pump(handle: handle, remaining: remaining - chunk.count, keepAlive: keepAlive)
        })
    }
}

extension HTTPConnection: EventStreamSink {
    var isOpen: Bool { !isClosed && isEventStream }
}
