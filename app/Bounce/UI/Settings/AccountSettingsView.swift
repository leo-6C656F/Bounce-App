import SwiftUI

/// Plaud account: region, token renewal status, and credentials. Removing
/// credentials lives in `SettingsView`'s Danger zone, not here, since every
/// irreversible action is consolidated there.
struct AccountSettingsView: View {

    @State private var isEditingCredentials = false

    var body: some View {
        Form {
            accountSection
        }
        .navigationTitle("Plaud account")
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingCredentials) {
            CredentialsView(isEditing: true)
        }
    }

    private var accountSection: some View {
        Section {
            LabeledContent("Region", value: TokenProvider.shared.region.label)

            if let expiry = TokenProvider.shared.tokenExpiresAt {
                LabeledContent("Access token") {
                    if TokenProvider.shared.isAuthenticating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Renewing…")
                        }
                    } else {
                        Text("Renews \(expiry.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = TokenProvider.shared.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Button("View or change credentials", systemImage: "key.horizontal") {
                isEditingCredentials = true
            }
        } header: {
            Text("Plaud account")
        } footer: {
            Text("Your Client ID and Secret Key are held in this iPhone's keychain \u{2014} encrypted, never synced to iCloud, and excluded from backups. Bounce uses them to renew its own access token, which is why you don't have to sign in again.")
        }
    }
}
