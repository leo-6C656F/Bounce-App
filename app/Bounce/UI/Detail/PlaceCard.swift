import SwiftUI
import MapKit
import CoreLocation

extension RecordingPlace {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// A region tight enough to show which building, wide enough that a
    /// hundred-metre fix isn't claiming a doorway.
    var previewRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 400,
            longitudinalMeters: 400)
    }

    /// SF Symbol for where the pin came from, so the map legend and the detail
    /// card agree without either restating the sentence.
    var symbolName: String {
        switch origin {
        case .recordStart: return "location.fill"
        case .calendar: return "calendar"
        case .sync: return "location.slash"
        case .manual: return "hand.point.up.left.fill"
        }
    }
}

/// Where a recording was made, on the detail screen.
///
/// Renders nothing at all when there's no place *and* geotagging is off — the
/// common case for a library recorded before the feature existed, and an empty
/// "no location" card on every one of those screens would be pure noise. With
/// the setting on it degrades to a single "Add location" button instead.
struct PlaceCard: View {

    let recording: Recording
    @State private var isEditing = false

    var body: some View {
        Group {
            if let place = recording.place {
                filled(place)
            } else if DeliverySettings.shared.geotagRecordings {
                addButton
            }
        }
        .sheet(isPresented: $isEditing) {
            PlaceEditor(recording: recording)
        }
    }

    private func filled(_ place: RecordingPlace) -> some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 10) {
                // `interactionModes: []` — this is a picture of a place, not a
                // map to explore. A pannable map inside a vertical ScrollView
                // steals every drag that was meant to scroll the page.
                Map(initialPosition: .region(place.previewRegion), interactionModes: []) {
                    Marker(place.displayName, systemImage: place.symbolName, coordinate: place.coordinate)
                        .tint(Color.accentColor)
                }
                .frame(height: 130)
                .clipShape(.rect(corners: .concentric))
                .allowsHitTesting(false)
                // One accessibility element: VoiceOver has nothing useful to say
                // about map tiles, and the text below states everything anyway.
                .accessibilityHidden(true)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        Text(place.origin.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Edit") { isEditing = true }
                        .buttonStyle(.glass)
                        .font(.caption.weight(.medium))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var addButton: some View {
        Button {
            isEditing = true
        } label: {
            Label("Add location", systemImage: "mappin.and.ellipse")
                .font(.subheadline)
        }
        .buttonStyle(.glass)
    }
}

/// Set, move, or clear a recording's location.
///
/// Three ways in, because the three failure modes are different: search covers
/// "I know the name of the place", the current-location button covers "I'm
/// still here", and tapping the map covers everything else — a customer site
/// with no listing, a car park, a street corner.
struct PlaceEditor: View {

    let recording: Recording

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @State private var camera: MapCameraPosition
    @State private var draft: RecordingPlace?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var isLocating = false
    /// The region the map is actually showing, kept so a search is biased to
    /// what's on screen rather than to the whole planet.
    @State private var visibleRegion: MKCoordinateRegion?

    init(recording: Recording) {
        self.recording = recording
        _draft = State(initialValue: recording.place)
        _camera = State(initialValue: recording.place.map { .region($0.previewRegion) }
            ?? .userLocation(fallback: .automatic))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapPane
                controls
            }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        // Nothing to save is different from clearing, which is
                        // the explicit Remove button below.
                        .disabled(draft == nil || draft == recording.place)
                }
            }
        }
    }

    private var mapPane: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let draft {
                    Marker(draft.displayName, systemImage: "mappin", coordinate: draft.coordinate)
                        .tint(Color.accentColor)
                }
            }
            .onMapCameraChange { context in visibleRegion = context.region }
            // Tap to drop the pin. `convert` returns nil for a point outside the
            // map's projection, which is why this isn't force-unwrapped.
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                setDraft(coordinate: coordinate, name: nil)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search for a place", text: $query)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.background.secondary, in: .capsule)

            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(results, id: \.self) { item in
                            Button {
                                select(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "Unnamed place")
                                        .font(.subheadline)
                                    if let detail = item.address?.fullAddress {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await useCurrentLocation() }
                } label: {
                    Label("Use current location", systemImage: "location")
                        .font(.subheadline)
                }
                .buttonStyle(.glass)
                .disabled(isLocating)

                Spacer(minLength: 0)

                if recording.place != nil {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        model.setPlace(nil, on: recording)
                        dismiss()
                    }
                    .buttonStyle(.glass)
                    .font(.subheadline)
                }
            }

            if let draft {
                Text(draft.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Tap the map, search, or use your current location.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(.bar)
    }

    // MARK: - Actions

    /// Every edit here is `.manual`, which outranks all three automatic sources
    /// — so a pin the user set is never quietly replaced by a later pass.
    private func setDraft(coordinate: CLLocationCoordinate2D, name: String?) {
        draft = RecordingPlace(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            name: name,
            source: .manual,
            capturedAt: Date())
        // Only reverse-geocode a bare tap: a search result already has a better
        // name than the geocoder would return for the same point.
        guard name == nil else { return }
        Task {
            let resolved = await LocationCapture.placeName(
                for: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            // The user may have tapped again while this was in flight.
            guard draft?.latitude == coordinate.latitude,
                  draft?.longitude == coordinate.longitude
            else { return }
            draft?.name = resolved
        }
    }

    private func select(_ item: MKMapItem) {
        let coordinate = item.location.coordinate
        setDraft(coordinate: coordinate, name: item.name ?? item.address?.shortAddress)
        camera = .region(MKCoordinateRegion(
            center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400))
        results = []
        query = ""
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let visibleRegion { request.region = visibleRegion }
        // A failed search is a normal outcome — offline, or nothing matched —
        // and an empty list says so as well as an alert would.
        results = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
    }

    private func useCurrentLocation() async {
        isLocating = true
        defer { isLocating = false }
        // Requests permission if it was never asked for, so this button works
        // even when the geotag setting was never switched on.
        guard await LocationCapture.shared.requestAccess() else { return }
        guard let place = await LocationCapture.shared.currentPlace(source: .manual) else { return }
        draft = place
        camera = .region(place.previewRegion)
    }

    private func save() {
        guard let draft else { return }
        model.setPlace(draft, on: recording)
        dismiss()
    }
}
