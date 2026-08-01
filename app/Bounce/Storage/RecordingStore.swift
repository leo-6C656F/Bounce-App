import Foundation

/// Local persistence: recording metadata in a JSON file, device pairing in UserDefaults.
///
/// Ported from the Plaud template app's `RecordingStore`. The important
/// invariant it protects: `audioFilename` is a bare filename, never an
/// absolute path, because the sandbox container path is not stable across
/// installs.
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
    private var cache: [Recording] = []

    private init() {
        storeURL = Self.documentsDirectory.appendingPathComponent("library.json")
        cache = Self.load(from: storeURL)
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

    // MARK: - Library

    /// Newest first.
    var recordings: [Recording] {
        cache.sorted { $0.createdAt > $1.createdAt }
    }

    func recording(id: String) -> Recording? {
        cache.first { $0.id == id }
    }

    func recording(sessionId: Int) -> Recording? {
        cache.first { $0.sessionId == sessionId }
    }

    /// Insert, skipping any session id already present.
    func add(_ newRecordings: [Recording]) {
        let known = Set(cache.map(\.sessionId))
        cache.append(contentsOf: newRecordings.filter { !known.contains($0.sessionId) })
        save()
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
        var candidate = -Int(Date().timeIntervalSince1970 * 1000)
        while candidate == -1 || recording(sessionId: candidate) != nil {
            candidate -= 1
        }
        return candidate
    }

    /// Replace the whole library — used by sync reconciliation.
    func replaceAll(_ recordings: [Recording]) {
        cache = recordings
        save()
    }

    func delete(id: String) {
        if let recording = recording(id: id) {
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
        cache.removeAll { $0.id == id }
        save()
    }

    /// Mutate one recording in place. No-op if the id is unknown.
    func update(id: String, _ mutate: (inout Recording) -> Void) {
        guard let index = cache.firstIndex(where: { $0.id == id }) else { return }
        mutate(&cache[index])
        save()
    }

    func markSynced(sessionId: Int, outputPath: String, duration: TimeInterval? = nil) {
        guard let index = cache.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        cache[index].syncedAt = Date()
        cache[index].audioFilename = (outputPath as NSString).lastPathComponent
        if let duration, duration > 0 { cache[index].duration = duration }
        save()
    }

    func clearAll() {
        for recording in cache {
            if let url = audioURL(for: recording) { try? FileManager.default.removeItem(at: url) }
        }
        cache = []
        pairedDeviceSNs = []
        activeDeviceSN = nil
        pairedDeviceNames = [:]
        userId = nil
        save()
    }

    // MARK: - Disk

    private static func load(from url: URL) -> [Recording] {
        guard let data = try? Data(contentsOf: url),
              let recordings = try? JSONDecoder().decode([Recording].self, from: data)
        else { return [] }
        return recordings.map(strippingControlTokens)
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

    private func save() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        // Explicit rather than relying on the platform default (which happens to
        // be the same class today): this file holds every transcript in the
        // library, and pinning the intent here means a future change elsewhere
        // can't silently weaken it to `.none` without the diff being visible in
        // this line. `.untilFirstUserAuthentication`, not `.complete` or
        // `.completeUnlessOpen` — sync can be triggered by a BLE reconnect while
        // the app is backgrounded, and either stronger class would make this
        // write (and the read at init) fail whenever that happens with the
        // phone locked and not yet unlocked since boot.
        try? data.write(
            to: storeURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
