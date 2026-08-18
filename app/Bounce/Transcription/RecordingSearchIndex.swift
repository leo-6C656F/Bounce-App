import Foundation

/// Process-lifetime cache of `Recording.searchHaystack`, so library and Ask
/// search don't re-join and re-lowercase every transcript on each keystroke.
///
/// Why a lock-guarded class rather than an `actor`: the two callers both need a
/// **synchronous** answer. `LibraryView` filters off the main actor inside a
/// `Task.detached`, and `AskCorpus` is a pure `enum` invoked off-main from the
/// web/MCP paths as well as the phone — neither can `await`. A plain lock keeps
/// `haystack(for:)` callable from anywhere while staying data-race-free.
///
/// Entries are keyed by recording id and invalidated by `searchIdentity`, which
/// changes whenever the transcript does. The cache only grows with the distinct
/// recording ids seen this session; a stale entry for a since-deleted recording
/// is a few bytes and harmless, so there is no eviction. It resets naturally at
/// each launch.
final class RecordingSearchIndex: @unchecked Sendable {
    static let shared = RecordingSearchIndex()

    private let lock = NSLock()
    private var cache: [String: (identity: String, haystack: String)] = [:]

    private init() {}

    /// The recording's lowercased transcript text, built once and reused until
    /// its transcript changes.
    func haystack(for recording: Recording) -> String {
        let id = recording.id
        let identity = recording.searchIdentity

        lock.lock()
        if let entry = cache[id], entry.identity == identity {
            let cached = entry.haystack
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Build outside the lock: this is the costly part, and two threads racing
        // to build the same haystack is far cheaper than serialising every caller
        // behind whichever one is currently lowercasing a long transcript.
        let haystack = recording.searchHaystack

        lock.lock()
        cache[id] = (identity, haystack)
        lock.unlock()
        return haystack
    }
}
