import Foundation

/// On-disk record of the live session in progress, so leaving Bounce — or being
/// killed while it's backgrounded — doesn't restart the transcript from the top
/// of the call.
///
/// Two artefacts per session, both in Caches (never backed up, and both
/// rebuildable):
///
/// - `<sessionId>.json` — the committed segments and how far into the audio they
///   reach. This restores the **text**.
/// - `<sessionId>.dat` — the assembled encrypted stream so far, extended on every
///   decode slice. This restores the **position**, and it is the part that makes
///   resuming worth anything: without it the recorder has to re-stream the
///   recording from byte 0, and at the ~4–6 KB/s this link delivers against a
///   recorder producing ~3.6 KB/s of audio, a long call never catches up.
///
/// The `.dat` is the recorder's own E2EE bytes, decryptable only with the RSA
/// private key in the keychain, so this stores nothing the recording hadn't
/// already put on the device. It is deleted the moment the recording stops.
@MainActor
final class LiveSessionCheckpoint {

    static let shared = LiveSessionCheckpoint()

    struct Record: Codable, Sendable {
        var sessionId: Int
        /// Committed segments, on the **recording's** timeline (not the engine's).
        var segments: [TranscriptSegment]
        /// How much decoded PCM those segments account for — 16 kHz mono Int16, so
        /// 32,000 bytes a second. A resume rewinds the decoder to exactly here,
        /// which re-transcribes the few seconds that were still volatile rather
        /// than losing the words in them.
        var transcribedPCMBytes: Int
        var localeIdentifier: String
        var updatedAt: Date
    }

    /// Finished records are kept until the recording syncs and the preview is
    /// applied. Anything older than this is from a session that never will.
    private static let staleAfter: TimeInterval = 24 * 60 * 60

    private let directory: URL

    private init() {
        directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveSession", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Text

    func record(forSessionId sessionId: Int) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(sessionId)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    func allRecords() -> [Record] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { Int($0.replacingOccurrences(of: ".json", with: "")) }
            .compactMap { record(forSessionId: $0) }
    }

    func save(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: recordURL(record.sessionId), options: .atomic)
    }

    // MARK: - Partial audio

    func partialAudio(forSessionId sessionId: Int) -> Data? {
        try? Data(contentsOf: audioURL(sessionId))
    }

    /// Extend the on-disk copy of the assembled stream, and report how much of it
    /// is now written.
    ///
    /// The file has to stay a byte-exact prefix of the buffer in memory —
    /// absolute offsets are what make the decrypt work at all — so if it has gone
    /// missing (Caches eviction, a failed write) the whole buffer is rewritten
    /// rather than an append landing at the wrong offset.
    func appendPartialAudio(
        _ file: Data, forSessionId sessionId: Int, alreadyWritten: Int
    ) -> Int {
        guard file.count > alreadyWritten else { return alreadyWritten }
        let url = audioURL(sessionId)
        do {
            if alreadyWritten == 0 || !FileManager.default.fileExists(atPath: url.path) {
                try file.write(to: url, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(file.suffix(from: alreadyWritten)))
            }
            return file.count
        } catch {
            TranscribeLog.log("live: couldn't checkpoint partial audio: \(error)")
            return alreadyWritten
        }
    }

    /// Drop the audio but keep the text: called when the recording stops, at which
    /// point there is nothing left to resume but the preview is still waiting for
    /// the file to sync.
    func discardPartialAudio(sessionId: Int) {
        try? FileManager.default.removeItem(at: audioURL(sessionId))
    }

    // MARK: - Housekeeping

    func clear(sessionId: Int) {
        try? FileManager.default.removeItem(at: recordURL(sessionId))
        try? FileManager.default.removeItem(at: audioURL(sessionId))
    }

    /// Remove sessions that will never be resumed or applied. `keeping` is the
    /// session about to start, which may have just been written.
    func pruneStale(keeping sessionId: Int?) {
        for record in allRecords() where record.sessionId != sessionId {
            guard -record.updatedAt.timeIntervalSinceNow > Self.staleAfter else { continue }
            TranscribeLog.log("live: pruning stale checkpoint for \(record.sessionId)")
            clear(sessionId: record.sessionId)
        }
    }

    private func recordURL(_ sessionId: Int) -> URL {
        directory.appendingPathComponent("\(sessionId).json")
    }

    private func audioURL(_ sessionId: Int) -> URL {
        directory.appendingPathComponent("\(sessionId).dat")
    }
}
