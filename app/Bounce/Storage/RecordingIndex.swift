import Foundation

/// The pure, testable core of `RecordingStore`'s in-memory library: the two
/// lookup maps (`byId`, `bySession`) and a lazily-materialised newest-first
/// sorted array, kept in step under every mutation.
///
/// Extracted from `RecordingStore` so the indexing/coalescing invariants can be
/// exercised as pure Foundation code by `tools/recordingstore-tests` — the store
/// itself drags in `Soniox`, `WaveformCache`, `UserDefaults` and disk I/O and
/// can't compile outside the app. `RecordingStore` composes this and adds the
/// lock, the off-main coalesced save and the corrupt-library quarantine.
///
/// Why the sorted array can be cached across `update`s: `Recording.id`,
/// `sessionId` and `createdAt` are all `let`, so a `mutate` closure can never
/// change a key or the sort order — only structural changes (insert/remove/
/// replaceAll) invalidate the cache. `update`/`markSynced` patch the value in
/// place and leave the ordering untouched, so they don't force a re-sort.
struct RecordingIndex {

    /// O(1) lookup by stable recording id.
    private(set) var byId: [String: Recording] = [:]
    /// O(1) lookup by recorder session id.
    private(set) var bySession: [Int: Recording] = [:]

    /// Newest-first, materialised on demand and reused until a structural change
    /// invalidates it. `nil` means "stale — rebuild on next read".
    private var sortedCache: [Recording]?

    init(_ recordings: [Recording] = []) {
        replaceAll(recordings)
    }

    var count: Int { byId.count }

    // MARK: - Reads

    /// Newest first. O(N log N) only on the first read after a structural change;
    /// O(1) thereafter.
    mutating func sorted() -> [Recording] {
        if let cached = sortedCache { return cached }
        let result = byId.values.sorted { $0.createdAt > $1.createdAt }
        sortedCache = result
        return result
    }

    func recording(id: String) -> Recording? { byId[id] }
    func recording(sessionId: Int) -> Recording? { bySession[sessionId] }

    /// Every recording in unspecified order — the snapshot the store encodes to
    /// disk. Order is irrelevant on disk (the library is re-sorted on load), and
    /// skipping the sort keeps the save path off the O(N log N) cost.
    var allUnsorted: [Recording] { Array(byId.values) }

    // MARK: - Structural mutations (invalidate the sorted cache)

    /// Insert, skipping any `sessionId` already present. Returns the ids actually
    /// inserted, so a caller can confirm a synthetic-id row really landed (the
    /// merge/edit path depends on this — a silent drop orphans audio).
    @discardableResult
    mutating func add(_ newRecordings: [Recording]) -> [String] {
        var inserted: [String] = []
        for recording in newRecordings where bySession[recording.sessionId] == nil {
            byId[recording.id] = recording
            bySession[recording.sessionId] = recording
            inserted.append(recording.id)
        }
        if !inserted.isEmpty { sortedCache = nil }
        return inserted
    }

    mutating func replaceAll(_ recordings: [Recording]) {
        byId.removeAll(keepingCapacity: true)
        bySession.removeAll(keepingCapacity: true)
        for recording in recordings {
            byId[recording.id] = recording
            bySession[recording.sessionId] = recording
        }
        sortedCache = nil
    }

    /// Remove by id. Returns the removed recording (so the store can clean up its
    /// audio + waveform envelope). No-op if unknown.
    @discardableResult
    mutating func remove(id: String) -> Recording? {
        guard let removed = byId.removeValue(forKey: id) else { return nil }
        bySession.removeValue(forKey: removed.sessionId)
        sortedCache = nil
        return removed
    }

    // MARK: - In-place mutations (order preserved; no re-sort)

    /// Mutate one recording in place. No-op if the id is unknown. Returns whether
    /// a row was found. `id`/`sessionId`/`createdAt` are `let`, so this can never
    /// move the row in sort order — the cached element is patched in place.
    @discardableResult
    mutating func update(id: String, _ mutate: (inout Recording) -> Void) -> Bool {
        guard var recording = byId[id] else { return false }
        mutate(&recording)
        byId[id] = recording
        bySession[recording.sessionId] = recording
        patchSorted(recording)
        return true
    }

    /// Apply `mutate` to every row once. The store's coalesced-save path calls
    /// this so an N-row reconciliation (Reminders/Calendar sync) mutates all rows
    /// and saves a single time, instead of N whole-library serializations.
    /// Returns the number of rows the closure actually changed.
    @discardableResult
    mutating func updateEach(_ mutate: (inout Recording) -> Void) -> Int {
        var changed = 0
        for id in byId.keys {
            guard var recording = byId[id] else { continue }
            let before = recording
            mutate(&recording)
            guard recording != before else { continue }
            byId[id] = recording
            bySession[recording.sessionId] = recording
            changed += 1
        }
        if changed > 0 { sortedCache = nil }
        return changed
    }

    /// Patch a single already-present row inside the cached sorted array so a
    /// subsequent `sorted()` doesn't have to re-sort the whole library after an
    /// `update`. Order is unchanged because the sort key (`createdAt`) is `let`.
    private mutating func patchSorted(_ recording: Recording) {
        guard sortedCache != nil else { return }
        if let i = sortedCache!.firstIndex(where: { $0.id == recording.id }) {
            sortedCache![i] = recording
        } else {
            sortedCache = nil
        }
    }
}
