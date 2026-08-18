import Foundation
import Synchronization

/// Local persistence: recording metadata in a JSON file, device pairing in UserDefaults.
///
/// Ported from the Plaud template app's `RecordingStore`. The important
/// invariant it protects: `audioFilename` is a bare filename, never an
/// absolute path, because the sandbox container path is not stable across
/// installs.
///
/// ## Isolation, indexing and off-main writes
///
/// The library is held as a `RecordingIndex` (`[id:]`/`[sessionId:]` maps + a
/// cached sorted array), guarded by a single `Mutex` (Synchronization). Every
/// public accessor is **synchronous** and takes that lock, so the store is safe to read/write from
/// any thread — reads are O(1) dictionary hits and `recordings` no longer
/// re-sorts on each access. This root-fixes the former unsynchronised-`cache`
/// data race: correctness no longer depends on ~120 call sites each being on the
/// right thread (the `SyncManager` main-hop can stay as belt-and-suspenders).
///
/// Encoding + the atomic disk write happen **off the main thread** on a serial
/// `ioQueue`, from a snapshot taken under the lock (the lock is never held across
/// the write). Saves are **coalesced**: a burst of single-field mutations in a
/// loop collapses to one whole-library serialization instead of N —
///
/// - `update` schedules a **debounced** save (~150 ms cancel-and-reschedule), so
///   the reconciliation loops in `AppModel.syncReminders`/`syncTaskCalendar` and
///   the tag/series sweeps coalesce automatically; `batchUpdate` mutates every
///   row and saves once for the same reason.
/// - Structural / user-visible durable events (`add`, `replaceAll`, `delete`,
///   `markSynced`, `batchUpdate`) save **immediately** (still off-main) so the
///   window in which a force-kill could lose them is a dispatch hop, not 150 ms.
/// - `flush()` performs a **synchronous** write and is called at lifecycle
///   boundaries (scene → background, terminate) where the process may be
///   suspended before an async write lands.
///
/// **Reentrancy:** the mutex is non-recursive, so a `mutate`/`batchUpdate`
/// closure must not call back into a public method of this store (all existing
/// closures only touch the `inout Recording`). Write failures are logged and
/// surfaced via `lastSaveError` rather than swallowed with `try?`.
final class RecordingStore {

    static let shared = RecordingStore()

    private enum Keys {
        static let pairedDeviceSNs = "pairedDeviceSNs"
        static let activeDeviceSN = "activeDeviceSN"
        static let pairedDeviceNames = "pairedDeviceNames"
        static let userId = "userId"
    }

    private let defaults = UserDefaults.standard
    private let storeURL: URL

    /// Everything the mutex protects, kept in one value so a single `Mutex`
    /// guards it all. `withLock` hands the body scoped, `inout` access — there is
    /// no raw lock/unlock to leak, and the type system enforces that the state is
    /// only reachable through the mutex.
    private struct State {
        var index: RecordingIndex
        /// Set when `library.json` existed at launch but couldn't be decoded, *and*
        /// the unreadable file couldn't be moved aside. While true, saves refuse to
        /// write — so a decode bug a future build could fix can't be turned into
        /// permanent, silent data loss by the next background mutation overwriting
        /// the only copy with `[]`. If the file was successfully preserved
        /// (`library.corrupt-<ts>.json`), this stays `false` and saves proceed
        /// normally against a fresh library.
        var refusesToSave: Bool
        /// The pending debounced save, cancelled and rescheduled on each `update`
        /// so a loop of mutations coalesces into one write.
        var pendingSave: DispatchWorkItem?
        /// The most recent save failure (encode or write), or nil after a success.
        var lastSaveError: Error?
    }

    /// Guards `State`. Swift `Mutex` (Synchronization) rather than a raw lock:
    /// scoped `withLock {}` access is harder to misuse than lock/unlock, and it's
    /// a value type. Non-recursive — a `mutate`/`batchUpdate` closure must not
    /// call back into a public store method, and the lock is never held across the
    /// disk write (snapshot under `withLock`, then encode+write on `ioQueue`).
    private let state: Mutex<State>

    /// Serial queue that owns every encode + atomic write. `.utility` because a
    /// library save is background housekeeping, never latency-critical for the UI.
    private let ioQueue = DispatchQueue(label: "ai.bounce.recordingstore.io", qos: .utility)
    private let debounceInterval: DispatchTimeInterval = .milliseconds(150)

    /// The most recent save failure (encode or write), or nil after a success.
    /// Surfaced instead of swallowing the error with `try?` so a disk-full or
    /// locked-file failure can't silently diverge the in-memory library from disk.
    var lastSaveError: Error? {
        state.withLock { $0.lastSaveError }
    }

    private init() {
        storeURL = Self.documentsDirectory.appendingPathComponent("library.json")
        let loadedIndex: RecordingIndex
        var refuses = false
        switch Self.load(from: storeURL) {
        case .loaded(let recordings):
            loadedIndex = RecordingIndex(recordings)
        case .missing:
            loadedIndex = RecordingIndex()
        case .corrupt:
            loadedIndex = RecordingIndex()
            // A decode failure is recoverable by a future fix, but only while the
            // bytes still exist. Preserve them before anything can overwrite the
            // library with []; if that move fails, protect the file by refusing
            // to save this session.
            refuses = !Self.preserveCorrupt(at: storeURL)
        }
        state = Mutex(State(index: loadedIndex, refusesToSave: refuses, pendingSave: nil, lastSaveError: nil))
        backupOnceIfNeeded()
    }

    /// One-time, best-effort copy of the existing `library.json` aside, made the
    /// first time this build's new store runs. Pure belt-and-suspenders: if a
    /// rollout bug in the rewritten save path ever wrote bad data, the untouched
    /// pre-refactor library is still on disk as `library.backup-<ts>.json`.
    ///
    /// Enqueued on `ioQueue` from `init`, so it is off the main thread (never
    /// blocks launch) and — because that queue is serial — runs *before* the
    /// first save this session could enqueue. Gated by a `UserDefaults` marker so
    /// it happens once. The marker is set only when the backup succeeds or there
    /// is nothing to back up, so a transient copy failure retries next launch
    /// rather than being lost.
    private func backupOnceIfNeeded() {
        let markerKey = "store.backup.preIndexRefactor.done"
        guard !defaults.bool(forKey: markerKey) else { return }
        let src = storeURL
        let stamp = Int(Date().timeIntervalSince1970)
        ioQueue.async { [defaults] in
            guard FileManager.default.fileExists(atPath: src.path) else {
                // No library yet (first install) — nothing to protect, don't retry.
                defaults.set(true, forKey: markerKey)
                return
            }
            let dst = src.deletingLastPathComponent()
                .appendingPathComponent("library.backup-\(stamp).json")
            do {
                try FileManager.default.copyItem(at: src, to: dst)
                defaults.set(true, forKey: markerKey)
                print("[Store] one-time pre-refactor backup written: \(dst.lastPathComponent)")
            } catch {
                // Leave the marker unset so the next launch tries again.
                print("[Store] one-time pre-refactor backup failed (\(error.localizedDescription)); will retry next launch")
            }
        }
    }

    // MARK: - Paths

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Directory the SDK exports synced audio into.
    ///
    /// Bounce doesn't control the write call for SDK-exported files — that
    /// happens inside the vendor binary — so the protection class can't be set
    /// per file the way `save()` and `MP3Frames` set it on the files Bounce
    /// writes itself. Setting it on the directory is the mechanism for that
    /// case: iOS has new files created within a directory inherit its
    /// `NSFileProtectionKey` unless the creator explicitly overrides it, and
    /// nothing here does. Same `.untilFirstUserAuthentication` reasoning as
    /// `RecordingStore.save()` — sync can land while backgrounded.
    /// `lazy`, not a plain computed property — this is read on nearly every
    /// recording/sync operation (`audioURL(for:)`, every list render, every
    /// SDK export call), and `RecordingStore` is a process-lifetime singleton,
    /// so there's no reason to repeat `createDirectory`/`setAttributes` on
    /// every access when doing it once achieves the same result.
    lazy var audioDirectory: URL = {
        let dir = Self.documentsDirectory.appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path)
        return dir
    }()

    /// Resolve a recording's audio to an absolute URL inside the *current* sandbox.
    func audioURL(for recording: Recording) -> URL? {
        guard let name = recording.audioFilename, !name.isEmpty else { return nil }
        let candidates = [
            audioDirectory.appendingPathComponent(name),
            Self.documentsDirectory.appendingPathComponent(name),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Pairing

    var userId: String? {
        get { defaults.string(forKey: Keys.userId) }
        set { defaults.set(newValue, forKey: Keys.userId) }
    }

    var pairedDeviceSNs: [String] {
        get { defaults.stringArray(forKey: Keys.pairedDeviceSNs) ?? [] }
        set { defaults.set(newValue, forKey: Keys.pairedDeviceSNs) }
    }

    /// The device we currently want to be talking to. BLE allows one at a time.
    var activeDeviceSN: String? {
        get { defaults.string(forKey: Keys.activeDeviceSN) }
        set { defaults.set(newValue, forKey: Keys.activeDeviceSN) }
    }

    private var pairedDeviceNames: [String: String] {
        get { defaults.dictionary(forKey: Keys.pairedDeviceNames) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.pairedDeviceNames) }
    }

    func addPairedDevice(sn: String, name: String) {
        var sns = pairedDeviceSNs
        if !sns.contains(sn) { sns.append(sn) }
        pairedDeviceSNs = sns
        var names = pairedDeviceNames
        names[sn] = name
        pairedDeviceNames = names
        activeDeviceSN = sn
    }

    func removePairedDevice(sn: String) {
        var sns = pairedDeviceSNs
        sns.removeAll { $0 == sn }
        pairedDeviceSNs = sns
        var names = pairedDeviceNames
        names.removeValue(forKey: sn)
        pairedDeviceNames = names
        if activeDeviceSN == sn { activeDeviceSN = sns.first }
    }

    func deviceName(for sn: String) -> String {
        pairedDeviceNames[sn] ?? sn
    }

    var pairedDevices: [PairedDeviceInfo] {
        pairedDeviceSNs.map {
            PairedDeviceInfo(serialNumber: $0, name: deviceName(for: $0), model: PlaudModel(serialNumber: $0))
        }
    }

    var hasPairedDevice: Bool { !pairedDeviceSNs.isEmpty && userId != nil }

    // MARK: - Library (reads — O(1)/no per-access re-sort, under the lock)

    /// Newest first.
    var recordings: [Recording] {
        state.withLock { $0.index.sorted() }
    }

    func recording(id: String) -> Recording? {
        state.withLock { $0.index.recording(id: id) }
    }

    func recording(sessionId: Int) -> Recording? {
        state.withLock { $0.index.recording(sessionId: sessionId) }
    }

    // MARK: - Library (mutations)

    /// Insert, skipping any session id already present. Saves immediately
    /// (off-main): a new/merged recording is a durable event worth persisting
    /// without waiting out the debounce window.
    func add(_ newRecordings: [Recording]) {
        let (snapshot, refuses) = state.withLock { s -> ([Recording], Bool) in
            s.index.add(newRecordings)
            return (s.index.allUnsorted, s.refusesToSave)
        }
        saveNow(snapshot: snapshot, refuses: refuses)
    }

    /// A `sessionId` the recorder can never produce, for a recording this app
    /// created itself — an edited copy, a merge.
    ///
    /// Real ids are the recording's start time as a Unix timestamp, so always
    /// positive and in the 1.4–2.5 billion range. A collision would be silent and
    /// destructive: `markSynced` joins on `sessionId`, so a device download
    /// landing on this id would overwrite the app-made recording's
    /// `audioFilename` with the raw file's, orphan its audio, and leave the real
    /// recording never marked synced — so it gets wiped and re-listed on every
    /// connection.
    ///
    /// Negative and verified unique against the library. `-1` is skipped because
    /// `Web/LiveChannel` uses it as its "no live session" sentinel and sharing the
    /// value only makes logs ambiguous.
    func syntheticSessionId() -> Int {
        state.withLock { s in
            var candidate = -Int(Date().timeIntervalSince1970 * 1000)
            // Uses the index directly rather than the public `recording(sessionId:)`,
            // which would re-enter the non-recursive mutex and deadlock.
            while candidate == -1 || s.index.recording(sessionId: candidate) != nil {
                candidate -= 1
            }
            return candidate
        }
    }

    /// Replace the whole library — used by sync reconciliation. Saves immediately.
    func replaceAll(_ recordings: [Recording]) {
        let (snapshot, refuses) = state.withLock { s -> ([Recording], Bool) in
            s.index.replaceAll(recordings)
            return (s.index.allUnsorted, s.refusesToSave)
        }
        saveNow(snapshot: snapshot, refuses: refuses)
    }

    func delete(id: String) {
        let (removed, snapshot, refuses) = state.withLock { s -> (Recording?, [Recording], Bool) in
            let removed = s.index.remove(id: id)
            return (removed, s.index.allUnsorted, s.refusesToSave)
        }

        // File-system cleanup happens off the lock (FileManager / WaveformCache
        // must never run while the mutex is held).
        if let recording = removed {
            if let url = audioURL(for: recording) {
                try? FileManager.default.removeItem(at: url)
            }
            // Keyed off `audioFilename` rather than the resolved URL, and outside
            // the `audioURL` binding on purpose: `audioURL` returns nil when the
            // audio is already missing (a failed sync, a container migration),
            // which is precisely the case where the envelope would otherwise be
            // orphaned forever.
            if let name = recording.audioFilename, !name.isEmpty {
                WaveformCache.forget(audioNamed: name)
            }
        }
        saveNow(snapshot: snapshot, refuses: refuses)
    }

    /// Mutate one recording in place. No-op if the id is unknown. Schedules a
    /// **debounced** save so a loop of `update`s (Reminders/Calendar reconcile,
    /// tag/series sweeps) coalesces into a single whole-library write.
    ///
    /// The `mutate` closure runs while the mutex is held and must not call back
    /// into this store.
    func update(id: String, _ mutate: (inout Recording) -> Void) {
        let result = state.withLock { s -> ([Recording], Bool)? in
            guard s.index.update(id: id, mutate) else { return nil }
            return (s.index.allUnsorted, s.refusesToSave)
        }
        if let (snapshot, refuses) = result { scheduleSave(snapshot: snapshot, refuses: refuses) }
    }

    /// Mutate **every** recording in one pass and save once. The closure guards
    /// itself (e.g. `guard var items = rec.actionItems`), mirroring the old
    /// `for recording in recordings { update(...) }` loops but without N
    /// whole-library serializations. Saves immediately when anything changed.
    func batchUpdate(_ mutate: (inout Recording) -> Void) {
        let result = state.withLock { s -> ([Recording], Bool)? in
            guard s.index.updateEach(mutate) > 0 else { return nil }
            return (s.index.allUnsorted, s.refusesToSave)
        }
        if let (snapshot, refuses) = result { saveNow(snapshot: snapshot, refuses: refuses) }
    }

    func markSynced(sessionId: Int, outputPath: String, duration: TimeInterval? = nil) {
        let result = state.withLock { s -> ([Recording], Bool)? in
            guard let existing = s.index.recording(sessionId: sessionId) else { return nil }
            let found = s.index.update(id: existing.id) { rec in
                rec.syncedAt = Date()
                rec.audioFilename = (outputPath as NSString).lastPathComponent
                if let duration, duration > 0 { rec.duration = duration }
            }
            return found ? (s.index.allUnsorted, s.refusesToSave) : nil
        }
        // A file becoming synced is durable (and, unpersisted, re-downloads on the
        // next connect), so save immediately rather than debounced.
        if let (snapshot, refuses) = result { saveNow(snapshot: snapshot, refuses: refuses) }
    }

    func clearAll() {
        let (all, refuses) = state.withLock { s -> ([Recording], Bool) in
            let all = s.index.allUnsorted
            s.index.replaceAll([])
            return (all, s.refusesToSave)
        }

        for recording in all {
            if let url = audioURL(for: recording) { try? FileManager.default.removeItem(at: url) }
        }
        pairedDeviceSNs = []
        activeDeviceSN = nil
        pairedDeviceNames = [:]
        userId = nil
        saveNow(snapshot: [], refuses: refuses)
    }

    /// Synchronously flush any pending write to disk. Called at lifecycle
    /// boundaries (scene → background, terminate) where the process may be
    /// suspended before an async save lands. Blocks the caller until the write
    /// completes; use only at those boundaries, not on hot paths.
    func flush() {
        let (snapshot, refuses) = state.withLock { s -> ([Recording], Bool) in
            s.pendingSave?.cancel()
            s.pendingSave = nil
            return (s.index.allUnsorted, s.refusesToSave)
        }
        ioQueue.sync { self.write(snapshot, refuses: refuses) }
    }

    // MARK: - Disk

    /// Cancel any in-flight debounced save and schedule a fresh one. A burst of
    /// mutations therefore results in exactly one write, ~`debounceInterval` after
    /// the last one.
    private func scheduleSave(snapshot: [Recording], refuses: Bool) {
        let work = DispatchWorkItem { [weak self] in self?.write(snapshot, refuses: refuses) }
        state.withLock { s in
            s.pendingSave?.cancel()
            s.pendingSave = work
        }
        ioQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Write immediately (still off-main) — no debounce wait. Cancels any pending
    /// debounced save first so the two can't race to write stale-then-fresh.
    private func saveNow(snapshot: [Recording], refuses: Bool) {
        state.withLock { s in
            s.pendingSave?.cancel()
            s.pendingSave = nil
        }
        ioQueue.async { self.write(snapshot, refuses: refuses) }
    }

    /// The one place that encodes + atomically writes the library. Always runs on
    /// `ioQueue`; never holds the mutex.
    private func write(_ recordings: [Recording], refuses: Bool) {
        // An undecodable library at launch that couldn't be preserved aside is
        // protected here: writing now would overwrite the only recoverable copy
        // with whatever this session built ([] in the worst case). See `init`.
        guard !refuses else {
            print("[Store] save skipped — library failed to decode this launch and is being protected")
            return
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(recordings)
        } catch {
            // The encode leg (e.g. a non-finite float in a segment time). Surface
            // it rather than silently keeping disk stale.
            recordSaveError(error, phase: "encode")
            return
        }
        do {
            // Explicit protection class rather than relying on the platform default
            // (which happens to be the same class today): this file holds every
            // transcript in the library, and pinning the intent here means a future
            // change elsewhere can't silently weaken it to `.none` without the diff
            // being visible in this line. `.untilFirstUserAuthentication`, not
            // `.complete` or `.completeUnlessOpen` — sync can be triggered by a BLE
            // reconnect while the app is backgrounded, and either stronger class
            // would make this write (and the read at init) fail whenever that
            // happens with the phone locked and not yet unlocked since boot.
            try data.write(
                to: storeURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            clearSaveError()
        } catch {
            // The write leg — disk full, or the protection class rejecting the
            // write while the device is locked and not yet unlocked since boot.
            // Previously swallowed with `try?`, which let the in-memory library
            // diverge from disk with no signal. Retry once, then surface.
            do {
                try data.write(
                    to: storeURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                clearSaveError()
            } catch {
                recordSaveError(error, phase: "write")
            }
        }
    }

    private func recordSaveError(_ error: Error, phase: String) {
        state.withLock { $0.lastSaveError = error }
        print("[Store] library \(phase) failed: \(error.localizedDescription) — in-memory library is ahead of disk")
    }

    private func clearSaveError() {
        state.withLock { if $0.lastSaveError != nil { $0.lastSaveError = nil } }
    }

    /// Outcome of reading `library.json`. The distinction between `.missing` and
    /// `.corrupt` is the whole point: conflating them (returning `[]` for both)
    /// let the next `save()` overwrite an unreadable-but-recoverable library with
    /// an empty one — turning a decode bug into permanent data loss.
    private enum LoadOutcome {
        case loaded([Recording])
        case missing
        case corrupt
    }

    private static func load(from url: URL) -> LoadOutcome {
        // No file at all — a first launch, or a wiped install. Nothing to lose.
        guard let data = try? Data(contentsOf: url) else { return .missing }
        // The file exists but doesn't decode. Deliberately *not* swallowed with
        // `try?` into `[]`: the caller preserves the bytes before any write.
        guard let recordings = try? JSONDecoder().decode([Recording].self, from: data) else {
            return .corrupt
        }
        return .loaded(recordings.map(strippingControlTokens))
    }

    /// Move an undecodable `library.json` aside so a later `save()` can't destroy
    /// the only copy of data a future decode fix could recover. Returns `true`
    /// when the live path is now clear (safe to write a fresh library), `false`
    /// when the corrupt file could not be moved and must instead be protected by
    /// refusing to save this session.
    private static func preserveCorrupt(at url: URL) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let sidelined = url.deletingLastPathComponent()
            .appendingPathComponent("library.corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: sidelined)
            print("[Store] library.json failed to decode — preserved as \(sidelined.lastPathComponent)")
            return true
        } catch {
            print("[Store] library.json failed to decode and could not be moved aside "
                + "(\(error)); refusing to save this session to avoid overwriting it")
            return false
        }
    }

    /// Scrub Soniox control tokens out of transcripts written before
    /// `Soniox.isControlToken` existed.
    ///
    /// Live sessions with endpoint detection on appended `<end>` to the
    /// transcript verbatim, so stored previews read "…their two best. `<end>`"
    /// and, worse, carried segments with no timing — which collapse to
    /// `start: 0` and collide on `TranscriptSegment.id`. Idempotent, so it costs
    /// one pass over the library at launch and nothing after the first save.
    private static func strippingControlTokens(_ recording: Recording) -> Recording {
        var recording = recording
        recording.transcript = recording.transcript.map(clean)
        recording.livePreview = recording.livePreview.map(clean)
        return recording
    }

    private static func clean(_ transcript: Transcript) -> Transcript {
        let segments = transcript.segments.compactMap { segment -> TranscriptSegment? in
            guard !Soniox.isControlToken(segment.text) else { return nil }
            // A marker could also have been merged into a phrase's head, since
            // it only got its own segment when the speaker changed with it.
            var text = segment.text
            for token in Soniox.controlTokens where text.hasPrefix(token) {
                text = String(text.dropFirst(token.count))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return text == segment.text
                ? segment
                : TranscriptSegment(
                    text: text, start: segment.start, end: segment.end, speaker: segment.speaker)
        }
        guard segments.count != transcript.segments.count
                || zip(segments, transcript.segments).contains(where: { $0.text != $1.text })
        else { return transcript }
        return Transcript(
            segments: segments,
            localeIdentifier: transcript.localeIdentifier,
            createdAt: transcript.createdAt,
            isPreview: transcript.isPreview)
    }
}
