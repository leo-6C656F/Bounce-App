import Foundation
import Observation

/// Access control for the desktop view.
///
/// The threat this defends against is not a targeted attacker — it is that
/// **every other device on the network can reach this port**, and the app holds
/// transcripts of the user's meetings. Office wifi, guest wifi and coffee-shop
/// wifi are all "the local network".
///
/// Four independent gates, because each covers a case the others don't:
///
/// 1. **A pairing code**, so reaching the port isn't the same as reading the
///    library. Entering it requires physically holding the phone.
/// 2. **Host-header validation**, which is the non-obvious one. Without it any
///    website the user visits can have its JavaScript fetch this server from
///    inside the user's own browser — carrying the session cookie — and read
///    everything back out. That is DNS rebinding, and a token alone does not
///    stop it.
/// 3. **A same-site check on pairing**, so a cross-origin page can't reach the
///    one unauthenticated `POST` (see `HTTPRequest.isCrossSite`).
/// 4. **A failed-attempt cap**, so a six-digit code can't be walked through.
///
/// Everything here is in-memory and dies with the app, on purpose: there is no
/// persisted trust for a feature meant to be switched on for an hour at a time.
@MainActor
@Observable
final class WebSession {

    /// Six digits is enough given the attempt cap below; longer codes are worse
    /// UX and buy nothing once guessing is bounded at five tries.
    private static let codeDigits = 6
    private static let maxFailedAttempts = 5

    struct Client: Identifiable, Hashable {
        let id: String
        let address: String
        let userAgent: String
        let pairedAt: Date

        /// "Safari on macOS" out of a User-Agent, best effort — this is a label
        /// in a list the user reads, not something logic depends on.
        var displayName: String {
            let browser: String
            if userAgent.contains("Firefox") { browser = "Firefox" }
            else if userAgent.contains("Edg/") { browser = "Edge" }
            else if userAgent.contains("Chrome") { browser = "Chrome" }
            else if userAgent.contains("Safari") { browser = "Safari" }
            else { browser = "Browser" }

            let platform: String
            if userAgent.contains("Macintosh") { platform = "macOS" }
            else if userAgent.contains("Windows") { platform = "Windows" }
            else if userAgent.contains("Linux") { platform = "Linux" }
            else if userAgent.contains("iPhone") || userAgent.contains("iPad") { platform = "iOS" }
            else { return browser }

            return "\(browser) on \(platform)"
        }
    }

    /// Shown on the phone while the server runs. Rotated after every successful
    /// pair so a code read over someone's shoulder is already spent.
    private(set) var pairingCode: String = ""
    private(set) var clients: [Client] = []

    /// Keyed by source address, not global — a hostile device on the LAN
    /// guessing wrong codes must only ever cost itself the ability to pair,
    /// never take the whole server down for every already-paired browser.
    /// A single shared counter turned the anti-brute-force cap into a one-shot
    /// unauthenticated denial-of-service switch anyone on the network could
    /// reach with zero credentials.
    private(set) var failedAttempts: [String: Int] = [:]
    private(set) var lockedOutAddresses: Set<String> = []

    /// Bounds `failedAttempts`/`lockedOutAddresses` for the life of one
    /// session. The per-address fix above stops one hostile device from
    /// taking the whole server down, but a single device can still present
    /// many distinct *source* addresses cheaply (IPv6 privacy addresses
    /// rotate on their own; nothing stops binding several on one interface),
    /// each costing only one wrong-code POST to add an entry — otherwise
    /// unbounded for as long as the session runs. Same FIFO-eviction shape as
    /// `TaskWebhook.sentIdLimit`: the oldest tracked address simply gets a
    /// fresh attempt budget again, which is a fine trade against unbounded
    /// growth.
    private static let maxTrackedAddresses = 256
    private var trackedAddressOrder: [String] = []

    /// Host values a request may claim. Filled in by `DesktopServer` once it
    /// knows the phone's address on the current network.
    var allowedHosts: Set<String> = []

    /// Fires when a client's authorization is withdrawn, so `LiveChannel` can
    /// drop any event stream that client already had open. Without this a
    /// revoked browser keeps receiving live transcripts: the token is checked
    /// when the stream opens and never again.
    var onRevoke: ((String) -> Void)?

    // MARK: - Lifecycle

    /// Bring the session up, keeping any browsers that are still paired.
    ///
    /// Deliberately not a full reset: the server stops and restarts around
    /// backgrounding, and clearing tokens there would mean re-typing a fresh
    /// six-digit code into every browser after glancing at another app.
    func resume() {
        if pairingCode.isEmpty { pairingCode = Self.makeCode() }
        failedAttempts = [:]
        lockedOutAddresses = []
        trackedAddressOrder = []
    }

    /// Stop serving but keep paired browsers, so foregrounding restores them.
    func suspend() {
        allowedHosts = []
    }

    /// Full reset — the user switched the feature off.
    func end() {
        let revoked = clients.map(\.id)
        pairingCode = ""
        clients = []
        allowedHosts = []
        failedAttempts = [:]
        lockedOutAddresses = []
        trackedAddressOrder = []
        for token in revoked { onRevoke?(token) }
    }

    // MARK: - Pairing

    enum PairResult {
        case paired(token: String)
        case wrongCode(remainingAttempts: Int)
        case lockedOut
    }

    /// Per-address, not global. A wrong-code cap that shares one counter across
    /// every source turns itself into the vulnerability it exists to prevent:
    /// any device on the LAN can walk it to the limit with zero credentials and
    /// take the whole feature down for everyone already paired. Scoping to the
    /// address means a hostile guesser only ever locks itself out.
    func pair(code: String, address: String, userAgent: String) -> PairResult {
        guard !lockedOutAddresses.contains(address) else { return .lockedOut }

        let submitted = code.filter(\.isNumber)
        guard !pairingCode.isEmpty, Self.constantTimeEqual(submitted, pairingCode) else {
            trackAddress(address)
            let attempts = (failedAttempts[address] ?? 0) + 1
            failedAttempts[address] = attempts
            if attempts >= Self.maxFailedAttempts {
                lockedOutAddresses.insert(address)
                return .lockedOut
            }
            return .wrongCode(remainingAttempts: Self.maxFailedAttempts - attempts)
        }

        let token = Self.makeToken()
        clients.append(Client(id: token, address: address, userAgent: userAgent, pairedAt: Date()))
        // Spend the code and issue a fresh one for the next browser.
        pairingCode = Self.makeCode()
        failedAttempts[address] = 0
        return .paired(token: token)
    }

    /// Records `address` in eviction order the first time it shows up with a
    /// failed attempt, evicting the oldest tracked address once the cap is
    /// exceeded so `failedAttempts`/`lockedOutAddresses` can't grow past
    /// `maxTrackedAddresses` for the life of the session.
    private func trackAddress(_ address: String) {
        guard failedAttempts[address] == nil else { return }
        trackedAddressOrder.append(address)
        guard trackedAddressOrder.count > Self.maxTrackedAddresses else { return }
        let evicted = trackedAddressOrder.removeFirst()
        failedAttempts.removeValue(forKey: evicted)
        lockedOutAddresses.remove(evicted)
    }

    func isAuthorized(token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return clients.contains { Self.constantTimeEqual($0.id, token) }
    }

    func revoke(_ client: Client) {
        clients.removeAll { $0.id == client.id }
        onRevoke?(client.id)
    }

    func revokeAll() {
        let revoked = clients.map(\.id)
        clients.removeAll()
        for token in revoked { onRevoke?(token) }
    }

    // MARK: - Host validation

    /// Reject requests that don't address the phone by an expected name.
    ///
    /// A browser sends the host the *user typed*. A malicious page can make the
    /// browser connect here, but it cannot make it lie about the Host header —
    /// so checking it is what stops a page at `evil.example` from reading the
    /// library through the user's own browser session.
    func isAllowedHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let lowered = host.lowercased()
        if allowedHosts.contains(lowered) { return true }
        // Any literal IPv4 on a private range is this phone on some interface —
        // the address can change under the app (wifi handover, hotspot) faster
        // than `allowedHosts` is refreshed.
        //
        // Deliberately **not** a `.hasSuffix(".local")` match, which was here
        // briefly and is unsound: mDNS names are claimed by whoever answers the
        // multicast query, with an attacker-chosen TTL, so a device on the same
        // network can advertise `evil.local` at its own address, serve a page,
        // then re-point the name at the phone. That is a rebind onto a Host this
        // check would have accepted. The real Bonjour name is added to
        // `allowedHosts` by `DesktopServer` instead.
        return Self.isPrivateIPv4(lowered)
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }),
              let a = UInt8(parts[0]), let b = UInt8(parts[1])
        else { return false }
        if a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 169 && b == 254 { return true }   // link-local
        return false
    }

    // MARK: - Secrets

    private static func makeCode() -> String {
        (0..<codeDigits).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    /// 256 bits from the system CSPRNG. `UUID` would be 122 bits of entropy and
    /// is meant for identity, not for holding a door shut.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Not strictly necessary — the five-attempt cap forecloses the sample count
    /// a timing attack needs, and 256 bits of token is not walkable regardless —
    /// but it is three lines and removes the question.
    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
