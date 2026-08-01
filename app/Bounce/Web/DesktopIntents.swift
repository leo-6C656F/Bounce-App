import AppIntents
import Foundation

/// Shortcuts actions for the desktop view, so an automation can turn it on
/// without the user opening Bounce and finding the toggle.
///
/// ## Why this is the answer to "can something start the app when it isn't running"
///
/// Nothing outside the phone can. When Bounce isn't running there is no listener,
/// so there is nothing on the network to knock on, and iOS has no equivalent of
/// wake-on-LAN for an app. The mechanisms that *can* launch a terminated app are
/// all worse than this one:
///
/// - **Silent push (`content-available`)** needs an APNs server, an internet
///   connection, and is explicitly throttled and opportunistic — iOS may simply
///   not deliver it. Wrong tool for "it must be up when I sit down".
/// - **PushKit VoIP push** launches reliably but iOS 13+ requires reporting a
///   CallKit call for every one, or the app is killed and eventually blocked.
/// - **CoreBluetooth state restoration** genuinely relaunches a terminated app
///   when a preserved peripheral turns up, which would be perfect for "press
///   record on the Plaud and Bounce wakes up" — but it requires owning the
///   `CBCentralManager` that does the scanning, and the SDK owns that one.
///   `BluetoothMonitor`'s fallback central scans with `nil` services, and iOS
///   does not preserve service-less scans. See CLAUDE.md on why claiming
///   `BleAgent`'s delegate isn't an option either.
/// - **`NEAppPushProvider`** is started by the system on joining a designated
///   wifi network — the closest thing to what was asked for — but see
///   `BackgroundResidency` for why that entitlement is out of reach.
///
/// A **Shortcuts personal automation** running `StartDesktopViewIntent` needs
/// none of that: trigger it on joining your desk wifi, tapping an NFC sticker, a
/// time of day, or the recorder connecting over Bluetooth. Combined with
/// `BackgroundResidency`, the app then stays up after you switch away, which is
/// the half that used not to work.
///
/// **`openAppWhenRun` is `true`, and that is not a stylistic choice.**
/// `DesktopServer.start()` fails with "isn't wired up yet" unless
/// `attach(model:)` has run, and that happens in `BounceApp`'s scene — so the
/// server cannot currently be started by an intent that runs headlessly.
/// Making the background-launch variant work means promoting `AppModel` to a
/// singleton, which is a much larger change than this file. The practical cost is
/// that the automation brings Bounce to the foreground for a moment, and that the
/// phone must be unlocked for a personal automation to open an app.
struct StartDesktopViewIntent: AppIntent {

    static var title: LocalizedStringResource { "Start Desktop View" }
    static var description: IntentDescription {
        IntentDescription(
            "Turns on the desktop view and reports the address to open in a browser.",
            categoryName: "Desktop view")
    }
    /// See the type comment: the server needs the app's `AppModel`, which only
    /// exists once the scene has come up.
    static var openAppWhenRun: Bool { true }

    /// How long to wait for the listener. Generous because a first run mints a
    /// self-signed certificate, and generating an RSA keypair on device is the
    /// slow part — several seconds, once, per certificate.
    private static let startTimeout: Duration = .seconds(12)

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let server = DesktopServer.shared
        if !server.isRunning { server.start() }

        // `start()` returns before the listener is up: the keypair is generated
        // off the main actor. Poll rather than reporting a URL that doesn't exist
        // yet — an automation's whole value is that nobody is watching it.
        var waited: Duration = .zero
        let step: Duration = .milliseconds(250)
        while !server.isRunning, waited < Self.startTimeout, server.lastError == nil {
            try? await Task.sleep(for: step)
            waited += step
        }

        guard server.isRunning, let url = server.url else {
            throw DesktopIntentError.couldNotStart(server.lastError)
        }
        return .result(dialog: "Desktop view is on at \(url). Pairing code \(server.session.pairingCode).")
    }
}

/// The other half, so an automation can close it again — leaving your desk,
/// end of the day, a Focus change.
struct StopDesktopViewIntent: AppIntent {

    static var title: LocalizedStringResource { "Stop Desktop View" }
    static var description: IntentDescription {
        IntentDescription(
            "Turns off the desktop view and disconnects any browsers.",
            categoryName: "Desktop view")
    }
    /// Unlike starting, this needs nothing from the UI — and if Bounce isn't
    /// running there is nothing serving anyway, so the call is a no-op rather
    /// than an error.
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        DesktopServer.shared.stop()
        return .result()
    }
}

enum DesktopIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    /// Carries the server's own message where there is one — "port already in
    /// use", "iOS refused the connection" and the rest are actionable, and an
    /// automation that just says "couldn't start" sends the user hunting.
    case couldNotStart(String?)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .couldNotStart(let reason):
            if let reason { return "Couldn't start desktop view. \(reason)" }
            return "Couldn't start desktop view — Bounce isn't on a network it can see."
        }
    }
}
