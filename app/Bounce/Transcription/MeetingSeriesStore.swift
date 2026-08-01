import Foundation
import Observation

/// The user's meeting series, persisted in `UserDefaults`.
///
/// Same shape as `CategoryStore` — a `@MainActor @Observable` singleton over one
/// encoded array, with a sweep on delete — because it has the same problem:
/// recordings reference these by id, so a deleted series that isn't swept out
/// leaves ids resolving to nothing, rendering as blank and impossible to clear.
///
/// Not seeded with anything. A series only exists because a recurring calendar
/// event produced one or the user made it, and inventing "Weekly standup" for
/// someone who has none would be noise.
@MainActor
@Observable
final class MeetingSeriesStore {

    static let shared = MeetingSeriesStore()

    private let defaultsKey = "meetingSeries"

    private(set) var series: [MeetingSeries]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([MeetingSeries].self, from: data) {
            series = stored
        } else {
            series = []
        }
    }

    // MARK: - Reading

    func series(id: String?) -> MeetingSeries? {
        guard let id else { return nil }
        return series.first { $0.id == id }
    }

    /// The series created from a given recurring calendar event, if any.
    func series(forCalendarKey key: String) -> MeetingSeries? {
        series.first { $0.calendarKey == key }
    }

    /// Case-insensitive, so "Weekly Standup" typed twice doesn't make two series.
    func series(named name: String) -> MeetingSeries? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return series.first { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    /// Every recording in a series, newest first.
    ///
    /// Lives here rather than on the series so the type stays Foundation-only and
    /// free of any dependency on `RecordingStore`.
    func recordings(in seriesId: String) -> [Recording] {
        RecordingStore.shared.recordings
            .filter { $0.seriesId == seriesId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func sessionCount(in seriesId: String) -> Int {
        RecordingStore.shared.recordings.count { $0.seriesId == seriesId }
    }

    /// Which session of the series this recording is, counting from the oldest.
    /// Nil when it isn't in one — used for "Session 4" in the detail view.
    func sessionNumber(of recording: Recording) -> Int? {
        guard let seriesId = recording.seriesId else { return nil }
        let ordered = RecordingStore.shared.recordings
            .filter { $0.seriesId == seriesId }
            .sorted { $0.createdAt < $1.createdAt }
        guard let index = ordered.firstIndex(where: { $0.id == recording.id }) else { return nil }
        return index + 1
    }

    // MARK: - Writing

    @discardableResult
    func add(name: String, calendarKey: String? = nil) -> MeetingSeries? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let created = MeetingSeries(name: trimmed, calendarKey: calendarKey)
        series.append(created)
        persist()
        return created
    }

    /// Find the series for a recurring calendar event, creating it on first
    /// sight.
    ///
    /// **Matched on `calendarKey` first and name only as a fallback**, because
    /// the key is stable and the name isn't: renaming a recurring meeting in
    /// Calendar would otherwise start a second series halfway through. When the
    /// key finds an existing series whose name has drifted, the stored name is
    /// left alone — the user may have renamed it here on purpose.
    @discardableResult
    func ensureSeries(calendarKey: String, name: String) -> MeetingSeries? {
        if let existing = series(forCalendarKey: calendarKey) { return existing }
        // A hand-made series with the same name adopts the key, so switching
        // calendar matching on later doesn't fork an existing series in two.
        if let named = series(named: name), named.calendarKey == nil {
            update(id: named.id) { $0.calendarKey = calendarKey }
            return series(id: named.id)
        }
        return add(name: name, calendarKey: calendarKey)
    }

    func update(id: String, _ mutate: (inout MeetingSeries) -> Void) {
        guard let index = series.firstIndex(where: { $0.id == id }) else { return }
        mutate(&series[index])
        persist()
    }

    func rename(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id: id) { $0.name = trimmed }
    }

    /// Delete a series and detach every recording from it.
    ///
    /// The recordings themselves are never touched beyond `seriesId` — and
    /// `seriesRecap` is cleared with it, because a recap is a statement about a
    /// series ("since last time we…") and is meaningless once there isn't one.
    func remove(id: String) {
        series.removeAll { $0.id == id }
        persist()
        sweep(id)
    }

    /// Move a recording into a series, out of one, or between two.
    ///
    /// Clears `seriesRecap` on any change: it was written against a different
    /// series' history, and leaving it would attribute one meeting's context to
    /// another. `SeriesContinuity` writes a fresh one on the next pass.
    func assign(_ recording: Recording, to seriesId: String?) {
        guard recording.seriesId != seriesId else { return }
        RecordingStore.shared.update(id: recording.id) {
            $0.seriesId = seriesId
            $0.seriesRecap = nil
        }
        SyncManager.shared.refreshLibrary()
    }

    private func sweep(_ seriesId: String) {
        let affected = RecordingStore.shared.recordings.filter { $0.seriesId == seriesId }
        guard !affected.isEmpty else { return }
        for recording in affected {
            RecordingStore.shared.update(id: recording.id) {
                $0.seriesId = nil
                $0.seriesRecap = nil
            }
        }
        SyncManager.shared.refreshLibrary()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(series), forKey: defaultsKey)
    }
}
