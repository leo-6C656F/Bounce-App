import Foundation

/// Where a recording was made.
///
/// **Foundation-only on purpose**, like `Recording` itself: it is part of the
/// stored library tree, so `tools/library-decode-tests/main.swift` compiles it
/// standalone on the Mac to prove `library.json` still decodes. Importing
/// CoreLocation or MapKit here would break that gate, which is the only
/// automated coverage the storage model has. `CLLocationCoordinate2D` is built
/// from these two doubles at the UI boundary instead.
struct RecordingPlace: Codable, Hashable {

    /// How the coordinates were arrived at — and therefore how much to trust
    /// them. A Plaud records standalone, so "where the phone was when the file
    /// arrived" is a different claim from "where the phone was while it was
    /// recording", and the UI must not present them as the same thing.
    enum Source: String, CaseIterable {
        /// A fix taken when the recorder told the phone it had started
        /// recording. The phone was in Bluetooth range at that moment, so this
        /// is genuinely where the recording happened.
        case recordStart
        /// The coordinates on the calendar event the recording matched. No GPS
        /// involved, works retroactively, and for a meeting it is usually more
        /// precise than a street-level fix.
        case calendar
        /// A fix taken when the audio was pulled off the recorder. **Only ever
        /// approximate** — it is where the sync happened, which is the same
        /// place only if the sync followed the recording closely. `PlaceStore`
        /// refuses to write one for an older recording for exactly this reason.
        case sync
        /// The user dropped or searched for the pin themselves. Beats
        /// everything, and is never overwritten.
        case manual

        /// Which source wins when two are available. Higher replaces lower;
        /// equal never replaces, so a re-run of the auto-organize pass can't
        /// churn a place that is already as good as it is going to get.
        var precedence: Int {
            switch self {
            case .sync: return 0
            case .calendar: return 1
            case .recordStart: return 2
            case .manual: return 3
            }
        }

        /// Shown beside the place name so an approximate pin says so.
        var caption: String {
            switch self {
            case .recordStart: return "Recorded here"
            case .calendar: return "From your calendar"
            case .sync: return "Synced here — approximate"
            case .manual: return "Set by you"
            }
        }
    }

    var latitude: Double
    var longitude: Double

    /// A human name for the pin: the calendar event's location, or the result
    /// of a reverse geocode.
    ///
    /// **Stored rather than derived.** Reverse geocoding is a rate-limited
    /// network call, so resolving it in a view body would throttle itself into
    /// silence the first time the map tab scrolled. Nil is legitimate — the
    /// coordinates still place the pin.
    var name: String?

    /// `Source.rawValue`.
    ///
    /// Stored as a `String`, not the enum: an unknown raw value throws out of a
    /// synthesised `Decodable`, and `library.json` is decoded as one array in
    /// one call — so a case added by a later build would make the whole library
    /// undecodable on an older one. Unknown degrades to `.sync`, the weakest
    /// claim, which is the safe way to be wrong.
    var source: String

    /// Horizontal accuracy in metres, when the fix came from CoreLocation. Nil
    /// for calendar and manual places, which have no such notion.
    var accuracyMeters: Double?

    /// When the fix was taken — *not* when the recording was made. The gap
    /// between the two is the whole reason `.sync` is labelled approximate.
    var capturedAt: Date?

    init(
        latitude: Double,
        longitude: Double,
        name: String? = nil,
        source: Source,
        accuracyMeters: Double? = nil,
        capturedAt: Date? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.source = source.rawValue
        self.accuracyMeters = accuracyMeters
        self.capturedAt = capturedAt
    }

    var origin: Source { Source(rawValue: source) ?? .sync }

    /// True when the pin is where the *phone* was rather than where the
    /// recording was. Drives the "approximate" wording, and keeps the map from
    /// claiming more than it knows.
    var isApproximate: Bool { origin == .sync }

    /// The name if there is one, else the coordinates at a sensible precision.
    /// Four decimal places is about 11 m — finer than any of these sources.
    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    /// Rejects the coordinates CoreLocation and calendar servers hand back for
    /// "no idea": out-of-range values, and the null island at 0,0 that a
    /// zeroed-out struct produces. Both would drop a pin in the Gulf of Guinea.
    var isValid: Bool {
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180
        else { return false }
        return !(abs(latitude) < 0.0001 && abs(longitude) < 0.0001)
    }

    /// Whether `other` should replace this place. Same-source updates are
    /// refused so nothing re-writes the row on every pass.
    func shouldBeReplaced(by other: RecordingPlace) -> Bool {
        other.isValid && other.origin.precedence > origin.precedence
    }
}
