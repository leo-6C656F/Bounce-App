import Darwin
import Foundation
import Network
import Observation
import UIKit

/// Owns the desktop view's lifecycle: the listener, the session, and the rules
/// about when all of it is allowed to be running.
///
/// ## Why this is a foreground session by default
///
/// iOS has no services: nothing runs outside the app's process, so surviving an
/// app switch is entirely a question of not being suspended. The app is suspended
/// seconds after it leaves the foreground and the socket dies with it. So the
/// screen is kept awake while the server runs, the server stops when the app
/// backgrounds, and the client is built to expect the server to vanish —
/// `EventSource` reconnects on its own.
///
/// Two things extend that, in order of preference, both handled in
/// `handleScenePhase`:
///
/// 1. **`BackgroundResidency`** — silence played through the `audio` background
///    mode, which keeps the process resident indefinitely. It is behind
///    `BOUNCE_BACKGROUND_DESKTOP` because it is an App Store rejection; read that
///    file for the full survey of what else was considered and why none of it
///    works. When it is holding, backgrounding changes nothing at all.
/// 2. **An active recording** — `bluetooth-central` is declared, and a recording
///    streams `bleData` continuously, so the app is being woken end to end and
///    plausibly never suspends. This is the review-safe half and needs no
///    entitlement, but it is a *hypothesis about scheduler behaviour*, not a
///    guarantee: hence `stayedUpInBackgroundSince`, the `isListening` check on
///    the way back, and the log line that says which way it went.
///
/// Whichever path is taken, a background hold is capped by
/// `backgroundHoldLimitMinutes` — a browser tab left open on a desk keeps
/// `clientCount` above zero forever, so the ordinary idle timeout can never fire
/// and nothing else would stop the phone staying awake overnight.
///
/// Read directly from views as `DesktopServer.shared`, the `DeliverySettings`
/// pattern: this is local state with no SDK callback behind it, so it does not
/// need the `AppModel` seam.
@MainActor
@Observable
final class DesktopServer {

    static let shared = DesktopServer()

    private enum Keys {
        static let port = "desktopViewPort"
        static let autoStopMinutes = "desktopViewAutoStopMinutes"
        static let useTLS = "desktopViewUseTLS"
        static let advertise = "desktopViewAdvertise"
    }

    static let defaultPort: UInt16 = 8080

    // MARK: - Observable state

    private(set) var isRunning = false
    /// The address to type into a browser, e.g. `http://192.168.1.42:8080`.
    private(set) var url: String?
    private(set) var lastError: String?
    /// False when the Bonjour advertisement couldn't be registered — the server
    /// still works, it just has to be reached by IP. Surfaced so the UI can stop
    /// implying a `.local` name will resolve.
    private(set) var isDiscoverable = true

    let session = WebSession()
    private(set) var connectedClients: Int = 0

    var port: UInt16 {
        didSet { UserDefaults.standard.set(Int(port), forKey: Keys.port) }
    }

    /// Minutes of no connected browser before the server shuts itself off. The
    /// point is that this is never left running unnoticed.
    var autoStopMinutes: Int {
        didSet { UserDefaults.standard.set(autoStopMinutes, forKey: Keys.autoStopMinutes) }
    }

    /// Serve over HTTPS with a self-signed certificate. **On by default.**
    ///
    /// The cost is a one-off browser warning per browser per certificate, which
    /// is why this is a toggle at all — but defaulting to cleartext would mean
    /// transcripts, audio and the pairing code readable by anything on the
    /// network, and that is the worse default. See `SelfSignedCertificate` for
    /// what the certificate does and does not prove.
    var useTLS: Bool {
        didSet { UserDefaults.standard.set(useTLS, forKey: Keys.useTLS) }
    }

    /// Advertise the server over Bonjour. **Off by default.**
    ///
    /// It has earned that default the hard way. Registering an mDNS service is
    /// what failed with `kDNSServiceErr_NoAuth` and took the whole listener down
    /// with it, and once it does register, everything on the network that probes
    /// advertised HTTP services connects — each probe aborting the TLS handshake
    /// because it doesn't trust a self-signed certificate, which buries the log
    /// and competes for the connection cap. The address and QR code are on screen
    /// anyway, so discovery buys very little for that.
    var advertiseOnNetwork: Bool {
        didSet { UserDefaults.standard.set(advertiseOnNetwork, forKey: Keys.advertise) }
    }

    /// Connections closed before sending a byte — mostly clients refusing the
    /// certificate. Paired with `hasServedAnything` to tell "noisy network" from
    /// "nothing can connect".
    var refusedConnections: Int { server.rejectedConnections }
    var hasServedAnything: Bool { server.servedRequests > 0 }

    /// SHA-256 of the certificate currently being served, for comparing against
    /// what the browser reports.
    var certificateFingerprint: String? { SelfSignedCertificate.fingerprint }

    /// Forget the certificate, so the next start mints a new one. Every browser
    /// that accepted the old one will warn again.
    func resetCertificate() {
        SelfSignedCertificate.discard()
        if isRunning {
            stop(keepingSessions: true)
            start()
        }
    }

    // MARK: - Internals

    private let server = HTTPServer()
    private let live = LiveChannel()
    private var api: WebAPI?
    /// `weak`, not `unowned`. `AppModel` is created by `@State` in `BounceApp`
    /// and outlives everything here, so neither would dangle today — but this
    /// singleton lives for the whole process, and if ownership ever changes an
    /// `unowned` read traps where a `weak` one falls into the "not wired up yet"
    /// path below.
    private weak var model: AppModel?

    private var watchdog: Task<Void, Never>?
    private var idleSince: Date?
    /// Set when the app backgrounds and the server is deliberately left running.
    /// Nil whenever the app is in the foreground, so it doubles as "we are in the
    /// background right now" for the watchdog's hold cap.
    private var stayedUpInBackgroundSince: Date?
    /// Ceiling on a single background hold, whatever is keeping it alive.
    ///
    /// Not a user setting: the two knobs that already exist (`autoStopMinutes`,
    /// and switching the feature off) cover the cases a user thinks about, and
    /// this one exists purely so a forgotten browser tab can't keep the phone
    /// awake all night — `autoStopMinutes` keys on `clientCount == 0` and an open
    /// tab holds its `EventSource` forever.
    static let backgroundHoldLimitMinutes = 120
    /// Guards against a second `start()` while the first is still waiting on a
    /// keypair.
    private var isStarting = false
    /// Monotonic id for each `start()`. `bringUp` captures the value current when
    /// it launched and re-checks it after the (seconds-long, off-actor) RSA
    /// keygen await; a `stop()` in that window bumps the counter, so the resumed
    /// `bringUp` sees a mismatch and bails instead of bringing a listener up that
    /// was already told to stop. `isStarting` alone couldn't express this — it is
    /// a single bool, and a stop→start pair inside the await window would leave it
    /// `true` again with no way to tell the two starts apart.
    private var startToken = 0
    /// Set when the server was stopped on backgrounding purely because nothing
    /// could hold it up (no residency, no active recording) — the feature is
    /// still enabled and its sessions were kept. On foreground this is what tells
    /// `returnToForeground` to bring the server back, closing the "dead URL after
    /// a brief app-switch" gap. Cleared when the user switches the feature off.
    private var suspendedForBackground = false

    /// Certificate work, off the main actor.
    ///
    /// `sec_identity_t` isn't `Sendable`, so it travels in a box. That's sound
    /// here: the value is created inside the detached task, handed over once, and
    /// only ever read afterwards.
    private struct IdentityBox: @unchecked Sendable {
        let identity: sec_identity_t
    }

    private static func tlsIdentity(for names: Set<String>) async throws -> sec_identity_t {
        try await Task.detached(priority: .userInitiated) {
            IdentityBox(identity: try SelfSignedCertificate.identity(for: names))
        }.value.identity
    }

    private init() {
        let storedPort = UserDefaults.standard.integer(forKey: Keys.port)
        port = storedPort > 0 ? UInt16(storedPort) : Self.defaultPort
        let storedTimeout = UserDefaults.standard.integer(forKey: Keys.autoStopMinutes)
        autoStopMinutes = storedTimeout > 0 ? storedTimeout : 30
        // `object(forKey:)` rather than `bool(forKey:)`, which returns false for
        // an absent key and would silently invert the default.
        useTLS = UserDefaults.standard.object(forKey: Keys.useTLS) as? Bool ?? true
        advertiseOnNetwork = UserDefaults.standard.object(forKey: Keys.advertise) as? Bool ?? false
    }

    /// Hand over the app's single `AppModel`. Called once, from `BounceApp`.
    func attach(model: AppModel) {
        self.model = model
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning, !isStarting else { return }
        launchBringUp(advertiseService: true)
    }

    /// Stamp a fresh `startToken`, mark the start in flight, and launch `bringUp`
    /// bound to that token. The single entry point for both `start()` and the
    /// Bonjour-failure retry, so neither can forget to advance the token.
    private func launchBringUp(advertiseService: Bool) {
        startToken &+= 1
        let token = startToken
        isStarting = true
        Task { await bringUp(advertiseService: advertiseService, token: token) }
    }

    /// Async because minting the TLS certificate generates an RSA keypair, which
    /// takes long enough on device to hang the UI if done inline — and the
    /// watchdog kills an app that hangs the main thread for a few seconds. The
    /// keygen runs detached; everything else here stays on the main actor.
    private func bringUp(advertiseService: Bool, token: Int) async {
        // Only clear `isStarting` if this is still the current start — a newer
        // `launchBringUp` (or a `stop`) has already taken ownership of the flag
        // otherwise, and clearing it here would stomp that.
        defer { if token == startToken { isStarting = false } }
        guard token == startToken, !isRunning else { return }
        guard let model else {
            lastError = "Desktop view isn't wired up yet."
            return
        }

        lastError = nil
        if advertiseService { isDiscoverable = true }
        session.resume()
        let hostNames = Self.currentHostNames()
        session.allowedHosts = hostNames
        // Revoking a browser has to take its live stream with it: the token is
        // checked when the stream opens and never again, so otherwise a revoked
        // client keeps receiving transcripts until the server stops.
        session.onRevoke = { [weak self] token in
            self?.live.closeStreams(token: token)
        }

        // The API token needs the same treatment, and it isn't automatic: only
        // `WebSession` fires `onRevoke`, and `APITokenStore` knows nothing about the
        // server. See `revokeAPIToken()`.

        let api = WebAPI(model: model, session: session, live: live)
        self.api = api

        // The certificate's SAN has to cover whatever host the browser will use,
        // so it is minted against the same name set the Host check accepts.
        var identity: sec_identity_t?
        if useTLS {
            do {
                identity = try await Self.tlsIdentity(for: hostNames)
                // Re-check against the start token: the user may have switched it
                // off (which bumps `startToken` in `stop`) while the keypair was
                // being generated. Without this the guard's old `isStarting` could
                // still read true and the listener would come up despite the stop.
                guard token == startToken, !isRunning else { return }
            } catch {
                // Encryption is a promise the UI makes, so failing to keep it is
                // not something to paper over by quietly serving cleartext.
                lastError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                session.suspend()
                self.api = nil
                return
            }
        }

        do {
            // The failure callback is passed *in* rather than assigned after.
            // `NWListener` doesn't throw for a port already in use — it reports
            // `.failed(EADDRINUSE)` asynchronously — so a callback installed
            // after `start` returns can miss it, leaving the UI advertising a
            // URL for a dead listener.
            WebLog.log("starting on \(useTLS ? "https" : "http") port \(port), "
                + "advertise=\(advertiseService && advertiseOnNetwork), "
                + "hosts=\(hostNames.sorted().joined(separator: " "))")
            try server.start(
                port: port,
                advertiseService: advertiseService && advertiseOnNetwork,
                tlsIdentity: identity,
                onFailure: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.isRunning else { return }
                        // A Bonjour registration failure fails the whole
                        // listener, but the TCP socket underneath it needs no
                        // permission. Drop the advertisement and try again
                        // rather than reporting a dead server the user could
                        // have had.
                        if advertiseService, Self.isBonjourFailure(error) {
                            self.stop(keepingSessions: true)
                            self.isDiscoverable = false
                            self.launchBringUp(advertiseService: false)
                            return
                        }
                        self.lastError = Self.describe(error)
                        self.stop()
                    }
                },
                handler: { [weak api] request, respond in
                    guard let api else {
                        respond(.error(503, "Desktop view is off."))
                        return
                    }
                    api.handle(request, respond: respond)
                })
        } catch {
            lastError = error.localizedDescription
            session.suspend()
            self.api = nil
            return
        }

        isRunning = true
        // A fresh, running listener supersedes any "restore me" marker: it is only
        // meaningful in the window between an auto-suspend and the next foreground,
        // and a stale one would make `returnToForeground` skip its `isListening`
        // repair on a later residency-held cycle.
        suspendedForBackground = false
        // The scheme has to match what is actually being served: pointing a
        // browser at http:// against a TLS listener fails the handshake with an
        // error that reads like the server is broken.
        let scheme = useTLS ? "https" : "http"
        url = Self.primaryAddress().map { "\(scheme)://\($0):\(port)" }
        idleSince = Date()

        // The screen must not lock underneath a server the user is looking at the
        // address of. This stays true even when residency is available: the phone
        // sitting on the desk showing the pairing code is the primary case.
        UIApplication.shared.isIdleTimerDisabled = true
        // Started here, in the foreground, rather than at the moment of
        // backgrounding — arming at the transition races iOS's suspension of the
        // app against the media server. No-op unless the build carries the flag.
        BackgroundResidency.shared.begin()
        startWatchdog()
    }

    /// `keepingSessions` preserves paired browsers so foregrounding restores
    /// them; the user switching the feature off clears everything.
    func stop(keepingSessions: Bool = false) {
        // `isStarting` in the guard so a stop *during* TLS keygen isn't a no-op:
        // `bringUp` has already set `self.api` before the await, so `api != nil`
        // covers it too, but a start that hasn't reached that line yet would slip
        // through without it.
        guard isRunning || api != nil || isStarting else { return }
        // Cancel any in-flight `bringUp`: clear the flag and advance the token so
        // the keygen, when it finishes, sees a mismatch and doesn't start a
        // listener we've just been told to stop.
        isStarting = false
        startToken &+= 1
        // A user switching the feature off is the one path that should *not*
        // restore on foreground; a background auto-suspend keeps the marker.
        if !keepingSessions { suspendedForBackground = false }
        watchdog?.cancel()
        watchdog = nil
        live.closeAll()
        server.stop()
        api = nil
        if keepingSessions {
            session.suspend()
        } else {
            session.onRevoke = nil
            session.end()
        }
        isRunning = false
        url = nil
        connectedClients = 0
        idleSince = nil
        stayedUpInBackgroundSince = nil
        BackgroundResidency.shared.end()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    /// Called from `BounceApp` on every scene-phase change.
    ///
    /// Keyed on `.background`, deliberately **not** on "anything but `.active`".
    /// `.inactive` fires for transient interruptions — pulling down Control
    /// Centre, an incoming-call banner, the app switcher — and tearing the
    /// server down for those would kill a live transcript on a monitor because
    /// the user glanced at a notification. Sessions are kept so foregrounding
    /// doesn't force a fresh six-digit code into every browser.
    func handleScenePhase(isBackground: Bool) {
        if isBackground {
            // Nothing to suspend if it isn't running.
            guard isRunning else { return }
            enterBackground()
        } else {
            // Deliberately *not* guarded on `isRunning`: the whole point of A17's
            // fix is that the server may have been stopped on the way into the
            // background and must be restarted here. `returnToForeground` decides.
            returnToForeground()
        }
    }

    private func enterBackground() {
        // `isHolding`, not "residency is supported": the question is whether
        // silence is *actually playing*, because that is the thing iOS grants
        // residency for. An activation that failed and reads as success is
        // exactly how you end up advertising a URL for a dead listener.
        if BackgroundResidency.shared.isHolding {
            stayedUpInBackgroundSince = Date()
            WebLog.log("backgrounded — staying up on audio residency")
            return
        }

        // Fallback: a recording streams `bleData` continuously and
        // `bluetooth-central` is declared, so the app is being woken end to end.
        // Whether that is enough to keep the listener accepting is not documented
        // anywhere — the log line on the way back out is the measurement, and
        // `returnToForeground` repairs it when the answer is no. Worth trying
        // because this is the case that matters most (walking away from the desk
        // mid-meeting) and it costs no entitlement and no battery.
        if RecordingManager.shared.state.isActive {
            stayedUpInBackgroundSince = Date()
            WebLog.log("backgrounded mid-recording — staying up on BLE wakes (unproven)")
            return
        }

        // Nothing can hold the process up, so the socket is about to die with the
        // app. Stop cleanly but keep the paired browsers, and remember that the
        // feature is still enabled so foregrounding restarts it rather than
        // leaving a dead URL — the bug A17 describes: a five-second glance at
        // another app used to switch the server off for good.
        stop(keepingSessions: true)
        suspendedForBackground = true
    }

    private func returnToForeground() {
        // Restart a server that was suspended on the way into the background. The
        // certificate is cached so this is cheap, and the browser's `EventSource`
        // reconnects on its own.
        if suspendedForBackground {
            suspendedForBackground = false
            WebLog.log("foregrounded — restarting server that was suspended on background")
            start()
            return
        }
        guard let since = stayedUpInBackgroundSince else { return }
        stayedUpInBackgroundSince = nil
        let seconds = Int(Date().timeIntervalSince(since))
        let listening = server.isListening
        WebLog.log("foregrounded after \(seconds)s in background — "
            + "listening=\(listening) clients=\(live.clientCount)")
        guard !listening else { return }

        // The hold didn't hold. Restart rather than surfacing an error: the user
        // has just come back to a screen whose job is to show a working address,
        // the certificate is cached so this is cheap, and the browser's
        // `EventSource` reconnects on its own. The log line above is where the
        // diagnosis lives.
        stop(keepingSessions: true)
        start()
    }

    /// Revoke the API token and cut off anything it has open.
    ///
    /// **Revoking the keychain entry alone is not enough.** A `/api/live` stream is
    /// authenticated once, when it opens, and never re-checked — so a bearer client
    /// tailing live transcripts would keep receiving them after revocation, for as
    /// long as the app stayed open. That's the exact hole `WebSession.onRevoke` →
    /// `closeStreams` exists to close for browsers, and it matters more here because
    /// a bearer token is durable by design.
    ///
    /// This is the only correct way to revoke; call it rather than
    /// `APITokenStore.clear()`. Ordinary request/response routes need nothing —
    /// `APITokenStore.matches` re-reads the keychain per call, so they 401 on the
    /// very next request.
    func revokeAPIToken() {
        guard let previous = APITokenStore.revoke() else { return }
        live.closeStreams(token: previous)
    }

    // MARK: - Watchdog

    /// One second tick doing three jobs: prune dead sockets, trip the idle
    /// timeout, and shut down if the pairing-attempt cap was hit.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRunning else { return }

                self.live.removeClosed()
                self.connectedClients = self.live.clientCount

                // A phone call or Siri stops the keep-alive player, which silently
                // converts a background-capable session into one that dies at the
                // next app switch. Cheaper to repair here than to own a timer.
                BackgroundResidency.shared.recoverIfNeeded()

                // Cap on a single background hold. Checked before the idle timeout
                // because the case it exists for is the one the idle timeout can
                // never catch: a browser tab left open holds `clientCount` above
                // zero indefinitely.
                if let since = self.stayedUpInBackgroundSince,
                   Date().timeIntervalSince(since) / 60 >= Double(Self.backgroundHoldLimitMinutes) {
                    self.lastError = "Desktop view switched off after "
                        + "\(Self.backgroundHoldLimitMinutes / 60) hours in the background."
                    self.stop()
                    return
                }

                // Lockout is enforced per source address inside `WebSession.pair`
                // and no longer tears the whole listener down — a hostile guesser
                // on the LAN used to be able to reach a shared global counter with
                // zero credentials and take every already-paired browser's session
                // down with it. Blocking that one address is enough.

                // Idle means "no browser has the page open", which is the live
                // channel's client count — a browser holds an `EventSource` for
                // as long as the tab is up. Deliberately *not* keyed on
                // `session.clients`: a paired browser stays in that list until
                // it's revoked, so once anyone had ever connected the timeout
                // would never fire again and the server would run until the app
                // backgrounded.
                //
                // A recording in progress is never idle, whatever the browser is
                // doing. Walking away from the desk mid-meeting is the normal
                // case, and shutting the server down then is the one moment it
                // most needs to still be there when you come back.
                let recording = RecordingManager.shared.state.isActive
                if self.live.clientCount == 0, !recording {
                    if let since = self.idleSince {
                        let minutes = Date().timeIntervalSince(since) / 60
                        if self.autoStopMinutes > 0, minutes >= Double(self.autoStopMinutes) {
                            self.lastError = "Desktop view switched off after "
                                + "\(self.autoStopMinutes) minutes with nothing connected."
                            self.stop()
                            return
                        }
                    } else {
                        self.idleSince = Date()
                    }
                } else {
                    self.idleSince = nil
                }
            }
        }
    }

    /// True for an mDNS/Bonjour registration failure, as opposed to a problem
    /// with the TCP socket itself. `NWListener` surfaces both as `.failed`.
    private static func isBonjourFailure(_ error: Error) -> Bool {
        guard let nwError = error as? NWError else { return false }
        if case .dns = nwError { return true }
        return false
    }

    private static func describe(_ error: Error) -> String {
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(.EADDRINUSE):
                return "Port \(DesktopServer.shared.port) is already in use — pick a different one."
            case .posix(.EACCES), .posix(.EPERM):
                return "iOS refused the connection. Allow Local Network access for Bounce in "
                    + "iOS Settings › Privacy & Security › Local Network."
            default:
                break
            }
        }
        let text = error.localizedDescription
        if text.contains("in use") || "\(error)".contains("addressInUse") {
            return "Port already in use — pick a different one."
        }
        return text
    }

    // MARK: - Addresses

    /// Every name a request is allowed to claim in its `Host` header. Anything
    /// else is refused — see `WebSession.isAllowedHost` for why that matters.
    ///
    /// Deliberately **no `.local` name of any kind** — not the device hostname,
    /// not the Bonjour service name. Every one of them is an mDNS answer, and
    /// mDNS answers are claimed by whoever responds to the multicast query with
    /// an attacker-chosen TTL: a device on the same network can advertise
    /// `bounce.local` (or the phone's own hostname) at its own address, serve a
    /// page, then re-point the name at the real phone — a rebind onto a Host
    /// this check would have accepted. An exact-match `.local` entry narrows
    /// that from "any suffix" to "one specific name" but doesn't remove the
    /// technique, so only the IP addresses actually shown in the UI/QR code are
    /// trusted here.
    private static func currentHostNames() -> Set<String> {
        var names: Set<String> = ["localhost", "127.0.0.1"]
        for address in localAddresses() { names.insert(address.lowercased()) }
        return names
    }

    /// Prefer wifi (`en0`); anything else is a fallback for tethering setups.
    static func primaryAddress() -> String? {
        let addresses = localAddressesByInterface()
        return addresses["en0"] ?? addresses.values.first
    }

    private static func localAddresses() -> [String] {
        Array(localAddressesByInterface().values)
    }

    /// IPv4 addresses on wifi/ethernet only.
    ///
    /// Deliberately **not** every interface. A phone also has the cellular CLAT
    /// addresses `192.0.0.2`/`192.0.0.6` (464XLAT) and, when DHCP hasn't landed,
    /// a `169.254.x.x` link-local — none of which a browser on your desk can
    /// reach. Worse, they come and go, and the TLS certificate is minted against
    /// this set: every change discarded the certificate and generated a fresh
    /// RSA keypair, which is expensive and invalidated every browser's stored
    /// exception. Restricting to `en*` keeps the set stable across a session.
    private static func localAddressesByInterface() -> [String: String] {
        var result: [String: String] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            // `en0` is wifi, `en1`+ are ethernet/adapters. Skips `pdp_ip*`
            // (cellular), `utun*` (VPN), `awdl0`/`llw0` (peer-to-peer).
            let interface = String(cString: pointer.pointee.ifa_name)
            guard interface.hasPrefix("en") else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }

            let address = String(cString: buffer)
            // A link-local address means DHCP hasn't finished; it isn't routable
            // from a desk browser and it churns, so keep it out of the
            // certificate.
            guard !address.hasPrefix("169.254.") else { continue }
            if result[interface] == nil { result[interface] = address }
        }
        return result
    }
}
