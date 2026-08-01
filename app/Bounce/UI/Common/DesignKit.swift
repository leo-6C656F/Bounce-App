import SwiftUI

/// The vocabulary every screen built in the July 2026 refresh shares.
///
/// **This file exists because the refresh landed six screens at once.** Home,
/// the live recorder, the transcript, the library, Ask and Settings were each
/// designed separately and then had to read as one app — so the pieces they have
/// in common (a section label, a status dot, a chip that names a source, a
/// speaker avatar, a sparkline) live here rather than being re-typed with
/// slightly different numbers on each screen. A tracking value or a chip radius
/// changed here changes everywhere, which is the whole point.
///
/// Nothing here is glass: these are *content* pieces, and per the Liquid Glass
/// rule in CLAUDE.md glass belongs to the navigation layer floating above
/// content. `GlassSupport.swift` owns that side.

// MARK: - Section label

/// The small uppercase label that heads a group: `TODAY`, `SOURCES`,
/// `MEETING NOTES`, `DANGER ZONE`, a chapter title.
///
/// One definition, because this shape appears on every screen in the refresh and
/// four independent copies had already drifted in tracking and weight during
/// design. Uses `.textCase(.uppercase)` rather than an uppercased string so
/// VoiceOver reads the words rather than spelling them.
struct SectionLabel: View {

    let text: String
    var tint: Color?

    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
    }
}

// MARK: - Status dot

/// A 7pt filled circle used wherever something is on/off/degraded — the device
/// card, the Settings dashboard, the live recorder, a source chip.
///
/// Colour-only and therefore **never a label on its own**: every call site
/// either combines it into an adjacent text element for VoiceOver or hides it.
struct StatusDot: View {

    let color: Color
    var diameter: CGFloat = 7

    init(_ color: Color, diameter: CGFloat = 7) {
        self.color = color
        self.diameter = diameter
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

extension DeviceConnectionState {
    /// The dot colour for this connection state. On the state rather than in a
    /// view so Home, Settings and the recorder can't disagree about what amber
    /// means.
    var indicatorColor: Color {
        switch self {
        case .connected: return .green
        case .scanning, .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }
}

// MARK: - Chips

/// A small tinted capsule carrying one word of state — `Connected`, `On-device`,
/// `2 active`, `overdue`.
///
/// Filled at 14% of the tint with the tint as the label, matching `CategoryChip`,
/// so a status chip and a category chip sit beside each other without one
/// shouting.
struct StatusChip: View {

    let text: String
    var tint: Color = .secondary
    /// Solid rather than tinted-translucent. Reserved for the one chip in a group
    /// that is genuinely selected, not for emphasis.
    var isProminent = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isProminent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)), in: .capsule)
    }
}

/// Names the recording a task or an answer came from, as a dot plus a title.
///
/// Used by Tasks and by Ask. The dot takes the recording's category colour, so
/// the same recording reads the same on both screens.
struct SourceChip: View {

    let title: String
    var categoryName: String?

    private var tint: Color {
        guard let categoryName,
              let category = CategoryStore.shared.category(named: categoryName)
        else { return .secondary }
        return CategoryStyle.color(for: category)
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tint, diameter: 6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.background.secondary, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("From \(title)")
    }
}

// MARK: - Speaker avatar

/// Initials in a tinted circle, standing in for a diarized speaker.
///
/// Replaces the repeated `Speaker 1` text label in the chaptered transcript: at
/// two or three speakers a colour is faster to scan than a word, and it buys
/// back the width the timecode rail used to take.
///
/// The tint is derived from the speaker's *label* by summing unicode scalars —
/// the same deterministic trick `CategoryStyle.fallbackIndex` uses, and for the
/// same reason: `hashValue` is seeded per process, so a speaker would change
/// colour every launch.
struct SpeakerAvatar: View {

    /// The display label — a user-assigned name, or `Speaker 2`.
    let label: String

    @ScaledMetric private var side: CGFloat = 30

    static func tint(for label: String) -> Color {
        let sum = label.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return CategoryStyle.swatches[abs(sum) % CategoryStyle.swatches.count].color
    }

    /// First letters of the first two words: "Leo Salazar" → LS, "Speaker 2" → S2.
    private var initials: String {
        let words = label.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init)
        return letters.joined().uppercased()
    }

    var body: some View {
        let tint = Self.tint(for: label)
        Text(initials)
            .font(.system(size: side * 0.38, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(tint.opacity(0.16), in: .circle)
            .accessibilityHidden(true)
    }
}

// MARK: - Sparkline

/// A recording's shape, small, with no playhead and no scrubbing.
///
/// Wraps `WaveformView` at the settings every decorative use wants, so a caller
/// can't accidentally pass `progress: 0` and paint the whole thing in the
/// unplayed style. **Reads the cache only** — see `WaveformCache.cached(for:)`;
/// a decode is never started from here, because these appear in list rows.
struct Sparkline: View {

    let peaks: [UInt8]
    var tint: Color?
    var barWidth: CGFloat = 2
    var barSpacing: CGFloat = 1

    var body: some View {
        WaveformView(
            peaks: peaks,
            progress: 1,
            barWidth: barWidth,
            barSpacing: barSpacing,
            playedStyle: tint.map { AnyShapeStyle($0.opacity(0.55)) } ?? AnyShapeStyle(.tertiary))
        .accessibilityHidden(true)
    }
}

/// Loads a recording's cached envelope, retrying while a prewarm fills it in.
///
/// Lifted out of `RecordingRow` so Home's deck, the library timeline and Ask's
/// source cards all share one loader instead of three copies of the same
/// bounded retry loop. **Never decodes** — `cached(for:)` only, so a screenful
/// of these can't start a decode storm.
struct SparklineLoader<Content: View>: View {

    let recording: Recording
    @ViewBuilder var content: ([UInt8]) -> Content

    @State private var peaks: [UInt8] = []

    var body: some View {
        content(peaks)
            .task(id: recording.audioFilename) {
                guard let url = RecordingStore.shared.audioURL(for: recording) else { return }
                // Bounded, and the task dies with the view. The prewarm builds
                // envelopes serially in the background, so a view that appeared
                // before its turn came round would otherwise stay blank until it
                // was scrolled away and recycled.
                for attempt in 0..<6 {
                    if let cached = await WaveformCache.shared.cached(for: url) {
                        peaks = cached
                        return
                    }
                    if attempt < 5 { try? await Task.sleep(for: .seconds(2)) }
                    if Task.isCancelled { return }
                }
            }
    }
}

// MARK: - Duration bar

/// A recording's length as a vertical bar, for the library timeline.
///
/// **The scale is deliberately not linear.** A day mixing a 7-second reminder
/// with a 42-minute call renders the reminder as a sub-pixel sliver under a
/// linear map; a square root keeps the short ones visible while a long meeting
/// still reads as obviously long. Clamped at both ends so nothing vanishes and
/// nothing runs off the row.
struct DurationBar: View {

    let duration: TimeInterval
    let tint: Color

    /// The longest recording a full-height bar represents. Beyond this the bar
    /// stops growing — a two-hour recording and a three-hour one are both
    /// simply "long", and letting the scale chase the outlier flattens
    /// everything else.
    static let fullScale: TimeInterval = 45 * 60
    static let minimumHeight: CGFloat = 10
    static let maximumHeight: CGFloat = 96

    static func height(for duration: TimeInterval) -> CGFloat {
        guard duration > 0 else { return minimumHeight }
        let fraction = min(duration / fullScale, 1)
        let scaled = fraction.squareRoot()
        return minimumHeight + (maximumHeight - minimumHeight) * scaled
    }

    var body: some View {
        Capsule()
            .fill(tint)
            .frame(width: 7, height: Self.height(for: duration))
            .accessibilityHidden(true)
    }
}

// MARK: - Wrapping chip row

/// A wrapping row of chips.
///
/// `FlowRow` rather than an `HStack` in a `ScrollView`: a horizontal scroller
/// hides items off the edge with no affordance saying so, and at accessibility
/// text sizes two chips already overflow a phone width.
///
/// Lives here rather than in `RecordingDetailView` because it now has two
/// callers — the speaker-naming sheet's suggestion chips and Ask's per-answer
/// source chips.
struct FlowRow: Layout {

    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
