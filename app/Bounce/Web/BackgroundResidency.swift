import AVFoundation
import Foundation
import Observation

/// Keeps Bounce out of the suspended state for as long as the desktop view is
/// on, by playing silence through the `audio` background mode.
///
/// ## Why this exists, and what it costs
///
/// iOS has no services. Nothing you can write runs outside the app's own
/// process, so "keep the desktop view alive while I'm in another app" reduces
/// entirely to "stop iOS suspending us". There are only a handful of mechanisms
/// that do that, and all but one are unusable here:
///
/// | Mechanism | Why not |
/// |---|---|
/// | `beginBackgroundTask` | ~30 s. Enough to finish a write, not to host a server. |
/// | `BGAppRefreshTask` / `BGProcessingTask` | System-scheduled, opportunistic, minutes apart. Cannot hold a listener. |
/// | Live Activity (the app ships one) | UI only. Grants no execution time whatsoever. |
/// | `BGContinuedProcessingTask` (iOS 26) | Capped near an hour, must be user-initiated with a visible system progress card, and the system marks a task *stalled* when it stops reporting progress. A socket has no progress to report. |
/// | `NEAppPushProvider` (Local Push Connectivity) | The only Apple-blessed persistent background socket, but it needs a restricted entitlement requested by the account owner for enterprise on-prem use, breaks automatic signing, and would move the whole server into an extension process with no access to `AppModel`, Speech or Foundation Models. |
/// | `location` + `allowsBackgroundLocationUpdates` | Works, but costs the blue status pill and more battery than this does, for the same result. |
/// | **`audio` + actually playing audio** | What this file does. |
///
/// **Playing silence to stay resident is an App Store rejection.** That is the
/// whole reason it sits behind `BOUNCE_BACKGROUND_DESKTOP`: with the flag off
/// this type compiles to a no-op, `isSupported` is false, and the desktop view
/// behaves exactly as it did before — foreground-only, with the narrower BLE
/// fallback in `DesktopServer.handleScenePhase` as the review-safe half. Flip
/// the flag in `project.yml` before ever submitting a build. The three
/// `[WIFI FAST TRANSFER]` markers are the precedent for that kind of switch.
///
/// ## Shape of the session, and why it is held for the whole desktop session
///
/// Residency starts when the server starts — in the foreground, where a blocking
/// `setActive(true)` is affordable — rather than at the moment of backgrounding.
/// Arming at the transition is the obvious alternative and it is a race: the
/// media server can take longer to answer than iOS gives us before suspension,
/// and losing that race means the listener dies with the promise already made
/// that it wouldn't. Holding a mixed, inaudible session for the length of an
/// explicitly-enabled desk session is the cheaper problem, and the screen being
/// kept awake alongside it costs far more battery.
///
/// The session is **always** `.mixWithOthers`, which is the difference between
/// this and `AudioPlayerModel`: a keep-alive must never become the phone's
/// now-playing app, never interrupt the user's music, and never blank the
/// now-playing info a real player published. Mixing is also what lets it coexist
/// with the SDK, which drives the shared session toward `.playAndRecord` while a
/// recorder is connected — the same reasoning as
/// `AudioPlayerModel.activatePlaybackSession(mixing:)`, for the same reason.
///
/// Read directly as `BackgroundResidency.shared`, the `DeliverySettings` pattern.
@MainActor
@Observable
final class BackgroundResidency {

    static let shared = BackgroundResidency()

    /// Whether this build can hold residency at all.
    static var isSupported: Bool {
        #if BOUNCE_BACKGROUND_DESKTOP
        return true
        #else
        return false
        #endif
    }

    /// True once silence is actually playing — i.e. the app will survive being
    /// backgrounded. Callers must key on this rather than on "we asked for it":
    /// a failed activation that reads as success is what leaves a dead listener
    /// advertising a URL.
    var isHolding: Bool { player?.isPlaying == true }

    /// The same answer, readable off the main actor.
    ///
    /// `nonisolated(unsafe)` for the same reason `AudioPlayerModel`'s observers
    /// are: `AudioPlayerModel.deactivatePlaybackSession` is `nonisolated static`
    /// and has to know whether deactivating the shared session would kill this.
    /// Written on the main actor only, and a stale read is benign in both
    /// directions — one extra `setActive(false)` that the watchdog repairs a
    /// second later, or one skipped that the next `stop()` performs.
    @ObservationIgnored nonisolated(unsafe) private(set) static var isHoldingUnsafe = false

    private(set) var lastError: String?

    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    /// Session operations are serialized through this, exactly as
    /// `AudioPlayerModel` serializes its own.
    ///
    /// **Observed on device, and it is not theoretical.** The Bonjour-registration
    /// fallback in `DesktopServer.bringUp` calls `stop(keepingSessions: true)` and
    /// then `bringUp` again, back to back — which is `end()` immediately followed
    /// by `begin()`, each scheduling an unordered `Task`. A device log of that
    /// path reads `holding → released → holding`, and it worked; nothing
    /// guaranteed it would. With the deactivate landing after the activate, the
    /// player is looping and `isHolding` is true while the session is *inactive*,
    /// so `DesktopServer` keeps the listener up on backgrounding and iOS suspends
    /// the app anyway. That is the invisible failure this whole file exists to
    /// avoid, arriving by the back door.
    private static var sessionTask: Task<Void, Never>?

    private init() {}

    /// Wait for a previous session operation, but not forever.
    ///
    /// Bounded for the reason CLAUDE.md gives for `AudioPlayerModel`'s pair of
    /// waits: a `setActive` still blocked in a busy media server must not wedge
    /// every later operation. Three seconds, matching that chain.
    private nonisolated static func drain(_ previous: Task<Void, Never>?) async {
        guard let previous else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await previous.value }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Lifecycle

    /// Start holding. Idempotent.
    ///
    /// Does not report success: activation happens off the main actor because
    /// `setActive(true)` blocks on a media-server round trip, so the answer isn't
    /// available synchronously. Poll `isHolding` — `DesktopServer` does, once, at
    /// the moment it matters.
    func begin() {
        guard Self.isSupported else { return }
        guard !isHolding else { return }

        lastError = nil
        registerInterruptionObserver()

        let clip: URL
        do {
            clip = try Self.silentClipURL()
        } catch {
            lastError = "Couldn't prepare the keep-alive clip. \(error.localizedDescription)"
            WebLog.log("residency: clip failed — \(error.localizedDescription)")
            return
        }

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: clip)
        } catch {
            lastError = "Couldn't start the keep-alive player. \(error.localizedDescription)"
            WebLog.log("residency: player failed — \(error.localizedDescription)")
            return
        }
        // Endless. The clip is a second of zeroes, so looping it is what the
        // `audio` background mode counts as "actively playing".
        player.numberOfLoops = -1
        self.player = player

        // Marked before the hop off the main actor, not after: between here and
        // the player starting, a detail view's `stop()` could otherwise deactivate
        // the shared session out from under the activation below.
        Self.isHoldingUnsafe = true

        let mixesWithRecorder = DeviceManager.shared.connectionState.isConnected
        let previous = Self.sessionTask
        Self.sessionTask = Task {
            await Self.drain(previous)
            do {
                try await Self.activateMixedSession(alongsideRecorder: mixesWithRecorder)
            } catch {
                let code = (error as NSError).code
                WebLog.log("residency: activation failed code=\(code) — \(error.localizedDescription)")
                lastError = "Couldn't keep Bounce running in the background. \(error.localizedDescription)"
                end()
                return
            }
            guard self.player === player else { return }
            guard player.play() else {
                WebLog.log("residency: play() refused")
                lastError = "Couldn't keep Bounce running in the background."
                end()
                return
            }
            WebLog.log("residency: holding (mixing with recorder=\(mixesWithRecorder))")
        }
    }

    /// Stop holding and hand the session back.
    func end() {
        guard player != nil || Self.isHoldingUnsafe else { return }
        player?.stop()
        player = nil
        Self.isHoldingUnsafe = false
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        WebLog.log("residency: released")
        // Same chain as `begin()`, and this is the end of it that matters: an
        // unordered deactivate is the one that lands after a restart's activate.
        let previous = Self.sessionTask
        Self.sessionTask = Task {
            await Self.drain(previous)
            await Self.deactivate()
        }
    }

    /// Restart playback if something stopped it — a phone call, Siri, or a media
    /// services reset. Called from `DesktopServer`'s one-second watchdog rather
    /// than owning a timer of its own.
    ///
    /// Without this, a single interruption silently converts a background-capable
    /// session into one that dies at the next app switch, and nothing says so.
    func recoverIfNeeded() {
        guard Self.isSupported, Self.isHoldingUnsafe else { return }
        guard let player, !player.isPlaying else { return }
        WebLog.log("residency: playback stopped — restarting")
        // Full rebuild rather than a bare `play()`: after a media services reset
        // the player object is unusable and `play()` returns true anyway.
        self.player = nil
        Self.isHoldingUnsafe = false
        begin()
    }

    private func registerInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            MainActor.assumeIsolated { self?.recoverIfNeeded() }
        }
    }

    // MARK: - Session

    /// `nonisolated` + async so both calls run off the main actor: `setActive`
    /// blocks on the media server, and calling it on the main thread also trips an
    /// `AVAudioSession_iOS.mm` warning.
    ///
    /// `.mixWithOthers` on both branches, unconditionally — see the type comment.
    /// The category family follows the recorder so that neither owner's
    /// `setCategory` invalidates the other's; **no route options on the
    /// `.playback` branch**, which iOS 26 rejects with `OSStatus -50` rather than
    /// ignoring as earlier versions did.
    fileprivate nonisolated static func activateMixedSession(
        alongsideRecorder: Bool
    ) async throws {
        let session = AVAudioSession.sharedInstance()
        if alongsideRecorder {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        }
        try session.setActive(true)
    }

    /// Put the session back into the keep-alive's mixed shape without
    /// deactivating it.
    ///
    /// Called by `AudioPlayerModel` in place of its `setActive(false)` while
    /// residency is held: deactivating would suspend the app at the next app
    /// switch, and leaving the player's non-mixing `.playback` category in place
    /// would keep Bounce holding the phone's audio focus after playback ended.
    ///
    /// The one thing lost by not deactivating is `.notifyOthersOnDeactivation`,
    /// so another app's paused audio doesn't get its resume hint. That only
    /// applies while desktop view is on, and it is the smaller of the two costs.
    nonisolated static func reassertSessionAfterPlayback() async {
        guard isHoldingUnsafe else { return }
        let mixesWithRecorder = await MainActor.run {
            DeviceManager.shared.connectionState.isConnected
        }
        do {
            try await activateMixedSession(alongsideRecorder: mixesWithRecorder)
        } catch {
            WebLog.log("residency: re-assert failed — \(error.localizedDescription)")
        }
    }

    private nonisolated static func deactivate() async {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - The clip

    /// A second of silence as 16 kHz mono LPCM, written once into the temp
    /// directory.
    ///
    /// Hand-built WAV rather than a bundled asset or an `AVAudioFile` write: the
    /// header is 44 bytes, it keeps a binary blob out of the repo, and it avoids
    /// the "iOS has no MP3 encoder" class of problem entirely — LPCM in a RIFF
    /// container is the one audio format nothing can refuse to produce.
    private static func silentClipURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounce-residency.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate: UInt32 = 16_000
        let bytesPerFrame: UInt32 = 2
        let dataBytes = sampleRate * bytesPerFrame

        var wav = Data()
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        func append(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }

        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataBytes)          // everything after this field
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                      // fmt chunk size
        append(UInt16(1))                       // PCM
        append(UInt16(1))                       // mono
        append(sampleRate)
        append(sampleRate * bytesPerFrame)      // byte rate
        append(UInt16(bytesPerFrame))           // block align
        append(UInt16(16))                      // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        append(dataBytes)
        wav.append(Data(count: Int(dataBytes)))

        try wav.write(to: url, options: .atomic)
        return url
    }
}
