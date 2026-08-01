import SwiftUI

/// First run: explain, scan, pair.
struct PairingView: View {

    @Environment(AppModel.self) private var model
    @State private var isScanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header

                    if isScanning {
                        scanResults
                    } else {
                        pitch
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
            .navigationTitle("Bounce")
        }
        .onDisappear { model.endPairing() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tint)
                .pulseWhenActive(isScanning)

            Text("Your recorder, your rules")
                .font(.largeTitle.weight(.light))
                .multilineTextAlignment(.center)

            Text("Pull recordings off your Plaud device, transcribe them on this iPhone, and send them anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }

    private var pitch: some View {
        VStack(spacing: 12) {
            FeatureRow(
                symbol: "lock.iphone",
                title: "Private by default",
                detail: "Transcription runs on this device with Apple's Speech models. Audio is never uploaded to transcribe it."
            )
            FeatureRow(
                symbol: "square.and.arrow.up",
                title: "Send it anywhere",
                detail: "Share sheet, a webhook, a folder in Files or iCloud Drive, or any Shortcuts automation you like."
            )
            FeatureRow(
                symbol: "bolt.horizontal",
                title: "WiFi Fast Transfer",
                detail: "Roughly ten times quicker than Bluetooth for pulling long recordings across."
            )
        }
    }

    @ViewBuilder
    private var scanResults: some View {
        if !model.bluetoothStatus.canScan {
            // A denied or powered-off radio makes the SDK's scan silent, so say
            // so rather than spinning forever.
            ContentCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.bluetoothStatus.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(model.bluetoothStatus.advice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if model.bluetoothStatus == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.scannedDevices.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking for recorders nearby…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Make sure the recorder is switched on and within a few metres.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Still nothing? It may still be paired with another app — a Plaud device only talks to one at a time.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 32)
        } else {
            VStack(spacing: 10) {
                ForEach(model.scannedDevices) { scanned in
                    Button {
                        model.connect(to: scanned)
                    } label: {
                        DeviceRow(scanned: scanned, state: model.connectionState)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            Button {
                if isScanning {
                    model.endPairing()
                    isScanning = false
                } else {
                    model.beginPairing()
                    isScanning = true
                }
            } label: {
                Text(isScanning ? "Stop scanning" : "Find my recorder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            if isScanning {
                Text("A Plaud device can only be paired with one app at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

// MARK: - Rows

private struct FeatureRow: View {

    let symbol: String
    let title: String
    let detail: String
    @ScaledMetric private var iconColumnWidth: CGFloat = 32

    var body: some View {
        ContentCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: iconColumnWidth)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct DeviceRow: View {

    let scanned: ScannedDevice
    let state: DeviceConnectionState
    @ScaledMetric private var iconColumnWidth: CGFloat = 32

    var body: some View {
        ContentCard {
            HStack(spacing: 14) {
                Image(systemName: PlaudModel(serialNumber: scanned.serialNumber).symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: iconColumnWidth)

                VStack(alignment: .leading, spacing: 2) {
                    Text(scanned.name.isEmpty ? PlaudModel(serialNumber: scanned.serialNumber).displayName : scanned.name)
                        .font(.headline)
                    Text(scanned.serialNumber)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    SignalBars(bars: scanned.signalBars)
                }
            }
        }
    }

    private var isConnecting: Bool {
        if case .connecting(let target) = state { return target.serialNumber == scanned.serialNumber }
        return false
    }
}

private struct SignalBars: View {

    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { index in
                Capsule()
                    .fill(index <= bars ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: CGFloat(index) * 5 + 3)
            }
        }
        // Without this, VoiceOver reads each bar as its own unlabeled
        // element before ever reaching the label below.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal strength \(bars) of 3")
    }
}
