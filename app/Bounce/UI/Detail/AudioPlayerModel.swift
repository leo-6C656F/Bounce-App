import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// Plays a single local recording.
///
/// Thin wrapper over `AVAudioPlayer` — enough for scrubbing and tap-to-seek from
/// the transcript, without AVPlayer's item plumbing.
///
/// Completion comes from the delegate rather than by polling `isPlaying`. An
/// earlier version inferred "finished" from `!player.isPlaying` inside the
/// progress ticker, which raced with playback starting: the first tick could
/// arrive before the audio engine reported itself as playing, so the UI snapped
/// straight back to 0:00 and nothing ever played.
@MainActor
@Observable
final class AudioPlayerModel: NSObject, AVAudioPlayerDelegate {

    static let shared = AudioPlayerModel()

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var currentTitle = ""
    private(set) var currentURL: URL?
    /// Playback speed. Spoken-audio playback is the main reason anyone opens a
    /// recording twice, so this is a first-class control rather than a setting.
    private(set) var rate: Float = 1
    /// Surfaced in the UI — a silent failure here is indistinguishable from a
    /// broken file.
    private(set) var errorMessage: String?

    /// Speeds offered in the UI. Below 0.75 spoken audio stops being useful and
    /// above 2× the recorder's own compression artefacts dominate.
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Skip distance, in seconds. 15 rather than 10 — this is spoken audio, and
    /// 15 is the interval Podcasts and every other speech player uses, so it is
    /// what a Lock Screen or AirPods skip is expected to do.
    static let skipInterval: TimeInterval = 15

    /// Whether this player claims the Lock Screen / Control Centre / AirPods
    /// transport.
    ///
    /// `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` are process-wide
    /// singletons, so two live players fight over them and the last one to
    /// register wins. The audio editor is presented *over* a detail view whose
    /// player is still alive, so it opts out: an editor auditioning a two-second
    /// segment has no business becoming the phone's now-playing app, and taking
    /// the slot would leave the Lock Screen wired to a modal after it closes.
    ///
    /// Set before `load(url:title:)`.
    var usesRemoteControls = true

    /// Regions of the file playback is confined to, in ascending order, or nil
    /// for the whole file.
    ///
    /// This is how the editor auditions an edit before anything is written: the
    /// file on disk still contains the removed audio, so rather than rendering a
    /// preview the ticker seeks over the excluded regions and stops at the end of
    /// the last kept one. Setting it does not move the playhead.
    var playbackRanges: [ClosedRange<TimeInterval>]? {
        didSet {
            // A tighter tick while confined: the seek that skips an excluded
            // region can only happen on a tick, so the tick interval *is* how
            // much removed audio leaks through at each boundary. 100 ms of the
            // wrong audio at every cut is clearly audible; 25 ms is not.
            if isPlaying { startTicker() }
        }
    }

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    /// Shown on the Lock Screen and in Control Centre.
    private var title = ""
    /// Guards against a second tap while the session is still activating.
    private var isStartingPlayback = false
    /// Session (de)activation now happens off the main thread, so operations
    /// chain through this task to keep the ordering the old synchronous calls
    /// had — otherwise a stop()'s setActive(false) could land after the next
    /// play's activation and silently kill it. Static, because each detail view
    /// creates its own model: navigating from recording A to recording B must
    /// order A's deactivation before B's activation, and an instance-level
    /// chain can't see across that boundary.
    private static var sessionTask: Task<Void, Never>?
    /// Bumped by stop() so an in-flight start (still waiting on session
    /// activation) knows it has been superseded and must not call play().
    private var startGeneration = 0

    /// `nonisolated(unsafe)` so `deinit` can unregister it. Only touched on the main
    /// actor otherwise.
    ///
    /// **`@ObservationIgnored` is load-bearing, not tidiness.** Without it the
    /// `@Observable` macro wraps these in `@ObservationTracked`, and the isolation
    /// attribute then lands on the macro's generated accessors rather than the
    /// stored property — which is what Swift was warning about with "'nonisolated(unsafe)'
    /// has no effect". Xcode's suggested fix, plain `nonisolated`, is not valid
    /// here: it cannot be applied to a mutable stored property. Opting out of
    /// observation is the actual fix, and it is also correct on its own terms —
    /// nothing observes these, so tracking them was pure overhead.
    @ObservationIgnored nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    /// Same reason: `deinit` has to hand the remote commands back, or a stale
    /// detail view keeps answering the Lock Screen after the user left it.
    @ObservationIgnored nonisolated(unsafe) private var remoteTargets: [(MPRemoteCommand, Any)] = []

    /// Loads a recording, replacing whatever was playing.
    ///
    /// Re-entrant by design: this is a shared instance now, and every
    /// `RecordingDetailView` calls it on appear — including the one the user just
    /// came back to. Reloading the *same* URL would restart a recording the user
    /// is part-way through, so an already-loaded URL only refreshes the title.
    func load(url: URL, title: String) {
        if currentURL == url, player != nil {
            self.title = title
            self.currentTitle = title
            return
        }
        stop()
        self.currentURL = url
        self.title = title
        self.currentTitle = title
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            // Must be set *before* `prepareToPlay()`; setting it afterwards is
            // silently ignored and `rate` then does nothing.
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            errorMessage = nil
            observeInterruptions()
            registerRemoteCommands()
            publishNowPlaying()
        } catch {
            errorMessage = "Couldn't open this recording. \(error.localizedDescription)"
        }
    }

    /// Keep the Lock Screen in step with a rename made while the detail view is
    /// open. `load` early-returns once a player exists, so without this the
    /// pre-rename title stays on the Lock Screen until the view is dismissed.
    func updateTitle(_ newTitle: String) {
        guard newTitle != title else { return }
        title = newTitle
        publishNowPlaying()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        // `AVAudioPlayer.rate` only takes effect while playing; setting it on a
        // paused player is kept but not applied until the next `play()`, which
        // `togglePlayback` handles.
        if let player, player.isPlaying { player.rate = newRate }
        publishNowPlaying()
    }

    /// The SDK shares this process's one `AVAudioSession` and drives it toward
    /// `.playAndRecord` while the recorder is connected. When it re-asserts the
    /// session, iOS interrupts our player — which otherwise looks like "playing
    /// but stuck at 0:00". Reflect the pause so the UI is honest.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init)
            print("[Player] interruption: \(String(describing: type))")
            MainActor.assumeIsolated {
                guard let self, type == .began else { return }
                self.player?.pause()
                self.isPlaying = false
                self.ticker?.cancel()
                // Without this the Lock Screen keeps the old non-zero playback
                // rate and extrapolates elapsed time from the last anchor — so
                // a phone call, or the SDK re-asserting the shared session for
                // the recorder, leaves it counting up while nothing is audible.
                self.publishNowPlaying()
            }
        }
    }

    func togglePlayback() {
        guard let player else { return }

        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
            publishNowPlaying()
            return
        }

        guard !isStartingPlayback else { return }
        isStartingPlayback = true

        // Re-registered on every play, not just at load: `stop()` tears the
        // targets down (it has to — this view may be gone), but `load` early-
        // returns once a player exists, so a leave-and-return to the same detail
        // view left the Lock Screen showing metadata whose buttons did nothing.
        // The call is idempotent.
        registerRemoteCommands()

        // Read on the main actor, before hopping off it. `.mixWithOthers` is
        // what lets us coexist with the SDK while it holds the session for the
        // recorder — but mixing also means iOS won't hand us the Lock Screen.
        // With no recorder attached there's nothing to coexist with, so take the
        // plain `.playback` session and get remote controls in exchange.
        let recorderIsAttached = DeviceManager.shared.connectionState.isConnected

        // Activated here rather than at load time: the SDK also uses the audio
        // session while streaming PCM off the recorder, so claiming it early can
        // lose the race. Doing it at the moment of playback is reliable.
        // Activation happens off the main actor — setActive(true) blocks, and
        // calling it on the main thread trips an AVAudioSession_iOS.mm warning.
        let generation = startGeneration
        let previous = Self.sessionTask
        Self.sessionTask = Task {
            defer { isStartingPlayback = false }
            // Bound the wait on the previous session op. A blocking setActive
            // (media server busy because the SDK holds the session) must not
            // wedge every future tap — the chain is static, across view
            // instances, so one stall would otherwise kill playback app-wide.
            if let previous {
                let drained = await Self.withTimeout(seconds: 3) { await previous.value }
                if !drained { print("[Player] previous session op didn't finish in 3s; proceeding") }
            }

            do {
                try await Self.activatePlaybackSession(mixing: recorderIsAttached)
            } catch {
                // Log the OSStatus and the session's actual shape, not just
                // `localizedDescription` — the latter is what reached the UI as a
                // bare "(OSStatus error -50.)" with nothing to act on.
                let code = (error as NSError).code
                print("""
                    [Player] activation failed: code=\(code) mixing=\(recorderIsAttached) \
                    \(Self.sessionDescription()) — \(error.localizedDescription)
                    """)
                errorMessage = "Couldn't start audio playback. \(error.localizedDescription)"
                return
            }

            // A re-load may have swapped the player, or stop() may have run,
            // while the session was activating.
            guard self.player === player, self.startGeneration == generation else {
                print("[Player] superseded before play() (match=\(self.player === player))")
                return
            }

            var started = player.play()
            print("[Player] play() -> \(started) at \(player.currentTime)")
            if !started {
                // The SDK may have re-grabbed the session between activate and
                // play; re-activate once and retry. Logged rather than swallowed:
                // a `try?` here hid the retry's own failure entirely.
                do {
                    try await Self.activatePlaybackSession(mixing: recorderIsAttached)
                } catch {
                    print("[Player] re-activation failed: code=\((error as NSError).code) \(Self.sessionDescription())")
                }
                started = player.play()
                print("[Player] retry play() -> \(started)")
            }
            guard started else {
                errorMessage = "Couldn't play this recording. The audio file may be incomplete."
                return
            }

            // Applied after `play()`: AVAudioPlayer resets to 1× on start, so
            // setting it beforehand silently loses the user's chosen speed.
            player.rate = rate
            isPlaying = true
            startTicker()
            publishNowPlaying()
        }
    }

    /// `nonisolated` + async so it runs on the global executor, not the main
    /// actor: both session calls block on a media-server round trip.
    ///
    /// Two session shapes, picked by whether the recorder is attached.
    ///
    /// **Mixing (`.playAndRecord` + `.mixWithOthers`)** is the original, and it
    /// is deliberate: the SDK drives the shared session toward `.playAndRecord`
    /// while the recorder is connected, so asking for the same family with
    /// mixing means neither owner's `setCategory` invalidates the other's —
    /// which is what silently blocked playback before. The cost is that a mixing
    /// session is not the "now playing" app, so the Lock Screen, AirPods stem
    /// and CarPlay stay dark.
    ///
    /// **Non-mixing (`.playback`)** is used when no recorder is connected. There
    /// is nothing to coexist with, so we take the full session and the remote
    /// controls that come with it. This is the common case for listening back.
    ///
    /// **Pass no route options on the `.playback` branch.** `.allowBluetoothA2DP`
    /// and `.allowAirPlay` describe behaviour `.playback` already has — they
    /// exist for the input-bearing categories — and iOS 26 *rejects* the
    /// combination with `OSStatus -50` instead of ignoring it, as earlier
    /// versions did. That surfaced as an intermittent "Couldn't start audio
    /// playback. (OSStatus error -50.)": intermittent only because which branch
    /// runs is decided by whether the recorder happens to be connected, so the
    /// same recording played fine right after a sync and failed once BLE
    /// dropped. The mixing branch's options are all legal for `.playAndRecord`.
    private nonisolated static func activatePlaybackSession(mixing: Bool) async throws {
        let session = AVAudioSession.sharedInstance()
        if mixing {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio)
        }
        try session.setActive(true)
    }

    /// What the session actually looks like right now. Only used in failure
    /// logging — a bare `localizedDescription` for an `OSStatus` tells you
    /// nothing about *which* configuration was rejected, which is what cost the
    /// diagnosis of the `-50` above.
    private nonisolated static func sessionDescription() -> String {
        let session = AVAudioSession.sharedInstance()
        return "category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
            + "options=\(session.categoryOptions.rawValue) "
            + "otherAudioPlaying=\(session.isOtherAudioPlaying)"
    }

    // MARK: - Lock Screen

    /// Wire the Lock Screen / Control Centre / AirPods transport to this player.
    ///
    /// Targets are torn down in `stop()` and `deinit`: each detail view creates
    /// its own model, so leaving them registered means a screen the user has
    /// already left keeps answering the Lock Screen.
    private func registerRemoteCommands() {
        guard usesRemoteControls, remoteTargets.isEmpty else { return }
        let centre = MPRemoteCommandCenter.shared()

        centre.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        centre.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]

        // `Task { @MainActor }` rather than `MainActor.assumeIsolated`: unlike the
        // interruption observer above (registered with `queue: .main`, so main
        // isolation is guaranteed), MPRemoteCommandCenter makes no documented
        // promise about which thread it calls a target on — and `assumeIsolated`
        // traps rather than hops when the assumption is wrong. Transport commands
        // don't need a synchronous answer, so the hop is free.
        func add(_ command: MPRemoteCommand, _ handler: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            let token = command.addTarget { _ in
                Task { @MainActor in handler() }
                return .success
            }
            remoteTargets.append((command, token))
        }

        add(centre.playCommand) { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.togglePlayback()
        }
        add(centre.pauseCommand) { [weak self] in
            guard let self, self.isPlaying else { return }
            self.togglePlayback()
        }
        add(centre.togglePlayPauseCommand) { [weak self] in self?.togglePlayback() }
        add(centre.skipBackwardCommand) { [weak self] in self?.skip(by: -Self.skipInterval) }
        add(centre.skipForwardCommand) { [weak self] in self?.skip(by: Self.skipInterval) }

        let scrub = centre.changePlaybackPositionCommand
        scrub.isEnabled = true
        let token = scrub.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        remoteTargets.append((scrub, token))
    }

    private nonisolated static func unregisterRemoteCommands(_ targets: [(MPRemoteCommand, Any)]) {
        for (command, token) in targets { command.removeTarget(token) }
    }

    private func publishNowPlaying() {
        guard usesRemoteControls, player != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
        ]
    }

    /// **Deactivation is conditional, and the condition is load-bearing.**
    ///
    /// `BackgroundResidency` keeps the app out of the suspended state by playing
    /// silence through an active session. `setActive(false)` here would kill that
    /// — and not visibly: playback would look fine, and the desktop view would
    /// simply die at the next app switch, minutes later and for no apparent
    /// reason. So while residency is held, hand the session back to *it* instead
    /// of tearing it down. `reassertSessionAfterPlayback` also restores the mixing
    /// category, which matters because this player takes a non-mixing `.playback`
    /// session when no recorder is attached, and leaving that in place would keep
    /// Bounce holding the phone's audio focus after playback ended.
    private nonisolated static func deactivatePlaybackSession() async {
        if BackgroundResidency.isHoldingUnsafe {
            await BackgroundResidency.reassertSessionAfterPlayback()
            return
        }
        // notifyOthersOnDeactivation lets the SDK reclaim/resume cleanly.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Run `work`, returning true if it finished within `seconds`, false if the
    /// timeout won. The work keeps running either way (its result is discarded);
    /// we just refuse to block on it forever.
    private nonisolated static func withTimeout(
        seconds: Double, _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(time, 0), player.duration)
        currentTime = player.currentTime
        publishNowPlaying()
    }

    /// Seek by a fraction of the whole recording — what the waveform scrubber
    /// hands back, since it works in 0…1 and knows nothing about duration.
    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        seek(to: min(max(fraction, 0), 1) * duration)
    }

    /// Playhead as 0…1, for the waveform.
    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    func stop() {
        startGeneration += 1
        ticker?.cancel()
        player?.stop()
        player = nil
        currentURL = nil
        currentTitle = ""
        isPlaying = false
        Self.unregisterRemoteCommands(remoteTargets)
        remoteTargets = []
        // Only if this player owns the slot. An editor presented over a detail
        // view must not blank the now-playing info the view underneath published.
        if usesRemoteControls {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        // Hand the session back so the SDK isn't fighting us for it. Off the
        // main actor for the same reason as activation: setActive blocks.
        let previous = Self.sessionTask
        Self.sessionTask = Task {
            // Bounded for the same reason as the activation side: the chain is
            // static across view instances, so an activation still blocked in the
            // media server would otherwise hold every future stop() behind it —
            // and a stop() that never runs leaves the session active and the
            // remote commands registered for a screen the user has left.
            if let previous {
                let drained = await Self.withTimeout(seconds: 3) { await previous.value }
                if !drained { print("[Player] previous session op didn't finish in 3s; deactivating anyway") }
            }
            await Self.deactivatePlaybackSession()
        }
    }

    /// Progress, plus enforcing `playbackRanges` when the editor has set it. It
    /// never decides that playback has *finished naturally* — that is the
    /// delegate's job; reaching the end of a confined range is a different thing
    /// and is handled here.
    private func startTicker() {
        ticker?.cancel()
        let interval: Duration = playbackRanges == nil ? .milliseconds(100) : .milliseconds(25)
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if self.enforcePlaybackRanges() { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Keep the playhead inside `playbackRanges`. Returns true when playback has
    /// run past the last kept region, in which case the ticker is done.
    private func enforcePlaybackRanges() -> Bool {
        guard let ranges = playbackRanges, !ranges.isEmpty, let player else { return false }
        let time = player.currentTime
        if ranges.contains(where: { $0.contains(time) }) { return false }

        // Outside every kept region: jump to the next one, or stop.
        if let next = ranges.first(where: { $0.lowerBound > time }) {
            seek(to: next.lowerBound)
            return false
        }
        player.pause()
        isPlaying = false
        // Park at the start of the edit rather than at the raw file's end, which
        // is inside removed audio and would make the next tap resume into it.
        seek(to: ranges[0].lowerBound)
        publishNowPlaying()
        return true
    }

    // MARK: - AVAudioPlayerDelegate

    // `nonisolated` because the protocol is: AVFoundation makes no promise about
    // which queue these arrive on, so each hops to the main actor explicitly
    // rather than assuming.

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.handlePlaybackFinished(successfully: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let detail = error?.localizedDescription ?? ""
        Task { @MainActor [weak self] in
            self?.handleDecodeError(detail)
        }
    }

    private func handlePlaybackFinished(successfully flag: Bool) {
        ticker?.cancel()
        isPlaying = false
        currentTime = 0
        player?.currentTime = 0
        publishNowPlaying()
        if !flag {
            errorMessage = "Playback stopped unexpectedly. The audio file may be damaged."
        }
    }

    private func handleDecodeError(_ detail: String) {
        ticker?.cancel()
        isPlaying = false
        // Same reason as the interruption path: a stale non-zero rate leaves the
        // Lock Screen advancing over audio that has stopped.
        publishNowPlaying()
        errorMessage = "Couldn't decode this recording. \(detail)"
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        Self.unregisterRemoteCommands(remoteTargets)
    }

    static func timecode(_ seconds: TimeInterval) -> String { seconds.timecodeText }
}
