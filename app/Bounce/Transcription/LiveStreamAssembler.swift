import Foundation
@preconcurrency import PlaudBleSDK
@preconcurrency import PlaudDeviceBasicSDK

/// Reassembles and decrypts the recorder's encrypted stream *while it records*,
/// so the audio can be transcribed before the recording finishes.
///
/// ## Why this exists
///
/// `blePcmData` never fires for E2EE recordings, so there is no decoded audio to
/// listen to. But `bleData` **does** stream the raw encrypted bytes live — proven
/// on hardware: ~208 bytes a packet, continuously, from the moment recording
/// starts.
///
/// ## The trick
///
/// The recorder's file is laid out as:
///
///     [0 … 511]      PlaudEncryptHeader — nonce + RSA-wrapped ChaCha20 key
///     [512 … 1023]   Ogg OpusHead + OpusTags (stream configuration)
///     [1024 … ]      encrypted Opus audio
///
/// `PlaudDeviceAgent.syncFile` reads a live recording **from offset 1024** — it
/// swallows 0–623 for its own E2EE header sync and never forwards 0–1023 at all.
/// So this issues its own read from offset 0, which delivers the whole stream
/// contiguously from the header onward. That contiguity is what lets
/// `decryptAudioToOgg` do the header parse, RSA unwrap and ChaCha20 pass in a
/// single call, with no manual keystream counter arithmetic. Bytes 512–1023 matter
/// on their own too: `OpusHead` lives there, and without it the decoder cannot
/// configure the stream.
///
/// ## Only one file sync exists at a time, and the last request wins
///
/// Both reads go through the same BLE channel, so they do not coexist — proven by
/// two runs of the same code taking opposite paths:
///
/// | `bleData` offsets | channel owner |
/// |---|---|
/// | `0, 208, … 135200` — contiguous from 0 | our read; it served the whole recording |
/// | `1024, 11216, …` (`1024 + n·208`) | the SDK's read; ours never landed |
///
/// Requesting at record start is therefore a coin flip against the SDK's own
/// header sync. Instead this waits until bytes arrive at an offset it cannot use —
/// which *is* the evidence that the SDK's read won — and only then requests, so it
/// is reliably the last request in. See `requestReadFromStart`.
///
/// ## Cost, and where decoding runs
///
/// Decoding is delegated to `LiveDecoder`, an actor that runs off the main actor
/// so this class's `ingest` — called from the Bluetooth queue on every packet —
/// never waits behind a decode. The assembler's own job is deliberately cheap:
/// buffer bytes at their true offsets, detect the header, and hand snapshots to
/// the decoder across `await`.
@MainActor
final class LiveStreamAssembler {

    /// Bytes before the audio payload: 512 header + 512 Ogg configuration.
    static let prefixLength = 1024

    private(set) var sessionId: Int?

    /// Off-main decode engine. See `LiveDecoder`.
    private let decoder = LiveDecoder()

    /// Total PCM the decoder has emitted for this session (16 kHz mono Int16, so
    /// 32,000 bytes a second). This is the recording's own audio timeline, which
    /// is what a mid-recording engine restart needs in order to place the new
    /// engine's timestamps — see `LiveTranscriber.reviveSonioxIfNeeded`.
    private(set) var emittedPCMBytes = 0

    /// Seconds of audio emitted so far, from `emittedPCMBytes`.
    var emittedSeconds: TimeInterval { Double(emittedPCMBytes) / 32000 }

    /// Which decode path served the last slice, so the slice cadence can adapt:
    /// the streaming path is linear and cheap, so it can run often; the whole-file
    /// fallback re-decodes everything, so it must run rarely. Starts optimistic.
    private(set) var lastDecodePath: LiveDecoder.Strategy?

    /// How long to wait before the next decode slice. Streaming keeps the
    /// transcript a few seconds behind the speaker; the whole-file fallback backs
    /// off so its quadratic cost doesn't dominate a long recording.
    var suggestedSliceInterval: Duration {
        lastDecodePath == .wholeFile ? .seconds(8) : .seconds(3)
    }

    /// Private key for the RSA unwrap, fetched once on the main actor and handed
    /// to the decoder so the decoder needn't touch main-actor SDK state.
    private var privateKey: String?

    /// The partial file, addressed by **absolute offset from 0**; holes are zeros.
    ///
    /// One offset-addressed buffer rather than append-in-arrival-order, because
    /// arrival order is not something this can rely on. A re-request restarts the
    /// stream at 0 and re-sends everything, and a packet can straddle the
    /// header/audio boundary. Appending got both wrong: the straddling packet's
    /// tail was dropped and then "padded" with zeros — 16 real bytes of Opus
    /// replaced with silence at the very start of the audio.
    ///
    /// Absolute offsets have to be preserved exactly. ChaCha20 is a stream cipher
    /// keyed by position, so one byte of drift turns every later frame into noise
    /// (`压缩数据已损坏，跳帧`).
    private var file = Data()

    /// Real bytes written, as opposed to `file.count`, which includes holes.
    private var receivedBytes = 0
    /// Next offset expected, so drops can be reported rather than hidden.
    private var expectedOffset: Int?
    private var holeBytes = 0

    /// Set once bytes 0…1023 have actually arrived and the header parses.
    private(set) var isHeaderReady = false

    private var readRequests = 0
    /// `receivedBytes` when the last read was requested, so a retry waits for
    /// evidence that the previous one didn't land instead of firing on the next
    /// packet.
    private var receivedAtLastRequest = 0
    private var isDecoding = false

    /// How much of `file` is on disk in the session checkpoint. Bytes only ever
    /// append, so this doubles as the write cursor.
    private var checkpointedBytes = 0

    /// Re-requests made because another read was re-sending bytes we already hold.
    /// Bounded for the same reason `maxReadRequests` is.
    private var resumeRequests = 0
    private static let maxResumeRequests = 3

    /// How far behind our cursor a re-send has to start before it counts as "some
    /// other read owns the channel" rather than ordinary overlap.
    private static let resendSlack = 65_536

    /// Serialises work sent to the decoder actor. Unstructured `Task`s have **no
    /// ordering guarantee** between them, so `reset()` and `restoreCursor` fired as
    /// separate tasks can land in either order — and losing that race silently
    /// re-emits the whole recording. Same pattern, and the same reason, as
    /// `AudioPlayerModel`'s `sessionTask` chain.
    private var decoderTask: Task<Void, Never>?

    /// When the last packet arrived, so a stall can be told from a quiet moment.
    private var lastArrival: ContinuousClock.Instant?

    // MARK: - Arrival instrumentation (Tier 1)
    //
    // These measure the two things that decide whether decode latency is ours to
    // fix. `maxHop` is the longest gap between a `bleData` callback firing and
    // `ingest` actually running on the main actor: if it spikes, the main actor
    // is blocked (which moving decode off-main is meant to cure). Throughput
    // shows whether bytes arrive smoothly or in bursts once the actor is free.
    private let clock = ContinuousClock()
    private var firstArrival: ContinuousClock.Instant?
    private var lastThroughputLog: ContinuousClock.Instant?
    private var bytesSinceThroughputLog = 0
    private var maxHop: Duration = .zero

    init() {}

    var assembledBytes: Int { receivedBytes }

    // MARK: - Session

    /// Begin assembling for a session, and ask for the stream.
    ///
    /// `resumeFromPCMBytes` is how much audio a previous run of this same session
    /// already transcribed (see `LiveSessionCheckpoint`). When there is a
    /// checkpointed buffer to go with it, this picks the stream up where it
    /// stopped instead of at byte 0 — which is the difference between the
    /// transcript continuing and the call being re-downloaded from the top.
    func begin(sessionId: Int, resumeFromPCMBytes: Int = 0) {
        reset()
        self.sessionId = sessionId
        LiveSessionCheckpoint.shared.pruneStale(keeping: sessionId)

        if let restored = LiveSessionCheckpoint.shared.partialAudio(forSessionId: sessionId),
           restored.count > Self.prefixLength {
            file = restored
            receivedBytes = restored.count
            expectedOffset = restored.count
            checkpointedBytes = restored.count
            checkHeader()
            TranscribeLog.log("assembler: restored \(restored.count) checkpointed byte(s) "
                + "for \(sessionId), header=\(isHeaderReady)")
        }

        // The cursor has to be in place before the first decode, or that decode
        // emits the whole restored buffer as fresh PCM and the call is transcribed
        // twice. `newPCM` waits on this chain for exactly that reason.
        if resumeFromPCMBytes > 0 {
            emittedPCMBytes = resumeFromPCMBytes
            onDecoder { await $0.restoreCursor(pcmBytes: resumeFromPCMBytes) }
        }

        // Only a restored *and* parseable buffer can be continued; anything else
        // needs the header, which only comes from the start of the file.
        // `resumeStream` schedules its own fallback to a read from 0.
        if isHeaderReady {
            resumeStream()
        } else {
            requestReadFromStart()
        }
    }

    func reset() {
        sessionId = nil
        file = Data()
        receivedBytes = 0
        expectedOffset = nil
        holeBytes = 0
        isHeaderReady = false
        privateKey = nil
        readRequests = 0
        receivedAtLastRequest = 0
        firstArrival = nil
        lastThroughputLog = nil
        bytesSinceThroughputLog = 0
        maxHop = .zero
        lastDecodePath = nil
        emittedPCMBytes = 0
        checkpointedBytes = 0
        resumeRequests = 0
        lastArrival = nil
        onDecoder { await $0.reset() }
    }

    /// Run decoder work in the order it was requested. See `decoderTask`.
    private func onDecoder(_ body: @escaping @Sendable (LiveDecoder) async -> Void) {
        let previous = decoderTask
        let decoder = self.decoder
        decoderTask = Task {
            await previous?.value
            await body(decoder)
        }
    }

    /// Two attempts beyond the first: enough to win the channel back from the
    /// SDK's read, few enough that a firmware that simply refuses can't be pestered
    /// for the length of a recording.
    private static let maxReadRequests = 3

    /// Bytes that must arrive without a header before a retry is worth making.
    /// At ~208 bytes a packet that is a few seconds of stream — long enough to be
    /// sure the previous request lost, short enough not to lose much audio.
    private static let retryAfterBytes = 8192

    /// Ask the recorder to stream this session from offset 0, continuously.
    ///
    /// **`end: 0` means "stream to the end", the same value the SDK's own
    /// continuous read uses** (`PlaudDeviceAgent.syncFile(…, end: 0)` in
    /// `DeviceManager.syncFile`). Passing `end: 1024` instead was a bug: it
    /// sometimes capped the read at 1024 bytes and ended it (`bleSyncFileTail`),
    /// and because our read cancels the SDK's stream on the shared channel, the
    /// whole byte flow then stalled — the recorder kept recording but nothing
    /// reached us past 10 KB. `end: 0` streams the growing file from the header
    /// onward, so the header arrives first (making `isHeaderReady` true almost
    /// immediately, before the retry threshold), and audio keeps flowing.
    private func requestReadFromStart() {
        guard let sessionId, readRequests < Self.maxReadRequests else { return }
        readRequests += 1
        receivedAtLastRequest = receivedBytes
        TranscribeLog.log("assembler: requesting stream from offset 0 for \(sessionId) "
            + "(attempt \(readRequests) of \(Self.maxReadRequests))")
        BleAgent.shared.syncFile(sessionId: sessionId, start: 0, end: 0, decode: false)
    }

    /// Re-open the byte stream after the recorder paused and resumed.
    ///
    /// A pause ends the read **silently** — no `bleSyncFileTail`, no error,
    /// `bleData` simply stops — and nothing restarted it, so every byte recorded
    /// after the resume never reached the app: the live transcript froze at the
    /// pause while the recorder happily kept recording (device log: the same
    /// `staging 97760 bytes` snapshot re-decoded until record stop, then the
    /// post-sync export streamed the full 171,520-byte file).
    ///
    /// Requests from the contiguous end of what we already hold rather than from
    /// 0. At the ~4–6 KB/s this link delivers, the recorder barely out-streams
    /// its own audio, so re-sending the whole file would put the transcript
    /// further behind the speaker the longer the recording had already run.
    /// Absolute offsets are preserved either way (see `write`), and the decrypt
    /// needs *the buffer* to be contiguous from 0 — not the request. Before the
    /// header lands there is nothing to be contiguous with, so that case starts
    /// over at 0.
    func resumeStream() {
        guard let sessionId else { return }
        let start = isHeaderReady ? (expectedOffset ?? 0) : 0
        receivedAtLastRequest = receivedBytes
        TranscribeLog.log("assembler: re-requesting stream from \(start) "
            + "for \(sessionId) after resume")
        BleAgent.shared.syncFile(sessionId: sessionId, start: start, end: 0, decode: false)
        if start > 0 { scheduleResumeFallback() }
    }

    /// If a mid-file resume produces nothing, go back to reading from 0.
    ///
    /// **Whether the recorder honours a `start` other than 0 is not verified on
    /// hardware** — the SDK's own live read only ever asks for 1024. A request it
    /// quietly ignores would freeze the transcript for the rest of the call, which
    /// is worse than the re-download the mid-file start was avoiding. So this
    /// waits for evidence of nothing and takes the slow path.
    private func scheduleResumeFallback() {
        let bytesAtRequest = receivedBytes
        Task { [weak self] in
            try? await Task.sleep(for: Self.resumeFallbackDelay)
            guard let self, self.sessionId != nil, self.receivedBytes == bytesAtRequest else { return }
            // Silence while paused is the recorder doing as it was told, not a
            // refused request — re-reading the whole file for that would be a
            // self-inflicted re-download.
            guard case .recording = RecordingManager.shared.state else { return }
            TranscribeLog.log("assembler: mid-file resume produced nothing — reading from 0")
            self.requestReadFromStart()
        }
    }

    private static let resumeFallbackDelay: Duration = .seconds(10)

    /// Re-open the stream only if it has actually gone quiet.
    ///
    /// Backgrounding the app is the third way the read dies silently (a pause and
    /// a BLE reconnect are the others), but it doesn't always: `bluetooth-central`
    /// is declared, so bytes sometimes keep arriving. Requesting unconditionally
    /// on every foreground would restart a healthy stream for nothing, so this
    /// waits for evidence — which is the same rule `requestReadFromStart` follows.
    func resumeStreamIfStalled(idleFor idle: Duration = .seconds(4)) {
        guard sessionId != nil else { return }
        if let lastArrival, lastArrival.duration(to: clock.now) < idle { return }
        resumeStream()
    }

    // MARK: - Raw ingestion

    /// Raw bytes from `bleData`, tagged with their file offset.
    ///
    /// Filtered on session because `bleData` also carries **batch downloads**: as
    /// soon as recording stops the app syncs the file list and exports every
    /// recording, and those bytes arrive through the same callback. Ingesting them
    /// writes another recording's audio into this buffer at offsets that happen to
    /// look plausible — seen on device as a spurious `128-byte gap` warning during
    /// an unrelated session's download.
    ///
    /// `callbackAt` is stamped in `bleData` the instant the SDK delivers the
    /// packet, before the hop to the main actor. The gap between it and now is
    /// the main-actor scheduling delay — the Tier-1 measurement.
    func ingest(sessionId: Int, offset: Int, data: Data, callbackAt: ContinuousClock.Instant) {
        guard sessionId == self.sessionId, !data.isEmpty else { return }

        recordArrival(bytes: data.count, callbackAt: callbackAt)

        if let expected = expectedOffset, offset != expected {
            if offset < expected {
                // A re-request restarts the stream, so earlier offsets are a
                // re-send, not corruption. Writing by offset makes them harmless.
                TranscribeLog.log("assembler: stream restarted at \(offset) "
                    + "(was expecting \(expected))")

                // Far behind our cursor means someone else's read owns the
                // channel — the SDK re-issues its own from 0 when the app
                // relaunches and adopts a recording in progress. Ours has to be
                // the last request in, so make it so rather than sit through a
                // re-download of the whole call.
                if isHeaderReady, expected - offset > Self.resendSlack,
                   resumeRequests < Self.maxResumeRequests,
                   receivedBytes - receivedAtLastRequest > Self.retryAfterBytes {
                    resumeRequests += 1
                    resumeStream()
                }
            } else {
                // Ogg is self-synchronising, so the parser resyncs at the next page
                // boundary and only the damaged pages are lost. The zeros left in
                // the hole keep every later byte at its true offset.
                holeBytes += offset - expected
                TranscribeLog.log("assembler: ⚠︎ \(offset - expected)-byte gap at "
                    + "\(expected), left as silence (total \(holeBytes))")
            }
        }

        write(offset: offset, data: data)
        expectedOffset = offset + data.count

        checkHeader()

        // Bytes are flowing but the header never came, so the SDK's read owns the
        // channel. Now is the moment to take it: this request goes in last.
        if !isHeaderReady, receivedBytes - receivedAtLastRequest > Self.retryAfterBytes {
            requestReadFromStart()
        }
    }

    /// Track main-actor hop latency and throughput, logging roughly every 2s.
    private func recordArrival(bytes: Int, callbackAt: ContinuousClock.Instant) {
        let now = clock.now
        let hop = callbackAt.duration(to: now)
        if hop > maxHop { maxHop = hop }
        lastArrival = now

        if firstArrival == nil {
            firstArrival = now
            lastThroughputLog = now
        }
        bytesSinceThroughputLog += bytes

        guard let since = lastThroughputLog else { return }
        let window = since.duration(to: now)
        let windowSeconds = Double(window.components.seconds)
            + Double(window.components.attoseconds) / 1e18
        guard windowSeconds >= 2 else { return }

        let kbps = Double(bytesSinceThroughputLog) / windowSeconds / 1024
        let hopMs = Double(maxHop.components.seconds) * 1000
            + Double(maxHop.components.attoseconds) / 1e15
        TranscribeLog.log(String(format:
            "assembler: throughput %.1f KB/s over %.1fs, max main-actor hop %.0fms",
            kbps, windowSeconds, hopMs))
        lastThroughputLog = now
        bytesSinceThroughputLog = 0
        maxHop = .zero
    }

    /// Write at an absolute offset, growing the buffer with zeros as needed.
    private func write(offset: Int, data: Data) {
        let end = offset + data.count
        if file.count < end {
            file.append(Data(count: end - file.count))
        }
        file.replaceSubrange(offset..<end, with: data)
        receivedBytes += data.count
    }

    /// Promote to header-ready the moment 0…1023 are genuinely present.
    ///
    /// The magic check is what distinguishes "the header arrived" from "the buffer
    /// is long enough because audio arrived at 1024 and 0…1023 are still zeros".
    private func checkHeader() {
        guard !isHeaderReady, file.count >= Self.prefixLength else { return }
        guard file.prefix(8).elementsEqual(Array("PLAUD.AI".utf8)) else { return }

        isHeaderReady = true
        // Fetch the private key once, here on the main actor, so the off-main
        // decoder never has to reach into main-actor SDK state.
        privateKey = RSASecretConfig.getCurrentPrivateKey()
        let header = PlaudEncryptHeader(data: file.prefix(Self.prefixLength))
        TranscribeLog.log("assembler: header ready — parsed=\(header != nil) "
            + "encrypted=\(header?.isEncrypted ?? false) "
            + "nonce=\(header?.nonce.count ?? 0)B keyCipher=\(header?.keyCipher.count ?? 0)B")
    }

    // MARK: - Decode

    /// Decrypt and decode everything captured so far, returning the PCM that has
    /// not been emitted yet.
    ///
    /// The heavy work happens in `LiveDecoder`, off the main actor. This method
    /// only snapshots the buffer (a cheap COW reference) and advances the cursor
    /// once the decoder reports back. Returns nil when there is nothing new, or
    /// when the slice can't yet be decoded.
    func newPCM() async -> Data? {
        guard !isDecoding else { return nil }
        guard isHeaderReady, let privateKey else {
            TranscribeLog.log("assembler: waiting for the header before decoding "
                + "(\(receivedBytes) bytes in, none of them 0..<\(Self.prefixLength))")
            return nil
        }
        // Below roughly a second of Opus there is little point, and partial pages
        // are more likely to yield nothing.
        guard file.count > Self.prefixLength + 4096 else { return nil }

        isDecoding = true
        defer { isDecoding = false }

        // Snapshot on the main actor (cheap COW), log the shape, and hand off.
        let snapshot = file
        TranscribeLog.log("assembler: staging \(snapshot.count) bytes "
            + "(\(receivedBytes) received, \(holeBytes) as silence)")

        // Extend the on-disk copy on the slice cadence rather than per packet:
        // one append of a few KB every few seconds, and it is always a prefix of
        // what the next decode will see.
        if let sessionId {
            checkpointedBytes = LiveSessionCheckpoint.shared.appendPartialAudio(
                snapshot, forSessionId: sessionId, alreadyWritten: checkpointedBytes)
        }

        // Any queued reset/cursor restore must land first — see `decoderTask`.
        await decoderTask?.value

        guard let output = await decoder.decode(file: snapshot, privateKey: privateKey) else {
            return nil
        }
        lastDecodePath = output.path
        emittedPCMBytes = output.totalPCMBytes
        return output.freshPCM
    }
}
