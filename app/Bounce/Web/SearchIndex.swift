import Foundation

/// A cached, lowercased "title + transcript" haystack per recording, so
/// `/api/search` doesn't re-lowercase every transcript in the library on every
/// request.
///
/// The naive filter — `recordings.filter { …transcript?.plainText.lowercased()
/// .contains(needle) }` — allocated a fresh lowercased copy of *every* transcript
/// per search, on the same main actor that drives the phone's SwiftUI. A library
/// of long meetings is tens of megabytes re-lowercased per request; the
/// allocation is the cost, and it is paid whether or not anything matches.
///
/// This caches the lowercased haystack and rebuilds an entry only when the
/// recording's *change signature* moves. On a cache hit a search is a plain
/// `String.contains` over already-lowercased strings — no allocation, no
/// case-folding — plus a hard result ceiling so a one-character query can't walk
/// the whole library.
///
/// **The signature is deliberately coarse**, mirroring `LiveChannel`'s own
/// library fingerprint: title, segment count and summary/speaker state, *not* the
/// full transcript text. An in-place word correction that changes neither the
/// segment count nor the title is therefore reflected in desktop search only
/// after the next library change (or an app restart — the cache is in-memory).
/// The phone's own search is always current; this is an accepted, self-healing
/// staleness that keeps the hit path allocation-free.
///
/// `@MainActor` for the same reason as `WebAPI`: `RecordingStore` has no lock, so
/// reading its cache off the main actor is a data race the compiler won't
/// diagnose under `SWIFT_STRICT_CONCURRENCY: minimal`.
@MainActor
final class WebSearchIndex {

    static let shared = WebSearchIndex()

    private struct Entry {
        let signature: Int
        let haystack: String
    }

    private var entries: [String: Entry] = [:]

    /// Recordings whose title or transcript contains `needle`, newest-first order
    /// preserved from the store, capped at `ceiling` matches.
    ///
    /// `needle` must already be lowercased and non-empty — the caller trims and
    /// lowercases once, and an empty needle is a 400 upstream rather than a match
    /// against everything.
    func matches(_ needle: String, ceiling: Int) -> [Recording] {
        let recordings = RecordingStore.shared.recordings
        pruneStaleEntries(against: recordings)

        var out: [Recording] = []
        out.reserveCapacity(min(ceiling, recordings.count))
        for recording in recordings {
            if haystack(for: recording).contains(needle) {
                out.append(recording)
                if out.count >= ceiling { break }
            }
        }
        return out
    }

    private func haystack(for recording: Recording) -> String {
        let signature = Self.signature(of: recording)
        if let entry = entries[recording.id], entry.signature == signature {
            return entry.haystack
        }
        // Rebuild. This is the one place the expensive lowercase happens, and only
        // on a miss. The same two fields, in the same order, as
        // `LibraryView.filtered` and `WebAPI.search`'s previous inline filter — a
        // search that disagreed with the phone's would be a quiet trap.
        let title = recording.displayTitle.lowercased()
        let body = recording.transcript?.plainText.lowercased() ?? ""
        let haystack = title + "\n" + body
        entries[recording.id] = Entry(signature: signature, haystack: haystack)
        return haystack
    }

    /// Cheap change signal — see the type doc for why it is coarse. Must not build
    /// `plainText` (that would reintroduce the per-request allocation this cache
    /// exists to remove).
    private static func signature(of recording: Recording) -> Int {
        var hasher = Hasher()
        hasher.combine(recording.id)
        hasher.combine(recording.displayTitle)
        hasher.combine(recording.transcript?.segments.count)
        hasher.combine(recording.summaries?.count)
        hasher.combine(recording.speakerNames)
        return hasher.finalize()
    }

    /// Drop entries for recordings that have left the store, so the cache can't
    /// outgrow the library across a long session of deletes. Cheap-gated on the
    /// count so the set-build only runs when something actually shrank.
    private func pruneStaleEntries(against recordings: [Recording]) {
        guard entries.count > recordings.count else { return }
        let live = Set(recordings.map(\.id))
        entries = entries.filter { live.contains($0.key) }
    }
}
