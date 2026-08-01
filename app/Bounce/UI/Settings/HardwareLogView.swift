import SwiftUI

/// Displays hardware diagnostic logs pulled from the connected Plaud recorder.
/// Allows exporting logs via native ShareSheet or deleting logs on the recorder.
struct HardwareLogView: View {

    @Environment(AppModel.self) private var model
    private var logManager: HardwareLogManager { HardwareLogManager.shared }

    @State private var isConfirmingDeleteDeviceLogs = false

    var body: some View {
        Form {
            statusSection
            logOutputSection
            deviceActionSection
        }
        .navigationTitle("Hardware Logs")
        .toolbarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete logs on recorder?",
            isPresented: $isConfirmingDeleteDeviceLogs,
            titleVisibility: .visible
        ) {
            Button("Delete hardware logs", role: .destructive) {
                logManager.deleteLogsFromDevice()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes internal log files stored on the Plaud recorder hardware. This action cannot be undone.")
        }
    }

    // MARK: - Status & Fetch

    private var statusSection: some View {
        Section {
            if let device = model.device {
                LabeledContent("Connected Device", value: "\(device.name) (\(device.serialNumber))")
            } else {
                LabeledContent("Connected Device", value: "Not connected")
            }

            switch logManager.state {
            case .idle:
                Button("Fetch hardware logs", systemImage: "arrow.down.doc") {
                    logManager.fetchLogs()
                }
                .disabled(model.device == nil)

            case .fetching(let receivedBytes):
                HStack {
                    ProgressView()
                        .padding(.trailing, 6)
                    VStack(alignment: .leading) {
                        Text("Fetching hardware logs…")
                            .font(.headline)
                        Text("\(receivedBytes) bytes received")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") {
                        logManager.stopSync()
                    }
                    .buttonStyle(.borderless)
                }

            case .ready(_, _, let fetchedAt):
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Logs ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.headline)
                        Text("Fetched at \(fetchedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Fetch again") {
                        logManager.fetchLogs()
                    }
                    .buttonStyle(.borderless)
                }

            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Log pull failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.headline)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry fetch") {
                        logManager.fetchLogs()
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
            }
        } header: {
            Text("Hardware Log Transfer")
        } footer: {
            Text("Pulls diagnostic log files from the Plaud recorder hardware over Bluetooth. Use this to inspect internal hardware events or share logs for debugging.")
        }
    }

    // MARK: - Log Text Viewer

    @ViewBuilder
    private var logOutputSection: some View {
        if case .ready(let logText, let fileURL, _) = logManager.state {
            Section {
                HStack {
                    ShareLink(item: fileURL) {
                        Label("Export Log File", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = logText
                    } label: {
                        Label("Copy Text", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }

                ScrollView(.vertical) {
                    Text(logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 350)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            } header: {
                Text("Log Contents")
            }
        }
    }

    // MARK: - Device Actions

    private var deviceActionSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingDeleteDeviceLogs = true
            } label: {
                Label("Delete logs on recorder", systemImage: "trash")
            }
            .disabled(model.device == nil || logManager.state.isFetching)
        } header: {
            Text("Recorder Maintenance")
        } footer: {
            Text("Clears diagnostic log files stored internally on the recorder to free log storage space.")
        }
    }
}
