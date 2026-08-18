import Foundation

/// Logging for the auth path, with redaction baked in.
///
/// The auth flow is the one part of Bounce you cannot debug by looking at the
/// screen — it either silently works or fails with a generic message. So it
/// logs. But it handles a partner secret and bearer tokens, and a log line is
/// forever: Xcode's console, sysdiagnose, a screenshot in a bug report. Hence a
/// dedicated helper rather than bare `print`, so redaction is the default
/// rather than something to remember.
///
/// Debug builds only. Nothing here ships in Release.
enum AuthLog {

    static func log(_ message: String) {
        #if DEBUG
        print("[Auth] \(message)")
        #endif
    }

    /// Fingerprint a secret so you can tell "it changed" or "it's empty"
    /// without the value ever reaching the log.
    ///
    /// Shows length and the first two characters only — enough to catch a
    /// paste that grabbed whitespace or truncated, useless to anyone reading
    /// the log later.
    static func redacted(_ secret: String) -> String {
        guard !secret.isEmpty else { return "<empty>" }
        let prefix = secret.prefix(2)
        return "\(prefix)…(\(secret.count) chars)"
    }

    /// Tokens get length only. Even a prefix of a JWT leaks the header, which
    /// identifies the algorithm and sometimes the key id.
    static func tokenSummary(_ token: String) -> String {
        token.isEmpty ? "<empty>" : "<\(token.count) chars>"
    }

    /// Strip secret *values* out of a JSON-ish response body before it reaches a
    /// log line.
    ///
    /// The decode-mismatch path logs the raw body so a schema change can be told
    /// from a genuine error — but on a 2xx that body carries the freshly minted
    /// `access_token`, and "never print a token" is the module's own rule. This
    /// keeps the keys and structure visible (which is what the diagnosis needs)
    /// while replacing the value after any sensitive key with `<redacted>`.
    static func redactingSecrets(_ body: String) -> String {
        let sensitiveKeys = ["access_token", "refresh_token", "token", "secret_key", "secret"]
        var result = body
        for key in sensitiveKeys {
            // Matches `"key" : "value"` (any spacing) and rewrites only the value.
            let pattern = "(\"\(key)\"\\s*:\\s*\")[^\"]*(\")"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: "$1<redacted>$2")
        }
        return result
    }
}
