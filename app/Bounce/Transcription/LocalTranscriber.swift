import AVFoundation
import Foundation
import Speech

/// Transcribes audio files entirely on this device, using Apple's Speech
/// framework (`SpeechAnalyzer` + `SpeechTranscriber`, iOS 26+).
///
/// No audio and no text leaves the phone. This is why Bounce needs no
/// transcription API key, and why `PlaudAPIService` from the reference template
/// app is absent — the cloud round-trip it existed for is gone.
///
/// Language models are downloaded on demand through `AssetInventory` and are
/// shared across apps, so the first run for a given language may pause to
/// install assets.
///
/// Deliberately **not an actor**, despite being stateless enough to be one. As an
/// actor, the `Task` that collects results inherited its isolation and reentered
/// it while `transcribe` was still holding it, which interacted badly with
/// `SpeechAnalyzer`'s own concurrency. There is no shared mutable state here to
/// protect, so isolation buys nothing and cost real breakage.
struct LocalTranscriber: Sendable {

    static let shared = LocalTranscriber()

    enum Failure: LocalizedError {
        case unreadableAudio(String)
        case unsupportedAudioFormat(String)
        case localeUnsupported(String)
        case assetsUnavailable(String)
        case analysisFailed(String)
        case noSpeechDetected

        var errorDescription: String? {
            switch self {
            case .unreadableAudio(let detail):
                return "Couldn't read the audio file. \(detail)"
            case .unsupportedAudioFormat(let format):
                return "This recording's audio format isn't supported for transcription (\(format))."
            case .localeUnsupported(let identifier):
                return "On-device transcription isn't available for \(identifier)."
            case .assetsUnavailable(let detail):
                return "Couldn't install the speech model. \(detail)"
            case .analysisFailed(let detail):
                return "Transcription failed. \(detail)"
            case .noSpeechDetected:
                return "No speech was found in this recording."
            }
        }

    }

    /// Coarse progress, for the UI.
    enum Phase: Equatable {
        case installingModel
        case transcribing
    }

    private init() {}

    // MARK: - Availability

    /// Whether we can transcribe the given language on this device at all.
    /// Checked before offering the option, since model availability is not
    /// purely a question of OS version.
    static func supportedLocale(for locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Languages already installed, for the settings screen.
    static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    // MARK: - Transcription

    /// Transcribe a file. `onPhase` is called as work moves between stages.
    func transcribe(
        audioAt url: URL,
        locale: Locale = .current,
        onPhase: @Sendable (Phase) -> Void = { _ in }
    ) async throws -> Transcript {

        TranscribeLog.log("start \(url.lastPathComponent) requested locale=\(locale.identifier)")

        let resolvedLocale = try await SpeechModel.resolveLocale(locale)
        TranscribeLog.log("locale resolved → \(resolvedLocale.identifier(.bcp47))")

        // Time-indexed so every phrase carries a CMTimeRange, which is what
        // makes tap-a-line-to-seek possible in the player.
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )

        onPhase(.installingModel)
        try await SpeechModel.prepare(for: transcriber, locale: resolvedLocale)

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadableAudio(error.localizedDescription)
        }

        onPhase(.transcribing)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: audioFile.processingFormat
        ) else {
            TranscribeLog.log("✗ no analyzer format available for \(audioFile.processingFormat)")
            throw Failure.unsupportedAudioFormat(audioFile.processingFormat.description)
        }

        TranscribeLog.log("file \(Int(audioFile.processingFormat.sampleRate))Hz "
            + "\(audioFile.processingFormat.channelCount)ch \(audioFile.length) frames "
            + "→ analyzer \(Int(analyzerFormat.sampleRate))Hz \(analyzerFormat.channelCount)ch")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)

        // Three roles, three tasks, following Apple's documented pattern:
        //
        //   analyzeSequence(_:)  drives analysis, returns the last sample time
        //   finalizeAndFinish(through:)  finalises up to that time
        //
        // Crucially **not** `start(inputSequence:)` +
        // `finalizeAndFinishThroughEndOfInput()`. `start` spins up the analyzer's
        // own autonomous input-loop worker, and finalising from our task then
        // races it:
        //
        //     Failed precondition: Attempt to modify worker after it was locked
        //     SpeechAnalyzer: Input loop ending with error: _GenericObjCError.nilError
        //
        // Those two lines were the real fault behind several rounds of
        // mis-attributed "format" and "cancellation" failures.
        //
        // Detached on purpose: neither task should inherit cancellation from
        // whatever called us, which has previously torn down analysis mid-flight.
        let collector = Task<[TranscriptSegment], Never>.detached {
            var collected: [TranscriptSegment] = []
            do {
                for try await result in transcriber.results {
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    collected.append(
                        TranscriptSegment(
                            text: text,
                            start: max(result.range.start.seconds, 0),
                            end: max(result.range.end.seconds, 0)
                        )
                    )
                }
            } catch {
                // The analyzer ends this sequence by cancelling it once analysis
                // finishes, so a CancellationError here is a normal stop — not a
                // failure, and definitely not a reason to discard what we have.
                TranscribeLog.log("results stream ended after \(collected.count) segment(s): "
                    + "\(type(of: error)) \(error)")
            }
            return collected
        }

        // Feeder: decode, convert, yield, then terminate the stream — which is
        // what makes `analyzeSequence` below return.
        //
        // A read failure at the tail is *salvaged* rather than thrown. MP3 frame
        // counts are estimates, so `length` can overshoot the real end; if audio
        // has already been decoded, stopping early yields a transcript of what we
        // got instead of discarding the lot over the last few milliseconds.
        let feeder = Task<Int, Error>.detached {
            defer { continuation.finish() }

            let converter = BufferConverter()
            // ~0.5s at 16kHz. Small enough to stay cheap on memory for a
            // long recording, large enough not to thrash the converter.
            let framesPerChunk: AVAudioFrameCount = 8192
            var chunksFed = 0

            // Bounded by `length`: `read(into:)` **throws** at end-of-file
            // rather than returning zero frames, so an unbounded loop reads one
            // chunk too many and fails with `_GenericObjCError.nilError` — an
            // error that names nothing and reads like corruption.
            while audioFile.framePosition < audioFile.length {
                guard let input = AVAudioPCMBuffer(
                    pcmFormat: audioFile.processingFormat,
                    frameCapacity: framesPerChunk
                ) else {
                    throw Failure.analysisFailed("couldn't allocate an audio buffer")
                }

                do {
                    try audioFile.read(into: input)
                } catch {
                    guard chunksFed == 0 else {
                        TranscribeLog.log("read stopped at frame \(audioFile.framePosition) of "
                            + "\(audioFile.length) after \(chunksFed) chunk(s) — keeping what "
                            + "decoded (\(error))")
                        break
                    }
                    throw Failure.unreadableAudio("\(error)")
                }
                guard input.frameLength > 0 else { break }

                continuation.yield(AnalyzerInput(buffer: try converter.convert(input, to: analyzerFormat)))
                chunksFed += 1
            }

            return chunksFed
        }

        // Drives analysis, and returns once the input stream terminates. Its
        // return value is the last sample time — exactly what finalising needs.
        let lastSampleTime: CMTime?
        do {
            lastSampleTime = try await analyzer.analyzeSequence(stream)
        } catch {
            feeder.cancel()
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            _ = await collector.value
            // Type name included because Speech framework errors like `nilError`
            // have a description naming neither domain nor cause.
            TranscribeLog.log("✗ analyzeSequence: \(type(of: error)) \(error)")
            throw Failure.analysisFailed("\(error)")
        }

        // Surfaces a decode failure that would otherwise look like "no speech".
        do {
            let chunksFed = try await feeder.value
            TranscribeLog.log("fed \(chunksFed) chunk(s), last sample "
                + "\(lastSampleTime.map { String(format: "%.2fs", $0.seconds) } ?? "unknown")")
        } catch let failure as Failure {
            await analyzer.cancelAndFinishNow()
            _ = await collector.value
            TranscribeLog.log("✗ \(failure.errorDescription ?? "failed")")
            throw failure
        } catch let failure as BufferConverter.Failure {
            await analyzer.cancelAndFinishNow()
            _ = await collector.value
            TranscribeLog.log("✗ conversion: \(failure.errorDescription ?? "failed")")
            throw Failure.analysisFailed(failure.errorDescription ?? "audio conversion failed")
        }

        if let lastSampleTime {
            do {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } catch {
                // Non-fatal: the collector may already hold everything useful.
                TranscribeLog.log("⚠︎ finalize through \(lastSampleTime.seconds)s failed: "
                    + "\(type(of: error)) \(error)")
            }
        } else {
            TranscribeLog.log("⚠︎ no last sample time — nothing was analysed")
            await analyzer.cancelAndFinishNow()
        }

        let segments = await collector.value

        guard !segments.isEmpty else {
            TranscribeLog.log("✗ analysis completed but produced no final segments")
            throw Failure.noSpeechDetected
        }

        TranscribeLog.log("✓ \(segments.count) segment(s), "
            + "\(segments.map(\.text).joined(separator: " ").count) chars")

        return Transcript(
            segments: segments,
            localeIdentifier: resolvedLocale.identifier(.bcp47),
            createdAt: Date()
        )
    }

}
