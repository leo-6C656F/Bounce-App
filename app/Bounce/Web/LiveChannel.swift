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

    /// A sink plus the token that opened it. The token is what makes revocation
    /// work: authorization is checked when the stream opens and never again, so
    /// without it a revoked browser keeps receiving live transcripts until the
    /// server stops entirely.
    private struct Subscriber {
        let sink: any EventStreamSink
        let token: String
    }

    private var subscribers: [Subscriber] = []
    private var pump: Task<Void, Never>?

    private var lastLiveFingerprint = ""
    private var lastStatusFingerprint = ""
    private var lastLibraryFingerprint = ""
    private var lastHeartbeat = Date.distantPast

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

        // Fingerprint first, build only on a change. Building the live payload
        // means regrouping the whole transcript into blocks and JSON-encoding
        // it, on the main actor, and at 4 Hz during a long recording that is a
        // real cost to pay for something usually thrown away.
        push(fingerprint: liveFingerprint(), against: &lastLiveFingerprint, build: livePayload)
        push(fingerprint: statusFingerprint(), against: &lastStatusFingerprint, build: statusPayload)
        push(fingerprint: libraryFingerprint(), against: &lastLibraryFingerprint) {
            #"{"type":"library"}"#
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

    private func livePayload() -> String {
        let live = LiveTranscriber.shared
        let names = live.sessionId.map {
            LiveSpeakerNameStore.shared.names(forSessionId: $0)
        } ?? [:]
        let blocks = Transcript(
            segments: live.segments,
            localeIdentifier: Locale.current.identifier,
            createdAt: Date()
        ).blocks(speakerNames: names.isEmpty ? nil : names)

        return encode(LivePayload(
            type: "live",
            isRunning: live.isRunning,
            sessionId: live.sessionId,
            error: live.errorMessage,
            volatile: live.volatileText,
            blocks: blocks.map(WebBlock.init)))
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
    let blocks: [WebBlock]
}

private struct StatusPayload: Encodable {
    let type: String
    let connected: Bool
    let deviceName: String?
    let isRecording: Bool
    let transcribing: String?
}
