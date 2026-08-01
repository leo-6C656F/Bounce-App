import SwiftUI

// MARK: - Style vocabulary

/// Colour and glyph vocabulary for the user's recording categories.
///
/// The **model stores strings** (`RecordingCategory.colorName` / `symbolName`)
/// and this resolves them, so `Transcription/RecordingCategories.swift` stays
/// free of SwiftUI and a colour rename can't invalidate a stored category.
enum CategoryStyle {

    struct Swatch: Identifiable, Hashable {
        let name: String
        let color: Color
        var id: String { name }
    }

    /// System colours, so each one already carries its own light/dark pair.
    static let swatches: [Swatch] = [
        Swatch(name: "blue", color: .blue),
        Swatch(name: "indigo", color: .indigo),
        Swatch(name: "purple", color: .purple),
        Swatch(name: "pink", color: .pink),
        Swatch(name: "red", color: .red),
        Swatch(name: "orange", color: .orange),
        Swatch(name: "yellow", color: .yellow),
        Swatch(name: "green", color: .green),
        Swatch(name: "teal", color: .teal),
        Swatch(name: "brown", color: .brown),
    ]

    /// Offered in the category editor's glyph picker. Deliberately a short,
    /// curated list rather than a symbol browser — the point is that categories
    /// are *distinguishable at a glance*, which a thousand choices works against.
    static let symbols: [String] = [
        "person.2.fill", "bubble.left.and.bubble.right.fill", "phone.fill",
        "checklist", "checkmark.circle.fill", "bell.fill", "calendar",
        "note.text", "lightbulb.fill", "brain", "book.fill", "graduationcap.fill",
        "briefcase.fill", "chart.line.uptrend.xyaxis", "dollarsign.circle.fill",
        "cart.fill", "house.fill", "heart.fill", "airplane", "car.fill",
        "fork.knife", "music.note", "camera.fill", "tag.fill",
    ]

    static let fallbackSymbol = "tag.fill"

    // MARK: Resolution

    static func color(for category: RecordingCategory?) -> Color {
        guard let category else { return .secondary }
        if let name = category.colorName,
           let swatch = swatches.first(where: { $0.name == name }) {
            return swatch.color
        }
        return swatches[fallbackIndex(for: category.id)].color
    }

    static func symbol(for category: RecordingCategory?) -> String {
        category?.symbolName ?? fallbackSymbol
    }

    /// A stable colour for a category the user hasn't styled, so a fresh library
    /// isn't uniformly grey.
    ///
    /// **Not `hashValue`** — Swift seeds it per process, so a category's colour
    /// would change on every launch. Summing scalars is deterministic across
    /// launches and devices.
    private static func fallbackIndex(for key: String) -> Int {
        let sum = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return abs(sum) % swatches.count
    }
}

// MARK: - Row glyph

/// The category marker in a list row.
///
/// Renders for uncategorized recordings too, in a neutral waveform: dropping the
/// column entirely would shift every uncategorized row's text out of alignment
/// with its categorized neighbours, which reads as a bug rather than as absence.
struct CategoryGlyph: View {

    /// `Recording.categoryName` — the category's *name* at the time the
    /// auto-organize pass ran, not its id.
    let categoryName: String?

    @ScaledMetric private var side: CGFloat = 30

    private var category: RecordingCategory? {
        guard let categoryName else { return nil }
        return CategoryStore.shared.category(named: categoryName)
    }

    var body: some View {
        let resolved = category
        let tint = resolved == nil ? Color.secondary : CategoryStyle.color(for: resolved)

        Image(systemName: resolved == nil ? "waveform" : CategoryStyle.symbol(for: resolved))
            .font(.system(size: side * 0.45, weight: .medium))
            .foregroundStyle(resolved == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
            .frame(width: side, height: side)
            .background(
                tint.opacity(resolved == nil ? 0 : 0.14),
                in: .rect(cornerRadius: side * 0.3))
            .accessibilityHidden(true)
    }
}

// MARK: - Detail chip

/// The category, named, for the recording detail. Silent when unclassified —
/// unlike the row glyph there is no alignment to preserve here, and a chip
/// reading "Uncategorized" is noise.
struct CategoryChip: View {

    let categoryName: String?

    private var category: RecordingCategory? {
        guard let categoryName else { return nil }
        return CategoryStore.shared.category(named: categoryName)
    }

    var body: some View {
        if let categoryName {
            let resolved = category
            let tint = CategoryStyle.color(for: resolved)
            Label(categoryName, systemImage: CategoryStyle.symbol(for: resolved))
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tint.opacity(0.14), in: .capsule)
                .accessibilityLabel("Category: \(categoryName)")
        }
    }
}
