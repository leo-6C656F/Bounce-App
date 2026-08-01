import PlaudBleSDK
import PlaudDeviceBasicSDK
import SwiftUI

/// Settings for recording quality, noise reduction, voice activation,
/// microphone processing gain, and live transcription preview.
struct AudioSettingsView: View {

    @Environment(AppModel.self) private var model
    private var deviceSettings: DeviceSettings { DeviceSettings.shared }
    private var settings: DeliverySettings { DeliverySettings.shared }

    var body: some View {
        Form {
            if let device = model.device {
                sceneSection(for: device)
                vadSection(for: device)
                micSection(for: device)
            } else {
                disconnectedSection
            }

            livePreviewSection
        }
        .navigationTitle("Audio & Recording")
        .toolbarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private func sceneSection(for device: PlaudDevice) -> some View {
        Section {
            Picker("Recording scene", selection: Binding(
                get: { deviceSettings.scene(for: device.serialNumber) },
                set: { newValue in if let newValue { deviceSettings.setScene(newValue, for: device.serialNumber) } }
            )) {
                Text("Default").tag(RecScene?.none)
                ForEach(Self.recScenes, id: \.self) { scene in
                    Text(Self.label(for: scene)).tag(RecScene?.some(scene))
                }
            }

            Picker("Recording mode", selection: Binding(
                get: { deviceSettings.mode(for: device.serialNumber) },
                set: { newValue in if let newValue { deviceSettings.setMode(newValue, for: device.serialNumber) } }
            )) {
                Text("Default").tag(RecMode?.none)
                Text("Standard").tag(RecMode?.some(.Normal))
                Text("Noise cancelling").tag(RecMode?.some(.NC))
            }
        } header: {
            Text("Audio quality & profile")
        } footer: {
            Text("Optimizes frequency response and noise filter profiles for your environment. Noise cancelling reduces ambient background hum during capture.")
        }
    }

    private func vadSection(for device: PlaudDevice) -> some View {
        Section {
            Picker("Voice activation (VAD)", selection: Binding(
                get: { deviceSettings.vadEnabled(for: device.serialNumber) },
                set: { newValue in if let newValue { deviceSettings.setVadEnabled(newValue, for: device.serialNumber) } }
            )) {
                Text("Default").tag(Bool?.none)
                Text("Enabled").tag(Bool?.some(true))
                Text("Disabled").tag(Bool?.some(false))
            }

            Picker("Activation sensitivity", selection: Binding(
                get: { deviceSettings.vadSensitivity(for: device.serialNumber) },
                set: { newValue in if let newValue { deviceSettings.setVadSensitivity(newValue, for: device.serialNumber) } }
            )) {
                Text("Default").tag(VadSensitivity?.none)
                ForEach(Self.vadSensitivities, id: \.self) { sensitivity in
                    Text(Self.label(for: sensitivity)).tag(VadSensitivity?.some(sensitivity))
                }
            }
        } header: {
            Text("Voice activation")
        } footer: {
            Text("Voice Activity Detection automatically pauses recording when speech is not detected, reducing silence in audio files.")
        }
    }

    private func micSection(for device: PlaudDevice) -> some View {
        Section {
            Picker("Processing gain", selection: Binding(
                get: { deviceSettings.vpuGain(for: device.serialNumber) },
                set: { newValue in if let newValue { deviceSettings.setVpuGain(newValue, for: device.serialNumber) } }
            )) {
                Text("Default").tag(VpuGain?.none)
                Text("Low").tag(VpuGain?.some(.Low))
                Text("Medium").tag(VpuGain?.some(.Medium))
                Text("High").tag(VpuGain?.some(.High))
            }

            LabeledContent("Current mic gain", value: deviceSettings.micGain.map(String.init) ?? "Unknown")
            Button("Refresh mic gain level") {
                deviceSettings.refreshMicGain()
            }
        } header: {
            Text("Microphone processing")
        } footer: {
            // The Tier 2 caveat, restated here because this page is now where all
            // of these controls live. Everything on it except mic gain is a
            // fire-and-forget BLE command with no confirming callback, so the UI
            // can only ever show the last value Bounce *requested*. Mic gain is
            // the exception — `readMicGain`/`bleMicGain` round-trips, which is why
            // it gets a "Current" row and a refresh button and the others don't.
            Text("Adjusts microphone pre-amplifier gain for distant voices or loud environments. Everything else on this page is sent to the recorder but never confirmed back, so it shows the last value Bounce requested rather than the recorder's actual setting — it can drift if changed from the recorder itself. “Not set” means Bounce hasn't sent a value; nothing is sent until you pick one.")
        }
        .task(id: device.serialNumber) {
            deviceSettings.refreshMicGain()
        }
    }

    private var livePreviewSection: some View {
        Section {
            Toggle("Live transcription preview", isOn: Binding(
                get: { settings.liveTranscription },
                set: { settings.liveTranscription = $0 }
            ))
        } header: {
            Text("Live preview")
        } footer: {
            Text("Streams on-device live transcription while recording is active. A final high-accuracy transcript replaces the preview once the recording syncs.")
        }
    }

    private var disconnectedSection: some View {
        Section {
            ContentUnavailableView(
                "Recorder Not Connected",
                systemImage: "waveform.slash",
                description: Text("Connect your recorder to customize scene presets, noise cancellation, voice activation, and microphone gain.")
            )
        }
    }

    // MARK: - Helpers

    private static let recScenes: [RecScene] = [.Normal, .Interview, .Classroom, .Music, .Meeting, .Memo]
    private static let vadSensitivities: [VadSensitivity] = [.Quality, .lowBitrate, .Normal, .Aggressive]

    private static func label(for scene: RecScene) -> String {
        switch scene {
        case .Unknown: return "Unknown"
        case .Normal: return "Normal"
        case .Interview: return "Interview"
        case .Classroom: return "Classroom"
        case .Music: return "Music"
        case .Meeting: return "Meeting"
        case .Memo: return "Voice memo"
        @unknown default: return "Unknown"
        }
    }

    private static func label(for sensitivity: VadSensitivity) -> String {
        switch sensitivity {
        case .Quality: return "High quality (less aggressive)"
        case .lowBitrate: return "Low bitrate"
        case .Normal: return "Balanced"
        case .Aggressive: return "High sensitivity (filters pause)"
        @unknown default: return "Unknown"
        }
    }
}
