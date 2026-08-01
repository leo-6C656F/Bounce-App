import AVFoundation
import Foundation

/// Decodes raw Opus packets to 16 kHz mono Int16 PCM, in memory, packet by
/// packet — no file I/O, no SDK file decoder.
///
/// This is the back half of the streaming decode path (Tier 3). It takes the raw
/// Opus packets that `OggOpusParser.parse` extracts from the decrypted Ogg stream
/// and turns them into exactly the PCM shape `PCMPipe` already expects (16 kHz,
/// mono, interleaved Int16), so nothing downstream changes.
///
/// ## Why `AVAudioConverter` and not a file decode
///
/// `AVAudioConverter` wraps AudioToolbox's Opus software codec directly:
/// synchronous, in-process, no disk, decode-and-resample in one object. That
/// removes the whole-file re-decode and the file staging that make the baseline
/// path quadratic. The config below was verified end-to-end against Apple's codec
/// (input at 48 kHz — Opus's canonical clock domain regardless of the OpusHead
/// input-rate hint; RFC 7845 §5.1).
///
/// ## The traps, all of which produce silent zero-frame output
///
/// - The Opus decoder is **stateful across packets** (inter-frame prediction), so
///   one converter is reused for the whole stream. A fresh converter per packet
///   decodes but garbles.
/// - The input block must return `.noDataNow` once the packet is consumed, never
///   `.endOfStream` — the latter ends the converter permanently.
/// - VBR (`mBytesPerPacket = 0`) means `packetDescriptions` and `packetCount`
///   must be set on the compressed buffer, or nothing is consumed.
///
/// If the converter can't be built, or decodes produce nothing, the caller demotes
/// to a file-based tier — this class never silently swallows a failure.
final class OpusStreamDecoder {

    enum Failure: Error, CustomStringConvertible {
        case converterUnavailable
        case bufferAllocationFailed
        var description: String {
            switch self {
            case .converterUnavailable: return "AVAudioConverter(from: Opus) returned nil"
            case .bufferAllocationFailed: return "couldn't allocate a decode buffer"
            }
        }
    }

    /// Opus always decodes in the 48 kHz clock domain.
    private static let opusClockRate = 48_000.0
    /// 20 ms per packet at 48 kHz. The recorder's stream is 20 ms frames (batch
    /// decode: ~2070 frames over 41.4 s). If a future firmware varies packet
    /// duration this constant is wrong and decode counts drift — the demotion
    /// path is the safety net.
    private static let framesPerPacket: UInt32 = 960
    /// Opus caps a frame at 1275 bytes; a packet with up to 3 frames stays well
    /// under this. Generous headroom for the compressed buffer.
    private static let maxPacketSize = 1500

    /// 16 kHz mono Int16 — byte-identical to what `oggToPcm` produced and what
    /// `PCMPipe` consumes.
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private let channels: UInt32
    private let inputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    /// - Parameter channels: from `OggOpusParser.parsedChannels` (1 for this
    ///   recorder). Must match the stream or decode fails.
    init(channels: Int) {
        self.channels = UInt32(max(1, channels))
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.opusClockRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,               // 0 = VBR; makes packetDescriptions live
            mFramesPerPacket: Self.framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: self.channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        inputFormat = AVAudioFormat(streamDescription: &asbd)!
    }

    /// Build the converter lazily so a failure surfaces on first real use and the
    /// caller can demote for the rest of the session.
    private func makeConverterIfNeeded() throws -> AVAudioConverter {
        if let converter { return converter }
        guard let created = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            throw Failure.converterUnavailable
        }
        // No priming: leading silence would shift every transcript timestamp.
        created.primeMethod = .none
        converter = created
        return created
    }

    /// Decode a batch of raw Opus packets to concatenated 16 kHz Int16 PCM bytes.
    ///
    /// Feeds one packet per `convert` call so the codec sees exact packet
    /// boundaries. Returns the PCM for *these* packets only — the caller decodes
    /// each packet exactly once, which is what makes streaming linear rather than
    /// quadratic.
    func decode(packets: [Data]) throws -> Data {
        guard !packets.isEmpty else { return Data() }
        let converter = try makeConverterIfNeeded()

        var pcm = Data()
        for packet in packets where !packet.isEmpty {
            guard let decoded = try decodeOne(packet: packet, converter: converter) else { continue }
            pcm.append(decoded)
        }
        return pcm
    }

    private func decodeOne(packet: Data, converter: AVAudioConverter) throws -> Data? {
        let input = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: max(packet.count, Self.maxPacketSize)
        )
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,       // trust mFramesPerPacket
            mDataByteSize: UInt32(packet.count)
        )
        packet.copyBytes(
            to: input.data.assumingMemoryBound(to: UInt8.self),
            count: packet.count
        )

        // Capacity: one packet is 20 ms → 320 frames at 16 kHz. 4096 is generous
        // slack for the converter's own latency.
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: 4096) else {
            throw Failure.bufferAllocationFailed
        }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow    // never .endOfStream mid-stream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }

        if status == .error {
            if let error { throw error }
            return nil
        }
        guard output.frameLength > 0, let channel = output.int16ChannelData?[0] else {
            return nil
        }
        return Data(bytes: channel, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
