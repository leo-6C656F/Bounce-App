import AVFoundation
import SwiftUI

// MARK: - Envelope cache

/// Peak envelopes for recordings, built once and cached to disk.
///
/// Building an envelope is a **full decode pass** over the MP3 — far too
/// expensive to run from a list row's body, and expensive enough that doing it
/// twice for the same file is worth avoiding. So it happens once, off the main
/// actor, and the result (one byte per bucket) is written to
/// `Documents/Waveforms/<audio filename>.peaks`.
///
/// Two entry points, deliberately different:
///
/// - `cached(for:)` **never decodes.** List rows call this, so scrolling can
///   never kick off a decode storm; a row with a cold cache simply draws a flat
///   baseline until something else warms it.
/// - `peaks(for:)` decodes on a miss. The detail view calls this, because that's
///   a screen the user chose to open and where the waveform is the point.
///
/// `prewarm(_:)` fills the cache for the top of the library once per launch, so
/// rows get their sparklines without any single screen paying for all of them.
actor WaveformCache {

    static let shared = WaveformCache()

    /// Buckets stored per recording. More than any phone-width waveform can
    /// draw, so the *view* downsamples rather than the cache being the ceiling —
    /// and it costs 512 bytes on disk.
    static let bucketCount = 512

    /// Ceiling on the one-shot prewarm. Decoding the entire library on first
    /// launch of the Library tab would be a real battery cost for envelopes the
    /// user may never scroll to.
    private static let prewarmLimit = 20

    private var memory: [String: [UInt8]] = [:]
    private var inFlight: [String: Task<[UInt8]?, Never>] = [:]
    /// Files deleted while a decode of them was in flight. The decode can't be
    /// cancelled (it runs detached, so it doesn't inherit cancellation), and
    /// without this its trailing write recreates the `.peaks` file *after* the
    /// delete — an orphan for audio that no longer exists, which nothing will
    /// ever clean up because the `Recording` is gone.
    private var forgotten: Set<String> = []
    private var hasPrewarmed = false
    private var isPrewarming = false

    // MARK: Reading

    /// The cached envelope, or nil. **Never decodes** — safe to call from a list
    /// row that may appear and disappear dozens of times during a scroll.
    func cached(for url: URL) -> [UInt8]? {
        let name = url.lastPathComponent
        let size = Self.fileSize(of: url)
        let key = Self.memoryKey(name, size)
        if let hit = memory[key] { return hit }
        guard let peaks = Self.read(forAudioNamed: name, expecting: size), !peaks.isEmpty else { return nil }
        memory[key] = peaks
        return peaks
    }

    /// The envelope, decoding and caching it on a miss. Concurrent callers for
    /// the same file share one decode rather than racing.
    func peaks(for url: URL) async -> [UInt8]? {
        if let hit = cached(for: url) { return hit }

        let name = url.lastPathComponent
        let size = Self.fileSize(of: url)
        let key = Self.memoryKey(name, size)
        if let existing = inFlight[key] { return await existing.value }

        // Detached on purpose: the decode must not run on this actor's
        // executor, or a 30-second file would block every `cached(for:)` call a
        // scrolling list makes behind it. The consequence is that it does *not*
        // inherit cancellation — `prewarm`'s `Task.isCancelled` bounds the loop,
        // never the decode already running, so leaving the Library tab still
        // pays for the file currently in flight.
        let task = Task.detached(priority: .utility) { () -> [UInt8]? in
            Self.buildEnvelope(of: url, buckets: Self.bucketCount)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        // Deleted while we were decoding. The write happens *here*, on the
        // actor and after this check, rather than inside the detached task —
        // otherwise it lands after `forget`'s delete and recreates the file as
        // an orphan for audio that no longer exists.
        guard forgotten.remove(name) == nil else { return nil }
        if let result {
            memory[key] = result
            Self.write(result, forAudioNamed: name, sourceSize: size)
        }
        return result
    }

    /// Warm the cache for the head of the library, serially, once per launch.
    /// Serial rather than concurrent so this stays a background trickle instead
    /// of pinning every core the moment the Library tab appears.
    func prewarm(_ urls: [URL]) async {
        // Nothing to do, and crucially **not** a completed pass: a user who opens
        // Library before their first sync would otherwise mark the prewarm done
        // over an empty list and get no sparklines for the rest of the launch.
        guard !hasPrewarmed, !isPrewarming, !urls.isEmpty else { return }
        isPrewarming = true
        defer { isPrewarming = false }

        for url in urls.prefix(Self.prewarmLimit) {
            // Bounds the *loop*, not the decode already running — that's
            // detached and doesn't inherit cancellation. Leaving the Library tab
            // stops the queue but still pays for the file in flight.
            if Task.isCancelled { return }
            _ = await peaks(for: url)
        }
        // Only after a full, uncancelled pass. `LibraryView`'s `.task` is
        // cancelled when the tab is deselected, so setting this up front meant
        // switching away a second in permanently disabled the prewarm.
        hasPrewarmed = true
    }

    /// Drop a recording's envelope, from disk and from memory. Called by
    /// `RecordingStore.delete(id:)` so deleted audio doesn't leave an orphan.
    nonisolated static func forget(audioNamed name: String) {
        Task { await shared.discard(name) }
    }

    private func discard(_ name: String) {
        // Tombstone only while a decode of this file is actually in flight.
        // Keeping every deleted name for the life of the process would grow
        // unbounded and could suppress a later recording that reused the
        // filename; `peaks(for:)` clears the entry as it consumes it.
        if inFlight.keys.contains(where: { $0.hasPrefix("\(name)#") }) {
            forgotten.insert(name)
        }
        memory = memory.filter { !$0.key.hasPrefix("\(name)#") }
        try? FileManager.default.removeItem(at: Self.cacheURL(forAudioNamed: name))
    }

    // MARK: Disk

    /// Envelopes are invalidated by **size**, not by filename alone.
    ///
    /// `RecordingStore.markSynced` derives `audioFilename` from the SDK's output
    /// path, which is session-derived — so re-downloading after a truncated or
    /// failed transfer lands at the same name. Keyed on the name alone, the
    /// truncated recording's envelope would win forever (`peaks(for:)`
    /// short-circuits on a disk hit), showing a waveform that stops partway
    /// through a recording that plays to the end, with no way to clear it.
    ///
    /// On disk that means an 8-byte little-endian source size ahead of the
    /// buckets; in memory, a composite key.
    private static let headerSize = 8

    private nonisolated static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func memoryKey(_ name: String, _ size: Int) -> String {
        "\(name)#\(size)"
    }

    private nonisolated static var directory: URL {
        let dir = RecordingStore.documentsDirectory
            .appendingPathComponent("Waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func cacheURL(forAudioNamed name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("peaks")
    }

    private nonisolated static func read(forAudioNamed name: String, expecting sourceSize: Int) -> [UInt8]? {
        guard let data = try? Data(contentsOf: cacheURL(forAudioNamed: name)),
              data.count > headerSize else { return nil }
        let header = Data(data.prefix(headerSize))
        let stored = header.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard stored == UInt64(sourceSize) else { return nil }
        return [UInt8](data.dropFirst(headerSize))
    }

    private nonisolated static func write(_ envelope: [UInt8], forAudioNamed name: String, sourceSize: Int) {
        var data = Data()
        withUnsafeBytes(of: UInt64(sourceSize).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: envelope)
        // Same explicit-protection-class reasoning as `RecordingStore.save()` —
        // an envelope is derived from the recording's audio, not raw speech,
        // but there's no reason to leave it weaker than the source it's cached
        // from.
        try? data.write(
            to: cacheURL(forAudioNamed: name),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Decode

    /// Peak magnitude per bucket, normalised to 0…255.
    private nonisolated static func buildEnvelope(of url: URL, buckets: Int) -> [UInt8]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = file.length
        guard total > 0, format.channelCount > 0 else { return nil }

        var envelope = [Float](repeating: 0, count: buckets)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return nil }

        var frameIndex = 0
        // `AVAudioFile.read(into:)` **throws at EOF** rather than returning zero
        // frames, so the loop is bounded by `framePosition`, not by a nil or
        // empty result. Getting this wrong surfaces as a bare
        // `_GenericObjCError.nilError` that reads exactly like file corruption —
        // see CLAUDE.md's Speech framework traps, same hazard, same fix.
        while file.framePosition < total {
            do { try file.read(into: buffer) } catch { break }
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }
            let samples = channels[0]
            for offset in 0..<count {
                // Proportional, not `frame / (total / buckets)`. Integer division
                // floors, which left-packed short files (a 300-frame file filled
                // buckets 0–299 and left the rest flat) and piled the remainder
                // into the last bucket. `Int64` because frames × 512 overflows
                // 32-bit for long recordings.
                let bucket = min(buckets - 1, Int(Int64(frameIndex + offset) * Int64(buckets) / total))
                let magnitude = abs(samples[offset])
                if magnitude > envelope[bucket] { envelope[bucket] = magnitude }
            }
            frameIndex += count
        }

        // A partial read — a decode error, or a short read mid-file — leaves the
        // remaining buckets at zero, and caching that would make a permanently
        // flat right-hand tail impossible to fix short of deleting the
        // recording. Fail instead, so the next open tries again.
        guard file.framePosition >= total, frameIndex > 0 else { return nil }

        let loudest = envelope.max() ?? 0
        guard loudest > 0 else { return [UInt8](repeating: 0, count: buckets) }

        // Speech sits well below full scale and a linear map draws a near-flat
        // line for most of a meeting. The square root lifts quiet passages into
        // view without clipping the loud ones.
        return envelope.map { value in
            UInt8(min(255, max(0, ((value / loudest).squareRoot() * 255).rounded())))
        }
    }
}

// MARK: - View

/// A recording's peak envelope, drawn as bars, with a playhead and optional
/// highlight marks. Scrubbable when `onScrub` is supplied.
///
/// Drawn in a `Canvas` rather than as a stack of `Capsule`s: a phone-width
/// waveform is 100+ bars, and 100 SwiftUI views that re-render on every
/// playback tick is exactly the kind of thing that makes a player feel heavy.
struct WaveformView: View {

    let peaks: [UInt8]
    /// Playhead, 0…1.
    var progress: Double = 0
    /// Highlight marks as 0…1 positions.
    var marks: [Double] = []
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2
    /// Bars behind the playhead. Overridden by the list-row sparkline, which has
    /// no playhead and shouldn't shout in tint.
    var playedStyle = AnyShapeStyle(.tint)
    /// Bars ahead of the playhead.
    var unplayedStyle = AnyShapeStyle(.quaternary)
    /// Highlight ticks. Gold rather than the app tint or `.secondary`: a mark is
    /// the one thing on this waveform the *user* put there, and it has to be
    /// distinguishable from the playhead's tinted bars behind it. See
    /// `Color.bounceGold` in `UI/Common/Theme.swift`.
    var markStyle = AnyShapeStyle(Color.bounceGold)
    /// What VoiceOver reads for the current position. A percentage is useless on
    /// a long recording — "37 percent" of a two-hour meeting locates nothing —
    /// so the caller supplies a timecode.
    var valueDescription: String?
    /// How far one VoiceOver increment moves, as a fraction. The caller sets it
    /// from duration so a swipe is a fixed number of seconds rather than a fixed
    /// slice of an arbitrarily long recording.
    var accessibilityStep: Double = 0.05
    /// Supplying this makes the waveform scrubbable; omit it for a decorative
    /// sparkline in a list row.
    var onScrub: ((Double) -> Void)?
    var onScrubEnded: (() -> Void)?

    @State private var width: CGFloat = 0
    /// `@GestureState` resets itself when a gesture is **cancelled** — which is
    /// the case `onEnded` doesn't cover (a competing system gesture, or the view
    /// tearing down mid-drag). Without observing it the caller's scrub position
    /// stays latched and the playhead freezes while audio keeps playing.
    @GestureState private var isDragging = false

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: &context, size: size)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(.rect)
        .gesture(scrubGesture, isEnabled: onScrub != nil)
        .onChange(of: isDragging) { _, dragging in
            // Harmless to fire alongside `onEnded` — both just clear the latch.
            if !dragging { onScrubEnded?() }
        }
        .accessibilityElement()
        .accessibilityHidden(onScrub == nil)
        .accessibilityLabel("Playback position")
        .accessibilityValue(valueDescription ?? "\(Int((progress * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard let onScrub else { return }
            let delta = direction == .increment ? accessibilityStep : -accessibilityStep
            onScrub(min(max(progress + delta, 0), 1))
            onScrubEnded?()
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                guard width > 0 else { return }
                onScrub?(min(max(value.location.x / width, 0), 1))
            }
            .onEnded { _ in onScrubEnded?() }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let stride = barWidth + barSpacing
        let barCount = max(1, Int(size.width / stride))
        let played = Int((Double(barCount) * min(max(progress, 0), 1)).rounded())

        for index in 0..<barCount {
            let height = max(2, CGFloat(amplitude(at: index, of: barCount)) * size.height)
            let rect = CGRect(
                x: CGFloat(index) * stride,
                y: (size.height - height) / 2,
                width: barWidth,
                height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .style(index < played ? playedStyle : unplayedStyle))
        }

        // Marks are placed on the *bar grid*, not on `size.width`. The bars only
        // span `barCount * stride`, which is up to `stride - 1` points short of
        // the full width, so measuring against the width drifted every mark to
        // the right of the bar it points at and clipped a mark at 0 in half.
        let gridWidth = max(CGFloat(barCount) * stride - barSpacing, 1)
        for mark in marks where mark >= 0 && mark <= 1 {
            let x = min(max(CGFloat(mark) * gridWidth, 0), gridWidth - barWidth)
            let rect = CGRect(x: x, y: 0, width: 2, height: size.height)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .style(markStyle))
        }
    }

    /// Peaks are stored at a fixed 512 buckets; the view has however many bars
    /// fit. Take the loudest sample in each bar's slice rather than a single
    /// sample, so downsampling doesn't drop transients and flatten the shape.
    private func amplitude(at index: Int, of barCount: Int) -> Double {
        guard !peaks.isEmpty else { return 0.06 }
        let lower = index * peaks.count / barCount
        let upper = max(lower + 1, (index + 1) * peaks.count / barCount)
        var loudest: UInt8 = 0
        for position in lower..<min(upper, peaks.count) where peaks[position] > loudest {
            loudest = peaks[position]
        }
        return Double(loudest) / 255
    }
}
