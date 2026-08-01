import Foundation

/// Logging for the on-device transcription path, debug builds only.
///
/// Same rationale as `AuthLog` and `DeviceLog`: when transcription fails, the
/// Speech framework tends to surface a bare `Foundation._GenericObjCError`,
/// which says nothing about which stage broke — locale resolution, model
/// install, format negotiation, audio conversion, or analysis itself.
enum TranscribeLog {

    static func log(_ message: String) {
        #if DEBUG
        print("[Transcribe] \(message)")
        #endif
    }
}
