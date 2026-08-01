import SwiftUI

// MARK: - Chip row

/// A recording's tags, as a row of compact chips.
///
/// Takes **already-resolved** `RecordingCategory` values rather than ids or the
/// store, so it has no dependency on `CategoryStore` and can't accidentally
/// render a dangling id as a blank chip — resolution (and dropping unknown ids)
/// happens once at the call site. It also means the row previews and tests with
/// literals.
///
/// Colour and glyph come from `CategoryStyle`, which is the only place that maps
/// the model's stored strings to appearance. **The unstyled fallback goes through
/// `CategoryStyle.color(for:)`, which sums unicode scalars — never `hashValue`,
/// which Swift seeds per process, so a tag's colour would change on every
/// launch.**
///
/// Overflow: the chips **wrap** onto as many lines as they need
/// (`ChipFlowLayout`). Truncating or horizontally scrolling would hide tags —
/// and at accessibility text sizes a single chip can be wider than the screen, so
/// there is no line count that fits by construction. Callers with a fixed-height
/// slot (a dense list row) pass `limit:` instead, which shows that many chips and
/// a "+N" counter, so the hiding is explicit and counted rather than a clip.
struct TagChipRow: View {

    /// The tags to show, resolved by the caller. Rendered sorted by name —
    /// **display only**: `Recording.tagIds` keeps its insertion order, and
    /// sorting on read then persisting would rewrite every recording.
    let tags: [RecordingCategory]

    /// Show at most this many chips, followed by a "+N" counter. Nil shows all.
    var limit: Int?

    /// When non-nil each chip gains a remove control, so the detail view's tag
    /// editor is the same row the rest of the app displays. Inert (and visually
    /// plain) when nil.
    var onRemove: ((RecordingCategory) -> Void)?

    private var sorted: [RecordingCategory] {
        // `localizedStandardCompare` so "item 2" sorts before "item 10" and
        // diacritics behave the way the user's locale expects.
        tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var visible: [RecordingCategory] {
        guard let limit, limit >= 0, sorted.count > limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    private var hiddenCount: Int { sorted.count - visible.count }

    var body: some View {
        if !tags.isEmpty {
            ChipFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(visible) { tag in
                    TagChip(tag: tag, onRemove: onRemove)
                }
                if hiddenCount > 0 {
                    OverflowChip(count: hiddenCount)
                }
            }
        }
    }
}

// MARK: - One chip

/// A single tag. Follows `CategoryChip`'s idiom — caption weight, the tag's tint
/// on a 0.14 wash of itself, capsule — so a tag and a category read as the same
/// family of thing rather than two unrelated badges.
private struct TagChip: View {

    let tag: RecordingCategory
    let onRemove: ((RecordingCategory) -> Void)?

    var body: some View {
        if let onRemove {
            // A real `Button`, not a tap gesture on the capsule: it brings its own
            // hit testing, pressed feedback, and `.isButton` trait. **The whole
            // chip is the target**, not just the glyph — an 11pt "xmark" is far
            // below the 44pt minimum, and at large Dynamic Type the name is what
            // the user is aiming at anyway.
            Button { onRemove(tag) } label: { chip }
                .buttonStyle(.plain)
                .accessibilityLabel("Tag: \(tag.name)")
                .accessibilityHint("Removes this tag")
        } else {
            chip
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Tag: \(tag.name)")
        }
    }

    private var chip: some View {
        let tint = CategoryStyle.color(for: tag)

        return HStack(spacing: 4) {
            Image(systemName: CategoryStyle.symbol(for: tag))
            Text(tag.name)
            if onRemove != nil {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: .capsule)
        .contentShape(.capsule)
    }
}

/// "+2" for tags a `limit:` is holding back. Neutral on purpose — it stands for
/// several tags of possibly different colours, so borrowing one of their tints
/// would misrepresent it.
private struct OverflowChip: View {

    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.14), in: .capsule)
            .accessibilityLabel("\(count) more tags")
    }
}

// MARK: - Wrapping layout

/// Lays subviews out left to right, wrapping to a new line when the next one
/// would overflow the proposed width.
///
/// SwiftUI has no built-in flow container, and the alternatives all lose
/// content: an `HStack` compresses and clips, a horizontal `ScrollView` hides
/// tags behind a gesture with no affordance, and `ViewThatFits` needs a fixed
/// set of candidate arrangements that can't cover an unbounded tag count.
/// Wrapping is the only shape that stays correct at accessibility text sizes,
/// where a single chip can be wider than the screen.
///
/// Named `ChipFlowLayout`, not `FlowLayout` or anything shortened to `Layout` —
/// see `Metrics` in `Theme.swift` for why that name is poison here: it collides
/// with SwiftUI's own `Layout` protocol.
struct ChipFlowLayout: Layout {

    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = self.lines(for: subviews, width: proposal.width)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } +
            lineSpacing * CGFloat(max(0, lines.count - 1))
        // Report the proposed width when there is one, so the row fills its slot
        // rather than jittering as chips are added and removed.
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(for: subviews, width: proposal.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// A nil proposed width means "how big would you like to be" — answer with
    /// one line. A zero-or-negative one would wrap every chip onto its own line
    /// forever, so it's treated the same way.
    private func lines(for subviews: Subviews, width proposed: CGFloat?) -> [Line] {
        let maxWidth = (proposed ?? .infinity) > 0 ? (proposed ?? .infinity) : .infinity
        var lines: [Line] = []
        var current = Line()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > maxWidth {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}
