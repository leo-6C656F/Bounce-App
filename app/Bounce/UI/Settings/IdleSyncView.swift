import SwiftUI

/// Idle WiFi sync: store WiFi credentials on the recorder so it uploads
/// recordings by itself, without the phone nearby.
///
/// **Unverified claim, stated plainly rather than assumed:** whether this
/// uploads to Plaud's cloud or somewhere Bounce controls hasn't been
/// established on real hardware. See `docs/plans/sdk-expansion.md` Phase 1
/// and `IdleSyncManager.handleUrl`.
struct IdleSyncView: View {

    @Environment(AppModel.self) private var model
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                Toggle("Sync over WiFi when idle", isOn: Binding(
                    get: { model.idleSyncEnabled },
                    set: { model.setIdleSyncEnabled($0) }
                ))
            } footer: {
                Text("\u{26A0}\u{FE0F} Unverified: it isn't yet established on real hardware whether idle sync uploads to Plaud's cloud or somewhere this app controls. Treat this as experimental until that's confirmed.")
            }

            Section {
                if model.idleSyncNetworks.isEmpty {
                    Text("No networks saved. Add one so the recorder has somewhere to sync to.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.idleSyncNetworks) { network in
                        IdleSyncNetworkRow(
                            network: network,
                            testResult: model.idleSyncTestResults[network.index],
                            onTest: { model.testIdleSyncNetwork(index: network.index) }
                        )
                    }
                    .onDelete { offsets in
                        let indices = offsets.map { model.idleSyncNetworks[$0].index }
                        model.deleteIdleSyncNetworks(indices: indices)
                    }
                }

                Button("Add network", systemImage: "plus") {
                    isAdding = true
                }
            } header: {
                Text("Networks")
            } footer: {
                Text("Passwords are sent straight to the recorder and never stored on this iPhone.")
            }
        }
        .navigationTitle("Idle WiFi Sync")
        .toolbarTitleDisplayMode(.inline)
        .task { model.refreshIdleSync() }
        .sheet(isPresented: $isAdding) {
            IdleSyncAddSheet { ssid, password in
                model.saveIdleSyncNetwork(index: model.nextFreeIdleSyncIndex(), ssid: ssid, password: password)
            }
        }
    }
}

private struct IdleSyncNetworkRow: View {

    let network: IdleSyncManager.Network
    let testResult: IdleSyncManager.TestResult?
    let onTest: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(network.ssid.isEmpty ? "(unnamed)" : network.ssid)
                if let testResult {
                    Text(testResult.label)
                        .font(.caption)
                        .foregroundStyle(testResult == .succeeded ? Color.secondary : Color.orange)
                }
            }
            Spacer()
            Button("Test", action: onTest)
                .buttonStyle(.borderless)
                .disabled(testResult == .testing)
        }
    }
}

private struct IdleSyncAddSheet: View {

    let onSave: (_ ssid: String, _ password: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Network name") {
                    TextField("SSID", text: $ssid)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Password") {
                    SecureField("Password", text: $password)
                }
            }
            .navigationTitle("Add network")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(ssid, password)
                        dismiss()
                    }
                    .disabled(ssid.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
