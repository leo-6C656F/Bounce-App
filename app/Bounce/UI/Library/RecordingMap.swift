import SwiftUI
import MapKit

/// The library as a map: one pin per recording that knows where it happened.
///
/// A third mode of the Library tab rather than a sixth tab. The tab bar already
/// carries five, and this is the same set of recordings under a different
/// index — the same argument that made the month grid a mode rather than a
/// screen of its own. It honours whatever filters the tab has applied, so
/// "Meetings tagged Client, on a map" costs no extra controls.
struct RecordingMap: View {

    /// Already filtered by the Library's search, category, tag and day filters.
    let recordings: [Recording]
    /// Pushes the detail screen. Owned by `LibraryView` so the map doesn't need
    /// a `NavigationStack` of its own.
    let onOpen: (Recording) -> Void

    @State private var camera: MapCameraPosition = .automatic
    @State private var selectedId: String?

    /// One marker's worth of recording.
    ///
    /// A flattened pair rather than a bare `Recording`, because `MapContentBuilder`
    /// can't infer a content type from a `ForEach` body that unwraps an optional —
    /// it resolves to the `Binding` overload of `ForEach` and fails with a message
    /// about `Binding<C>` that says nothing about the real cause. Unwrapping once,
    /// out here, keeps the map content unconditional.
    private struct Pin: Identifiable {
        let recording: Recording
        let place: RecordingPlace
        var id: String { recording.id }
    }

    /// Only recordings with a place can be pinned, and a pin needs valid
    /// coordinates — a corrupted row drops off the map rather than landing in
    /// the Atlantic.
    private var placed: [Pin] {
        recordings.compactMap { recording in
            guard let place = recording.place, place.isValid else { return nil }
            return Pin(recording: recording, place: place)
        }
    }

    private var selected: Pin? {
        placed.first { $0.id == selectedId }
    }

    var body: some View {
        Group {
            if placed.isEmpty { empty } else { map }
        }
        // Recompute the frame when the filters change the pin set, but not when
        // the user has picked something — snapping the camera away from the pin
        // someone just tapped is disorienting.
        .onChange(of: placed.map(\.id)) { _, _ in
            guard selectedId == nil else { return }
            camera = .automatic
        }
    }

    private var map: some View {
        Map(position: $camera, selection: $selectedId) {
            ForEach(placed) { pin in
                Marker(
                    pin.recording.displayTitle,
                    systemImage: pin.place.symbolName,
                    coordinate: pin.place.coordinate)
                    // Fainter for a sync-time guess, so an approximate pin
                    // doesn't read as confidently as a real one.
                    .tint(pin.place.isApproximate ? Color.secondary : Color.accentColor)
                    .tag(pin.id)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .safeAreaInset(edge: .bottom) {
            if let selected {
                selectionCard(selected)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selectedId)
    }

    private func selectionCard(_ pin: Pin) -> some View {
        Button {
            onOpen(pin.recording)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RecordingRow(recording: pin.recording)
                Label(
                    "\(pin.place.displayName) · \(pin.place.origin.caption)",
                    systemImage: pin.place.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        // Glass here is correct by the project's own rule: this floats above the
        // map, which is content — it is chrome over a media backdrop, which is
        // what the `.clear` variant exists for.
        .adaptiveGlass(in: .rect(cornerRadius: Metrics.cardRadius), variant: .clear)
    }

    /// Distinguishes "nothing has a location" from "the filter matched nothing",
    /// and — the important one — from "the feature is off", which is otherwise
    /// indistinguishable from an empty map and reads as a broken screen.
    @ViewBuilder
    private var empty: some View {
        if !DeliverySettings.shared.geotagRecordings {
            EmptyHint(
                symbol: "mappin.slash",
                title: "Locations are off",
                message: "Turn on “Tag recordings with where they happened” in Settings › Integrations & Delivery, and new recordings will appear here. You can also set a location by hand on any recording.")
        } else if recordings.isEmpty {
            EmptyHint(
                symbol: "mappin.slash",
                title: "Nothing to map",
                message: "No recordings match the current filters.")
        } else {
            EmptyHint(
                symbol: "mappin.slash",
                title: "No locations yet",
                message: "Recordings get a location when your iPhone is connected to the recorder as it starts recording, when they match a calendar event with a place, or when you set one by hand.")
        }
    }
}
