import Foundation
import Observation
import WatchConnectivity

/// The watch half of the remote.
///
/// Holds the last `WatchLink.Snapshot` the phone sent and sends commands back.
/// It owns no state of its own beyond that snapshot — **the phone is the single
/// source of truth**, because only the phone can see the recorder. Guessing on
/// the watch would produce a UI that confidently shows "Recording" when the
/// recorder never got the command.
///
/// The one exception is `pending`, which is optimism with a deadline: a tap has
/// to feel like it did something, and the recorder's confirmation is a BLE
/// round-trip away.
@MainActor
@Observable
final class WatchConnector {

    static let shared = WatchConnector()

    private(set) var snapshot = WatchLink.Snapshot()
    /// True from a tap until the phone answers. Drives the spinner, and gates
    /// the buttons so a double-tap can't send two conflicting commands.
    private(set) var isSending = false
    /// Set when the phone can't be reached at all — a different failure from
    /// "the phone is there but the recorder isn't", and the user needs to be
    /// told which.
    private(set) var unreachableMessage: String?

    @ObservationIgnored private let delegate = Delegate()

    private init() {
        delegate.owner = self
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
    }

    /// The last state the phone volunteered, applied on launch so the first
    /// frame isn't empty while the status request is in flight.
    func primeFromContext() {
        guard WCSession.isSupported() else { return }
        if let stored = WatchLink.decodeSnapshot(from: WCSession.default.receivedApplicationContext) {
            apply(stored)
        }
    }

    func send(_ command: WatchLink.Command) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            unreachableMessage = "Not connected to your iPhone."
            return
        }

        isSending = true
        unreachableMessage = nil
        session.sendMessage(
            WatchLink.message(for: command),
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.isSending = false
                    if let snapshot = WatchLink.decodeSnapshot(from: reply) {
                        self?.apply(snapshot)
                    }
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.isSending = false
                    // `sendMessage` fails when the phone is unreachable *and*
                    // cannot be woken — out of range, or Bluetooth off. It is
                    // the one case where the watch genuinely knows nothing.
                    self?.unreachableMessage = Self.message(for: error)
                }
            })
    }

    /// Ask for the current state without changing anything. Cheap, and the right
    /// thing to do whenever the app comes to the front.
    func refresh() { send(.status) }

    fileprivate func apply(_ snapshot: WatchLink.Snapshot) {
        // Out-of-order delivery is real: a queued application context can land
        // after a fresher reply. Dropping the older one keeps the UI monotonic.
        guard snapshot.updatedAt >= self.snapshot.updatedAt else { return }
        self.snapshot = snapshot
        unreachableMessage = nil
    }

    private static func message(for error: Error) -> String {
        let code = (error as NSError).code
        // `WCErrorCodeNotReachable` is the ordinary case — phone asleep, out of
        // range, or Bluetooth off — and deserves plain words rather than a
        // framework error string nobody can act on.
        if code == WCError.notReachable.rawValue || code == WCError.deviceNotPaired.rawValue {
            return "Can't reach your iPhone."
        }
        return error.localizedDescription
    }
}

private final class Delegate: NSObject, WCSessionDelegate {

    weak var owner: WatchConnector?

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor [owner] in
            owner?.primeFromContext()
            owner?.refresh()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = WatchLink.decodeSnapshot(from: applicationContext) else { return }
        Task { @MainActor [owner] in owner?.apply(snapshot) }
    }
}
