import Foundation
import WatchConnectivity

/// The iPhone half of the watch remote.
///
/// Receives a `WatchLink.Command`, performs it through `AppModel` — exactly the
/// same call the phone's own record screen makes — and answers with a
/// `WatchLink.Snapshot`. It also pushes a snapshot whenever the phone's state
/// changes, so a watch that was asleep shows the truth on waking rather than
/// whatever it last saw.
///
/// **Why this is worth having at all:** `sendMessage` from the watch wakes this
/// app in the background if it isn't running. Bounce already declares the
/// `bluetooth-central` background mode and keeps its BLE connection, so a tap
/// on the wrist starts a recording with the phone in a pocket and the app off
/// screen. Nothing here works when the phone is out of Bluetooth range of the
/// *recorder*, and the snapshot says so rather than the watch appearing to have
/// done nothing.
///
/// Two transports, used for what each is for:
///
/// - **`sendMessage`** — the watch asking for something now. Needs the
///   counterpart reachable, and carries a reply.
/// - **`updateApplicationContext`** — the phone volunteering its latest state.
///   Queued by the system and delivered when the watch is next available, with
///   only the newest one kept. That last part is exactly right here: a snapshot
///   is a complete picture, so an undelivered older one is worth nothing.
@MainActor
final class WatchBridge: NSObject {

    static let shared = WatchBridge()

    private weak var model: AppModel?
    private let delegate = Delegate()

    /// The last context pushed, so an unchanged state doesn't re-transmit.
    /// `AppModel` republishes on every BLE callback, several a second during a
    /// sync, and `updateApplicationContext` throttles — spending that budget on
    /// identical payloads means the one that matters arrives late.
    private var lastPushed: WatchLink.Snapshot?

    private override init() {
        super.init()
        delegate.owner = self
    }

    /// Called once from `BounceApp`, mirroring `DesktopServer.attach(model:)`.
    ///
    /// Activation is here rather than in `init` because a `WCSession` with no
    /// way to answer a command is worse than no session: the watch would reach a
    /// live counterpart that replies with an empty snapshot.
    func attach(model: AppModel) {
        self.model = model
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
    }

    /// Push the current state to the watch, if it has changed.
    ///
    /// Safe to call from anywhere and often — that's the point. `AppModel` calls
    /// it from the same place it republishes device, recording and sync state.
    func publish() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        // `isPaired`/`isWatchAppInstalled` are iOS-only and are the difference
        // between "no watch" and "watch asleep" — without the check every push
        // on a phone with no watch throws.
        guard session.isPaired, session.isWatchAppInstalled else { return }

        let snapshot = currentSnapshot()
        // `updatedAt` differs on every build, so compare everything else.
        if var previous = lastPushed {
            previous.updatedAt = snapshot.updatedAt
            guard previous != snapshot else { return }
        }
        lastPushed = snapshot
        // Throws when called faster than the system allows. There is nothing
        // useful to do about it: the next state change pushes again, and the
        // system keeps only the newest context anyway.
        try? session.updateApplicationContext(WatchLink.encode(snapshot))
    }

    // MARK: - Commands

    /// Perform a command and return the state it produced.
    ///
    /// **Every command is a no-op without a connected recorder**, and says so in
    /// `lastMessage` rather than failing silently — a wrist tap that appears to
    /// do nothing is indistinguishable from a broken app. `status` is exempt: it
    /// is a question, not an instruction.
    fileprivate func perform(_ command: WatchLink.Command) -> WatchLink.Snapshot {
        guard let model else {
            return WatchLink.Snapshot(lastMessage: "Bounce is still starting up.")
        }

        guard command == .status || model.connectionState.isConnected else {
            var snapshot = currentSnapshot()
            snapshot.lastMessage = "Your recorder isn't connected."
            return snapshot
        }

        switch command {
        case .status:
            break
        case .toggleRecording:
            // The phone's own single-button semantics, deliberately reused
            // rather than reimplemented: start / stop / resume by state.
            model.toggleRecording()
        case .pauseRecording:
            model.pauseRecording()
        case .highlight:
            model.addHighlight()
        case .sync:
            model.sync()
        }

        // Deliberately the state *before* the recorder has answered. Every one of
        // these is a BLE write whose confirmation arrives on a callback later, so
        // waiting here would sit on `sendMessage`'s reply until it timed out. The
        // watch shows this immediately and the real state arrives moments later
        // through `publish()`.
        return currentSnapshot()
    }

    private func currentSnapshot() -> WatchLink.Snapshot {
        guard let model else { return WatchLink.Snapshot() }

        let phase: WatchLink.Snapshot.Phase
        switch model.recordingState {
        case .idle: phase = .idle
        case .recording: phase = .recording
        case .paused: phase = .paused
        }

        return WatchLink.Snapshot(
            isConnected: model.connectionState.isConnected,
            deviceName: model.device?.name,
            batteryPercent: model.device.map(\.batteryLevel),
            phase: phase,
            startedAt: model.recordingState.startedAt,
            highlightCount: model.currentHighlightCount,
            syncStatus: Self.syncStatus(model.syncState),
            updatedAt: Date())
    }

    /// A short line, or nil when nothing is happening. Kept terse on purpose —
    /// it renders on a watch, under a button.
    private static func syncStatus(_ state: SyncState) -> String? {
        switch state {
        case .idle, .completed:
            return nil
        case .syncing(let progress), .wifiTransferring(let progress):
            return "Syncing \(min(progress.syncedFiles + 1, progress.totalFiles)) of \(progress.totalFiles)"
        case .wifiConnecting:
            return "Connecting over WiFi"
        case .failed(let message):
            return message
        }
    }
}

/// The `WCSessionDelegate`, kept off `WatchBridge` for the same reason
/// `LocationCapture` splits its `CLLocationManagerDelegate` out: the callbacks
/// are `nonisolated` while everything they touch is main-actor isolated.
private final class Delegate: NSObject, WCSessionDelegate {

    weak var owner: WatchBridge?

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        // The watch may have been waiting on a state it never got — say hello.
        Task { @MainActor [owner] in owner?.publish() }
    }

    /// Both of these are **required on iOS** and the app won't compile without
    /// them. `sessionDidDeactivate` must reactivate, or switching to a second
    /// paired watch leaves the session dead with no error.
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [owner] in owner?.publish() }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let command = WatchLink.command(in: message) else {
            replyHandler([:])
            return
        }
        // Hopping to the main actor before replying is required — `AppModel` and
        // every manager under it are main-actor isolated — and is why the reply
        // handler is captured rather than called inline.
        Task { @MainActor [owner] in
            guard let owner else {
                replyHandler(WatchLink.encode(
                    WatchLink.Snapshot(lastMessage: "Bounce is still starting up.")))
                return
            }
            let snapshot = owner.perform(command)
            replyHandler(WatchLink.encode(snapshot))
        }
    }

    /// A command sent while the phone was unreachable, delivered on wake. Same
    /// handling, minus the reply — the watch finds out through the context push
    /// that `perform` triggers by changing the phone's state.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = WatchLink.command(in: message) else { return }
        Task { @MainActor [owner] in
            _ = owner?.perform(command)
            owner?.publish()
        }
    }
}
