import Foundation
import CoreLocation
import MapKit

/// One-shot location fixes, plus the name of the place they landed in.
///
/// Deliberately **not** a location *tracker*. Bounce wants a single coordinate
/// at two moments — the recorder started recording, or a file just synced — and
/// nothing in between. So there is no `startUpdatingLocation`, no background
/// location mode, and no blue status bar: `requestLocation()` delivers one fix
/// and stops on its own.
///
/// The cost of that choice, stated plainly because it shapes the whole feature:
/// **with When In Use authorization a fix only arrives while the app is
/// foreground or recently so.** Recording usually starts with the phone in the
/// user's hand, so `.recordStart` normally works; when it doesn't, the calendar
/// and sync-time fallbacks in `PlaceStore` pick it up, and the user can always
/// set the pin by hand. Adding the `location` background mode would fix the
/// remaining gap at the cost of the always-on location indicator and an App
/// Store review conversation — not worth it for a metadata nicety.
@MainActor
@Observable
final class LocationCapture {

    static let shared = LocationCapture()

    /// Mirrors `CLLocationManager.authorizationStatus`, republished so views can
    /// read it without holding the manager.
    private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private let proxy = Proxy()

    /// Continuations waiting on the in-flight `requestLocation()`.
    ///
    /// A list rather than a single slot: a record-start fix and a sync-time fix
    /// can be asked for within a second of each other, and `requestLocation()`
    /// is not re-entrant — calling it again while one is outstanding cancels the
    /// first, which surfaced as the second request never completing.
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    private var isRequesting = false

    /// A fix younger than this is reused instead of asking for a new one. Two
    /// minutes is well inside the distance a meeting moves, and it means the
    /// sync that follows a recording by seconds costs no second GPS wake-up.
    private static let cacheWindow: TimeInterval = 120

    private init() {
        authorizationStatus = manager.authorizationStatus
        manager.delegate = proxy
        // Street level is plenty for "which office was this". `kCLLocationAccuracyBest`
        // keeps the radio up longer for precision no one will ever look at.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        proxy.owner = self
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// Ask for When In Use access, returning whether it ended up granted.
    ///
    /// Called on first enable of the setting, never at launch — same rule as the
    /// calendar and notification permissions. A prompt the user can't connect to
    /// something they just did gets denied, and a denial is permanent from the
    /// app's side.
    func requestAccess() async -> Bool {
        guard authorizationStatus == .notDetermined else { return isAuthorized }
        manager.requestWhenInUseAuthorization()
        // The delegate callback is the only signal; poll it rather than holding a
        // continuation, because `requestWhenInUseAuthorization` is documented to
        // call back "possibly more than once" and resuming twice traps.
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(250))
            if authorizationStatus != .notDetermined { break }
        }
        return isAuthorized
    }

    /// A single fix, reverse-geocoded, tagged with `source`. Nil when location
    /// isn't authorized, the fix never arrived, or it came back nonsense.
    func currentPlace(source: RecordingPlace.Source) async -> RecordingPlace? {
        guard isAuthorized else { return nil }
        guard let location = await currentLocation() else { return nil }

        var place = RecordingPlace(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            source: source,
            accuracyMeters: location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil,
            capturedAt: Date())
        guard place.isValid else { return nil }
        place.name = await Self.placeName(for: location)
        return place
    }

    /// The freshest fix available: the cached one if it's recent, else a new
    /// request.
    private func currentLocation() async -> CLLocation? {
        if let cached = manager.location,
           cached.timestamp.timeIntervalSinceNow > -Self.cacheWindow,
           cached.horizontalAccuracy >= 0 {
            return cached
        }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard !isRequesting else { return }
            isRequesting = true
            manager.requestLocation()
        }
    }

    /// Resume everyone waiting, exactly once each.
    fileprivate func finishRequest(with location: CLLocation?) {
        isRequesting = false
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume(returning: location) }
    }

    fileprivate func updateAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        // A denial mid-flight would otherwise leave `requestLocation`'s callers
        // parked until the manager's own timeout.
        if status == .denied || status == .restricted { finishRequest(with: nil) }
    }

    // MARK: - Reverse geocoding

    /// A human name for a coordinate, or nil.
    ///
    /// `MKReverseGeocodingRequest` rather than `CLGeocoder`, which iOS 26
    /// deprecates. Failures are swallowed on purpose: the geocoder is rate
    /// limited and offline-hostile, and a pin with coordinates and no name is a
    /// perfectly good pin — `RecordingPlace.displayName` falls back to the
    /// coordinates. Never let this failure lose the fix.
    static func placeName(for location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        guard let items = try? await request.mapItems, let item = items.first else { return nil }
        return name(of: item)
    }

    /// Prefer the point of interest's own name ("Blue Bottle Coffee") over the
    /// street address, then fall back to locality. A bare street number is a
    /// worse label than "San Francisco" for scanning a list of meetings.
    private static func name(of item: MKMapItem) -> String? {
        let address = item.address
        if let poi = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !poi.isEmpty {
            return poi
        }
        if let short = address?.shortAddress, !short.isEmpty { return short }
        return address?.fullAddress
    }
}

/// The `CLLocationManagerDelegate`, kept off `LocationCapture` itself.
///
/// `@Observable` and `NSObject` conformance sit awkwardly together, and the
/// delegate methods are `nonisolated` while everything they touch is main-actor
/// isolated. A tiny forwarding object is less subtle than either annotating
/// around it or making the whole store an `NSObject`.
private final class Proxy: NSObject, CLLocationManagerDelegate {

    weak var owner: LocationCapture?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Last is the most recent, and `requestLocation` can deliver more than one.
        let location = locations.last
        Task { @MainActor [owner] in owner?.finishRequest(with: location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Includes the ~10 s timeout `requestLocation` applies for us, which is
        // why there is no watchdog here.
        Task { @MainActor [owner] in owner?.finishRequest(with: nil) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [owner] in owner?.updateAuthorization(status) }
    }
}
