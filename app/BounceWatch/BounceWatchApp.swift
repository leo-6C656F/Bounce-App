import SwiftUI

@main
struct BounceWatchApp: App {

    @Environment(\.scenePhase) private var scenePhase
    @State private var connector = WatchConnector.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(connector)
                .tint(.bounceWatch)
        }
        .onChange(of: scenePhase) { _, phase in
            // The watch app is almost always resumed rather than launched, and
            // the phone's state has usually moved on since it was last visible.
            // A `status` request is cheap and is the only way to be sure.
            if phase == .active { connector.refresh() }
        }
    }
}

extension Color {
    /// The app's accent, restated rather than shared.
    ///
    /// `UI/Common/Theme.swift` builds `Color.bounce` from a light/dark `UIColor`
    /// pair, and **`UIColor` does not exist on watchOS** — so that file can't be
    /// compiled into this target, and there is no asset catalog here either. The
    /// value below is `Brand.blueDark` (`#5A92CA`), because a watch face is
    /// always the dark variant's context.
    ///
    /// If `Brand` changes, this changes with it. Nothing enforces that — the same
    /// standing warning `tools/make-icon.swift` carries about the app icon.
    static let bounceWatch = Color(red: 0.353, green: 0.573, blue: 0.792)
}
