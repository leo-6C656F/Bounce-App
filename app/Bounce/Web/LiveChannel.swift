import Foundation
import Observation

/// Server-sent-events fan-out: the phone pushing state to every open browser.
///
/// **Why SSE and not a WebSocket.** Everything on this channel travels one way,
/// phone → browser. `EventSource` is a handful of lines in the client, needs no
/// handshake or frame codec on the server, and reconnects on its own after a
/// dropped socket. A WebSocket would mean hand-rolling RFC 6455 framing on one
/// port, or a second listener, to end up somewhere worse.
///
/// Note what `EventSource` does **not** recover from: a non-200 status. Per the
/// HTML spec that is *fail the connection*, not *reconnect* — `readyState` goes
/// to CLOSED and stays there. So `/api/live` must never answer 401; `WebAPI`
/// returns a 200 stream carrying an `unauthorized` event instead.
///
/// Updates are polled and diffed at `tickInterval` rather than pushed from an
/// observation. `LiveTranscriber` is `@MainActor @Observable` with no publisher
/// to subscribe to, and its volatile text changes on every token — so something
/// has to coalesce regardless. Polling makes the rate explicit and has no
/// re-arming lifetime to get wrong.
@MainActor
final class LiveChannel {

    /// 4 Hz. Fast enough that live text feels immediate, slow enough that a long
    /// transcript isn't re-encoded on every recognised token.
    private static let tickInterval = Duration.milliseconds(250)
    /// Prunes sockets the OS hasn't told us about yet.
    private static let heartbeatInterval: TimeInterval = 15
    /// The library hash is the expensive per-tick job — ~8 fields of every
    /// recording — and the library changes far slower than the transcript. Recheck
    /// it at ~1 Hz rather than 4 Hz (A14). The event it drives is only a
    /// refetch signal, so a fraction of a second of latency costs nothing.
    private static let libraryHashInterval: TimeInterval = 1.0

    /// A sink plus the token that opened it. The token is what makes revocation
    /// work: authorization is checked when the stream opens and never again, so
    /// without it a revoked browser keeps receiving live transcripts until the
    /// server stops entirely.
    ///
    /// `sentLiveBaseline` is the guard behind A15's delta stream: the transcript
    /// is sent as incremental block deltas, so a subscriber's **first** live event
    /// after connecting (or after an `EventSource` auto-reconnect — a brand new
    /// subscriber either way) must be a complete snapshot, or it would be applying
    /// a suffix delta against a transcript it never received and desync. It starts
    /// false and is set true once this sink has been handed a full snapshot.
    private struct Subscriber {
        let sink: any EventStreamSink
        let token: String
        var sentLiveBaseline = false
    }

    private var subscribers: [Subscriber] = []
    private var pump: Task<Void, Never>?

    private var lastLiveFingerprint = ""
    private var lastStatusFingerprint = ""
    private var lastLibraryFingerprint = ""
    private var lastHeartbeat = Date.distantPast
    private var lastLibraryHashAt = Date.distantPast

    /// The block list as of the last live push, and the session it belonged to,
    /// so each tick can send only the changed suffix. A new session (or none)
    /// resets both and forces a fresh baseline to every subscriber.
    private var lastLiveBlocks: [WebBlock] = []
    private var lastLiveSessionId: Int?

    // MARK: - Clients

    func add(_ sink: any EventStreamSink, token: String) {
        subscribers.append(Subscriber(sink: sink, token: token))
        // A browser that just connected knows nothing; force a full push rather
        // than making it wait for the next change.
        resetFingerprints()
        startPumpIfNeeded()
    }

    /// Drop and close every stream opened with this token.
    func closeStreams(token: String) {
        let doomed = subscribers.filter { $0.token == token }
        subscribers.removeAll { $0.token == token }
        for subscriber in doomed {
            subscriber.sink.sendEvent(#"{"type":"unauthorized"}"#)
            subscriber.sink.close()
        }
    }

    func removeClosed() {
        subscribers.removeAll { !$0.sink.isOpen }
    }

    func closeAll() {
        for subscriber in subscribers { subscriber.sink.close() }
        subscribers.removeAll()
        pump?.cancel()
        pump = nil
    }

    var clientCount: Int { subscribers.count }

    private func resetFingerprints() {
        lastLiveFingerprint = ""
        lastStatusFingerprint = ""
        lastLibraryFingerprint = ""
        // Force the throttled library check to fire on the very next tick, so a
        // newly connected browser gets the refetch signal promptly rather than
        // waiting up to a full `libraryHashInterval`.
        lastLibraryHashAt = .distantPast
    }

    // MARK: - Pump

    private func startPumpIfNeeded() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self else { return }
                self.tick()
                if self.subscribers.isEmpty {
                    // Only clear the handle if it's still ours. A cancelled pump
                    // whose resumption lands after a newer one was installed
                    // would otherwise orphan that newer task, leaving it ticking
                    // at 4 Hz for the rest of the process with no way to cancel.
                    if !Task.isCancelled { self.pump = nil }
                    return
                }
            }
        }
    }

    private func tick() {
        removeClosed()
        guard !subscribers.isEmpty else { return }

        // Live is handled per-subscriber: incremental deltas to established
        // clients, a full snapshot to any that haven't received a baseline yet.
        pushLive()

        push(fingerprint: statusFingerprint(), against: &lastStatusFingerprint, build: statusPayload)

        // A14: recheck the (expensive, whole-library) fingerprint at ~1 Hz.
        if Date().timeIntervalSince(lastLibraryHashAt) >= Self.libraryHashInterval {
            lastLibraryHashAt = Date()
            push(fingerprint: libraryFingerprint(), against: &lastLibraryFingerprint) {
                #"{"type":"library"}"#
            }
        }

        if Date().timeIntervalSince(lastHeartbeat) > Self.heartbeatInterval {
            lastHeartbeat = Date()
            broadcast(#"{"type":"ping"}"#)
        }
    }

    private func push(fingerprint: String, against last: inout String, build: () -> String) {
        guard fingerprint != last else { return }
        last = fingerprint
        broadcast(build())
    }

    /// Send to every open client. A failed write closes that socket; the next
    /// tick prunes it.
    func broadcast(_ json: String) {
        for subscriber in subscribers where subscriber.sink.isOpen {
            subscriber.sink.sendEvent(json)
        }
    }

    // MARK: - Payloads

    private func liveFingerprint() -> String {
        let live = LiveTranscriber.shared
        // Segment count plus volatile length is enough to notice every change
        // without hashing the whole transcript four times a second.
        let named = live.sessionId.map {
            LiveSpeakerNameStore.shared.names(forSessionId: $0)
        } ?? [:]
        return "\(live.isRunning)|\(live.sessionId ?? -1)|\(live.segments.count)"
            + "|\(live.volatileText.count)|\(live.errorMessage ?? "")"
            // Naming a voice mid-recording has to move the preview, or the rename
            // looks like it didn't take until the next phrase arrives.
            + "|\(named.sorted { $0.key < $1.key })"
    }

    /// Push the live transcript to each subscriber: a full snapshot to any that
    /// hasn't been given a baseline yet (a fresh connect, or an `EventSource`
    /// auto-reconnect — a new subscriber either way), an incremental delta to the
    /// rest — and only when something actually changed.
    ///
    /// This is A15: the old code regrouped the whole transcript and JSON-encoded
    /// every block up to 4×/sec, a cost that grew with meeting length (quadratic
    /// over a call). Grouping still happens — it reads all segments — but the
    /// encode, the network payload and (with the client's matching splice) the DOM
    /// work are now bounded to the changed suffix, which is normally one block.
    private func pushLive() {
        let live = LiveTranscriber.shared
        let sessionId = live.sessionId

        // A new recording (or the end of one) invalidates every client's block
        // list, so reset the diff base and force a fresh baseline to everyone —
        // otherwise a delta would be spliced onto the previous recording.
        if sessionId != lastLiveSessionId {
            lastLiveSessionId = sessionId
            lastLiveBlocks = []
            for index in subscribers.indices { subscribers[index].sentLiveBaseline = false }
            lastLiveFingerprint = ""
        }

        let needsBaseline = subscribers.contains { $0.sink.isOpen && !$0.sentLiveBaseline }
        let fingerprint = liveFingerprint()
        let changed = fingerprint != lastLiveFingerprint

        // Idle open socket: nothing changed and everyone has a baseline. Skipping
        // here is what stops a quiet stream regrouping and encoding four times a
        // second.
        guard changed || needsBaseline else { return }

        // Regroup once (grouping reads all segments), then diff against the last
        // push to find the first changed block.
        let names = sessionId.map { LiveSpeakerNameStore.shared.names(forSessionId: $0) } ?? [:]
        let blocks = Transcript(
            segments: live.segments,
            localeIdentifier: Locale.current.identifier,
            createdAt: Date()
        ).blocks(speakerNames: names.isEmpty ? nil : names).map(WebBlock.init)

        let changedFrom = Self.firstChangedBlock(lastLiveBlocks, blocks)

        // Build the full and delta bodies lazily — most ticks send only one kind.
        var fullBody: String?
        var deltaBody: String?
        func fullPayload() -> String {
            if let fullBody { return fullBody }
            let body = encode(LivePayload(
                type: "live", isRunning: live.isRunning, sessionId: sessionId,
                error: live.errorMessage, volatile: live.volatileText,
                full: true, replaceFrom: 0, blocks: blocks))
            fullBody = body
            return body
        }
        func deltaPayload() -> String {
            if let deltaBody { return deltaBody }
            let suffix = changedFrom < blocks.count ? Array(blocks[changedFrom...]) : []
            let body = encode(LivePayload(
                type: "live", isRunning: live.isRunning, sessionId: sessionId,
                error: live.errorMessage, volatile: live.volatileText,
                full: false, replaceFrom: changedFrom, blocks: suffix))
            deltaBody = body
            return body
        }

        for index in subscribers.indices {
            guard subscribers[index].sink.isOpen else { continue }
            if !subscribers[index].sentLiveBaseline {
                subscribers[index].sink.sendEvent(fullPayload())
                subscribers[index].sentLiveBaseline = true
            } else if changed {
                subscribers[index].sink.sendEvent(deltaPayload())
            }
        }

        lastLiveFingerprint = fingerprint
        lastLiveBlocks = blocks
    }

    /// First index at which two block lists diverge. Earlier blocks are immutable
    /// once a later block starts, so in steady state this is `new.count - 1` (the
    /// growing tail) or `new.count` (only the volatile text moved, no block
    /// changed).
    private static func firstChangedBlock(_ old: [WebBlock], _ new: [WebBlock]) -> Int {
        let common = min(old.count, new.count)
        var index = 0
        while index < common {
            if !sameBlock(old[index], new[index]) { return index }
            index += 1
        }
        return index
    }

    private static func sameBlock(_ a: WebBlock, _ b: WebBlock) -> Bool {
        a.id == b.id && a.start == b.start && a.speaker == b.speaker
            && a.phrases.count == b.phrases.count && a.text == b.text
    }

    private func statusFingerprint() -> String {
        let device = DeviceManager.shared
        return "\(device.connectionState.isConnected)|\(device.device?.name ?? "")"
            + "|\(RecordingManager.shared.state.isActive)|\(Self.transcribingId ?? "")"
    }

    private func statusPayload() -> String {
        let device = DeviceManager.shared
        return encode(StatusPayload(
            type: "status",
            connected: device.connectionState.isConnected,
            deviceName: device.device?.name,
            isRecording: RecordingManager.shared.state.isActive,
            transcribing: Self.transcribingId))
    }

    private static var transcribingId: String? {
        TranscriptionCoordinator.shared.statuses.first { $0.value.isWorking }?.key
    }

    /// The library payload is only a signal to refetch — sending the whole list
    /// at 4 Hz would mean re-encoding every transcript in the library.
    private func libraryFingerprint() -> String {
        let recordings = RecordingStore.shared.recordings
        var hasher = Hasher()
        for recording in recordings {
            hasher.combine(recording.id)
            hasher.combine(recording.title)
            hasher.combine(recording.categoryName)
            hasher.combine(recording.audioFilename)
            hasher.combine(recording.transcript?.segments.count)
            hasher.combine(recording.summaries?.count)
            hasher.combine(recording.speakerNames)
            hasher.combine(recording.highlights?.count)
        }
        // Transcription status is not stored on the recording, so without this
        // a row's "Queued"/"Transcribing" label could never change: pressing
        // Transcribe in the browser would look like a no-op for minutes.
        for (id, status) in TranscriptionCoordinator.shared.statuses.sorted(by: { $0.key < $1.key }) {
            hasher.combine(id)
            hasher.combine(status.label)
        }
        return "\(recordings.count)|\(hasher.finalize())"
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"type":"error"}"# }
        return text
    }
}

// MARK: - Wire types

private struct LivePayload: Encodable {
    let type: String
    let isRunning: Bool
    let sessionId: Int?
    let error: String?
    let volatile: String
    /// True for a complete snapshot: `blocks` replace the whole list. A late
    /// joiner or an `EventSource` reconnect always receives one of these before
    /// any delta, so it never splices a suffix onto a transcript it never had.
    let full: Bool
    /// The index `blocks` replace from. For a full snapshot this is 0; for a
    /// delta it is the first changed block, so the client keeps `[0..<replaceFrom)`
    /// and swaps in `blocks` for the rest.
    let replaceFrom: Int
    let blocks: [WebBlock]
}

private struct StatusPayload: Encodable {
    let type: String
    let connected: Bool
    let deviceName: String?
    let isRecording: Bool
    let transcribing: String?
}
