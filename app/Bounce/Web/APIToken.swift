import Foundation

/// Format and comparison rules for the long-lived API token.
///
/// **Why this exists separately from the browser session cookie.** The cookie
/// `WebSession` issues is deliberately a *session* cookie — "the state it
/// authenticates lives in memory and dies with the app" — and `WebSession`'s
/// whole comment block says the same thing about its clients: nothing is
/// persisted, because there is no persisted trust for a feature meant to be
/// switched on for an hour at a time. An agent (Claude Desktop over MCP, a
/// script, a cron job) cannot work that way: it needs a credential it can put
/// in a config file once.
///
/// So this token is a **materially larger exposure than the cookie**, and is
/// treated as one:
///
/// - It grants read access to every transcript on the phone until it is
///   revoked. Not for an hour — until revoked.
/// - It is a credential in the sense of `CLAUDE.md`: never printed, never in a
///   URL query string, keychain-only at rest (see `APITokenStore`).
/// - It does **not** replace the host check or the same-site check in
///   `WebAPI.route`. Those stop a web page the user happens to be browsing from
///   driving this server from inside their own browser, and a bearer token does
///   nothing about that. The token is an *additional* way through the third
///   gate, not a way around the first two.
///
/// This type is pure — Foundation only, no `Security`, no keychain, no main
/// actor — so the security-critical parts (entropy, constant-time comparison,
/// header parsing, redaction) can be exercised by `tools/api-token-tests`
/// without touching a keychain. The storage half lives in `APITokenStore.swift`.
enum APITokenFormat {

    // MARK: - Shape

    /// Recognisable, greppable, and identifiable at a glance in a config file
    /// or a leaked paste. If this string ever shows up in a log or a gist, it is
    /// obvious what it is and that it needs revoking.
    static let prefix = "bnc_"

    /// 32 symbols: lowercase letters and digits, minus the four that get
    /// misread when a human retypes one — `0`/`O` and `1`/`l`. A power-of-two
    /// alphabet also means a random byte can be masked down to an index with no
    /// modulo bias (see `generate`).
    static let alphabet = Array("23456789abcdefghijkmnpqrstuvwxyz")

    /// 32 symbols from a 32-symbol alphabet = 5 bits each = **160 bits of
    /// entropy**, comfortably past the 128-bit floor and in the same league as
    /// `WebSession.makeToken`'s 256-bit hex. The prefix carries no entropy and
    /// is not counted.
    static let bodyLength = 32

    /// `bnc_` + 32 = 36 characters.
    static var length: Int { prefix.count + bodyLength }

    /// Below this, `redacted` shows no characters at all — see there.
    static let minimumRedactableLength = 16

    // MARK: - Generation

    /// A fresh token from the system CSPRNG.
    ///
    /// `SystemRandomNumberGenerator` is Swift's wrapper over the platform's
    /// cryptographic generator (`arc4random_buf` on Darwin) — the same source
    /// `SecRandomCopyBytes` draws from, without needing to import `Security`
    /// here and give up the standalone-testable property of this file. It is
    /// explicitly *not* `Int.random` on some seeded generator, which would be
    /// reproducible.
    ///
    /// `UUID()` is also rejected, and it is worth saying why since it is the
    /// reflex: a v4 UUID is 122 bits, not 128, six of its bits being fixed
    /// version and variant markers; it is specified as an *identifier*, not a
    /// secret, so nothing forbids an implementation from making it predictable;
    /// and its hyphenated hex form is far less dense per character. 160 bits of
    /// deliberate CSPRNG output costs nothing more.
    ///
    /// Uniformity: 256 is an exact multiple of 32, so masking a random byte to
    /// its low 5 bits yields each alphabet index with equal probability. A
    /// `% alphabet.count` over a non-power-of-two alphabet would bias the early
    /// symbols and quietly cost entropy.
    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        var body = ""
        body.reserveCapacity(bodyLength)
        for _ in 0..<bodyLength {
            let byte = UInt8.random(in: 0...255, using: &rng)
            body.append(alphabet[Int(byte & 0x1F)])
        }
        return prefix + body
    }

    /// Shape check only — that a string *could* be one of our tokens. Says
    /// nothing about whether it is the stored one; use `matches` for that.
    static func isWellFormed(_ token: String) -> Bool {
        guard token.count == length, token.hasPrefix(prefix) else { return false }
        let set = Set(alphabet)
        return token.dropFirst(prefix.count).allSatisfy(set.contains)
    }

    // MARK: - Comparison

    /// Constant-time equality. **The obvious implementation is wrong here.**
    ///
    /// `candidate == stored` on `String` — and equally a loop that `return`s on
    /// the first differing byte — takes a length of time that depends on how
    /// many leading characters matched. An attacker who can time responses can
    /// therefore learn the token one character at a time: try all 32 first
    /// characters, keep the slowest, move to the second, and 36 × 32 tries
    /// recovers a secret that brute force would never have reached. `==` leaks
    /// the length the same way, by returning immediately when it differs.
    ///
    /// So: no early return on a mismatch, no early return on a length
    /// difference. Differences are folded into an accumulator with `|=` and the
    /// verdict is read once at the end. The length difference is folded in as a
    /// value too, rather than short-circuiting.
    ///
    /// The loop runs over the **stored** token's length, not the candidate's, so
    /// the work done is fixed by our own secret and can't be inflated by a
    /// caller sending a megabyte. A short candidate is zero-padded out to that
    /// width; a long one is caught by the length term.
    ///
    /// The one early return kept is for an empty stored token — no token has
    /// been generated, so there is no secret whose properties could leak, and
    /// "any string authenticates when no token exists" is the failure mode worth
    /// foreclosing loudly.
    static func matches(_ candidate: String, _ stored: String) -> Bool {
        guard !stored.isEmpty, !candidate.isEmpty else { return false }

        let a = Array(candidate.utf8)
        let b = Array(stored.utf8)

        var difference = UInt32(truncatingIfNeeded: a.count ^ b.count)
        for index in 0..<b.count {
            let left: UInt8 = index < a.count ? a[index] : 0
            difference |= UInt32(left ^ b[index])
        }
        return difference == 0
    }

    // MARK: - Redaction

    /// The redaction layer for this token.
    ///
    /// `CLAUDE.md` is blunt that there is no redaction layer and that a
    /// credential must never be printed. `AuthLog.redacted` is the equivalent
    /// for the Plaud secret; this is it for the API token, and it is what makes
    /// the token safe to mention in a log line, an error, or a settings screen.
    ///
    /// Short strings show **no characters at all**. Eight characters of a
    /// 36-character token is 20 bits out of 160 and useless to a reader; eight
    /// characters of an eight-character token is the whole thing. Anything
    /// shorter than `minimumRedactableLength` is therefore reported by length
    /// only — which also means a malformed or truncated value pasted into
    /// Settings can be diagnosed ("4 chars") without echoing it.
    static func redacted(_ token: String) -> String {
        guard !token.isEmpty else { return "<empty>" }
        guard token.count >= minimumRedactableLength else {
            return "<\(token.count) chars>"
        }
        return "\(token.prefix(8))…(\(token.count) chars)"
    }

    // MARK: - Header parsing

    /// Pull the token out of an `Authorization: Bearer <token>` header.
    ///
    /// Deliberately strict about the shape and lax about the spelling: RFC 7235
    /// makes the scheme case-insensitive and allows run-on whitespace, and
    /// clients vary, but anything that isn't exactly a scheme plus one token is
    /// rejected rather than guessed at. In particular `Basic …` returns nil —
    /// falling through to "treat the credentials as a bearer token" would let a
    /// browser's own basic-auth prompt supply one.
    ///
    /// Returns nil for: a nil or blank header, another scheme, the word
    /// `Bearer` with nothing after it, a bare token with no scheme, and more
    /// than one token after the scheme (our tokens contain no spaces).
    static func bearer(in headerValue: String?) -> String? {
        guard let headerValue else { return nil }
        let parts = headerValue.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2 else { return nil }
        guard parts[0].lowercased() == "bearer" else { return nil }
        let token = String(parts[1])
        return token.isEmpty ? nil : token
    }
}
