import PlaudBleSDK
import PlaudDeviceBasicSDK
import SwiftUI

/// Recorder hardware: device details, firmware updates, battery monitoring,
/// connection modes, and storage.
///
/// Named `RecorderSettingsView` rather than `DeviceSettingsView` to avoid
/// colliding with `Device/DeviceSettings.swift`, the model this view reads from.
struct RecorderSettingsView: View {

    @Environment(AppModel.self) private var model
    private var settings: DeliverySettings { DeliverySettings.shared }
    private var deviceSettings: DeviceSettings { DeviceSettings.shared }
    @State private var notifications = NotificationCenterBridge.shared

    @State private var isShowingFirmware = false
    @State private var deviceNameDraft = ""
    @AppStorage("uDiskModeEnabled") private var isUDiskModeEnabled = false

    var body: some View {
        Form {
            deviceInfoSection
            deviceSettingsSection
            batterySection
            storageSection
        }
        .navigationTitle("Recorder Hardware")
        .toolbarTitleDisplayMode(.inline)
        .task(id: model.device?.name) {
            deviceNameDraft = model.device?.name ?? ""
        }
        .task {
            await NotificationCenterBridge.shared.refreshAuthorizationStatus()
        }
        .sheet(isPresented: $isShowingFirmware) {
            FirmwareUpdateSheet()
        }
    }

    // MARK: - Device Info

    private var deviceInfoSection: some View {
        Section("Recorder Status") {
            if let device = model.device {
                LabeledContent("Model", value: device.model.displayName)
                LabeledContent("Serial Number", value: device.serialNumber)
                LabeledContent("Firmware Version", value: device.firmwareVersion)

                if device.hasFirmwareUpdate {
                    Button {
                        isShowingFirmware = true
                    } label: {
                        HStack {
                            Label("Firmware Update Available", systemImage: "arrow.down.circle.fill")
                            Spacer()
                            Text(device.latestFirmwareVersion ?? "")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                LabeledContent("Status", value: "Not connected")
            }
        }
    }

    // MARK: - Hardware Controls

    private var deviceSettingsSection: some View {
        Section {
            if let device = model.device {
                HStack {
                    TextField("Recorder name", text: $deviceNameDraft)
                    if !deviceNameDraft.isEmpty, deviceNameDraft != model.device?.name {
                        Button("Rename") {
                            DeviceManager.shared.renameDevice(deviceNameDraft)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Toggle("Recording LED light", isOn: Binding(
                    get: { deviceSettings.ledEnabled(for: device.serialNumber) ?? true },
                    set: { deviceSettings.setLedEnabled($0, for: device.serialNumber) }
                ))

                Picker("Auto power-off", selection: Binding(
                    get: { deviceSettings.autoPowerOff(for: device.serialNumber) },
                    set: { newValue in if let newValue { deviceSettings.setAutoPowerOff(newValue, for: device.serialNumber) } }
                )) {
                    Text("Default").tag(DeviceSettings.AutoPowerOffOption?.none)
                    ForEach(DeviceSettings.AutoPowerOffOption.allCases) { option in
                        Text(option.label).tag(DeviceSettings.AutoPowerOffOption?.some(option))
                    }
                }

                Toggle("USB drive mode", isOn: $isUDiskModeEnabled)
                    .onChange(of: isUDiskModeEnabled) { _, newValue in
                        DeviceManager.shared.setUDiskMode(newValue)
                    }

                if model.canUseWiFiTransfer {
                    Button("WiFi Fast Transfer", systemImage: "bolt.horizontal") {
                        model.startWiFiTransfer()
                    }
                    .disabled(model.syncState.isActive)
                }

                NavigationLink("Idle WiFi Sync") { IdleSyncView() }
                NavigationLink("Hardware Diagnostic Logs") { HardwareLogView() }
            } else {
                Text("Connect a recorder to customize hardware settings.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Hardware & Connection Controls")
        } footer: {
            Text("Turning off the LED light enables discreet recording. Auto power-off powers off the recorder when idle to save battery.")
        }
    }


    // MARK: - Battery Alerts

    private var batterySection: some View {
        Section {
            Toggle("Low battery alert", isOn: Binding(
                get: { settings.lowBatteryAlerts },
                set: { enabling in
                    guard enabling else {
                        settings.lowBatteryAlerts = false
                        return
                    }
                    Task {
                        let granted = await NotificationCenterBridge.shared.requestAuthorization()
                        settings.lowBatteryAlerts = granted
                    }
                }
            ))
            .disabled(notifications.isDenied)

            if settings.lowBatteryAlerts {
                Picker("Alert threshold", selection: Binding(
                    get: { settings.lowBatteryThreshold },
                    set: { settings.lowBatteryThreshold = $0 }
                )) {
                    ForEach([10, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
            }
        } header: {
            Text("Battery Monitoring")
        } footer: {
            Text(batteryFooter)
        }
    }

    private var batteryFooter: String {
        if notifications.isDenied {
            return "Notifications are turned off for Bounce. Turn them on in iOS Settings › Notifications › Bounce to use this."
        }
        // Deliberately explicit about the limit. `UIBackgroundModes` includes
        // `bluetooth-central`, so readings arrive while Bounce is in the
        // background — but iOS suspends and eventually terminates backgrounded
        // apps, and a terminated app receives nothing. Implying always-on
        // monitoring would be a promise the OS doesn't let us keep.
        return "Notifies you once each time the recorder drops below this level, and again only after it's charged back up. Bounce has to be running — in the foreground or recently backgrounded — to see the reading, so this won't catch a battery that runs down days after you last opened the app."
    }

    // MARK: - Storage & Cleanup

    private var storageSection: some View {
        Section {
            Toggle("Delete from recorder after sync", isOn: Binding(
                get: { settings.deleteFromRecorderAfterSync },
                set: { settings.deleteFromRecorderAfterSync = $0 }
            ))
        } header: {
            Text("Recorder Storage")
        } footer: {
            // Says "removed", not "frees space". A confirmed delete takes the
            // file off the recorder's list, but the 64 KiB block it occupied was
            // measured as still in use a second later, and whether the recorder
            // reclaims it lazily has never been established on hardware. Don't
            // promise reclaimed storage until it is.
            Text(settings.deleteFromRecorderAfterSync
                 ? "Recordings are removed from the recorder once the audio is safely on this iPhone, so its storage doesn't fill up."
                 : "Recordings stay on the recorder. Its 64GB will fill up eventually, and Bounce treats anything still on the device as not yet synced — so a fresh install will pull everything down again.")
        }
    }
}

// MARK: - Firmware Update Sheet

private struct FirmwareUpdateSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var phaseLabel = "Ready to update"
    @State private var progress: Float = 0
    @State private var isRunning = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(.tint)
                    .pulseWhenActive(isRunning)

                Text(result ?? phaseLabel)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if isRunning {
                    ProgressView(value: progress)
                        .padding(.horizontal)
                    Text("Keep the recorder nearby and stay in the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                if result == nil {
                    Button("Update now") { run() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(isRunning)
                } else {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            }
            .padding(28)
            .navigationTitle("Firmware Update")
            .toolbarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isRunning)
            .toolbar {
                if !isRunning, result == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    private func run() {
        isRunning = true
        Task {
            let outcome = await DeviceManager.shared.startFirmwareUpdate { phase, percent in
                phaseLabel = Self.label(for: phase)
                progress = percent
            }
            isRunning = false
            result = outcome.success
                ? "Updated to \(outcome.version)"
                : "Update failed. \(outcome.errorMessage ?? "Ensure recorder is charged and nearby, then try again.")"
        }
    }

    private static func label(for phase: PlaudFirmwarePhase) -> String {
        switch phase {
        case .downloading: return "Downloading firmware"
        case .installing: return "Installing update"
        case .restarting: return "Restarting recorder"
        case .complete: return "Completing setup"
        @unknown default: return "Updating"
        }
    }
}
