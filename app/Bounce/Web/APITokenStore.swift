import Foundation

/// Keychain storage for the long-lived API token.
///
/// Split out of `APIToken.swift` so the format and comparison logic stays
/// importable — and testable by `tools/api-token-tests` — without the `Security`
/// framework or a keychain on the machine running the tests. Everything
/// security-critical about the *token* is in `APITokenFormat`; everything here
/// is about where the bytes sit at rest.
///
/// Mirrors `Soniox.Credentials` exactly, which mirrors the Plaud credentials:
/// `KeychainStore` applies `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
/// `kSecAttrSynchronizable: false`, and both matter more here than anywhere else
/// in the app:
///
/// - **`ThisDeviceOnly`** keeps the token out of an encrypted Finder/iTunes
///   backup. A backup that carried it would be a second, offline copy of a
///   credential that reads every transcript, and revoking on the phone would not
///   touch it.
/// - **`kSecAttrSynchronizable: false`** keeps it off iCloud Keychain. The token
///   authenticates against *this phone's* LAN server; replicating it to every
///   device on the Apple ID copies the secret without copying anything that can
///   use it.
/// - **`WhenUnlocked`** rather than `AfterFirstUnlock` is a deliberate small
///   cost: the desktop server can't authenticate a request while the phone is
///   locked. That is the correct answer for a feature the user switches on while
///   looking at the phone.
///
/// Only one token exists at a time. Generating replaces; revoking deletes. There
/// is no list of issued tokens because there is nothing useful to do with one —
/// a token is not attributable to a client the way a paired browser is.
enum APITokenStore {

    private static let key = "web_api_token"

    /// The stored token, or nil if none has been generated (or the device is
    /// locked, which reads the same as absent — and correctly denies the
    /// request either way).
    static var token: String? {
        guard let data = KeychainStore.loadData(for: key),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static var hasToken: Bool { token != nil }

    /// Mint a new token, persist it, and hand it back **once** for display.
    ///
    /// The caller shows it so the user can copy it into an agent's config. It is
    /// readable again from `token` — this is a local API key, not a password
    /// hash, and the server has to be able to compare against it — but the UI
    /// should still treat the moment of generation as the moment to copy.
    @discardableResult
    static func generate() throws -> String {
        let value = APITokenFormat.generate()
        try save(value)
        return value
    }

    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return }
        try KeychainStore.saveData(Data(trimmed.utf8), for: key)
    }

    /// Revoke. Takes effect on the next request — there is no cached copy.
    static func clear() { KeychainStore.delete(key) }

    /// Revoke, handing back the token that was in force.
    ///
    /// Exists because "the next request is denied" is not the whole of
    /// revocation: an SSE stream on `/api/live` is authorised once, when it
    /// opens, and then never again — so a stream a revoked token already has
    /// open keeps receiving live transcripts until the server stops. That is the
    /// hole `WebSession.onRevoke` → `LiveChannel.closeStreams(token:)` exists to
    /// close for browsers, and it needs the *old* value to find the subscriber,
    /// which is gone the moment `clear()` runs.
    ///
    /// Callers that own a `LiveChannel` should close streams with the returned
    /// value. Nothing is done here: this type deliberately knows nothing about
    /// the server or the channel.
    @discardableResult
    static func revoke() -> String? {
        let previous = token
        clear()
        return previous
    }

    /// The auth check. Constant-time, and false when no token has been
    /// generated so revoking is immediate and total.
    ///
    /// Reads the keychain per call rather than caching, which is what makes
    /// revocation instant; at LAN request volumes the read is not worth a cache
    /// that would need invalidating.
    static func matches(_ candidate: String?) -> Bool {
        guard let candidate, let stored = token else { return false }
        return APITokenFormat.matches(candidate, stored)
    }

    /// For display and logs. Never render `token` directly.
    static var redactedToken: String {
        APITokenFormat.redacted(token ?? "")
    }
}
