import AVFoundation
import Foundation

/// Carries live PCM from the Bluetooth callback queue into an `AsyncStream`.
///
/// The SDK delivers `blePcmData` on its own queue at roughly 50 callbacks a
/// second, while the analyzer consumes from Swift concurrency. This is the seam
/// between them: `ingest` is safe to call from anywhere, `stream` is consumed by
/// the transcriber.
///
/// `@unchecked Sendable` with an explicit lock, because the continuation is
/// touched from both sides and `AsyncStream.Continuation` is not itself
/// isolated.
///
/// `PipeBox` below exists for the same reason: the pipe has to be reachable from
/// the Bluetooth queue without touching the main actor. Reading it through
/// `MainActor.assumeIsolated` **traps and crashes** when the caller is not
/// actually on the main actor, which `blePcmData` never is.
final class PCMPipe: @unchecked Sendable {

    /// The recorder's stream: 16 kHz mono signed 16-bit, arriving as 640-byte
    /// chunks (320 frames, ~20 ms).
    static let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    let stream: AsyncStream<AVAudioPCMBuffer>

    private let lock = NSLock()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var isFinished = false
    private(set) var framesIngested: Int64 = 0

    init() {
        var captured: AsyncStream<AVAudioPCMBuffer>.Continuation!
        // Buffered rather than unbounded: if the analyzer stalls, dropping the
        // oldest audio is better than growing without limit for the length of a
        // long meeting. Live transcription is a preview; the post-sync pass is
        // the authoritative transcript.
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { captured = $0 }
        continuation = captured
    }

    /// Convert one raw PCM chunk and hand it on. Safe from any queue.
    func ingest(_ data: Data) {
        guard let buffer = Self.makeBuffer(from: data) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        framesIngested += Int64(buffer.frameLength)
        continuation?.yield(buffer)
    }

    /// Terminate the stream. Idempotent.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        continuation?.finish()
        continuation = nil
    }

    var secondsIngested: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(framesIngested) / Self.sourceFormat.sampleRate
    }

    // MARK: - Buffer construction

    /// Wrap raw interleaved Int16 bytes in an `AVAudioPCMBuffer`.
    private static func makeBuffer(from data: Data) -> AVAudioPCMBuffer? {
        // Two bytes per frame: mono, Int16. An odd byte count would mean a torn
        // chunk, so the remainder is discarded rather than misaligning the rest.
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData?[0]
        else { return nil }

        buffer.frameLength = frameCount
        data.withUnsafeBytes { raw in
            guard let source = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            channel.update(from: source, count: Int(frameCount))
        }
        return buffer
    }
}

/// Lock-protected holder for the active pipe.
///
/// Lets the Bluetooth callback reach the current pipe without an actor hop —
/// which matters at 50 packets a second — and without `assumeIsolated`, which
/// would crash because that callback is not on the main actor.
final class PipeBox: @unchecked Sendable {

    private let lock = NSLock()
    private var pipe: PCMPipe?

    var current: PCMPipe? {
        lock.lock()
        defer { lock.unlock() }
        return pipe
    }

    func set(_ pipe: PCMPipe?) {
        lock.lock()
        defer { lock.unlock() }
        self.pipe = pipe
    }
}
