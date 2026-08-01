import SwiftUI
import UniformTypeIdentifiers

/// Where transcripts go once they're ready: automatic delivery, a webhook, a
/// synced folder, and the Shortcuts actions Bounce exposes.
struct DeliverySettingsView: View {

    private var settings: DeliverySettings { DeliverySettings.shared }
    @State private var isPickingFolder = false

    var body: some View {
        Form {
            Section {
                Toggle("Send automatically", isOn: Binding(
                    get: { settings.autoDeliver },
                    set: { settings.autoDeliver = $0 }
                ))
                .disabled(settings.activeDestinations.isEmpty)

                Picker("Include", selection: Binding(
                    get: { settings.payloadContent },
                    set: { settings.payloadContent = $0 }
                )) {
                    ForEach(PayloadContent.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Delivery")
            } footer: {
                Text(settings.activeDestinations.isEmpty
                     ? "Set up a destination below, or use the share button on any recording to send it by hand."
                     : "Sends to every destination below as soon as transcription finishes.")
            }

            Section {
                Toggle("Enabled", isOn: Binding(
                    get: { settings.webhookEnabled },
                    set: { settings.webhookEnabled = $0 }
                ))
                if settings.webhookEnabled {
                    TextField("https://example.com/hook", text: Binding(
                        get: { settings.webhookURLString },
                        set: { settings.webhookURLString = $0 }
                    ))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    SecureField("Shared secret (optional)", text: Binding(
                        get: { settings.webhookSecret },
                        set: { settings.webhookSecret = $0 }
                    ))
                }
            } header: {
                Text("Webhook")
            } footer: {
                if settings.webhookEnabled {
                    Text("POSTs multipart/form-data with `metadata` (JSON), `transcript` (text), and `audio` (file). The secret is sent as `X-Bounce-Secret`.")
                }
            }

            Section {
                if let name = settings.folderName {
                    HStack {
                        Label(name, systemImage: "folder.fill")
                        Spacer()
                        Button("Change") { isPickingFolder = true }
                            .buttonStyle(.borderless)
                    }
                    Button("Stop saving to folder", role: .destructive) {
                        settings.clearFolder()
                    }
                } else {
                    Button("Choose a folder…", systemImage: "folder.badge.plus") {
                        isPickingFolder = true
                    }
                }
            } header: {
                Text("Folder")
            } footer: {
                if settings.folderName == nil {
                    Text("Pick a folder in Files or iCloud Drive and Bounce will drop the audio and transcript there.")
                }
            }

            Section {
                Label("Shortcuts", systemImage: "app.connected.to.app.below.fill")
            } header: {
                Text("Automation")
            } footer: {
                Text("Bounce exposes Get Latest Transcript, Get Transcript, Transcribe Recording, Send Recording, and Sync Recorder to the Shortcuts app — enough to route recordings into anything with a Shortcuts action.")
            }
        }
        .navigationTitle("Delivery")
        .toolbarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result { settings.setFolder(url) }
        }
    }
}
