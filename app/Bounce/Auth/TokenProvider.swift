import Foundation
import LocalAuthentication
import Observation
@preconcurrency import PlaudDeviceBasicSDK

/// Owns credentials and keeps a valid Plaud user token in front of the SDK.
///
/// This is the piece that makes Bounce work past its first day. Plaud user
/// tokens carry **no refresh mechanism** — the documented example lifetime is
/// 24 hours — so the only way to stay signed in without a backend is to hold
/// `client_id` / `secret_key` and mint a new one when the old one lapses.
///
/// Nothing here is ever written to a build file, a log, or `UserDefaults`. The
/// credentials and the cached token live in the keychain, device-only and
/// non-syncing.
@MainActor
@Observable
final class TokenProvider {

    static let shared = TokenProvider()

    private enum Keys {
        static let credentials = "plaud.credentials"
        static let userToken = "plaud.userToken"
        static let userId = "plaud.userId"
    }

    /// Plaud caps user tokens at 24 hours and rejects anything longer with a
    /// 422, so this asks for the maximum. In practice Bounce re-mints daily,
    /// which `refreshIfNeeded()` does on foreground.
    private static let requestedTokenLifetime = PlaudAuthService.maximumUserTokenLifetime

    private let auth = PlaudAuthService()

    /// True once credentials are stored. Drives onboarding routing.
    private(set) var hasCredentials: Bool
    private(set) var region: PlaudRegion
    /// Non-nil while a mint is in flight, for the UI.
    private(set) var isAuthenticating = false
    private(set) var lastError: String?
    /// When the cached token lapses, shown in Settings.
    private(set) var tokenExpiresAt: Date?

    private var cachedToken: UserToken?
    private var inFlight: Task<String, Error>?

    private init() {
        let credentials = KeychainStore.load(PlaudCredentials.self, for: Keys.credentials)
        hasCredentials = credentials?.isComplete ?? false
        region = credentials?.region ?? .us
        cachedToken = KeychainStore.load(UserToken.self, for: Keys.userToken)
        tokenExpiresAt = cachedToken?.expiresAt
    }

    // MARK: - Stable user id

    /// A stable per-install id, 6–120 characters as Plaud requires. Generated
    /// once and kept, because the recorder's binding is tied to it — changing it
    /// would orphan the paired device.
    var userId: String {
        if let existing = KeychainStore.load(String.self, for: Keys.userId) { return existing }
        let generated = "bounce-" + UUID().uuidString.lowercased()
        try? KeychainStore.save(generated, for: Keys.userId)
        return generated
    }

    // MARK: - Credentials

    func save(_ credentials: PlaudCredentials) async throws {
        AuthLog.log("saving credentials, verifying against Plaud first…")

        // Prove they work before persisting, so a typo can't leave the app
        // wedged in a state where it thinks it's configured.
        let token = try await auth.mintUserToken(
            credentials: credentials,
            userId: userId,
            expiresIn: Self.requestedTokenLifetime
        )
        AuthLog.log("credentials verified, storing in keychain")

        try KeychainStore.save(credentials, for: Keys.credentials)
        try? KeychainStore.save(token, for: Keys.userToken)

        cachedToken = token
        tokenExpiresAt = token.expiresAt
        hasCredentials = true
        region = credentials.region
        lastError = nil

        applyToSDK(token.value)
    }

    func clearCredentials() {
        KeychainStore.delete(Keys.credentials)
        KeychainStore.delete(Keys.userToken)
        cachedToken = nil
        tokenExpiresAt = nil
        hasCredentials = false
        lastError = nil
    }

    /// Read the stored credentials back, behind a biometric / passcode check.
    ///
    /// The keychain items themselves are readable whenever the device is
    /// unlocked — that is deliberate, so token refresh can run in the
    /// background. This gate protects *showing the secret on screen*, which is
    /// the part that benefits from a second factor.
    func revealCredentials(reason: String = "View your Plaud credentials") async -> PlaudCredentials? {
        let context = LAContext()
        context.localizedReason = reason

        var error: NSError?
        // If the device has no passcode there is nothing to check against;
        // fall through rather than locking the user out of their own settings.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return KeychainStore.load(PlaudCredentials.self, for: Keys.credentials)
        }

        do {
            let approved = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard approved else { return nil }
        } catch {
            return nil
        }
        return KeychainStore.load(PlaudCredentials.self, for: Keys.credentials)
    }

    // MARK: - Tokens

    /// The current user token, minting a fresh one if the cached one is spent.
    /// Concurrent callers share one network round trip.
    @discardableResult
    func validToken() async throws -> String {
        if let cachedToken, cachedToken.isValid() {
            return cachedToken.value
        }
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task<String, Error> { try await mint() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func mint() async throws -> String {
        guard let credentials = KeychainStore.load(PlaudCredentials.self, for: Keys.credentials),
              credentials.isComplete
        else {
            throw PlaudAuthService.Failure.invalidCredentials
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let token = try await auth.mintUserToken(
                credentials: credentials,
                userId: userId,
                expiresIn: Self.requestedTokenLifetime
            )
            try? KeychainStore.save(token, for: Keys.userToken)
            cachedToken = token
            tokenExpiresAt = token.expiresAt
            lastError = nil
            applyToSDK(token.value)
            return token.value
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    /// Refresh opportunistically — called when the app foregrounds. Silent by
    /// design: a failure here shouldn't interrupt anything, the next real
    /// request will surface it.
    func refreshIfNeeded() async {
        guard hasCredentials else { return }
        guard cachedToken?.isValid(margin: 3600) != true else { return }
        _ = try? await validToken()
    }

    /// Hand the token to the SDK. `setUserAccessToken` swaps it live, so this
    /// works whether or not `initSDK` has already run.
    private func applyToSDK(_ token: String) {
        PlaudDeviceAgent.shared.setUserAccessToken(token)
    }
}
