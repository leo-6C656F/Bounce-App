import AVFoundation
import Foundation

/// Where the speech is in a recording, and where it isn't.
///
/// Backs the audio editor's "Remove silence" and the segment strip: a full
/// decode pass computing short-window RMS, then a merge pass that turns
/// per-window loudness into a handful of coarse speech segments.
///
/// Deliberately **not** built from `WaveformCache`'s envelope. That's a fixed
/// 512 buckets regardless of length, so on a one-hour meeting each bucket spans
/// seven seconds — it cannot locate a two-second pause, which is the whole job
/// here. This pays for its own decode instead.
struct SilenceDetector {

    /// A stretch of the recording that contains speech.
    struct Segment: Hashable, Identifiable {
        var start: TimeInterval
        var end: TimeInterval

        var id: String { "\(start)-\(end)" }
        var duration: TimeInterval { max(0, end - start) }
    }

    struct Options {
        /// Analysis window. 20 ms matches the recorder's Opus frame size and is
        /// short enough that a boundary lands mid-syllable at worst.
        var window: TimeInterval = 0.02

        /// A quiet stretch shorter than this is the rhythm of speech — the beat
        /// between sentences — not a gap worth cutting. Below roughly 0.5 s the
        /// output stops being "silence removed" and starts sounding clipped.
        var minimumSilence: TimeInterval = 0.7

        /// Speech runs shorter than this are almost always a cough, a chair
        /// scrape or a door; keeping them turns the segment strip into a row of
        /// unusable slivers. Measured on the *unpadded* run.
        var minimumSegment: TimeInterval = 0.35

        /// Kept either side of every segment. Onsets and trailing consonants are
        /// quiet, so a cut placed exactly at the threshold crossing audibly
        /// clips words even though the RMS said silence.
        var padding: TimeInterval = 0.12

        /// How far below the recording's loudest window a window must sit to
        /// count as silence.
        var thresholdBelowPeak: Double = 32

        /// How far above the estimated noise floor the threshold must sit. Sets
        /// the floor of the threshold in a noisy room, where
        /// `thresholdBelowPeak` alone would put it under the air conditioning.
        var thresholdAboveNoiseFloor: Double = 6

        /// Hard bounds on the resulting threshold, dBFS. Without these a
        /// recording that is *all* loud or *all* quiet produces a threshold that
        /// classifies everything one way.
        var thresholdRange: ClosedRange<Double> = -60...(-22)

        static let `default` = Options()
    }

    var options = Options.default

    // MARK: - Analysis

    /// Speech segments in `url`, in order, non-overlapping.
    ///
    /// Returns nil when the file can't be decoded. Returns a single
    /// full-duration segment when no silence qualifies — "nothing to remove" is
    /// a valid answer and callers shouldn't have to special-case an empty array
    /// to mean "keep everything".
    ///
    /// `progress` is called on an arbitrary queue with 0…1.
    static func segments(
        of url: URL,
        options: Options = .default,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> [Segment]? {
        guard let levels = levels(of: url, window: options.window, progress: progress),
              !levels.windows.isEmpty else { return nil }
        return segments(from: levels, options: options)
    }

    /// Per-window loudness, in dBFS.
    struct Levels {
        /// One entry per analysis window, dBFS (`-.infinity` for pure digital
        /// silence).
        var windows: [Double]
        /// Seconds per window as actually used — derived from the file's sample
        /// rate, so it is not exactly `options.window`.
        var windowDuration: TimeInterval
        var duration: TimeInterval
    }

    static func levels(
        of url: URL,
        window: TimeInterval,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> Levels? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = file.length
        let sampleRate = format.sampleRate
        guard total > 0, sampleRate > 0, format.channelCount > 0 else { return nil }

        let windowFrames = max(1, Int((window * sampleRate).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return nil }

        var levels: [Double] = []
        levels.reserveCapacity(Int(total) / windowFrames + 1)

        // Carried across `read(into:)` calls: a window rarely aligns with a
        // buffer boundary, and restarting the accumulator per buffer would make
        // one short window every 65k frames — enough to read as a spurious
        // silence in a quiet passage.
        var sumOfSquares: Double = 0
        var framesInWindow = 0
        var framesRead: AVAudioFramePosition = 0
        var lastReported: Double = -1

        // `AVAudioFile.read(into:)` **throws at EOF** rather than returning zero
        // frames, so bound the loop by `framePosition`. Getting this wrong
        // surfaces as a bare `_GenericObjCError.nilError` that reads exactly
        // like file corruption — same trap as `WaveformCache.buildEnvelope` and
        // the Speech pipeline.
        while file.framePosition < total {
            do { try file.read(into: buffer) } catch { break }
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }
            let samples = channels[0]

            for offset in 0..<count {
                let sample = Double(samples[offset])
                sumOfSquares += sample * sample
                framesInWindow += 1
                if framesInWindow == windowFrames {
                    levels.append(decibels(sumOfSquares / Double(windowFrames)))
                    sumOfSquares = 0
                    framesInWindow = 0
                }
            }

            framesRead += AVAudioFramePosition(count)
            if let progress {
                let fraction = Double(framesRead) / Double(total)
                // Throttled: this loop runs hundreds of times on a long file and
                // every report crosses onto the main actor to update the UI.
                if fraction - lastReported >= 0.02 {
                    lastReported = fraction
                    progress(min(1, fraction))
                }
            }
        }

        // The tail window is short; include it anyway, normalised by what it
        // actually holds. Dropping it loses up to 20 ms, which matters when the
        // recording ends mid-word.
        if framesInWindow > 0 {
            levels.append(decibels(sumOfSquares / Double(framesInWindow)))
        }

        guard !levels.isEmpty else { return nil }
        progress?(1)

        return Levels(
            windows: levels,
            windowDuration: Double(windowFrames) / sampleRate,
            duration: Double(total) / sampleRate)
    }

    // MARK: - Segmentation

    static func segments(from levels: Levels, options: Options = .default) -> [Segment] {
        let threshold = self.threshold(for: levels.windows, options: options)
        let step = levels.windowDuration
        let duration = levels.duration

        // 1. Runs of windows above the threshold.
        var runs: [Segment] = []
        var runStart: Int?
        for (index, level) in levels.windows.enumerated() {
            if level > threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append(Segment(start: Double(start) * step, end: Double(index) * step))
                runStart = nil
            }
        }
        if let start = runStart {
            runs.append(Segment(start: Double(start) * step, end: duration))
        }

        guard !runs.isEmpty else {
            // Everything read as silence — a recording of a quiet room, or a
            // threshold that misjudged it. Either way, refusing to cut anything
            // is the safe answer; cutting the whole file is not.
            return [Segment(start: 0, end: duration)]
        }

        // 2. Bridge gaps too short to be worth cutting. Done *before* the
        //    minimum-length filter so a run of short utterances separated by
        //    breaths becomes one real segment instead of being filtered away
        //    utterance by utterance.
        var bridged: [Segment] = [runs[0]]
        for run in runs.dropFirst() {
            if run.start - bridged[bridged.count - 1].end < options.minimumSilence {
                bridged[bridged.count - 1].end = run.end
            } else {
                bridged.append(run)
            }
        }

        // 3. Drop the slivers, measured before padding inflates them.
        var kept = bridged.filter { $0.duration >= options.minimumSegment }
        if kept.isEmpty { return [Segment(start: 0, end: duration)] }

        // 4. Pad, clamp, then re-merge anything the padding pushed into overlap.
        kept = kept.map {
            Segment(
                start: max(0, $0.start - options.padding),
                end: min(duration, $0.end + options.padding))
        }
        var merged: [Segment] = [kept[0]]
        for segment in kept.dropFirst() {
            if segment.start <= merged[merged.count - 1].end {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, segment.end)
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// Map speech `segments` — whose times come from `AVAudioFile` PCM decoding —
    /// onto a target timeline of `frameDuration` seconds, then clamp to it.
    ///
    /// The audio editor's `kept` ranges live in the MP3 *frame-index* timeline
    /// (`MP3Frames.Index.duration`), while these segments live in the *decoded*
    /// timeline (`levels.duration`). For MP3 the two disagree by decoder
    /// delay/padding — up to ~70 ms at 16 kHz — so intersecting them directly
    /// biases every silence cut by a systematic offset, trimming into word
    /// onsets. Scaling by the duration ratio brings the segments into the frame
    /// timeline before they meet `kept`; the clamp is the floor of the same fix
    /// (`0...frameDuration`) for the degenerate case where the ratio is unknown.
    static func speechRanges(
        _ segments: [Segment],
        decodedDuration: TimeInterval,
        frameDuration: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        let scale = decodedDuration > 0 ? frameDuration / decodedDuration : 1
        return segments.map { segment in
            let start = min(max(0, segment.start * scale), frameDuration)
            let end = min(max(start, segment.end * scale), frameDuration)
            return start...end
        }
    }

    /// The silence threshold, in dBFS.
    ///
    /// Two constraints, whichever is higher: a fixed distance below the loudest
    /// window (works in a quiet room), and a fixed distance above the noise
    /// floor (works in a noisy one, where the first constraint would put the
    /// threshold underneath the air conditioning and find no silence at all).
    private static func threshold(for windows: [Double], options: Options) -> Double {
        let finite = windows.filter { $0.isFinite }
        guard let peak = finite.max() else { return options.thresholdRange.lowerBound }

        // 10th percentile as the noise floor rather than the minimum: a single
        // window of digital silence — a dropped BLE packet, a zero-filled hole —
        // would otherwise define the floor as -infinity.
        let sorted = finite.sorted()
        let noiseFloor = sorted[min(sorted.count - 1, sorted.count / 10)]

        let candidate = max(
            peak - options.thresholdBelowPeak,
            noiseFloor + options.thresholdAboveNoiseFloor)
        return min(max(candidate, options.thresholdRange.lowerBound), options.thresholdRange.upperBound)
    }

    // MARK: - Helpers

    private static func decibels(_ meanSquare: Double) -> Double {
        guard meanSquare > 0 else { return -.infinity }
        return 10 * log10(meanSquare)
    }
}

extension Array where Element == SilenceDetector.Segment {

    /// The gaps between these segments, plus any lead-in and tail-out.
    func gaps(in duration: TimeInterval) -> [SilenceDetector.Segment] {
        var result: [SilenceDetector.Segment] = []
        var cursor: TimeInterval = 0
        for segment in self {
            if segment.start > cursor {
                result.append(.init(start: cursor, end: segment.start))
            }
            // `Swift.max`, not `max` — inside an `Array` extension the bare name
            // resolves to `Array.max()`, the instance method.
            cursor = Swift.max(cursor, segment.end)
        }
        if cursor < duration {
            result.append(.init(start: cursor, end: duration))
        }
        return result
    }

    var totalDuration: TimeInterval { reduce(0) { $0 + $1.duration } }
}
