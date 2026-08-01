import SwiftUI

/// Settings: a status card, then the category pages, then the things you can't
/// undo.
///
/// **The status moved out of the rows.** Every category link used to carry its
/// own trailing value — `Connected`, `On-Device`, `2 Active`, `Off` — so
/// answering "is everything working?" meant reading seven right-aligned greys
/// down the page and assembling them yourself. They're one card at the top now,
/// and the rows below are just navigation.
///
/// The category pages themselves are unchanged: `RecorderSettingsView`,
/// `AudioSettingsView`, `TranscriptionSettingsView`, `AISettingsView`,
/// `IntegrationsSettingsView`, `DesktopViewSettingsView` and
/// `AccountSettingsView` each own one category's sections.
struct SettingsView: View {

    @Environment(AppModel.self) private var model

    @State private var isConfirmingUnpair = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingClearAllFiles = false
    @State private var isConfirmingFactoryReset = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    NavigationLink { RecorderSettingsView() } label: {
                        Label("Recorder Hardware", systemImage: "recordingtape")
                    }
                    NavigationLink { AudioSettingsView() } label: {
                        Label("Audio & Recording", systemImage: "waveform")
                    }
                    NavigationLink { TranscriptionSettingsView() } label: {
                        Label("Transcription & Engine", systemImage: "quote.bubble")
                    }
                    NavigationLink { AISettingsView() } label: {
                        Label("AI & Intelligence", systemImage: "sparkles")
                    }
                    NavigationLink { IntegrationsSettingsView() } label: {
                        Label("Integrations & Delivery", systemImage: "paperplane")
                    }
                    NavigationLink { DesktopViewSettingsView() } label: {
                        Label("Desktop View & API", systemImage: "laptopcomputer")
                    }
                    NavigationLink { AccountSettingsView() } label: {
                        Label("Plaud Account", systemImage: "person.crop.circle")
                    }
                }

                dangerZoneSection
                aboutSection
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Remove Plaud credentials?",
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    TokenProvider.shared.clearCredentials()
                    model.unpair()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Bounce will stop being able to reach your recorder until you enter them again. Recordings already on this iPhone are kept.")
            }
            .confirmationDialog(
                "Unpair recorder?",
                isPresented: $isConfirmingUnpair,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) { model.unpair() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Recordings already on this iPhone are kept. The device will be free to pair with another app.")
            }
            .confirmationDialog(
                "Erase all recordings on recorder?",
                isPresented: $isConfirmingClearAllFiles,
                titleVisibility: .visible
            ) {
                Button("Erase recordings", role: .destructive) {
                    DeviceManager.shared.clearAllFiles()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every recording still on the recorder itself and can't be undone. Recordings already synced to this iPhone are kept.")
            }
            .confirmationDialog(
                "Factory reset recorder?",
                isPresented: $isConfirmingFactoryReset,
                titleVisibility: .visible
            ) {
                Button("Factory reset", role: .destructive) {
                    DeviceManager.shared.restoreFactory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Erases everything on the recorder and restores its factory settings. Bounce unpairs it immediately \u{2014} you'll need to pair it again to use it, with this app or Plaud's own.")
            }
        }
    }

    // MARK: - Status

    /// Four things worth knowing at a glance, in a 2×2.
    ///
    /// **`HStack`s, not a `Grid`.** A `Grid` with `Divider()` cells sized its
    /// columns from the dividers rather than from the tiles, so the tiles blew
    /// past the card's width and out of the screen — the dividers stretched, the
    /// values clipped, and the card's own background never drew because its
    /// content was wider than the row it sat in. Two `HStack`s with a fixed
    /// vertical rule between them size predictably.
    private var statusCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tile("Recorder", recorderValue, dot: model.connectionState.indicatorColor)
                verticalRule
                tile("Engine", engineValue, dot: .accentColor)
            }
            Divider().padding(.horizontal, 16)
            HStack(spacing: 0) {
                tile("Delivery", deliveryValue, dot: deliveryDot)
                verticalRule
                tile("Desktop view", desktopValue, dot: DesktopServer.shared.isRunning ? .green : .secondary)
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: Metrics.cardRadius))
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    /// A hairline of a fixed height. `Divider()` inside an `HStack` renders
    /// vertically but takes its length from the row, which makes the two tiles
    /// fight over the remaining width.
    private var verticalRule: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 34)
    }

    private func tile(_ label: String, _ value: String, dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                StatusDot(dot, diameter: 7)
                SectionLabel(label)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                // Long values — "Slack · Webhook · Folder" — shrink rather than
                // truncate to an ellipsis that hides which destinations they are.
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // `.frame(maxWidth: .infinity)` on the tile *and* half the row: each one
        // takes an equal share, so a long delivery list can't squeeze the engine
        // tile to nothing.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var recorderValue: String {
        guard model.connectionState.isConnected, let device = model.device else {
            return model.pairedDevices.isEmpty ? "Not paired" : "Not connected"
        }
        return "\(device.name) · \(device.batteryLevel)%"
    }

    private var engineValue: String {
        DeliverySettings.shared.effectiveTranscriptionEngine == .local ? "On device" : "Soniox cloud"
    }

    private var deliveryValue: String {
        let active = DeliverySettings.shared.activeDestinations
        guard !active.isEmpty else { return "None" }
        // Named rather than counted: "2 Active" makes you open the page to find
        // out which two, which is the trip this card exists to save.
        return active.map(\.label).joined(separator: " · ")
    }

    private var deliveryDot: Color {
        DeliverySettings.shared.activeDestinations.isEmpty ? .secondary : .orange
    }

    private var desktopValue: String {
        DesktopServer.shared.isRunning ? "Running" : "Off"
    }

    // MARK: - Danger zone

    /// **Every irreversible action lives here, at the root.** Deliberately not
    /// folded into the category pages: it's never more than one screen away, and
    /// it isn't scattered next to the read-only info each used to sit beside.
    private var dangerZoneSection: some View {
        Section {
            if model.device != nil {
                Button("Erase all recordings on recorder", role: .destructive) {
                    isConfirmingClearAllFiles = true
                }
                .disabled(model.syncState.isActive)

                Button("Factory reset recorder", role: .destructive) {
                    isConfirmingFactoryReset = true
                }
                .disabled(model.syncState.isActive)

                Button("Unpair recorder", role: .destructive) {
                    isConfirmingUnpair = true
                }
            }

            Button("Remove credentials", role: .destructive) {
                isConfirmingSignOut = true
            }
        } header: {
            Text("Danger zone")
        } footer: {
            Text("These act on the recorder itself or your Plaud account and can't be undone. Recording actions are disabled while a sync is running.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.shortVersion)
            LabeledContent("Saved recordings", value: "\(model.recordings.count)")
        } header: {
            Text("About Bounce")
        } footer: {
            Text("Bounce processes audio and transcriptions on device using privacy-first local AI models.")
        }
    }
}

// MARK: - Helpers

extension Bundle {
    var shortVersion: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
