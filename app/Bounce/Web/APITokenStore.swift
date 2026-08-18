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

    /// In-memory copy of the token, so a bearer request doesn't hit the keychain
    /// on every call.
    ///
    /// The read used to go to the keychain per request, which made revocation
    /// instant at the cost of serializing a synchronous `SecItemCopyMatching` on
    /// the main actor under any request storm (a single detail view fans out to
    /// `/detail` + `/audio` + `/waveform`; an agent hits it every call). This
    /// caches instead, and stays correct because **this app is the only writer of
    /// this keychain item** — every mutation goes through `save`/`clear` below,
    /// which invalidate the cache, so revocation is still immediate and total.
    /// `.loaded == false` means "not yet read"; a loaded `nil` means "read, and
    /// there is no token" (also how a locked device reads — correctly denied).
    private static let cacheLock = NSLock()
    private static var cache: (loaded: Bool, value: String?) = (false, nil)

    /// The stored token, or nil if none has been generated (or the device is
    /// locked, which reads the same as absent — and correctly denies the
    /// request either way).
    static var token: String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache.loaded { return cache.value }
        let value = loadFromKeychain()
        cache = (true, value)
        return value
    }

    private static func loadFromKeychain() -> String? {
        guard let data = KeychainStore.loadData(for: key),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Drop the in-memory copy so the next read re-consults the keychain. Called
    /// from every path that changes the stored token.
    private static func invalidateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache = (false, nil)
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
        invalidateCache()
    }

    /// Revoke. Takes effect on the next request — the in-memory copy is dropped
    /// here, so `matches` re-reads the (now empty) keychain immediately.
    static func clear() {
        KeychainStore.delete(key)
        invalidateCache()
    }

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
    /// Reads through the in-memory cache (see `token`), which every mutation
    /// invalidates — so revocation is still instant while a request storm no
    /// longer serializes a keychain read on the main actor per call.
    static func matches(_ candidate: String?) -> Bool {
        guard let candidate, let stored = token else { return false }
        return APITokenFormat.matches(candidate, stored)
    }

    /// For display and logs. Never render `token` directly.
    static var redactedToken: String {
        APITokenFormat.redacted(token ?? "")
    }
}
