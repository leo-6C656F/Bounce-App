import Foundation

/// Logging for the desktop view, matching the repo's convention: `print` with a
/// `[Component]` prefix, behind `#if DEBUG`.
///
/// This exists because the desktop view's failures are otherwise invisible in a
/// device log. Network.framework logs handshake failures at length and with no
/// indication of *which* listener they belong to, so a run full of
/// `boringssl_session_handshake_error_print` says nothing about whether Bounce's
/// own server ever started, on which scheme, or whether anything reached it.
enum WebLog {
    static func log(_ message: String) {
        #if DEBUG
        print("[Web] \(message)")
        #endif
    }
}
