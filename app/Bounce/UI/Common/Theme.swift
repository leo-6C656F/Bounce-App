import SwiftUI

/// **The canonical brand palette. This table is the source of truth.**
///
/// Brand colour lives in code rather than in the asset catalog: keeping the
/// light and dark values next to each other in readable form beats burying
/// them in JSON. But four *other* files need the same numbers and cannot
/// import this one — a standalone `swift` script and an asset catalog's JSON
/// have no way to read a Swift constant. So they carry copies:
///
/// 1. `tools/make-icon.swift` — the icon background gradient's middle stop.
/// 2. `tools/make-launch-logo.swift` — the launch mark's gradient, light and dark.
/// 3. `app/Bounce/Resources/Assets.xcassets/AccentColor.colorset`.
/// 4. `app/BounceWidgets/Assets.xcassets/AccentColor.colorset` — the widget
///    extension has its own bundle and never sees `RootView`'s `.tint(.bounce)`,
///    so it needs its own copy to render brand-coloured rather than system blue.
///
/// The two scripts carry a comment pointing back here. The colorsets can't —
/// `Contents.json` is strict JSON, and `actool` isn't worth risking an unknown
/// key for. So the real enforcement is
/// **`tools/check-brand-colors.swift`, which compares all five and exits
/// nonzero on drift** — run `swift tools/check-brand-colors.swift` from the
/// repo root after changing anything in this enum. Nothing runs it
/// automatically; there is no CI and no test target.
///
/// Components are sRGB, 0…1, rounded to three places — which is the precision
/// an `.xcassets` `Contents.json` stores, so the two can compare exactly.
enum Brand {

    /// `#1E518A` — a deep, slightly desaturated blue.
    static let blueLight = (red: 0.118, green: 0.318, blue: 0.541)
    /// `#5A92CA` — lifted for dark mode; the same hue, not a brightened tint.
    static let blueDark = (red: 0.353, green: 0.573, blue: 0.792)

    /// `#9A6A0C` — the warm highlight accent, dark enough to read as text on a
    /// light background.
    static let goldLight = (red: 0.604, green: 0.416, blue: 0.047)
    /// `#F0B23C` — the same accent for dark mode.
    static let goldDark = (red: 0.941, green: 0.698, blue: 0.235)
}

extension Color {

    /// The brand blue. The app's primary tint, applied once at `RootView`.
    static let bounce = Color(light: Color(brand: Brand.blueLight), dark: Color(brand: Brand.blueDark))

    /// The live recorder's surface.
    ///
    /// **Fixed, not a light/dark pair.** `RecordingView` forces
    /// `.preferredColorScheme(.dark)` so the transcript rows it shares with the
    /// detail screen resolve light-on-dark; a colour that flipped with the system
    /// scheme would put a white surface under white text in Light Mode. Near-black
    /// with a blue cast rather than pure black, so the brand tint and the red
    /// transport read as lit rather than as stickers.
    static let consoleBackground = Color(red: 0.055, green: 0.078, blue: 0.125)

    /// The second accent, reserved for **"you marked this"** meanings —
    /// highlight ticks on the waveform and the highlight chip row.
    ///
    /// Deliberately narrow. Recording state, category tints and sent badges are
    /// *not* this colour: a second accent that appears everywhere is just a
    /// second default, and the point is that gold means one thing. The same
    /// amber is used for marks in the desk web view, so both surfaces agree.
    static let bounceGold = Color(light: Color(brand: Brand.goldLight), dark: Color(brand: Brand.goldDark))
}

/// Radii and paddings shared across `UI/`, collected so a corner or spacing
/// change doesn't require an archaeological dig through a dozen files.
/// Concentric surfaces (Phase 0.3 of `docs/plans/ios26-ui-refresh.md`) derive
/// their inner radius from `.rect(corners: .concentric)` instead of a second
/// literal, so only the outer radius needs a token at all.
enum Metrics {
    /// `ContentCard`'s corner radius, and other top-level card-ish surfaces.
    static let cardRadius: CGFloat = 20
    /// `PlayerBar`'s corner radius.
    static let playerBarRadius: CGFloat = 24
    /// Inset text fields (`AskView.askField`) and similar secondary surfaces.
    static let fieldRadius: CGFloat = 14

    static let cardPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 18
    static let contentSpacing: CGFloat = 16
    static let compactSpacing: CGFloat = 12

    /// Extra leading for transcript paragraphs, on top of the font's own line
    /// height. The desktop client sets `1.7` (`WebClient/index.html`, `.said`),
    /// but that column is 68 characters wide and a phone's is closer to 38 after
    /// the timecode rail and the screen margins — the same ratio there strands
    /// lines. This lands nearer `1.5`. Apply through `@ScaledMetric` so it grows
    /// with the text rather than closing up at large Dynamic Type.
    static let readingLineSpacing: CGFloat = 5
}

/// The two faces, and which text gets which.
///
/// Transcripts and the recording's own title are set in the serif; every other
/// piece of text in the app stays in the UI face. That split is not decoration —
/// it is the same one the desktop client makes (`WebClient/index.html`:
/// `--font-read` for `.said` and `#title`, `--font-ui` for chrome), and it says
/// that a transcript is a document you read rather than the contents of a
/// window. Keep the two clients in step if either changes.
extension Font {

    /// Transcript paragraphs, live and final.
    static let reading = Font.system(.body, design: .serif)

    /// The recording's title at the head of the detail screen.
    static let readingTitle = Font.system(.largeTitle, design: .serif).weight(.semibold)
}

extension Color {
    /// Builds a colour from one of `Brand`'s sRGB component triples.
    init(brand components: (red: Double, green: Double, blue: Double)) {
        self.init(red: components.red, green: components.green, blue: components.blue)
    }

    /// Light/dark pair without an asset catalog.
    init(light: Color, dark: Color) {
        self.init(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
            }
        )
    }
}
