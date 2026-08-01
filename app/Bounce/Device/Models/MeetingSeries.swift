import Foundation

/// A run of related recordings — a weekly standup, a monthly review, an ongoing
/// project call — that the AI reads as one continuing conversation rather than
/// as unrelated sessions.
///
/// **Foundation-only**, like `Recording` and `RecordingPlace`: it is referenced
/// by the stored library (`Recording.seriesId`) and its own list is persisted,
/// so `tools/library-decode-tests/` compiles it standalone on the Mac.
struct MeetingSeries: Codable, Hashable, Identifiable {

    let id: String
    var name: String
    let createdAt: Date

    /// The calendar's identifier for the recurring event this series was created
    /// from, when it was created automatically.
    ///
    /// `EKEvent.calendarItemExternalIdentifier` is **shared by every occurrence
    /// of a recurring event**, which is what makes automatic grouping possible at
    /// all: two recordings six weeks apart resolve to the same key with no user
    /// input. Nil for a series the user made by hand. Optional also for the usual
    /// decode reason.
    var calendarKey: String?

    /// The running "where this series stands" context, rewritten after each
    /// session and fed back in as the starting point for the next one.
    ///
    /// This is the whole feature: the on-device model's context window is ~4,096
    /// tokens *shared* across instructions, question and answer, so N transcripts
    /// cannot be handed to it. A compact carry-forward that gets rewritten each
    /// time can — it stays a fixed size however long the series runs.
    var digest: String?

    /// When `digest` was last rewritten, and through which recording.
    ///
    /// `digestThroughDate` is the guard against out-of-order arrival: a Plaud
    /// syncs whenever it next connects, so an older session can land after a
    /// newer one. `digestThroughRecordingId` makes a re-run idempotent, so
    /// re-transcribing a recording doesn't fold it into the digest twice.
    var digestUpdatedAt: Date?
    var digestThroughDate: Date?
    var digestThroughRecordingId: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date(),
        calendarKey: String? = nil,
        digest: String? = nil,
        digestUpdatedAt: Date? = nil,
        digestThroughDate: Date? = nil,
        digestThroughRecordingId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.calendarKey = calendarKey
        self.digest = digest
        self.digestUpdatedAt = digestUpdatedAt
        self.digestThroughDate = digestThroughDate
        self.digestThroughRecordingId = digestThroughRecordingId
    }

    var hasDigest: Bool {
        !(digest ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether `recording` is the newest session this series has folded in.
    ///
    /// A recording that isn't gets its content carried forward but **no recap** —
    /// "since last time" is a claim about sequence, and it would be a false one
    /// for a session that arrived out of order.
    func isNewerThanDigest(_ recordedAt: Date) -> Bool {
        guard let through = digestThroughDate else { return true }
        return recordedAt >= through
    }
}
