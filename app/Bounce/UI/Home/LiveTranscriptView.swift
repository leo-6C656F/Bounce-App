import SwiftUI

/// The conversation appearing as it happens, grouped into timed blocks.
///
/// Committed phrases are shown in full strength; the phrase currently being
/// spoken is dimmed and italic, because the analyzer rewrites it as it refines
/// its guess. Showing both at the same weight makes the text look like it is
/// glitching.
///
/// Blocks come from `Transcript.blocks(.live)` — the same grouping the detail
/// view and the web client use — and render through the same
/// `TranscriptBlockRow`. That is deliberate: this used to be a flat run of
/// `Text` views, so the same recording read completely differently before and
/// after the post-sync pass replaced the preview.
struct LiveTranscriptView: View {

    private var live: LiveTranscriber { LiveTranscriber.shared }

    var body: some View {
        Group {
            if let error = live.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else if live.hasContent {
                LiveTranscriptScroll()
            } else if live.isRunning {
                Label("Listening…", systemImage: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The scrolling transcript, its follow state, and the jump-to-live affordance.
private struct LiveTranscriptScroll: View {

    private var live: LiveTranscriber { LiveTranscriber.shared }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var position = ScrollPosition()
    /// Whether this session is diarized, and so whether the rows carry a speaker
    /// avatar gutter.
    ///
    /// Owned here rather than derived in each child: `LiveBlockList` and
    /// `VolatileTail` are deliberately separate views reading different parts of
    /// `LiveTranscriber` (see the notes on each), and the tail's blank gutter has
    /// to match the list's real one or the in-progress phrase steps out of the
    /// paragraph column. The list reports it up from the blocks it has already
    /// grouped, so nothing observes `segments` twice, and it flips at most once
    /// per session.
    @State private var showsAvatars = false
    /// Whether new text should pull the view down with it. Defeated the moment
    /// the user drags, so reading back through a long recording isn't yanked
    /// away every few seconds.
    @State private var isFollowing = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LiveBlockList(showsAvatars: $showsAvatars)
                VolatileTail(showsAvatar: showsAvatars)
            }
            .padding(.horizontal, 4)
        }
        .scrollPosition($position, anchor: .bottom)
        .frame(maxHeight: .infinity)
        // A drag is the only thing that stops following. Explicit, so it can
        // never be confused with the programmatic scroll we just performed.
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { isFollowing = false }
        }
        // Scrolling back to the bottom by hand re-engages, so the pill isn't
        // the only way out. `isPositionedByUser` can't do this — it stays true
        // after a manual return to the bottom, so following would never resume.
        // The 80pt slack mirrors the web client's own near-bottom threshold.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let bottom = geometry.contentOffset.y + geometry.containerSize.height
            return bottom >= geometry.contentSize.height - 80
        } action: { _, isAtBottom in
            if isAtBottom { isFollowing = true }
        }
        .onChange(of: live.segments.count) { follow() }
        .onChange(of: live.volatileText) { follow() }
        .overlay(alignment: .bottomTrailing) {
            if !isFollowing { jumpToLive }
        }
    }

    /// Chrome, not content — and it inherits `RecordingView`'s
    /// `GlassEffectContainer` from up the view tree, so it renders as part of
    /// the same material family as the transport pill rather than a stray layer.
    private var jumpToLive: some View {
        Button {
            isFollowing = true
            follow()
        } label: {
            Label("Jump to live", systemImage: "arrow.down")
                .font(.footnote)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .padding(.trailing, 4)
        .padding(.bottom, 8)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFollowing)
    }

    /// Under Reduce Motion this jumps rather than not following at all: the
    /// transcript is live, and a view stalled behind the speaker is worse than
    /// one that moves without animating.
    private func follow() {
        guard isFollowing else { return }
        if reduceMotion {
            position.scrollTo(edge: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                position.scrollTo(edge: .bottom)
            }
        }
    }
}

/// The committed blocks.
///
/// **Its own view, and it reads `segments` but never `volatileText`.** Those
/// were in one body, so every refinement of the in-progress phrase — several a
/// second — invalidated the whole block list. Same reason `TranscriptSection`
/// is separate from `RecordingDetailView`.
private struct LiveBlockList: View {

    /// Reported up to `LiveTranscriptScroll` so `VolatileTail` can reserve the
    /// same gutter. Latched true: a diarizing engine occasionally emits an
    /// unlabelled phrase, and letting the column vanish for it would shift the
    /// whole transcript sideways mid-sentence.
    @Binding var showsAvatars: Bool

    private var live: LiveTranscriber { LiveTranscriber.shared }

    /// Grouping allocates a block per run and joins its text, so it's done when
    /// the segments change rather than on every render.
    @State private var blocks: [TranscriptBlock] = []

    var body: some View {
        // Lazily: eagerly, a 40-minute recording rebuilt every row on every
        // WebSocket frame.
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                TranscriptBlockRow(
                    block: block,
                    // The newest block gets a tinted timecode so the eye can
                    // find the live edge without a background wash, which would
                    // read as a selection.
                    emphasis: index == blocks.count - 1 ? .newest : .none,
                    showsSpeaker: blocks.showsSpeaker(at: index),
                    showsAvatar: showsAvatars)
            }
        }
        .onAppear { rebuild() }
        .onChange(of: live.segments) { rebuild() }
    }

    private func rebuild() {
        blocks = Transcript(
            segments: live.segments,
            localeIdentifier: Locale.current.identifier,
            createdAt: Date(),
            isPreview: true
        ).blocks(.live)
        if !showsAvatars, blocks.contains(where: { $0.speaker != nil }) {
            showsAvatars = true
        }
    }
}

/// The phrase still being spoken.
///
/// Rendered without a timecode rather than with `0:00`: the volatile phrase has
/// no timing yet, and inventing one would put a wrong number in a column whose
/// whole job is to be trustworthy.
private struct VolatileTail: View {

    /// Whether the blocks above are drawing an avatar gutter. Passed in rather
    /// than derived — see `LiveTranscriptScroll.showsAvatars`.
    var showsAvatar: Bool

    private var live: LiveTranscriber { LiveTranscriber.shared }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Matches `TranscriptBlockRow.avatarColumn`.
    @ScaledMetric private var avatarColumn: CGFloat = 30
    /// Matches `TranscriptBlockRow.paragraphLineSpacing`. This phrase is the
    /// continuation of the paragraph above it, so face and leading have to agree
    /// or the sentence changes typeface halfway through.
    @ScaledMetric private var paragraphLineSpacing: CGFloat = Metrics.readingLineSpacing

    var body: some View {
        if !live.volatileText.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if showsAvatar, !dynamicTypeSize.isAccessibilitySize {
                    // Empty, but exactly an avatar wide, so the paragraph stays
                    // in the same column as every block above it. `TranscriptBlockRow`
                    // drops the avatar at accessibility sizes; this matches.
                    Color.clear.frame(width: avatarColumn, height: 1)
                }
                Text(live.volatileText)
                    .font(.reading.italic())
                    .lineSpacing(paragraphLineSpacing)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            // A text view that rewrites itself several times a second must not
            // announce or steal focus; VoiceOver users get the committed blocks.
            .accessibilityHidden(true)
        }
    }
}
