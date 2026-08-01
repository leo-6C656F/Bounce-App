import Foundation

/// The contract between the iPhone app and the watch app.
///
/// **Compiled into both targets**, which is the whole point: one definition of
/// the message keys and the state snapshot, so the two halves cannot drift. It
/// is Foundation-only and deliberately knows nothing about the Plaud SDK — the
/// watch has no Bluetooth relationship with the recorder and never will.
///
/// ## What the watch actually is
///
/// A remote control for the *phone*, not for the recorder. A Plaud binds to one
/// app over Bluetooth, the SDK ships an arm64 **iOS** slice only, and watchOS
/// cannot link it — so every command here is a request for the phone to issue a
/// BLE write on the watch's behalf. If the phone is out of range of the watch,
/// or out of range of the recorder, nothing happens and the watch says so.
///
/// The one thing that makes this genuinely useful rather than a toy:
/// `WCSession.sendMessage` **wakes the iOS app in the background** if it isn't
/// running. Combined with the `bluetooth-central` background mode Bounce
/// already declares, a tap on the wrist can start a recording with the phone in
/// a pocket and Bounce not on screen.
enum WatchLink {

    /// Message dictionary key carrying a `Command.rawValue`.
    static let commandKey = "command"
    /// Message/context key carrying an encoded `Snapshot`.
    static let snapshotKey = "snapshot"

    /// What the watch can ask the phone to do.
    ///
    /// A closed set of five, each mapping to something `AppModel` already does
    /// from the phone's own UI. Nothing here can delete, deliver, or change a
    /// recording — the watch is a transport control, and a mis-tap on a wrist
    /// should never be able to destroy anything.
    enum Command: String, Codable, CaseIterable {
        /// No side effect; just asks for a fresh `Snapshot`.
        case status
        /// Start if idle, stop if recording, resume if paused — the same single
        /// button the phone's record screen offers, so the two can't disagree
        /// about what one tap means.
        case toggleRecording
        case pauseRecording
        /// Flag the current moment. App-side only; the recorder isn't told.
        case highlight
        /// Pull anything new off the recorder.
        case sync
    }

    /// Everything the watch shows, in one value.
    ///
    /// One snapshot rather than a message per property: the watch is often
    /// asleep and will miss individual updates, so what it needs on waking is
    /// the whole current state, not a diff it can't reconstruct.
    ///
    /// **Carries no transcript, no recording title, and no location.** The watch
    /// is a transport control; shipping content to a second device would widen
    /// the app's data footprint for no feature anyone asked for.
    struct Snapshot: Codable, Hashable {

        enum Phase: String, Codable {
            case idle, recording, paused
        }

        var isConnected: Bool
        var deviceName: String?
        /// 0–100, when the phone has a reading. Nil rather than 0 — a recorder
        /// that has never reported is not a recorder that is flat.
        var batteryPercent: Int?
        var phase: Phase
        /// When the current recording started, so the watch can run its own
        /// timer instead of being sent a tick a second.
        var startedAt: Date?
        var highlightCount: Int
        /// A short line about a sync in progress, or nil when idle.
        var syncStatus: String?
        /// Set when the phone refused a command, so the watch can say why
        /// instead of appearing to have done nothing.
        var lastMessage: String?
        var updatedAt: Date

        init(
            isConnected: Bool = false,
            deviceName: String? = nil,
            batteryPercent: Int? = nil,
            phase: Phase = .idle,
            startedAt: Date? = nil,
            highlightCount: Int = 0,
            syncStatus: String? = nil,
            lastMessage: String? = nil,
            updatedAt: Date = Date()
        ) {
            self.isConnected = isConnected
            self.deviceName = deviceName
            self.batteryPercent = batteryPercent
            self.phase = phase
            self.startedAt = startedAt
            self.highlightCount = highlightCount
            self.syncStatus = syncStatus
            self.lastMessage = lastMessage
            self.updatedAt = updatedAt
        }

        var isRecording: Bool { phase == .recording }
        var isActive: Bool { phase != .idle }

        /// What the primary button does next, given this state. Defined here so
        /// the watch's label and the phone's `toggleRecording` can't disagree.
        var primaryActionTitle: String {
            switch phase {
            case .idle: return "Record"
            case .recording: return "Stop"
            case .paused: return "Resume"
            }
        }
    }

    // MARK: - Coding

    /// `WCSession` dictionaries must hold property-list types, so the snapshot
    /// travels as `Data` under one key rather than as loose values. That also
    /// means adding a field can't break an older counterpart: every property is
    /// decoded by the same synthesised `Decodable`, and a decode failure is
    /// caught below and treated as "no update".
    static func encode(_ snapshot: Snapshot) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(snapshot) else { return [:] }
        return [snapshotKey: data]
    }

    static func decodeSnapshot(from payload: [String: Any]) -> Snapshot? {
        guard let data = payload[snapshotKey] as? Data else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func command(in payload: [String: Any]) -> Command? {
        guard let raw = payload[commandKey] as? String else { return nil }
        return Command(rawValue: raw)
    }

    static func message(for command: Command) -> [String: Any] {
        [commandKey: command.rawValue]
    }
}
