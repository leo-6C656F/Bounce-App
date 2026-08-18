import Foundation

/// Streams live PCM to Soniox's real-time WebSocket and reports transcript
/// updates as they arrive.
///
/// The cloud counterpart to the Apple `SpeechAnalyzer` live path. `LiveTranscriber`
/// owns the decrypt/decode pipeline and hands this the same 16 kHz mono Int16 PCM
/// it would otherwise feed Apple; this ships it to Soniox instead.
///
/// Protocol (raw WebSocket, no SDK):
///   1. connect to `wss://stt-rt.soniox.com/transcribe-websocket`
///   2. send one JSON text frame: the config, carrying the API key
///   3. stream raw PCM as binary frames
///   4. receive JSON result frames: `{tokens:[{text,is_final}], finished}`
///   5. to end, send an empty frame; the server flushes and sends `finished:true`
///
/// `@unchecked Sendable` with a lock because the receive loop runs on a URLSession
/// delegate/continuation thread while `ingest`/`finish` are called from the main
/// actor. Token state is lock-guarded; `onUpdate` hops to the main actor itself.
final class SonioxLiveSession: NSObject, @unchecked Sendable {

    /// Reports (committed segments, volatile text) as the transcript evolves.
    /// Set by `LiveTranscriber`; invoked from a background thread, so the closure
    /// must hop to the main actor before touching observable state.
    var onUpdate: (@Sendable ([TranscriptSegment], String) -> Void)?

    private let apiKey: String
    private let locale: Locale
    /// One-way translation target for the live preview, or nil for off.
    /// Captured at init so the session's filtering can't drift from the config
    /// it sent if the setting changes mid-recording.
    private let translationTarget: String?
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    private let lock = NSLock()
    private var finalTokens: [Soniox.Token] = []
    private var started = false
    private var closed = false

    /// Resolved once the server sends `finished:true` (or the socket closes), so
    /// `finish()` can wait for the real final tokens rather than guessing.
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(apiKey: String, locale: Locale) {
        self.apiKey = apiKey
        self.locale = locale
        self.translationTarget = DeliverySettings.sonioxTranslationTargetCode
        self.session = URLSession(configuration: .default)
        super.init()
    }

    /// True once the socket has closed — the server sent `finished`, reported an
    /// error, or the receive loop failed. A closed session cannot be reused and
    /// `ingest` becomes a silent no-op, so `LiveTranscriber` watches this and
    /// reconnects mid-recording rather than transcribing into a dead socket.
    var isFinished: Bool { isClosed }

    // MARK: - Lifecycle

    /// Connect and send the config frame. Throws if the socket can't open, so the
    /// caller can fall back to on-device before any audio is lost.
    func start() throws {
        let task = session.webSocketTask(with: Soniox.realtimeURL)
        self.task = task
        task.resume()

        var config: [String: Any] = [
            "api_key": apiKey,
            "model": Soniox.realtimeModel,
            "audio_format": Soniox.audioFormat,
            "sample_rate": Soniox.sampleRate,
            "num_channels": Soniox.channels,
            "enable_speaker_diarization": true,
            "enable_language_identification": true,
            // Finalize tokens as soon as the speaker pauses, instead of holding
            // them volatile — visibly cuts live-caption latency.
            "enable_endpoint_detection": true,
        ]
        let hints = Soniox.languageHints(for: locale)
        if !hints.isEmpty {
            config["language_hints"] = hints
        }
        if let context = Soniox.contextPayload() {
            config["context"] = context
        }
        if let target = translationTarget {
            // Everything spoken is translated into the target language; the
            // preview shows the translation (the post-sync pass keeps the
            // original language).
            config["translation"] = ["type": "one_way", "target_language": target]
        }

        let data = try JSONSerialization.data(withJSONObject: config)
        let json = String(decoding: data, as: UTF8.self)
        task.send(.string(json)) { [weak self] error in
            if let error {
                TranscribeLog.log("soniox live: config send failed: \(error)")
                self?.close()
            }
        }
        started = true
        TranscribeLog.log("soniox live: connected, model \(Soniox.realtimeModel)")
        receiveLoop()
    }

    /// Feed one PCM chunk (16 kHz mono Int16). Safe from the main actor.
    func ingest(_ pcm: Data) {
        guard started, !closed, let task else { return }
        task.send(.data(pcm)) { error in
            if let error { TranscribeLog.log("soniox live: audio send failed: \(error)") }
        }
    }

    /// Signal end-of-audio, wait briefly for the server's final tokens, and return
    /// the committed segments. Bounded so a silent server can't hang teardown.
    func finish() async -> [TranscriptSegment] {
        guard started, !closed, let task else { return currentSegments() }

        // Empty frame = "no more audio"; the server flushes and sends finished.
        task.send(.data(Data())) { _ in }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    guard let self else { cont.resume(); return }
                    self.lock.lock()
                    if self.closed { self.lock.unlock(); cont.resume(); return }
                    self.finishContinuation = cont
                    self.lock.unlock()
                }
            }
            group.addTask {
                // Don't wait forever for a `finished` that may never come.
                try? await Task.sleep(for: .seconds(4))
            }
            await group.next()   // whichever happens first

            // Resume the parked continuation here, *inside* the group scope. If
            // the timeout won, the continuation child is still blocked in a
            // non-cancellation-aware `withCheckedContinuation` — `cancelAll()`
            // can't wake it, and `withTaskGroup` implicitly awaits *all* children
            // before returning, so without this the group (and `finish()`) would
            // hang forever on a silent socket. `close()` is idempotent, so if a
            // real `finished` already closed the session this is a no-op.
            close()
            group.cancelAll()
        }

        return currentSegments()
    }

    // MARK: - Receive

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                TranscribeLog.log("soniox live: receive ended (\(error))")
                self.close()
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text)
                } else if case .data(let data) = message,
                          let text = String(data: data, encoding: .utf8) {
                    self.handle(text)
                }
                if !self.isClosed { self.receiveLoop() }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let result = try? JSONDecoder().decode(Soniox.Result.self, from: data) else {
            // A `try?` here used to fail silently — indistinguishable from
            // "server never replied". Logging the raw payload is what tells
            // the two apart, and shows the wire shape if our `Soniox.Result`
            // doesn't actually match the server's schema.
            TranscribeLog.log("soniox live: undecodable message (\(text.count) chars): "
                + text.prefix(300))
            return
        }

        if let code = result.errorCode {
            TranscribeLog.log("soniox live: server error \(code) \(result.errorMessage ?? "")")
            close()
            return
        }

        if translationTarget != nil {
            // Translation mode filters on `translationStatus == "translation"`;
            // this breakdown is what shows whether the server is actually
            // sending any, versus the filter discarding everything silently.
            let byStatus = Dictionary(grouping: result.tokens ?? []) { $0.translationStatus ?? "nil" }
                .mapValues(\.count)
            TranscribeLog.log("soniox live: \(result.tokens?.count ?? 0) token(s) by status \(byStatus)"
                + (result.finished == true ? ", finished" : ""))
        } else {
            TranscribeLog.log("soniox live: \(result.tokens?.count ?? 0) token(s)"
                + (result.finished == true ? ", finished" : ""))
        }

        var volatile = ""
        lock.lock()
        for token in result.tokens ?? [] {
            // With one-way translation on, the stream interleaves "original"
            // (pre-translation source text — paired with a "translation" token,
            // so shown it would double the text up in two languages) and
            // "translation" tokens. It can also send "none": nothing needed
            // translating, most commonly because the detected source language
            // already *is* the target — e.g. target "en" while speaking
            // English. Skipping "none" too silently blanks the whole preview in
            // that case; showing the untranslated text is strictly better than
            // showing nothing.
            if translationTarget != nil, token.translationStatus == "original" { continue }
            if token.isFinal == true {
                // Kept, not dropped: `Soniox.segments` uses the endpoint marker
                // to break phrases. It just never renders it.
                finalTokens.append(token)
            } else if !Soniox.isControlToken(token.text) {
                // The volatile tail is shown verbatim, so a control token here
                // would appear on screen.
                volatile += token.text
            }
        }
        let committed = Soniox.segments(from: finalTokens)
        lock.unlock()

        onUpdate?(committed, volatile.trimmingCharacters(in: .whitespacesAndNewlines))

        if result.finished == true { close() }
    }

    // MARK: - Teardown

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func currentSegments() -> [TranscriptSegment] {
        lock.lock(); defer { lock.unlock() }
        return Soniox.segments(from: finalTokens)
    }

    private func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let cont = finishContinuation
        finishContinuation = nil
        lock.unlock()

        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        cont?.resume()
    }
}
