import AppIntents
import Foundation

/// Interactive Live Activity buttons for pausing/resuming/stopping the recording
/// from the Lock Screen and Dynamic Island.
///
/// Shared by both targets (the widget needs the *type* to build `Button(intent:)`;
/// the app runs `perform()`). To stay compilable in the widget extension — which
/// has none of the app's Bluetooth code — `perform()` does the minimum: it posts
/// a `NotificationCenter` message. Because a `LiveActivityIntent` executes in the
/// **app's** process while the app is running (which it is, mid-recording), the
/// app's observer receives it and drives `DeviceManager`. No App Group, no shared
/// framework, no app-only symbols leaking into the extension.
extension Notification.Name {
    static let bounceRecordingPause = Notification.Name("bounce.recording.pause")
    static let bounceRecordingResume = Notification.Name("bounce.recording.resume")
    static let bounceRecordingStop = Notification.Name("bounce.recording.stop")
}

struct PauseRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause Recording"
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .bounceRecordingPause, object: nil)
        return .result()
    }
}

struct ResumeRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resume Recording"
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .bounceRecordingResume, object: nil)
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Recording"
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .bounceRecordingStop, object: nil)
        return .result()
    }
}
