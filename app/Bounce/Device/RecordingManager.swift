import Combine
import Foundation
import PlaudBleSDK
import PlaudDeviceBasicSDK

/// Live recording state and the waveform level that drives the record screen.
///
/// All `handle*` methods are called by `DeviceManager`, which owns the SDK
/// delegate slot — nothing else should call them.
final class RecordingManager {

    static let shared = RecordingManager()

    private let stateSubject = CurrentValueSubject<RecordingState, Never>(.idle)
    private let levelSubject = PassthroughSubject<Float, Never>()

    var statePublisher: AnyPublisher<RecordingState, Never> { stateSubject.eraseToAnyPublisher() }
    /// Normalised 0–1 microphone level, emitted every 100ms while recording.
    var levelPublisher: AnyPublisher<Float, Never> { levelSubject.eraseToAnyPublisher() }

    var state: RecordingState { stateSubject.value }

    /// Latest level, written on the BLE callback queue and read by the main-queue
    /// timer. The indirection decouples rendering from BLE packet jitter; the
    /// lock is what makes the cross-queue handoff actually safe.
    private var latestLevel: Float = 0
    private let levelLock = NSLock()
    private var levelTimer: Timer?

    /// Wall-clock anchor for the session currently being recorded, so a
    /// pause/resume restores the same one instead of re-deriving it from a
    /// callback field. Keyed by session id so the next recording can't inherit it.
    private var sessionAnchor: (sessionId: Int, startedAt: Date)?

    private init() {}

    // MARK: - Callbacks from DeviceManager

    func handleRecordStart(sessionId: Int, startTime: Int) {
        stateSubject.send(.recording(
            sessionId: sessionId,
            startedAt: anchor(sessionId: sessionId, startTime: startTime)))
        startLevelTimer()

        // Hop to main: this callback arrives on the SDK's queue, and both the
        // settings store and the live transcriber are main-actor isolated.
        Task { @MainActor in
            // The one moment worth a location fix: the recorder is recording and
            // the phone is in Bluetooth range of it, so wherever the phone is, the
            // recording is. Fire-and-forget and silent when the setting is off —
            // and deliberately ahead of the live-transcription guard below, since
            // the two features are unrelated.
            PlaceStore.shared.captureAtRecordStart(sessionId: sessionId)

            // Logged rather than silent: a stored `false` from an earlier build
            // survives a change to the code default, so "nothing happened" is
            // otherwise indistinguishable from a bug.
            guard DeliverySettings.shared.liveTranscription else {
                TranscribeLog.log("live: skipped — turn on Live transcription in Settings")
                return
            }
            LiveTranscriber.shared.start(
                sessionId: sessionId,
                locale: DeliverySettings.shared.transcriptionLocale
            )
        }
    }

    func handleRecordStop(sessionId: Int) {
        stopLevelTimer()
        sessionAnchor = nil
        stateSubject.send(.idle)

        // The new file's cost should show on the Recorder card now, not at the
        // next reconnect. The sync that starts below refreshes again when its
        // queue drains; this reading is the one that still happens when
        // delete-after-sync is off or the sync fails. The debounce inside
        // `refreshStorage` means the two rarely cost two commands.
        DeviceManager.shared.refreshStorage()

        // Keep the live transcript as a stand-in until the real file syncs and
        // gets transcribed properly.
        Task { @MainActor in
            if let transcript = await LiveTranscriber.shared.stop() {
                LiveTranscriptStore.shared.hold(transcript, forSessionId: sessionId)
            }
        }

        // Give the recorder a moment to finalise the file, then pull it down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SyncManager.shared.startSync()
        }
    }

    func handleRecordPause(sessionId: Int) {
        stopLevelTimer()
        stateSubject.send(.paused(sessionId: sessionId))

        // No more bytes will arrive until the resume, so stop slicing rather than
        // re-decoding the same buffer every few seconds.
        Task { @MainActor in LiveTranscriber.shared.suspendStreaming() }
    }

    func handleRecordResume(sessionId: Int, startTime: Int) {
        stateSubject.send(.recording(
            sessionId: sessionId,
            startedAt: anchor(sessionId: sessionId, startTime: startTime)))
        startLevelTimer()

        // A pause silently ends the BLE file read, so without this the live
        // transcript stays frozen at the pause for the rest of the recording.
        Task { @MainActor in LiveTranscriber.shared.resumeStreaming() }
    }

    /// The wall-clock instant a session started, for the elapsed readout.
    ///
    /// `startTime` arrives as **0** from real hardware — `bleRecordStart` logs
    /// `startTime:0` — and `bleRecordResume` carries the same field, so resume
    /// used to anchor the timer at `Date(timeIntervalSince1970: 0)` and the
    /// elapsed readout jumped to ~1.8 billion seconds on the record screen, the
    /// tab-bar accessory and the Live Activity. Hence two rules: an anchor
    /// already established for this session always wins, so pause/resume can't
    /// move it; and a candidate must look like a plausible Unix timestamp before
    /// it's trusted at all.
    ///
    /// Elapsed therefore counts paused time, which is what the Live Activity
    /// already did (it keeps its own anchor across a pause) — not what the
    /// recorder's file duration will say.
    private func anchor(sessionId: Int, startTime: Int) -> Date {
        if let sessionAnchor, sessionAnchor.sessionId == sessionId {
            return sessionAnchor.startedAt
        }
        let startedAt = Self.plausibleDate(sessionId) ?? Self.plausibleDate(startTime) ?? Date()
        sessionAnchor = (sessionId, startedAt)
        return startedAt
    }

    /// Session ids are Unix timestamps — `RecordingStore.markSynced` joins on
    /// them — so a value outside a sane range is a field we've misread, not a date.
    private static func plausibleDate(_ unixSeconds: Int) -> Date? {
        guard unixSeconds >= 1_500_000_000 else { return nil }        // 2017-07
        let date = Date(timeIntervalSince1970: Double(unixSeconds))
        guard date.timeIntervalSinceNow <= 60 else { return nil }     // not in the future
        return date
    }

    /// Decoded PCM from `blePcmData`: 640 bytes, 16 kHz mono. Never actually
    /// called — `blePcmData` doesn't fire for E2EE recordings (see
    /// `DeviceManager.startLivePCMStream`) — but kept because it's the right
    /// input if Plaud ever ships decoded audio, and because it also forwards
    /// to `LiveTranscriber`. The real level meter is fed by `updateLevel`,
    /// called from `LiveTranscriber.pumpSlice()` with the same decoded PCM
    /// the live decrypt/decode pipeline already produces.
    func handlePcmData(_ pcmData: Data) {
        updateLevel(fromPCM: pcmData)
        LiveTranscriber.shared.ingest(pcmData)
    }

    /// `averageVolume` returns roughly 0–90 dB, which we normalise to 0–1.
    func updateLevel(fromPCM pcmData: Data) {
        let decibels = JXRecordVolumer.shared.averageVolume(pcmData)
        let normalised = Float(min(max(decibels, 0), 90)) / 90.0
        levelLock.withLock { latestLevel = normalised }
    }

    // MARK: - Level timer

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.levelSubject.send(self.levelLock.withLock { self.latestLevel })
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        levelLock.withLock { latestLevel = 0 }
        levelSubject.send(0)
    }
}
