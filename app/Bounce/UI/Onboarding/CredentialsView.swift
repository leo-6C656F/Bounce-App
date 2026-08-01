import SwiftUI

/// First-run credential entry.
///
/// Deliberately the very first screen: without credentials Bounce cannot mint a
/// token, and without a token the SDK will not initialise, so there is nothing
/// useful to show behind this.
struct CredentialsView: View {

    /// Set when editing from Settings rather than onboarding.
    var isEditing = false

    @Environment(\.dismiss) private var dismiss

    @State private var clientId = ""
    @State private var secretKey = ""
    @State private var region: PlaudRegion = .us
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !clientId.trimmingCharacters(in: .whitespaces).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "key.horizontal.fill")
                                .font(.system(size: 36, weight: .thin))
                                .foregroundStyle(.tint)
                            Text("Connect your Plaud account")
                                .font(.title3.weight(.medium))
                            Text("Bounce needs the Client ID and Secret Key from your Plaud developer application. It uses them to issue its own access tokens, so you never have to sign in again.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Credentials") {
                    // Deliberately no .textContentType(.username/.password) — that
                    // opts this form into iOS's "Save Password" prompt, which would
                    // copy an account-level secret into iCloud Keychain. The whole
                    // point of KeychainStore's kSecAttrSynchronizable: false is to
                    // keep this credential off iCloud; a second, app-uncontrolled
                    // copy there defeats it.
                    TextField("Client ID", text: $clientId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("Secret Key", text: $secretKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Picker("Region", selection: $region) {
                        ForEach(PlaudRegion.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    Label("Stored in the iPhone keychain", systemImage: "lock.shield.fill")
                        .font(.footnote)
                    Text("Encrypted at rest, never synced to iCloud, excluded from backups, and never written to a log or a build file. Viewing them again requires Face ID.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Where these go")
                } footer: {
                    Text("These are account-level credentials: anything holding them can issue tokens for your whole Plaud application. Keep a passcode on this iPhone, and clear them from Settings if you pass the device on.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Link(destination: URL(string: "https://portal.plaud.ai")!) {
                        Label("Plaud Developer Portal", systemImage: "arrow.up.right.square")
                    }
                    Text("Create an Embedded SDK Application to get a Client ID and Secret Key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isEditing ? "Credentials" : "Get started")
            .toolbarTitleDisplayMode(isEditing ? .inline : .large)
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Checking…" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .disabled(isSaving)
            .task {
                guard isEditing else { return }
                // Reveal is Face ID gated; a decline just leaves the form blank.
                if let existing = await TokenProvider.shared.revealCredentials() {
                    clientId = existing.clientId
                    secretKey = existing.secretKey
                    region = existing.region
                }
            }
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        Task {
            let credentials = PlaudCredentials(
                clientId: clientId.trimmingCharacters(in: .whitespaces),
                secretKey: secretKey.trimmingCharacters(in: .whitespaces),
                region: region
            )
            do {
                // Verified against Plaud before being persisted, so a typo
                // can't leave the app thinking it's configured.
                try await TokenProvider.shared.save(credentials)
                isSaving = false
                if isEditing { dismiss() }
            } catch {
                isSaving = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
