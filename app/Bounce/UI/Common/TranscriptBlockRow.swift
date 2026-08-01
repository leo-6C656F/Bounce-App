import SwiftUI

/// One block of transcript: who said it, when, and what.
///
/// **Shared between the live screen and the detail screen on purpose.** These
/// were two independent layouts, so the same recording read differently before
/// and after syncing — the live view a flat wall of text, the detail view a
/// stacked timecode header. One row means the transcript looks continuous across
/// the transition from preview to authoritative pass, and it is why the avatar
/// gutter introduced for the chaptered detail view appears on the live screen
/// too rather than only where it was designed.
///
/// The layout is an avatar gutter, then a `0:12 · Speaker 2` header line, then
/// the paragraph. It replaced a 54pt right-aligned timecode rail:
///
/// - **The gutter is still fixed width**, so rows stay aligned with their
///   neighbours — the same argument `CategoryGlyph` makes for rendering on
///   uncategorized rows. When a transcript has no speakers at all (the on-device
///   engine doesn't diarize) the column is dropped for *every* row at once, so
///   alignment within a transcript is never mixed.
/// - **The timecode is never suppressed.** Only the speaker is, and only when it
///   repeats, so a back-and-forth doesn't print "Speaker 1" on every line.
/// - At accessibility text sizes the avatar goes too. A fixed gutter plus a
///   30pt avatar leaves about two words per line, which is the same reason the
///   rail used to fold away there.
struct TranscriptBlockRow: View {

    /// What, if anything, this row should be emphasising.
    enum Emphasis: Equatable {
        case none
        /// Under the playhead. `currentTime` lifts the phrase being spoken —
        /// only meaningful on the current row, so the parent passes `.none` to
        /// every other one and they don't rebuild on each tick.
        case playing(currentTime: TimeInterval)
        /// The newest committed block on the live screen. Tints the timecode
        /// without the background wash, which would read as a selection.
        case newest
    }

    let block: TranscriptBlock
    var emphasis: Emphasis = .none
    /// Suppressed when the previous block has the same speaker.
    var showsSpeaker: Bool = true
    /// Whether this transcript is diarized at all. A per-transcript decision
    /// passed down rather than derived per block, so a block that happens to
    /// have no speaker can't knock one row's text column out of line with the
    /// rest.
    var showsAvatar: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric private var avatarColumn: CGFloat = 30
    /// See `Metrics.readingLineSpacing`. `VolatileTail` in `LiveTranscriptView`
    /// carries the same pair of values — the in-progress phrase sits directly
    /// under these paragraphs in the same column, so a mismatch changes face or
    /// leading mid-sentence.
    @ScaledMetric private var paragraphLineSpacing: CGFloat = Metrics.readingLineSpacing

    private var isPlaying: Bool { if case .playing = emphasis { return true }; return false }
    private var isEmphasised: Bool { emphasis != .none }

    /// The avatar is a nicety, not information — at accessibility sizes the
    /// width it costs is worth more than the colour it adds.
    private var drawsAvatar: Bool {
        showsAvatar && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if drawsAvatar {
                Group {
                    if let speaker = block.speakerLabel {
                        SpeakerAvatar(label: speaker)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: avatarColumn)
            }

            VStack(alignment: .leading, spacing: 4) {
                header
                paragraph
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            // A literal radius, not `.concentric`: this row sits directly in the
            // scroll view's stack, so there is no ancestor container shape for
            // `.concentric` to derive an inset radius from.
            isPlaying ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 10)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isPlaying)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(block.timecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(timecodeStyle)
            if showsSpeaker, let speaker = block.speakerLabel {
                Text("·").foregroundStyle(.tertiary)
                Text(speaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isEmphasised ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
    }

    /// The reading face and an opened-up leading, not raw `.body` — see
    /// `Font.reading`.
    ///
    /// **No maximum measure.** The desktop client caps its column at 68
    /// characters, but after the gutter and the screen margins a portrait iPhone
    /// already gives about 40, so a width limit here would only narrow a column
    /// that is if anything too narrow already. The app is portrait-only; revisit
    /// if that ever changes.
    private var paragraph: some View {
        text
            .font(.reading)
            .lineSpacing(paragraphLineSpacing)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timecodeStyle: AnyShapeStyle {
        isEmphasised ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
    }

    /// Read as one utterance, with the position spoken as a duration rather
    /// than as the digits of a timecode.
    private var accessibilityLabel: String {
        let who = showsSpeaker ? block.speakerLabel.map { "\($0), " } ?? "" : ""
        return "\(who)at \(block.start.spokenTimecode). \(block.text)"
    }

    /// The block under the playhead reads as one paragraph with the phrase
    /// currently being spoken lifted to full contrast — the transcript's
    /// timings are per phrase, so this costs nothing but the concatenation.
    /// Every other block is a single flat `Text`.
    private var text: Text {
        guard case .playing(let currentTime) = emphasis, !block.segments.isEmpty else {
            return Text(block.text).foregroundStyle(.secondary)
        }
        // The most recent phrase that has *started*, rather than the one whose
        // `start..<end` contains the playhead. Segments don't abut — both Apple's
        // phrase ranges and Soniox's token spans leave gaps at pauses, and there
        // is always a gap between a block's last segment and the next block's
        // start — so matching the interval greyed the entire paragraph out
        // several times per block and reliably at its tail. That was a
        // regression: before this, the current block was unconditionally
        // `.primary`.
        let spoken = block.segments.lastIndex { currentTime >= $0.start } ?? 0
        // One `AttributedString` with a run per phrase, rather than `Text` values
        // concatenated with `+` — which iOS 26 deprecates. Interpolation, the
        // suggested replacement, doesn't fit: each phrase needs its own colour and
        // the count is dynamic, so there is no literal to interpolate into. A
        // single attributed value is also one view instead of N, which matters on a
        // paragraph that re-renders on every playback tick.
        var attributed = AttributedString()
        for (index, segment) in block.segments.enumerated() {
            // No trailing space after the last phrase, so this renders identically
            // to `block.text` (joined with a single space) and the final line's
            // wrap point doesn't shift as a block gains focus.
            let separator = index == block.segments.count - 1 ? "" : " "
            var run = AttributedString(segment.text + separator)
            // `Color`, not a `ShapeStyle` — `AttributedString` carries colours, and
            // `.primary`/`.secondary` exist as both. Same rendering as before.
            run.foregroundColor = index == spoken ? .primary : .secondary
            attributed.append(run)
        }
        return Text(attributed)
    }
}

extension Array where Element == TranscriptBlock {
    /// Whether the block at `index` should print its speaker: only when it
    /// differs from the one before it. Kept here rather than on `TranscriptBlock`
    /// because it's a property of the sequence, not the block.
    func showsSpeaker(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return self[index].speaker != self[index - 1].speaker
    }
}
