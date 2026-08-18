import SwiftUI

@main
struct BounceApp: App {

    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.bounce)
                .task {
                    // Minting a token is a network call, so the SDK comes up
                    // here rather than in `init`.
                    DesktopServer.shared.attach(model: model)
                    // Same seam, same reason: a singleton that needs the model
                    // but is created before it. Activating the session here
                    // rather than in `init` means it is never live without a
                    // model to answer a wrist tap with.
                    WatchBridge.shared.attach(model: model)
                    if RecordingStore.shared.hasPairedDevice {
                        await model.configureSDK()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Refreshes the token, then rescans. BLE needs a moment
                    // after foregrounding; the manager owns that delay and the
                    // already-connected check.
                    if phase == .active { model.handleForeground() }
                    // The desktop server is foreground-only: iOS suspends the
                    // app behind it and the socket dies anyway, so stop it
                    // deliberately rather than leaving a half-dead listener and
                    // the idle timer disabled. `.background` only — `.inactive`
                    // fires for Control Centre and notification banners.
                    DesktopServer.shared.handleScenePhase(isBackground: phase == .background)
                    // Library saves are off-main and debounced, so a mutation in
                    // the last ~150 ms before suspension could still be in flight.
                    // Force it to disk synchronously before the OS can suspend us.
                    // `.inactive` (not just `.background`) so a mutation made right
                    // before an app-switch or lock is durable too.
                    if phase != .active { RecordingStore.shared.flush() }
                }
        }
    }
}
