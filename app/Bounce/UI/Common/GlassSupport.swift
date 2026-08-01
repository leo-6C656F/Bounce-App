import SwiftUI

// MARK: - Accessibility-aware glass

/// Applies Liquid Glass, but yields to Reduce Transparency.
///
/// `.identity` is the documented way to switch the effect off without changing
/// layout, so this keeps the same geometry either way.
struct AdaptiveGlass<S: Shape>: ViewModifier {

    let shape: S
    /// `.regular` for chrome over ordinary content; `.clear` for chrome over a
    /// media/immersive backdrop (e.g. `RecordingView`'s transport pill sits
    /// over a colour wash, exactly the case `.clear` exists for).
    let variant: Glass
    let tint: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.regularMaterial, in: shape)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        var glass = variant
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// Glass that respects Reduce Transparency.
    func adaptiveGlass<S: Shape>(
        in shape: S = .capsule,
        variant: Glass = .regular,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(AdaptiveGlass(shape: shape, variant: variant, tint: tint, interactive: interactive))
    }
}

// MARK: - Reduce Motion aware pulse

/// `.symbolEffect(.pulse, isActive:)`, but yields to Reduce Motion — the
/// same precedent `AdaptiveGlass` sets above for reading an accessibility
/// environment value before applying an effect.
private struct ReduceMotionAwarePulse: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(.pulse, isActive: isActive)
        }
    }
}

extension View {
    func pulseWhenActive(_ isActive: Bool) -> some View {
        modifier(ReduceMotionAwarePulse(isActive: isActive))
    }
}

// MARK: - Reduce Motion aware zoom navigation

/// The view a pushed screen should zoom out of.
///
/// One value rather than an id and a namespace passed separately, so a
/// destination can take it as a single optional: not every push has a source to
/// zoom from — `TasksView` pushes a recording from an action-item row, which is
/// not a `RecordingRow` — and those fall back to the standard slide.
struct ZoomTransitionSource: Equatable {
    let id: String
    let namespace: Namespace.ID
}

/// `.navigationTransition(.zoom(sourceID:in:))`, but yields to Reduce Motion —
/// the same precedent `pulseWhenActive` sets above.
///
/// **Only the destination is gated.** `matchedTransitionSource` at the source is
/// inert on its own: with no destination asking for the zoom there is nothing to
/// match. Leaving the sources unconditional keeps list rows on one view identity
/// instead of wrapping every one of them in a `_ConditionalContent` that exists
/// only to read an accessibility setting.
private struct ZoomNavigation: ViewModifier {

    let source: ZoomTransitionSource?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let source, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: source.id, in: source.namespace))
        } else {
            content
        }
    }
}

extension View {
    /// Zoom out of `source` when this screen is pushed. No-op when the caller
    /// has no source, or when Reduce Motion is on.
    func zoomTransition(from source: ZoomTransitionSource?) -> some View {
        modifier(ZoomNavigation(source: source))
    }
}

// MARK: - Content card

/// A plain content surface. Deliberately *not* glass: glass belongs to the
/// navigation layer floating above content, and glass-on-glass reads as mud.
///
/// Publishes its own corner radius via `.containerShape`, so any inner
/// surface using `.rect(corners: .concentric)` derives an inset radius that
/// actually nests instead of guessing a smaller literal that may or may not
/// match (`ConcentricRectangle`/`.concentric` are iOS 26 SwiftUICore API —
/// see `docs/plans/ios26-ui-refresh.md` Phase 0.3).
struct ContentCard<Content: View>: View {

    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Metrics.contentSpacing)
            .background(.background.secondary, in: .rect(cornerRadius: Metrics.cardRadius))
            .containerShape(.rect(cornerRadius: Metrics.cardRadius))
    }
}

// MARK: - Alerts

extension View {
    /// Present an identifiable message as a simple alert.
    func alert(item: Binding<AppModel.AlertMessage?>) -> some View {
        alert(
            item.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            presenting: item.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.message)
        }
    }
}

// MARK: - Small pieces

/// Battery pill for the device card.
struct BatteryLabel: View {

    let level: Int
    let isCharging: Bool

    var body: some View {
        Label {
            Text("\(level)%")
                .monospacedDigit()
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(isCharging ? .green : tint)
        }
        .font(.subheadline)
    }

    private var symbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<70: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var tint: Color {
        level < 15 ? .red : .secondary
    }
}

// `LevelMeter` — a 28-bar symmetric bell driven by the instantaneous mic level —
// lived here and had exactly two callers, Home's record button and the live
// recorder. Both are gone: Home no longer shows a meter at all, and the recorder
// draws `LevelRibbon` (in `RecordingView.swift`), which keeps a short history and
// renders it in a `Canvas` rather than as 28 views repainting at 10 Hz.

/// Empty-state block used by Library and Home.
struct EmptyHint: View {

    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}
