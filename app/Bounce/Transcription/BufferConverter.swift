import AVFoundation
import Foundation

/// Converts audio buffers into the format `SpeechAnalyzer` asks for.
///
/// This is required, not an optimisation: `SpeechAnalyzer` performs **no** audio
/// conversion of its own. Handing it a decoded MP3 at the file's native format
/// fails with an opaque `Foundation._GenericObjCError error 0`, so everything
/// must be resampled to the format `bestAvailableAudioFormat` reports first.
///
/// One converter instance is reused across a file's chunks, because
/// `AVAudioConverter` carries resampler state between calls — rebuilding it per
/// chunk would click at every boundary.
final class BufferConverter {

    enum Failure: LocalizedError {
        case cannotCreateConverter(from: AVAudioFormat, to: AVAudioFormat)
        case cannotAllocateBuffer
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateConverter(let from, let to):
                return "Can't convert audio from \(from.sampleRate)Hz to \(to.sampleRate)Hz."
            case .cannotAllocateBuffer:
                return "Ran out of memory preparing the audio."
            case .conversionFailed(let detail):
                return "Couldn't convert the audio for transcription. \(detail)"
            }
        }
    }

    private var converter: AVAudioConverter?

    /// Convert one buffer, returning it untouched when the formats already match.
    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            guard let created = AVAudioConverter(from: buffer.format, to: format) else {
                throw Failure.cannotCreateConverter(from: buffer.format, to: format)
            }
            // .none — priming would insert leading silence, shifting every
            // timestamp in the transcript against the source audio.
            created.primeMethod = .none
            converter = created
        }
        guard let converter else { throw Failure.cannotAllocateBuffer }

        // Room for resampling upward, plus slack for the converter's own latency.
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw Failure.cannotAllocateBuffer
        }

        var error: NSError?
        var didSupplyInput = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if didSupplyInput {
                // One buffer per call; tell the converter to drain and stop.
                inputStatus.pointee = .noDataNow
                return nil
            }
            didSupplyInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw Failure.conversionFailed(error?.localizedDescription ?? "unknown error")
        }
        return output
    }
}
