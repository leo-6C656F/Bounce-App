import Foundation

/// A frame-level index of an MPEG Layer III file, and a writer that cuts one
/// down to a subset of its frames **without re-encoding**.
///
/// ## Why frame copying rather than an export session
///
/// iOS ships an MP3 *decoder* and no MP3 *encoder*, so anything that goes
/// through `AVAssetExportSession` or `AVAudioFile(forWriting:)` comes out as AAC,
/// ALAC or LPCM — never MP3. That would break a documented invariant: every
/// recording in Bounce is MP3 because `AVAudioPlayer` must play it *and*
/// `AVAudioFile` must read it for transcription, `Web/WebAPI` serves it as
/// `audio/mpeg`, and `SyncManager` refuses any other format. See
/// `docs/architecture.md`.
///
/// Copying whole frames sidesteps the encoder entirely. Layer III frames are
/// self-delimiting — each one's header states its own length — so a cut is a
/// byte-range copy. The output is bit-identical audio, and stays MP3.
///
/// ## What it costs
///
/// Cuts land on frame boundaries, so they are quantised to one frame: 1152
/// samples on MPEG-1 (26 ms at 44.1 kHz), 576 on MPEG-2/2.5 (36 ms at 16 kHz,
/// which is what the recorder produces). Imperceptible for trimming a meeting.
///
/// The other cost is the **bit reservoir**: a Layer III frame may store part of
/// its main data in space left over by *earlier* frames, referenced by a backward
/// pointer (`main_data_begin`) of up to 255 bytes on MPEG-2/2.5 and 511 on
/// MPEG-1. So a byte-exact frame boundary is not a decode boundary — the first
/// retained frame after a cut can point at data that is no longer in the file.
///
/// Every mainstream decoder, Apple's included, compares that pointer against
/// what it has actually accumulated and silences the granule when it comes up
/// short: no crash, no desync, no error surfaced. Overlapping IMDCT windows smear
/// a little into the following frame, so budget up to two frames — about 72 ms at
/// 16 kHz — of imperfect audio at each cut, after which the stream self-heals.
/// This is the same thing that happens on every seek in every MP3 player, and it
/// is why "fast MP3 cut" tools universally accept it rather than re-encode.
enum MP3Frames {

    // MARK: - Stream description

    enum Version {
        case mpeg1, mpeg2, mpeg25

        /// Layer III encodes 1152 samples per frame on MPEG-1 and 576 on the
        /// lower-rate versions. Getting this wrong scales every timestamp.
        var samplesPerFrame: Int { self == .mpeg1 ? 1152 : 576 }

        /// The numerator of the frame-length formula: `samplesPerFrame / 8`.
        var lengthCoefficient: Int { self == .mpeg1 ? 144 : 72 }
    }

    /// One Layer III frame's position in the file and on the sample timeline.
    struct Frame {
        let byteOffset: Int
        let byteLength: Int
        /// Samples before this frame, i.e. its start on the decoded timeline.
        let sampleOffset: Int
        let sampleCount: Int
        let bitrate: Int
    }

    /// A parsed file: every audio frame, in order, plus the stream's format.
    struct Index {
        var frames: [Frame]
        var version: Version
        var sampleRate: Int
        var channels: Int
        /// True when the frames don't all share one bitrate. Only VBR needs a
        /// Xing header written on the way out.
        var isVariableBitRate: Bool
        /// Byte range of the source's own Xing/Info/VBRI frame, if it had one.
        /// Excluded from `frames` — it carries no audio and decodes as a frame of
        /// silence, so copying it would prepend silence and skew every timestamp.
        var metadataFrame: Range<Int>?

        var sampleCount: Int {
            guard let last = frames.last else { return 0 }
            return last.sampleOffset + last.sampleCount
        }

        var duration: TimeInterval {
            sampleRate > 0 ? Double(sampleCount) / Double(sampleRate) : 0
        }

        /// The frame containing `time`, or the nearest boundary. Binary search —
        /// an hour of 16 kHz mono is ~100,000 frames and the editor resolves
        /// several ranges per save.
        func frameIndex(atOrBefore time: TimeInterval) -> Int {
            let target = Int((time * Double(sampleRate)).rounded())
            var low = 0
            var high = frames.count - 1
            var result = 0
            while low <= high {
                let mid = (low + high) / 2
                if frames[mid].sampleOffset <= target {
                    result = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return result
        }

        /// The first frame that starts at or after `time`, clamped to the end.
        func frameIndex(atOrAfter time: TimeInterval) -> Int {
            let candidate = frameIndex(atOrBefore: time)
            guard candidate < frames.count else { return frames.count }
            if frames[candidate].sampleOffset >= Int((time * Double(sampleRate)).rounded()) {
                return candidate
            }
            return candidate + 1
        }
    }

    enum Failure: LocalizedError {
        case unreadable
        case notLayerIII
        case empty
        case nothingKept
        case writeFailed(String)
        /// Sources handed to `merge` that don't describe the same stream.
        case formatMismatch

        var errorDescription: String? {
            switch self {
            case .unreadable: "The audio file couldn't be read."
            case .notLayerIII: "This recording isn't an MP3, so it can't be edited losslessly."
            case .empty: "No audio frames were found in this recording."
            case .nothingKept: "The edit would leave no audio."
            case .writeFailed(let detail): "Couldn't write the edited audio. \(detail)"
            case .formatMismatch:
                "These recordings were made at different audio settings, so they can't be joined "
                    + "without re-encoding them."
            }
        }
    }

    // MARK: - Header decoding

    private static let mpeg1Bitrates = [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
    ]
    private static let mpeg2Bitrates = [
        0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
    ]
    private static let sampleRates: [Version: [Int]] = [
        .mpeg1: [44100, 48000, 32000, 0],
        .mpeg2: [22050, 24000, 16000, 0],
        .mpeg25: [11025, 12000, 8000, 0],
    ]

    private struct Header {
        var version: Version
        var bitrate: Int
        var sampleRate: Int
        var channels: Int
        var frameLength: Int
        var hasCRC: Bool

        /// Bytes between the header and the start of main data: the optional
        /// 16-bit CRC plus the side info block, whose size depends on version and
        /// channel count. Needed to locate a Xing tag.
        var sideInfoOffset: Int {
            let sideInfo: Int
            switch version {
            case .mpeg1: sideInfo = channels == 1 ? 17 : 32
            case .mpeg2, .mpeg25: sideInfo = channels == 1 ? 9 : 17
            }
            return 4 + (hasCRC ? 2 : 0) + sideInfo
        }
    }

    /// Decode a 4-byte frame header, or nil if these bytes aren't a valid
    /// Layer III header. Validation is what makes resynchronisation safe: an
    /// 11-bit sync word occurs by chance roughly every 2 KB of arbitrary data, so
    /// accepting one without checking the fields would index garbage as frames.
    private static func header(at offset: Int, in data: Data) -> Header? {
        guard offset + 4 <= data.count else { return nil }
        let b0 = data[offset], b1 = data[offset + 1]
        let b2 = data[offset + 2], b3 = data[offset + 3]

        // 11-bit sync.
        guard b0 == 0xFF, b1 & 0xE0 == 0xE0 else { return nil }

        let version: Version
        switch (b1 & 0x18) >> 3 {
        case 0b11: version = .mpeg1
        case 0b10: version = .mpeg2
        case 0b00: version = .mpeg25
        default: return nil        // 0b01 is reserved
        }

        // Layer III only — 0b01 in the layer field. Layers I and II have
        // different frame maths and Bounce never sees them.
        guard (b1 & 0x06) >> 1 == 0b01 else { return nil }

        let hasCRC = b1 & 0x01 == 0

        let bitrateIndex = Int((b2 & 0xF0) >> 4)
        let table = version == .mpeg1 ? mpeg1Bitrates : mpeg2Bitrates
        let bitrate = table[bitrateIndex] * 1000
        // Index 0 is "free format" and 15 is reserved; both give 0 here and
        // neither has a computable frame length.
        guard bitrate > 0 else { return nil }

        let rateIndex = Int((b2 & 0x0C) >> 2)
        guard let rates = sampleRates[version] else { return nil }
        let sampleRate = rates[rateIndex]
        guard sampleRate > 0 else { return nil }

        let padding = Int((b2 & 0x02) >> 1)
        // Channel mode 0b11 is single channel; the other three are all two.
        let channels = (b3 & 0xC0) >> 6 == 0b11 ? 1 : 2

        // Truncating divide *then* add the padding slot — the ISO formulation. One
        // slot is a byte for Layer III. The length includes the header and the
        // CRC, so the next frame's sync is at `offset + frameLength`.
        let frameLength = version.lengthCoefficient * bitrate / sampleRate + padding
        // The shortest legal Layer III frame is 72 bytes (8 kbps at 8 kHz). The
        // guard exists to make a degenerate header unable to produce a
        // zero-advance loop, so anything under a plausible floor is rejected.
        guard frameLength >= 24 else { return nil }

        return Header(
            version: version,
            bitrate: bitrate,
            sampleRate: sampleRate,
            channels: channels,
            frameLength: frameLength,
            hasCRC: hasCRC)
    }

    // MARK: - Tags

    /// Where the audio starts: past any ID3v2 tags at the head of the file.
    ///
    /// Loops, because tags can be stacked — a file that has been through two
    /// taggers carries two, and stopping after the first leaves the second to be
    /// byte-resynced through, which risks a false sync inside cover art.
    private static func audioStart(in data: Data) -> Int {
        var offset = 0
        while offset + 10 <= data.count,
              data[offset] == 0x49, data[offset + 1] == 0x44, data[offset + 2] == 0x33 {  // "ID3"
            // Syncsafe: four bytes, low 7 bits each, so no byte can look like a
            // sync word.
            let size = (Int(data[offset + 6] & 0x7F) << 21)
                | (Int(data[offset + 7] & 0x7F) << 14)
                | (Int(data[offset + 8] & 0x7F) << 7)
                | Int(data[offset + 9] & 0x7F)
            let hasFooter = data[offset + 5] & 0x10 != 0   // v2.4 only
            let total = 10 + size + (hasFooter ? 10 : 0)
            guard total > 10, offset + total <= data.count else { break }
            offset += total
        }
        return offset
    }

    /// Where the audio ends: before any trailing metadata.
    ///
    /// Three things can sit at the tail, in this order — a Lyrics3v2 block, a
    /// 227-byte "TAG+" extended tag, then the 128-byte ID3v1 tag. Each is checked
    /// relative to what the previous one excluded. Missing one doesn't corrupt the
    /// output (a frame walk validates every header), but it does invite a false
    /// sync inside text, which would append a junk frame.
    private static func audioEnd(in data: Data) -> Int {
        var end = data.count

        func matches(_ tag: [UInt8], at position: Int) -> Bool {
            guard position >= 0, position + tag.count <= data.count else { return false }
            return (0..<tag.count).allSatisfy { data[position + $0] == tag[$0] }
        }

        if matches([0x54, 0x41, 0x47], at: end - 128) { end -= 128 }              // "TAG"
        if matches([0x54, 0x41, 0x47, 0x2B], at: end - 227) { end -= 227 }        // "TAG+"
        // Lyrics3v2 ends with "LYRICS200" preceded by a 6-digit ASCII size that
        // covers everything from "LYRICSBEGIN" onwards.
        if matches([0x4C, 0x59, 0x52, 0x49, 0x43, 0x53, 0x32, 0x30, 0x30], at: end - 9) {
            let digits = (end - 15)..<(end - 9)
            if digits.lowerBound >= 0 {
                let text = String(decoding: data[digits], as: UTF8.self)
                if let size = Int(text), size > 0, end - 9 - size >= 0 { end -= 9 + size }
            }
        }
        return end
    }

    /// True if this frame is a Xing/Info or VBRI metadata frame rather than
    /// audio. The encoder emits one to carry the duration and a seek table; it
    /// holds no samples and decodes as a frame of silence, so including it would
    /// prepend silence and shift every timestamp by one frame.
    ///
    /// The Xing tag is *scanned for* across the window it can occupy rather than
    /// read at the computed offset. The computed position depends on whether the
    /// CRC precedes or follows the tag, and encoders disagree — LAME's own output
    /// has been observed both ways — so trusting the arithmetic means silently
    /// treating a metadata frame as audio on some files.
    private static func isMetadataFrame(at offset: Int, header: Header, in data: Data) -> Bool {
        func matches(_ tag: [UInt8], at position: Int) -> Bool {
            guard position + tag.count <= data.count else { return false }
            return (0..<tag.count).allSatisfy { data[position + $0] == tag[$0] }
        }
        // "Xing" (VBR) or "Info" (CBR — same layout, and what LAME writes for the
        // constant-bitrate encode the recorder produces).
        let windowEnd = min(data.count - 4, offset + header.sideInfoOffset + 4)
        var position = offset + 4
        while position <= windowEnd {
            if matches([0x58, 0x69, 0x6E, 0x67], at: position) { return true }   // "Xing"
            if matches([0x49, 0x6E, 0x66, 0x6F], at: position) { return true }   // "Info"
            position += 1
        }
        // Fraunhofer VBRI sits at a fixed 32 bytes past the header, regardless of
        // channel mode. Mutually exclusive with Xing.
        return matches([0x56, 0x42, 0x52, 0x49], at: offset + 36)               // "VBRI"
    }

    // MARK: - Parsing

    /// Index every Layer III frame in `url`.
    ///
    /// Memory-mapped, so a 30 MB recording costs no resident memory to walk. The
    /// resulting index is roughly 40 bytes per frame — about 4 MB for an hour of
    /// 16 kHz mono, which is why it is built on demand and not cached.
    static func index(of url: URL) throws -> Index {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw Failure.unreadable
        }

        var offset = audioStart(in: data)
        let end = audioEnd(in: data)

        var frames: [Frame] = []
        var sampleCursor = 0
        var streamVersion: Version?
        var streamSampleRate = 0
        var streamChannels = 0
        var bitrates = Set<Int>()
        var metadataFrame: Range<Int>?
        var resyncCount = 0

        while offset + 4 <= end {
            // An 11-bit sync word turns up by chance roughly every 2 KB of
            // arbitrary data, so a valid-looking header is not enough. Once the
            // stream's identity is known, every later frame must agree with it —
            // version, sample rate and channel count are fixed for the whole file,
            // and requiring them is what stops a false sync inside album art or a
            // text tag from being indexed as a frame.
            var candidate = header(at: offset, in: data)
            if let found = candidate, let known = streamVersion {
                if found.version != known
                    || found.sampleRate != streamSampleRate
                    || found.channels != streamChannels {
                    candidate = nil
                }
            }

            guard let header = candidate, offset + header.frameLength <= end else {
                // Not a frame here. Advance one byte and look again — this recovers
                // from a stray tag, a partial write, or the junk some encoders
                // leave between the ID3 tag and the first frame.
                offset += 1
                resyncCount += 1
                // Give up scanning a blob that isn't yielding frames, rather than
                // spend minutes walking 30 MB one byte at a time. If frames were
                // already found, keep them and stop — a truncated tail is worth
                // salvaging; if none were, this isn't a file we can edit.
                if resyncCount > 1 << 20 {
                    if frames.isEmpty { throw Failure.notLayerIII }
                    break
                }
                continue
            }

            if streamVersion == nil {
                streamVersion = header.version
                streamSampleRate = header.sampleRate
                streamChannels = header.channels
            }

            if frames.isEmpty, metadataFrame == nil,
               isMetadataFrame(at: offset, header: header, in: data) {
                metadataFrame = offset..<(offset + header.frameLength)
                offset += header.frameLength
                continue
            }

            frames.append(Frame(
                byteOffset: offset,
                byteLength: header.frameLength,
                sampleOffset: sampleCursor,
                sampleCount: header.version.samplesPerFrame,
                bitrate: header.bitrate))
            bitrates.insert(header.bitrate)
            sampleCursor += header.version.samplesPerFrame
            offset += header.frameLength
        }

        guard let version = streamVersion, !frames.isEmpty else {
            throw streamVersion == nil ? Failure.notLayerIII : Failure.empty
        }

        return Index(
            frames: frames,
            version: version,
            sampleRate: streamSampleRate,
            channels: streamChannels,
            isVariableBitRate: bitrates.count > 1,
            metadataFrame: metadataFrame)
    }

    // MARK: - Writing

    struct Output {
        var url: URL
        /// The duration actually written, which is the sum of the kept frames and
        /// so differs from the requested ranges by up to one frame per cut. The
        /// caller should store *this*, not the requested total.
        var duration: TimeInterval
        var byteCount: Int
        /// The kept ranges snapped to frame boundaries, in the **source's**
        /// timeline. Used to re-map transcript timings onto the output.
        var keptRanges: [ClosedRange<TimeInterval>]
    }

    /// Write the frames covering `ranges` to `destination`, in order.
    ///
    /// `ranges` need not be sorted or disjoint; they're normalised first.
    @discardableResult
    static func write(
        source: URL,
        keeping ranges: [ClosedRange<TimeInterval>],
        to destination: URL
    ) throws -> Output {
        let index = try index(of: source)
        return try write(source: source, index: index, keeping: ranges, to: destination)
    }

    /// As above, but reusing an index the caller already built — which the editor
    /// has, since it parsed the file to lay out its timeline.
    @discardableResult
    static func write(
        source: URL,
        index: Index,
        keeping ranges: [ClosedRange<TimeInterval>],
        to destination: URL
    ) throws -> Output {
        let frameRanges = try selectFrames(in: index, covering: ranges)

        // Stream the kept frames straight to disk rather than accumulating the
        // whole output in a resident `Data` (S-14). A Xing header is only worth
        // the risk on a variable-bitrate stream: on the CBR the recorder produces,
        // `AVAudioPlayer` derives an exact duration from file size and bitrate, and
        // a hand-built metadata frame could only add a frame of silence at the head
        // for nothing.
        let totals = try streamWrite(
            [FramePlan(url: source, index: index, frameRanges: frameRanges)],
            xingTemplate: index.isVariableBitRate ? index : nil,
            to: destination)

        return Output(
            url: destination,
            duration: duration(of: frameRanges, in: index),
            byteCount: totals.byteCount,
            keptRanges: keptRanges(of: frameRanges, in: index))
    }

    // MARK: - Merging

    /// One recording's contribution to a merge.
    struct MergeSource {
        var url: URL
        var index: Index
        /// The parts of this source to take, in its own timeline. Empty means the
        /// whole file — which is what merging recordings actually does; the
        /// parameter exists so a merge and an edit can't drift into two different
        /// notions of "kept".
        var ranges: [ClosedRange<TimeInterval>] = []
    }

    /// Where one source ended up in the merged file.
    struct Placement {
        /// Seconds into the **output** where this source begins.
        var start: TimeInterval
        /// How much of the output it accounts for, measured in frames written.
        var duration: TimeInterval
        /// What was taken, in the **source's** timeline, snapped to frames.
        var keptRanges: [ClosedRange<TimeInterval>]
    }

    struct MergeOutput {
        var url: URL
        var duration: TimeInterval
        var byteCount: Int
        /// One entry per source, in the order they were written. The caller needs
        /// these to shift transcripts, highlights and chapters onto the merged
        /// timeline — and must use *these* numbers rather than the sources' stored
        /// durations, which are a frame or two out.
        var placements: [Placement]
    }

    /// Concatenate several MP3s into one, still without re-encoding.
    ///
    /// This is the same frame copy `write` does, run across several files: Layer
    /// III frames are self-delimiting and carry no file-level state, so an MP3 is
    /// a bare sequence of frames and appending one file's frames to another's
    /// produces a valid stream. Nothing is decoded and nothing is re-encoded, so
    /// the audio is bit-identical to its sources and the output is still MP3 —
    /// which the whole app depends on (see the type's own note).
    ///
    /// **The sources must describe the same stream.** Version, sample rate and
    /// channel count are compared and a mismatch throws: a decoder handles a
    /// bitrate change mid-stream (that is all VBR is) but not a sample-rate or
    /// mono/stereo change, which would play the rest of the file at the wrong
    /// speed or drop a channel. Every file from one Plaud is 16 kHz mono MPEG-2,
    /// so in practice this only fires on a hand-imported file.
    ///
    /// Expect the same ~72 ms of imperfect audio at each join as at any cut —
    /// the first frame of each source can reference bit-reservoir bytes that
    /// preceded it. Decoders silence that granule and recover.
    @discardableResult
    static func merge(sources: [MergeSource], to destination: URL) throws -> MergeOutput {
        guard let first = sources.first else { throw Failure.nothingKept }
        for source in sources.dropFirst() {
            guard source.index.version == first.index.version,
                  source.index.sampleRate == first.index.sampleRate,
                  source.index.channels == first.index.channels
            else { throw Failure.formatMismatch }
        }

        var placements: [Placement] = []
        var elapsed: TimeInterval = 0
        var plan: [FramePlan] = []

        for source in sources {
            let ranges = source.ranges.isEmpty
                ? [0...max(source.index.duration, 0)]
                : source.ranges
            let frameRanges = try selectFrames(in: source.index, covering: ranges)
            let span = duration(of: frameRanges, in: source.index)
            placements.append(Placement(
                start: elapsed,
                duration: span,
                keptRanges: keptRanges(of: frameRanges, in: source.index)))
            elapsed += span
            plan.append(FramePlan(url: source.url, index: source.index, frameRanges: frameRanges))
        }

        // Bitrate is the one header field allowed to vary between sources — that
        // is a VBR stream, which is exactly what a Xing header is for. Compared on
        // each index's first frame rather than by scanning every frame: the
        // per-file answer is already in `isVariableBitRate`, and the cross-file
        // one only needs one representative frame each.
        let bitrates = Set(sources.compactMap { $0.index.frames.first?.bitrate })
        let isVBR = bitrates.count > 1 || sources.contains { $0.index.isVariableBitRate }

        // Stream to disk rather than concatenating the whole output resident
        // (S-14): a 30-part join of hour-long files would otherwise build a
        // ~400 MB buffer and be killed by jetsam mid-merge. The Xing frame, when
        // one is written, is reserved up front and patched with the true totals
        // once the frames are on disk.
        let totals = try streamWrite(
            plan, xingTemplate: isVBR ? first.index : nil, to: destination)

        return MergeOutput(
            url: destination,
            duration: elapsed,
            byteCount: totals.byteCount,
            placements: placements)
    }

    // MARK: - Frame selection

    /// Snap `ranges` to whole frames and coalesce them.
    ///
    /// Coalescing happens *after* snapping because two ranges a few milliseconds
    /// apart can land on the same frame, and copying that frame twice would
    /// duplicate audio.
    private static func selectFrames(
        in index: Index,
        covering ranges: [ClosedRange<TimeInterval>]
    ) throws -> [Range<Int>] {
        var frameRanges: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let first = index.frameIndex(atOrBefore: range.lowerBound)
            let last = index.frameIndex(atOrBefore: range.upperBound)
            guard first < index.frames.count else { continue }
            // `last + 1`: the frame containing the upper bound is kept, so the
            // cut never lands mid-word by rounding a range shorter than asked.
            let candidate = first..<min(index.frames.count, last + 1)
            guard !candidate.isEmpty else { continue }
            if let previous = frameRanges.last, candidate.lowerBound <= previous.upperBound {
                frameRanges[frameRanges.count - 1] =
                    previous.lowerBound..<max(previous.upperBound, candidate.upperBound)
            } else {
                frameRanges.append(candidate)
            }
        }
        guard !frameRanges.isEmpty else { throw Failure.nothingKept }
        return frameRanges
    }

    /// One source's contribution to a streamed write: which frames of which
    /// mapped file to copy, in order.
    private struct FramePlan {
        let url: URL
        let index: Index
        let frameRanges: [Range<Int>]
    }

    /// Bytes buffered before a flush to the file handle. Keeps peak memory to this
    /// plus the mapped source, rather than the whole output — the point of S-14 —
    /// while still writing in large chunks instead of a syscall per frame.
    private static let flushThreshold = 4 * 1024 * 1024

    /// Stream the selected frames of each source to `destination`, optionally
    /// prefixed by a Xing frame patched from the final totals. Returns the frame
    /// and byte counts written.
    ///
    /// This is the memory-bounded replacement for accumulating the whole output in
    /// a resident `Data` (S-14). Sources are memory-mapped and copied a bounded
    /// buffer at a time; the output never exists in RAM in full, so a large or
    /// many-part merge can't jetsam mid-write.
    ///
    /// The Xing frame has to sit at the head, but its `frameCount`/`byteCount`
    /// fields aren't known until every frame is written. Its *length* is fixed by
    /// the stream, though (`xingFrame` picks the bitrate from the version table,
    /// not from the totals), so a placeholder is reserved first and overwritten in
    /// place once the totals are in.
    ///
    /// Writes to a sibling temp file and moves it into place, so a crash mid-write
    /// can't leave a half-written file where the destination is — the atomicity the
    /// old single `Data.write(.atomic)` gave. The explicit protection class matches
    /// that write's (`RecordingStore.save`'s reasoning): this is the recording's
    /// audio, and `.completeUntilFirstUserAuthentication` is the strongest class
    /// that won't fail a background-BLE-sync write before the first unlock. It's
    /// best-effort so the macOS `tools/audio-edit-tests` harness, where file
    /// protection is a no-op, still runs.
    @discardableResult
    private static func streamWrite(
        _ plan: [FramePlan],
        xingTemplate: Index?,
        to destination: URL
    ) throws -> (frameCount: Int, byteCount: Int) {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).mp3.partial")

        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw Failure.writeFailed("couldn't create the output file")
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: tempURL.path)

        func cleanUp() { try? FileManager.default.removeItem(at: tempURL) }

        do {
            let handle = try FileHandle(forWritingTo: tempURL)

            // Reserve the Xing frame up front; its length is fixed for the stream,
            // so the real one (below) overwrites it in place once totals are known.
            let placeholder = xingTemplate.flatMap { xingFrame(index: $0, frameCount: 0, byteCount: 0) }
            if let placeholder { try handle.write(contentsOf: placeholder) }

            var writtenFrames = 0
            var payloadBytes = 0
            var buffer = Data()
            buffer.reserveCapacity(flushThreshold)

            for entry in plan {
                guard let data = try? Data(contentsOf: entry.url, options: .mappedIfSafe) else {
                    throw Failure.unreadable
                }
                for range in entry.frameRanges {
                    for frame in entry.index.frames[range] {
                        buffer.append(data[frame.byteOffset..<(frame.byteOffset + frame.byteLength)])
                        writtenFrames += 1
                        payloadBytes += frame.byteLength
                        if buffer.count >= flushThreshold {
                            try handle.write(contentsOf: buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }

            // Patch the reserved Xing frame with the real totals (same length).
            if placeholder != nil,
               let xing = xingTemplate.flatMap({
                   xingFrame(index: $0, frameCount: writtenFrames, byteCount: payloadBytes)
               }) {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: xing)
            }
            try handle.close()

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            return (writtenFrames, payloadBytes + (placeholder?.count ?? 0))
        } catch let failure as Failure {
            cleanUp()
            throw failure
        } catch {
            cleanUp()
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// The playing time of the selected frames.
    private static func duration(of frameRanges: [Range<Int>], in index: Index) -> TimeInterval {
        guard index.sampleRate > 0 else { return 0 }
        let samples = frameRanges.reduce(0) { total, range in
            total + index.frames[range].reduce(0) { $0 + $1.sampleCount }
        }
        return Double(samples) / Double(index.sampleRate)
    }

    /// The selected frames expressed as ranges of the source's own timeline.
    private static func keptRanges(
        of frameRanges: [Range<Int>],
        in index: Index
    ) -> [ClosedRange<TimeInterval>] {
        let rate = Double(index.sampleRate)
        guard rate > 0 else { return [] }
        return frameRanges.map { range in
            let first = index.frames[range.lowerBound]
            let last = index.frames[range.upperBound - 1]
            return Double(first.sampleOffset) / rate
                ... Double(last.sampleOffset + last.sampleCount) / rate
        }
    }

    /// A synthetic Xing frame describing the output, so a VBR result reports an
    /// honest duration. Contains no audio: flags advertise only the frame and
    /// byte counts, no seek table and no quality field.
    private static func xingFrame(index: Index, frameCount: Int, byteCount: Int) -> Data? {
        // Reuse the source's own first-frame header so version, sample rate and
        // channel mode match the stream exactly, and only override the bitrate to
        // one that leaves room for the tag.
        guard let template = index.frames.first else { return nil }
        let table = index.version == .mpeg1 ? mpeg1Bitrates : mpeg2Bitrates
        let sideInfo: Int
        switch index.version {
        case .mpeg1: sideInfo = index.channels == 1 ? 17 : 32
        case .mpeg2, .mpeg25: sideInfo = index.channels == 1 ? 9 : 17
        }
        let needed = 4 + sideInfo + 4 + 4 + 4 + 4   // header, side info, "Xing", flags, frames, bytes

        // Smallest bitrate whose frame is long enough to hold the tag.
        var chosenIndex = 0
        var chosenLength = 0
        for candidate in 1..<15 {
            let bitrate = table[candidate] * 1000
            guard bitrate > 0 else { continue }
            let length = index.version.lengthCoefficient * bitrate / index.sampleRate
            if length >= needed {
                chosenIndex = candidate
                chosenLength = length
                break
            }
        }
        guard chosenIndex > 0 else { return nil }
        _ = template

        var frame = Data(repeating: 0, count: chosenLength)
        frame[0] = 0xFF
        var b1: UInt8 = 0xE0
        switch index.version {
        case .mpeg1: b1 |= 0b0001_1000
        case .mpeg2: b1 |= 0b0001_0000
        case .mpeg25: b1 |= 0b0000_0000
        }
        b1 |= 0b0000_0010          // Layer III
        b1 |= 0b0000_0001          // no CRC
        frame[1] = b1
        guard let rates = sampleRates[index.version],
              let rateIndex = rates.firstIndex(of: index.sampleRate) else { return nil }
        frame[2] = UInt8(chosenIndex << 4) | UInt8(rateIndex << 2)
        frame[3] = index.channels == 1 ? 0b1100_0000 : 0b0000_0000

        var cursor = 4 + sideInfo
        for byte in [0x58, 0x69, 0x6E, 0x67] as [UInt8] {   // "Xing"
            frame[cursor] = byte
            cursor += 1
        }
        // Flags: frames present (0x1) + bytes present (0x2).
        for byte in bigEndian(UInt32(0x0000_0003)) { frame[cursor] = byte; cursor += 1 }
        // The frame count a decoder should expect includes this metadata frame.
        for byte in bigEndian(UInt32(frameCount + 1)) { frame[cursor] = byte; cursor += 1 }
        for byte in bigEndian(UInt32(byteCount + chosenLength)) { frame[cursor] = byte; cursor += 1 }

        return frame
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}
