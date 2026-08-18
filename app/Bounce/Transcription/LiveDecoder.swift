import Foundation
@preconcurrency import PlaudBleSDK
@preconcurrency import PlaudDeviceBasicSDK

/// Turns the reassembled encrypted stream into PCM, **off the main actor**.
///
/// ## Why an actor, and why off-main
///
/// `LiveStreamAssembler` is `@MainActor` because `ingest` is called from the
/// Bluetooth queue and hops to main. Decoding used to run there too — a ~1.2 MB
/// file write, an RSA-unwrap-plus-ChaCha20 decrypt, a ~1.2 MB file read and a
/// ~400 KB copy, all synchronous, all blocking the same actor the next
/// `bleData` packet needs. That is the leading suspect for the bursty arrival
/// measured on device (0.8 KB then 55 KB in consecutive slice windows). This
/// actor runs that work on its own executor so `ingest` stays prompt; the
/// assembler only touches it across `await`.
///
/// ## Layered strategies, demoting per slice
///
/// Two decode paths, tried strongest-first, the faster one falling back **per
/// slice** so a bug in it can never take live transcription below the verified
/// baseline:
///
/// - `.streaming` — decrypt in memory + `OggOpusParser.parse` + native Opus→PCM
///   of only the new packets, no file I/O. Linear, lowest latency. The Opus
///   decode config is the one thing that can only be confirmed on device, so a
///   failure here demotes.
/// - `.wholeFile` — the verified baseline: reconstruct the whole file, hand it to
///   `AudioFileDecryptor.decryptAudioToOgg` and `JXFileDecoder.oggToPcm`. Slow
///   (re-decodes everything each slice) but known-good on hardware.
///
/// A windowed SDK-decoder tier (re-mux new Ogg pages, run `oggToPcm` on the
/// window) was considered and deliberately left out: it is dominated by streaming
/// when the codec works, and its Ogg re-muxing is a fresh silent-corruption risk
/// (page-role indexing, packets spanning pages, lost inter-frame state at window
/// seams) for a case the verified whole-file path already covers.
actor LiveDecoder {

    /// The strongest path this build will attempt. Each `decode` still demotes
    /// below this per slice on failure.
    enum Strategy: Int, Comparable, Sendable {
        case wholeFile = 0
        case streaming = 1
        static func < (a: Strategy, b: Strategy) -> Bool { a.rawValue < b.rawValue }
    }

    /// Bytes before the audio payload — mirror of `LiveStreamAssembler`. This is
    /// the *fetch* prefix (512-byte header + 512-byte Ogg config), used only to
    /// gate "enough data to bother".
    static let prefixLength = 1024

    /// The `PlaudEncryptHeader` is exactly 512 bytes and the ChaCha20-encrypted
    /// region is `file[512…]` with block counter 0 (binary-verified). This is
    /// **not** `prefixLength`: decrypting from 1024 misaligns the keystream by 512
    /// bytes and every frame comes out as noise. That off-by-512 is why the first
    /// device run demoted with "plaintext is not OggS".
    static let headerSize = 512

    /// Result of one decode: the PCM not yet handed to the transcriber, plus the
    /// new running total so the assembler can advance its cursor.
    struct Output: Sendable {
        let freshPCM: Data
        let totalPCMBytes: Int
        let path: Strategy
    }

    private var ceiling: Strategy
    private let workDirectory: URL

    /// How much decoded PCM has been emitted across all slices, so each decode
    /// returns only what is new. **Shared** by both the streaming and whole-file
    /// paths and measured in the same units (16 kHz mono Int16 bytes), so a
    /// mid-session demotion from streaming to whole-file resumes at the same point
    /// rather than re-emitting the whole recording.
    private var pcmBytesEmitted = 0

    // Streaming (Tier 3) state, cached across slices.
    private var symmetricKey: Data?      // RSA-unwrapped once from the header
    private var nonce: Data?
    private var packetsDecoded = 0       // Opus packets already handed to the codec
    private var opusDecoder: OpusStreamDecoder?

    init(ceiling: Strategy = .streaming) {
        self.ceiling = ceiling
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    func reset() {
        pcmBytesEmitted = 0
        symmetricKey = nil
        nonce = nil
        packetsDecoded = 0
        opusDecoder = nil
        try? FileManager.default.removeItem(at: workDirectory)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    /// PCM one Opus packet decodes to: 20 ms at 16 kHz mono Int16. The recorder's
    /// frames are uniformly 20 ms (`OpusStreamDecoder.framesPerPacket` = 960 in
    /// Opus's 48 kHz clock domain), which is what makes a byte cursor convertible
    /// to a packet count.
    static let pcmBytesPerPacket = 640

    /// Most Opus packets one streaming slice will decode, so a catch-up backlog
    /// can't be decoded in a single blocking slice.
    ///
    /// A relaunch restores a checkpointed buffer whose assembled audio can sit
    /// minutes ahead of the committed cursor, and a mid-file resume the recorder
    /// restarts from 0 re-delivers a large prefix at once. Without a cap the first
    /// slice decodes that entire backlog — a multi-second Opus decode and a
    /// multi-MB PCM allocation handed downstream in one burst, observed on device
    /// as the app freezing when a long recording is resumed. 3000 packets is 60 s
    /// of audio (~1.9 MB PCM, ~120 ms Opus decode on device), so at the streaming
    /// cadence the transcript still catches up to real time within a few slices
    /// while no single slice stalls.
    static let maxPacketsPerSlice = 3000

    /// Rewind the cursor to audio already transcribed in an earlier run, so a
    /// resumed session decodes only what is new.
    ///
    /// Called when `LiveStreamAssembler` restores a checkpointed buffer after the
    /// app was relaunched mid-recording. Without it the first slice would emit the
    /// whole recording as "fresh" — a large allocation, a wasted decode, and the
    /// call transcribed a second time from the top.
    ///
    /// The Opus codec instance is necessarily new, so the first packets after a
    /// resume decode without the inter-frame state they were encoded against.
    /// Expect the same brief imperfection as an audio-edit cut, then self-healing.
    func restoreCursor(pcmBytes: Int) {
        pcmBytesEmitted = pcmBytes
        packetsDecoded = pcmBytes / Self.pcmBytesPerPacket
    }

    // MARK: - Decode

    /// Decrypt and decode everything captured so far, returning only the PCM that
    /// hasn't been emitted yet. `nil` when there is nothing new to hand over.
    ///
    /// `file` is a snapshot taken on the main actor; copying it there is a cheap
    /// COW reference, and the heavy work below happens here, off-main.
    ///
    /// Tries the strongest enabled path and **demotes per slice** on failure: a
    /// streaming failure lowers the ceiling for the rest of the session and falls
    /// through to the verified whole-file decode, so live transcription can never
    /// drop below the baseline.
    func decode(file: Data, privateKey: String) async -> Output? {
        if ceiling >= .streaming {
            switch decodeStreaming(file: file, privateKey: privateKey) {
            case .output(let out):
                return out
            case .nothingNew:
                // Whole-file would find nothing new either — same bytes.
                return nil
            case .failed(let why):
                TranscribeLog.log("decoder: streaming demoted to whole-file — \(why)")
                ceiling = .wholeFile
            }
        }
        return await decodeWholeFile(file: file, privateKey: privateKey)
    }

    // MARK: - Tier 3: streaming (native Opus, no file decode)

    private enum StreamResult {
        case output(Output)
        case nothingNew
        case failed(String)
    }

    /// Decrypt in memory, parse the whole Ogg from page 0, and natively decode
    /// only the Opus packets past the cursor.
    ///
    /// Whole-region re-decrypt every slice is deliberate: ChaCha20 is ~1000× faster
    /// than the Opus decode it replaces, so re-running it is negligible, and doing
    /// so keeps the plaintext byte-identical to the SDK's verified output with no
    /// keystream-offset arithmetic to get wrong. The linear win is that only *new*
    /// Opus packets are decoded; the codec instance is reused so inter-frame
    /// prediction carries across slices.
    ///
    /// **The parse, though, still walks the whole plaintext each slice, and it has
    /// to** (S-12): `OggOpusParser` assigns page roles by index within the buffer
    /// it is given, so a windowed parse starting mid-file loses OpusHead/OpusTags
    /// and the stream config — a silent-corruption class this design already pays a
    /// full re-decrypt to avoid. Rather than trade that for incremental-parse
    /// arithmetic (or an incremental decrypt whose cached plaintext would diverge
    /// from a late-backfilled hole), the residual O(n²) is bounded by stretching
    /// the slice cadence with buffer size — see
    /// `LiveStreamAssembler.suggestedSliceInterval`.
    private func decodeStreaming(file: Data, privateKey: String) -> StreamResult {
        var timing = PhaseTimer()

        // Unwrap the symmetric key once. `segment != 0` means the keystream
        // restarts per segment (Agent B confirmed from the binary); every observed
        // recording has been segment 0, but rather than replicate the chunked
        // path here, hand those off to the SDK-backed whole-file decode.
        if symmetricKey == nil {
            guard file.count >= Self.prefixLength,
                  let header = PlaudEncryptHeader(data: file.prefix(Self.prefixLength))
            else { return .failed("header not parseable yet") }
            guard header.segment == 0 else {
                return .failed("segment=\(header.segment), needs the segmented keystream")
            }
            do {
                let clear = try SecretUtil.decryptWithPrivateKey(
                    header.keyCipher, privateKeyPem: privateKey)
                guard clear.count >= 32 else { return .failed("unwrapped key too short") }
                symmetricKey = clear.prefix(32)
                nonce = header.nonce
            } catch {
                return .failed("RSA unwrap: \(error)")
            }
        }
        guard let key = symmetricKey, let nonce else { return .failed("no key") }
        timing.mark("key")

        // Decrypt the whole audio region: byte-for-byte the SDK's plaintext.
        let plaintext: Data
        do {
            // Encrypted region is file[512…] (headerSize), NOT file[1024…].
            plaintext = try ChaCha20.decrypt(
                data: Data(file.suffix(from: Self.headerSize)),
                key: key, nonce: nonce, counter: 0)
        } catch {
            return .failed("ChaCha20: \(error)")
        }
        guard plaintext.prefix(4).elementsEqual([0x4F, 0x67, 0x67, 0x53]) else {
            return .failed("plaintext is not OggS")
        }
        timing.mark("decrypt")

        // Parse from page 0 so OpusHead/OpusTags get their correct roles. Stateless
        // and tail-safe: a truncated trailing page is dropped cleanly.
        let parser = OggOpusParser()
        let packets = parser.parse(plaintext)
        timing.mark("parse")
        guard packets.count > packetsDecoded else { return .nothingNew }

        // Decode at most `maxPacketsPerSlice` so a catch-up backlog (relaunch
        // restore, or a resume the recorder restarts from 0) can't be decoded in
        // one blocking slice. The cursor advances by exactly what is emitted, so
        // the next slice continues seamlessly — the reused `opusDecoder` carries
        // inter-frame state across the seam — and the transcript catches up over a
        // few ticks instead of one multi-second stall. Only the Opus decode is
        // bounded here; the parse still walks the whole plaintext (a separate
        // O(n²) concern the slice cadence handles).
        let sliceEnd = min(packets.count, packetsDecoded + Self.maxPacketsPerSlice)
        let newPackets = Array(packets[packetsDecoded..<sliceEnd])
        if opusDecoder == nil {
            opusDecoder = OpusStreamDecoder(channels: max(1, parser.parsedChannels))
        }
        let pcm: Data
        do {
            pcm = try opusDecoder!.decode(packets: newPackets)
        } catch {
            return .failed("Opus decode: \(error)")
        }
        // Non-empty packets that decode to nothing means the codec is unavailable
        // on this device — a hard failure, so demote rather than stall silently.
        guard !pcm.isEmpty else {
            return .failed("0 PCM from \(newPackets.count) packet(s)")
        }
        timing.mark("opus")

        packetsDecoded = sliceEnd
        pcmBytesEmitted += pcm.count
        let seconds = Double(pcmBytesEmitted) / 32000
        let backlog = packets.count - packetsDecoded
        TranscribeLog.log("decoder: streaming +\(newPackets.count) packet(s) → "
            + "\(pcm.count) new PCM (\(String(format: "%.1f", seconds))s total"
            + (backlog > 0 ? ", \(backlog) packet(s) of backlog remaining" : "")
            + ") \(timing)")
        return .output(Output(freshPCM: pcm, totalPCMBytes: pcmBytesEmitted, path: .streaming))
    }

    // MARK: - Tier 0: whole-file (verified baseline)

    private func decodeWholeFile(file: Data, privateKey: String) async -> Output? {
        var timing = PhaseTimer()

        let encryptedPath = workDirectory.appendingPathComponent("partial.dat")
        do {
            try file.write(to: encryptedPath, options: .atomic)
        } catch {
            TranscribeLog.log("decoder: ✗ couldn't stage partial file: \(error)")
            return nil
        }
        timing.mark("stage")

        // One call: header parse, RSA unwrap of the ChaCha20 key, and stream
        // decrypt. Possible only because the file is contiguous from offset 0.
        let oggPath: String
        do {
            guard let decrypted = try AudioFileDecryptor.decryptAudioToOgg(
                inputPath: encryptedPath.path,
                privateKeyPem: privateKey
            ) else {
                TranscribeLog.log("decoder: ✗ decryptAudioToOgg returned nil")
                return nil
            }
            oggPath = decrypted
        } catch {
            TranscribeLog.log("decoder: ✗ decrypt failed: \(error)")
            return nil
        }
        timing.mark("decrypt")

        let pcmPath = workDirectory.appendingPathComponent("partial.pcm").path
        let decoded = await Self.oggToPCM(oggPath: oggPath, pcmPath: pcmPath)
        guard decoded else { return nil }
        timing.mark("oggToPcm")

        guard let pcm = FileManager.default.contents(atPath: pcmPath) else { return nil }
        timing.mark("read")

        guard pcm.count > pcmBytesEmitted else {
            TranscribeLog.log("decoder: whole-file — nothing new "
                + "(\(pcm.count) PCM, \(pcmBytesEmitted) already out) \(timing)")
            return nil
        }

        let fresh = Data(pcm.suffix(from: pcmBytesEmitted))
        let total = pcm.count
        pcmBytesEmitted = total
        timing.mark("slice")

        TranscribeLog.log("decoder: whole-file decoded \(total) PCM, "
            + "emitting \(fresh.count) new "
            + "(\(String(format: "%.1f", Double(total) / 32000))s) \(timing)")
        return Output(freshPCM: fresh, totalPCMBytes: total, path: .wholeFile)
    }

    // MARK: - SDK bridge

    /// `oggToPcm` is callback-based and file-oriented; bridge it to async.
    ///
    /// It lives on `JXFileDecoder`, not `BleAgent` — a separate singleton.
    ///
    /// ## The handler reports progress *and* completion on the same closure
    ///
    /// Read out of `JXFileDecoder.convertOggToPcm` in the shipped binary, because
    /// nothing in the `.swiftinterface` says so:
    ///
    /// | call | first arg | second arg |
    /// |---|---|---|
    /// | progress tick | `false` | percent, `0…100` |
    /// | finished | `true` | `100` |
    /// | failed | `false` | `-1` |
    ///
    /// So `false` on its own is **not** failure — it is a progress tick unless the
    /// value is negative. Resuming on the *first* call resumed on a progress tick
    /// carrying `false`; every decode looked failed and the analyzer was fed
    /// nothing while the log looked healthy. The resume stays latched because the
    /// handler keeps firing after the terminal call — resuming a checked
    /// continuation twice traps.
    static func oggToPCM(oggPath: String, pcmPath: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let latch = ResumeLatch()
            JXFileDecoder.shared.oggToPcm(
                avcPath: oggPath,
                pcmPath: pcmPath,
                clearUnfinished: true,
                channels: 1,
                ns_agc: false
            ) { finished, value in
                guard finished || value < 0 else { return }
                guard latch.claim() else { return }
                if !finished {
                    TranscribeLog.log("decoder: ✗ oggToPcm failed (value \(value))")
                }
                continuation.resume(returning: finished)
            }
        }
    }
}

/// Records elapsed time between named phases, for one-line latency logging.
///
/// This is the Tier-1 measurement: it is what finally distinguishes "the main
/// actor was blocked by decode" from "the recorder streams in bursts". If the
/// per-phase totals here are small but arrival is still bursty, the burst is the
/// device's, not ours.
struct PhaseTimer: CustomStringConvertible {
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var last: ContinuousClock.Instant
    private var phases: [(String, Duration)] = []

    init() {
        start = clock.now
        last = start
    }

    mutating func mark(_ name: String) {
        let now = clock.now
        phases.append((name, last.duration(to: now)))
        last = now
    }

    var description: String {
        let parts = phases.map { "\($0.0)=\(ms($0.1))" }.joined(separator: " ")
        return "[\(parts) total=\(ms(start.duration(to: last)))]"
    }

    private func ms(_ d: Duration) -> String {
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.0fms", seconds * 1000)
    }
}

/// Lets exactly one caller through, from any thread.
final class ResumeLatch: @unchecked Sendable {

    private let lock = NSLock()
    private var isClaimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
