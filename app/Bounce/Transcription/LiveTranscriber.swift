import AVFoundation
import Foundation
import Observation
import Speech

/// Transcribes the recorder's audio **as it is being spoken**, on device.
///
/// The recorder streams decoded PCM over Bluetooth while it records
/// (`blePcmData`), which Bounce was already receiving to drive the waveform and
/// then discarding. This feeds that same audio into `SpeechAnalyzer` with a
/// progressive preset, so text appears during the conversation instead of after
/// the file syncs.
///
/// Deliberately a **preview**, not the product. Bluetooth drops packets, so a
/// live transcript can be lossier than one made from the complete file. The
/// post-sync pass in `LocalTranscriber` remains authoritative and is allowed to
/// replace whatever this produced.
@MainActor
@Observable
final class LiveTranscriber {

    /// Reachable from the Bluetooth callback queue via the `nonisolated` `ingest`.
    /// The mutable state behind it stays on the main actor.
    nonisolated static let shared = LiveTranscriber()

    /// Phrases the analyzer has committed to.
    private(set) var segments: [TranscriptSegment] = []
    /// The phrase currently being spoken. Rewrites itself as the analyzer
    /// refines its guess, so it should be rendered as provisional.
    private(set) var volatileText: String = ""
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    /// Session id this transcript belongs to, so it can be matched to the
    /// recording once it syncs.
    private(set) var sessionId: Int?

    /// Lock-protected so `ingest` can reach it from the Bluetooth queue without
    /// hopping actors. See `PipeBox`.
    private let pipeBox = PipeBox()
    /// Reassembles and decrypts the raw stream, since the SDK gives us no
    /// decoded audio for E2EE recordings.
    let assembler = LiveStreamAssembler()
    /// Drives periodic decode slices while recording.
    private var sliceTimer: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var driver: Task<CMTime?, Error>?
    private var collector: Task<Void, Never>?

    /// Which engine this session is using. Decided at `beginSession` from the
    /// setting, and may fall back from `.soniox` to `.local` if Soniox can't start.
    private var engine: TranscriptionEngine = .local
    /// Live cloud session, when `engine == .soniox`. The decrypt/decode pipeline
    /// is shared; only the PCM sink differs — this WebSocket instead of the
    /// on-device analyzer.
    private var sonioxSession: SonioxLiveSession?

    /// Locale this session started with, so a mid-recording reconnect uses the
    /// same one rather than whatever the setting says by then.
    private var sessionLocale: Locale = .current

    /// Segments this session inherited rather than transcribed — from a previous
    /// run of the same recording (`LiveSessionCheckpoint`) or from a cloud socket
    /// that died and was reconnected — and the offset that puts the *current*
    /// engine's timestamps on the recording's timeline after them.
    ///
    /// Both are empty/zero for an ordinary session, which makes `placed` an
    /// identity. Every engine's timeline starts at zero when it starts, so
    /// whichever way a session is inherited, this is the correction.
    private var carriedSegments: [TranscriptSegment] = []
    private var timelineOffset: TimeInterval = 0

    /// 16 kHz mono Int16 — the one PCM format this whole pipeline speaks.
    private static let pcmBytesPerSecond: Double = 32000

    /// `nonisolated` so the shared instance can be created outside the main
    /// actor, which is what lets `ingest` reach it from the Bluetooth queue.
    nonisolated private init() {}

    var hasContent: Bool { !segments.isEmpty || !volatileText.isEmpty }

    /// Everything so far, including the in-progress phrase.
    var displayText: String {
        let committed = segments.map(\.text).joined(separator: " ")
        if volatileText.isEmpty { return committed }
        return committed.isEmpty ? volatileText : committed + " " + volatileText
    }

    // MARK: - Session

    /// Begin a live session. Safe to call when one is already running.
    func start(sessionId: Int, locale: Locale) {
        guard !isRunning else { return }

        self.sessionId = sessionId
        self.sessionLocale = locale
        volatileText = ""
        errorMessage = nil
        isRunning = true
        engine = .local

        // Continue a session this app already transcribed part of, rather than
        // starting the call over. This is the relaunch path: leaving Bounce (or
        // being killed while backgrounded) tears down every in-memory cursor, but
        // `blePenState` adopts the recording in progress on the next connect and
        // lands back here with the same session id.
        let resumed = LiveSessionCheckpoint.shared.record(forSessionId: sessionId)
        carriedSegments = resumed?.segments ?? []
        timelineOffset = resumed.map { Double($0.transcribedPCMBytes) / Self.pcmBytesPerSecond } ?? 0
        segments = carriedSegments

        if let resumed {
            TranscribeLog.log("live: resuming session \(sessionId) — "
                + "\(resumed.segments.count) segment(s), "
                + String(format: "%.1fs", timelineOffset) + " already transcribed")
        } else {
            TranscribeLog.log("live: starting for session \(sessionId)")
        }

        // Fetch the prefix immediately — it must land before the SDK's own stream
        // read starts competing for the channel.
        assembler.begin(
            sessionId: sessionId,
            resumeFromPCMBytes: resumed?.transcribedPCMBytes ?? 0)

        Task { await beginSession(locale: locale) }
    }

    private func beginSession(locale: Locale) async {
        // Cloud engine first, if selected and it starts. A failure to start (no
        // key, socket refused) falls through to the on-device path so live
        // transcription still happens — matching the batch fallback.
        engine = DeliverySettings.shared.effectiveTranscriptionEngine
        if engine == .soniox {
            if startSoniox(locale: locale) {
                startSliceLoop()
                return
            }
            engine = .local
            TranscribeLog.log("live: soniox unavailable, using on-device")
        }

        do {
            let resolved = try await SpeechModel.resolveLocale(locale)

            // Progressive + time-indexed: volatile results as the person speaks,
            // each carrying a CMTimeRange so the finished transcript still
            // supports tap-to-seek.
            let transcriber = SpeechTranscriber(
                locale: resolved,
                preset: .timeIndexedProgressiveTranscription
            )
            try await SpeechModel.prepare(for: transcriber, locale: resolved)

            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: PCMPipe.sourceFormat
            ) else {
                throw SpeechModel.Failure.unavailable("No compatible audio format.")
            }

            // Still running? `stop()` may have been called during model prep,
            // which can take a while on first use of a language.
            guard isRunning else { return }

            let pipe = PCMPipe()
            pipeBox.set(pipe)

            let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
            self.analyzer = analyzer

            TranscribeLog.log("live: \(resolved.identifier(.bcp47)), "
                + "\(Int(PCMPipe.sourceFormat.sampleRate))Hz → "
                + "\(Int(analyzerFormat.sampleRate))Hz")

            collector = Task { [weak self] in
                await self?.collectResults(from: transcriber)
            }

            // Converts and forwards on a detached task, then drives analysis.
            // Same drive/finalise pairing as the batch path — `analyzeSequence`
            // returns the last sample time, which is what finalising needs.
            // `start(inputSequence:)` would race the analyzer's own worker.
            let inputs = Self.convertedInputs(from: pipe, to: analyzerFormat)
            driver = Task { try await analyzer.analyzeSequence(inputs) }

            startSliceLoop()

        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            TranscribeLog.log("live: ✗ \(message)")
            errorMessage = message
            isRunning = false
        }
    }

    /// Connect the live cloud engine and wire its updates into our observable
    /// state. Returns false if it can't start, so the caller falls back.
    private func startSoniox(locale: Locale) -> Bool {
        guard let apiKey = Soniox.Credentials.apiKey else { return false }
        let session = SonioxLiveSession(apiKey: apiKey, locale: locale)
        session.onUpdate = { [weak self] committed, volatile in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                let placed = self.placed(committed)
                // Guarded, not assigned: `SonioxLiveSession` re-derives every
                // segment from every token on each frame, so an idle-but-open
                // socket would otherwise invalidate the block list several
                // times a second with identical content.
                if self.segments != placed { self.segments = placed }
                if self.volatileText != volatile { self.volatileText = volatile }
            }
        }
        do {
            try session.start()
        } catch {
            TranscribeLog.log("live: soniox start failed: \(error)")
            return false
        }
        sonioxSession = session
        TranscribeLog.log("live: engine = soniox")
        return true
    }

    /// Finish the session and return what was captured, if anything.
    @discardableResult
    func stop() async -> Transcript? {
        guard isRunning else { return nil }
        isRunning = false

        sliceTimer?.cancel()
        sliceTimer = nil

        // One last slice: recording almost certainly ended mid-interval, and this
        // is the cheapest way not to lose the tail.
        await pumpSlice()

        // Cloud engine: drain the socket for final tokens, then build the preview.
        // Keyed on the engine rather than on a live session, because a socket that
        // died and couldn't be reconnected leaves `sonioxSession` nil with a real
        // cloud transcript still in `segments`.
        if engine == .soniox {
            let session = sonioxSession
            sonioxSession = nil
            TranscribeLog.log("live: stopping (soniox), "
                + "\(assembler.assembledBytes) encrypted bytes assembled")
            assembler.reset()
            let finalSegments = await session?.finish() ?? []
            // Guarded on the *server's* set being non-empty, not the merged one:
            // after a reconnect the carryover alone would silently drop
            // everything the final socket captured.
            if !finalSegments.isEmpty { segments = placed(finalSegments) }
            volatileText = ""
            engine = .local
            carriedSegments = []
            timelineOffset = 0
            finishCheckpoint()
            guard !segments.isEmpty else {
                TranscribeLog.log("live: no segments captured")
                return nil
            }
            TranscribeLog.log("live: ✓ \(segments.count) segment(s) (soniox)")
            return Transcript(
                segments: segments,
                localeIdentifier: DeliverySettings.shared.transcriptionLocale.identifier(.bcp47),
                createdAt: Date(),
                isPreview: true
            )
        }

        let pipe = pipeBox.current
        let seconds = pipe?.secondsIngested ?? 0
        TranscribeLog.log("live: stopping after "
            + String(format: "%.1fs", seconds) + " of audio, "
            + "\(assembler.assembledBytes) encrypted bytes assembled")

        pipe?.finish()

        // Release the capture side *before* awaiting the analyzer, and hand the
        // analyzer state to locals. Teardown below suspends for as long as the
        // analyzer takes, and meanwhile the app has already moved on to syncing —
        // an assembler still holding a session would ingest those bytes, and a
        // late resume would reset the assembler out from under the *next* live
        // session.
        assembler.reset()
        pipeBox.set(nil)
        let analyzer = self.analyzer
        let driver = self.driver
        let collector = self.collector
        self.analyzer = nil
        self.driver = nil
        self.collector = nil

        if seconds > 0 {
            // Driving returns once the input stream terminates; its value is the
            // last sample time, which is what finalising needs.
            var lastSampleTime: CMTime?
            if let driver {
                lastSampleTime = (try? await driver.value) ?? nil
            }
            if let analyzer {
                if let lastSampleTime {
                    try? await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            }
        } else {
            // Nothing was ever fed, so there is no sample time to finalise
            // through — and awaiting the driver in that state has been observed
            // not to return, which used to strand this whole method.
            driver?.cancel()
            await analyzer?.cancelAndFinishNow()
        }
        await collector?.value

        volatileText = ""
        carriedSegments = []
        timelineOffset = 0
        finishCheckpoint()

        guard !segments.isEmpty else {
            TranscribeLog.log("live: no segments captured")
            return nil
        }

        TranscribeLog.log("live: ✓ \(segments.count) segment(s)")
        return Transcript(
            segments: segments,
            localeIdentifier: DeliverySettings.shared.transcriptionLocale.identifier(.bcp47),
            createdAt: Date(),
            isPreview: true
        )
    }

    /// Raw PCM from `blePcmData`. Called on the SDK's queue, ~50 times a second.
    ///
    /// Retained because it is the *right* input if Plaud ever delivers decoded
    /// audio. It currently never fires for E2EE recordings, so the assembler's
    /// decode slices are the real source.
    nonisolated func ingest(_ pcmData: Data) {
        pipeBox.current?.ingest(pcmData)
    }

    /// Decrypt-and-decode a slice and feed the new PCM in, then wait a cadence
    /// that depends on which decode path is active.
    ///
    /// The streaming path decodes only the new Opus packets, so it is cheap and
    /// runs on a short interval — the transcript lands a few seconds behind the
    /// speaker. If it demotes to the whole-file fallback (which re-decodes
    /// everything), the assembler lengthens the interval so that quadratic cost
    /// doesn't dominate. See `LiveStreamAssembler.suggestedSliceInterval`.
    private func startSliceLoop() {
        sliceTimer?.cancel()
        sliceTimer = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.assembler.suggestedSliceInterval ?? .seconds(3)
                try? await Task.sleep(for: interval)
                guard let self, self.isRunning else { return }
                await self.pumpSlice()
            }
        }
    }

    /// Pull one decode slice and hand the fresh PCM to the active engine — the
    /// Soniox WebSocket, or the on-device analyzer's pipe.
    func pumpSlice() async {
        guard let pcm = await assembler.newPCM(), !pcm.isEmpty else { return }
        // The real level meter's only input: `blePcmData` never fires for
        // E2EE recordings, so this decoded slice — already produced for
        // transcription — is the sole source of an honest live level. See
        // `docs/plans/ios26-ui-refresh.md` Phase 4.3.
        RecordingManager.shared.updateLevel(fromPCM: pcm)
        if engine == .soniox {
            // This slice's own position in the recording, which is where a
            // reconnected socket's timestamps have to start from.
            reviveSonioxIfNeeded(startingAt: assembler.emittedSeconds
                - Double(pcm.count) / Self.pcmBytesPerSecond)
            sonioxSession?.ingest(pcm)
        } else {
            pipeBox.current?.ingest(pcm)
        }
        saveCheckpoint()
    }

    /// Write the session's progress to disk so a relaunch can pick it up.
    ///
    /// The cursor is **what the engine has committed**, not what it has been fed:
    /// the last few seconds are still volatile, and rewinding to the last
    /// committed phrase re-transcribes them rather than dropping the words. On the
    /// slice cadence, so a long call costs one small append and one small write
    /// every few seconds.
    private func saveCheckpoint() {
        guard let sessionId else { return }
        let committedThrough = max(segments.last?.end ?? 0, 0)
        // Whole packets only — the decoder resumes by packet count, so a cursor
        // between two packets would round the wrong way and clip a frame.
        let committedBytes = Int(committedThrough * Self.pcmBytesPerSecond)
            / LiveDecoder.pcmBytesPerPacket * LiveDecoder.pcmBytesPerPacket
        // Never claim more than was actually decoded — except at stop, where the
        // assembler has already been reset and its cursor reads zero.
        let emitted = assembler.emittedPCMBytes
        LiveSessionCheckpoint.shared.save(
            LiveSessionCheckpoint.Record(
                sessionId: sessionId,
                segments: segments,
                transcribedPCMBytes: emitted > 0 ? min(committedBytes, emitted) : committedBytes,
                localeIdentifier: sessionLocale.identifier(.bcp47),
                updatedAt: Date()))
    }

    /// The session is over: the buffered audio has no further use, but the text
    /// stays on disk until the recording syncs and `LiveTranscriptStore` applies
    /// it, so a relaunch in that window doesn't lose the preview either.
    private func finishCheckpoint() {
        guard let sessionId else { return }
        LiveSessionCheckpoint.shared.discardPartialAudio(sessionId: sessionId)
        if segments.isEmpty {
            LiveSessionCheckpoint.shared.clear(sessionId: sessionId)
        } else {
            saveCheckpoint()
        }
    }

    /// The app came back to the foreground, or the recorder reconnected. Both can
    /// leave the byte stream dead with no callback to say so, and the assembler
    /// only re-requests if it really has gone quiet.
    func resumeStreamingIfStalled() {
        guard isRunning else { return }
        assembler.resumeStreamIfStalled()
    }

    // MARK: - Pause / resume

    /// The recorder paused. Keep the session, engine and transcript exactly as
    /// they are, but stop slicing: no new bytes can arrive until the resume, so
    /// every tick would re-decode the same buffer for nothing (observed on device
    /// as `staging 97760 bytes` repeating every 3 s until record stop).
    func suspendStreaming() {
        guard isRunning else { return }
        sliceTimer?.cancel()
        sliceTimer = nil
        TranscribeLog.log("live: recorder paused — slicing suspended")
        // One last slice, for the same reason `stop()` takes one: the pause
        // almost certainly landed mid-interval.
        Task { await pumpSlice() }
    }

    /// The recorder resumed. Re-open the byte stream — a pause silently ends the
    /// BLE read and nothing else restarts it — and start slicing again. The
    /// cloud socket, if it timed out during the pause, is reconnected by
    /// `pumpSlice` once there is audio to send.
    func resumeStreaming() {
        guard isRunning else { return }
        TranscribeLog.log("live: recorder resumed")
        assembler.resumeStream()
        startSliceLoop()
    }

    /// Reconnect the cloud session when its socket has died mid-recording.
    ///
    /// Soniox closes a real-time connection that goes quiet, and a recorder pause
    /// produces exactly that — `server error 408 Request timeout` on device.
    /// A network drop does too. `SonioxLiveSession` can't be restarted, and until
    /// this existed nothing noticed: `ingest` became a silent no-op and the live
    /// transcript stayed frozen for the rest of the recording while every other
    /// log line looked healthy.
    ///
    /// Called only when there is fresh audio to send, which is what keeps it from
    /// hammering the endpoint through a long pause.
    ///
    /// Speaker labels are per socket, so the same person may be `"1"` before the
    /// reconnect and `"2"` after. Diarization is already anonymous and per
    /// recording (see `Recording.speakerNames`), and this is a preview the
    /// post-sync pass replaces.
    private func reviveSonioxIfNeeded(startingAt seconds: TimeInterval) {
        guard engine == .soniox else { return }
        if let sonioxSession, !sonioxSession.isFinished { return }

        // Everything committed so far becomes a fixed prefix: the new socket's
        // timestamps restart at zero, and segments that don't ascend in time
        // break `Transcript.blocks`, `currentBlockId` and — via duplicate
        // `"start-end"` ids — `ForEach` diffing.
        carriedSegments = segments
        timelineOffset = max(seconds, carriedSegments.last?.end ?? 0)
        sonioxSession = nil
        TranscribeLog.log("live: soniox socket closed — reconnecting at "
            + String(format: "%.1fs", timelineOffset))

        if !startSoniox(locale: sessionLocale) {
            // Deliberately not a mid-recording switch to the on-device engine:
            // its analyzer would start its own timeline at zero and there is no
            // honest way to interleave the two. What was captured is kept, and
            // the post-sync pass is still authoritative.
            TranscribeLog.log("live: soniox reconnect failed — preview ends here")
        }
    }

    /// Place a socket's segments on the recording's timeline. Identity unless the
    /// socket has been reconnected.
    private func placed(_ incoming: [TranscriptSegment]) -> [TranscriptSegment] {
        guard timelineOffset > 0 || !carriedSegments.isEmpty else { return incoming }
        return carriedSegments + incoming.map {
            TranscriptSegment(
                text: $0.text,
                start: $0.start + timelineOffset,
                end: $0.end + timelineOffset,
                speaker: $0.speaker)
        }
    }

    // MARK: - Plumbing

    /// Resample the pipe's buffers into the analyzer's format.
    private static func convertedInputs(
        from pipe: PCMPipe,
        to format: AVAudioFormat
    ) -> AsyncStream<AnalyzerInput> {
        AsyncStream { continuation in
            Task.detached {
                let converter = BufferConverter()
                for await buffer in pipe.stream {
                    guard let converted = try? converter.convert(buffer, to: format) else { continue }
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
                continuation.finish()
            }
        }
    }

    private func collectResults(from transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if result.isFinal {
                    volatileText = ""
                    guard !text.isEmpty else { continue }
                    // Shifted for the same reason the cloud path is: the analyzer
                    // times from the first sample *it* was fed, which on a resumed
                    // session is minutes into the recording.
                    segments.append(
                        TranscriptSegment(
                            text: text,
                            start: max(result.range.start.seconds, 0) + timelineOffset,
                            end: max(result.range.end.seconds, 0) + timelineOffset
                        )
                    )
                } else {
                    // Provisional — replaced wholesale on each refinement.
                    volatileText = text
                }
            }
        } catch {
            // The analyzer ends this sequence by cancelling it, so this is the
            // normal stop.
            TranscribeLog.log("live: results ended (\(type(of: error)))")
        }
    }
}
