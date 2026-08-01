import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

/// Settings for the desktop view: turn it on, show the address and pairing
/// code, and see which browsers are connected.
struct DesktopViewSettingsView: View {

    @State private var server = DesktopServer.shared
    @State private var portText = ""
    /// Shown in full **once**, immediately after generating, and never again —
    /// it isn't read back out of the keychain for display. If the user loses it
    /// they generate a new one, which is also the moment the old one stops
    /// working. That's the standard shape for an API token and it's the honest
    /// one: a token permanently readable on screen is a token that leaks over
    /// someone's shoulder.
    @State private var freshToken: String?
    @State private var hasToken = APITokenStore.hasToken
    @State private var isConfirmingRevoke = false
    @State private var tokenError: String?

    var body: some View {
        Form {
            switchSection
            if server.isRunning {
                connectSection
                clientsSection
            }
            encryptionSection
            apiTokenSection
            optionsSection
            privacySection
        }
        .navigationTitle("Desktop view")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { portText = String(server.port) }
    }

    // MARK: - Switch

    private var switchSection: some View {
        Section {
            Toggle("Desktop view", isOn: Binding(
                get: { server.isRunning },
                set: { $0 ? server.start() : server.stop() }))

            if let error = server.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }

            // Only shown once it is actually holding — the point of the row is to
            // say the app switch is safe, and saying that on the strength of a
            // failed activation is worse than saying nothing.
            if server.isRunning, BackgroundResidency.shared.isHolding {
                Label(
                    "Stays running when you switch apps, for up to "
                    + "\(DesktopServer.backgroundHoldLimitMinutes / 60) hours.",
                    systemImage: "moon.zzz")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let residencyError = BackgroundResidency.shared.lastError {
                Label(residencyError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        } footer: {
            Text(BackgroundResidency.isSupported
                 ? "Allows web browser access to your recording library over your local Wi-Fi network. Bounce keeps itself running in the background while this is on, which uses more battery."
                 : "Allows web browser access to your recording library over your local Wi-Fi network while Bounce is open on screen.")
        }
    }

    // MARK: - Connect

    private var connectSection: some View {
        Section("Connect") {
            if let url = server.url {
                VStack(alignment: .leading, spacing: Metrics.compactSpacing) {
                    Text(url)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)

                    if let qr = Self.qrCode(for: url) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 130, height: 130)
                            .accessibilityLabel("QR code for \(url)")
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("Not on a network Bounce can see.")
                    .foregroundStyle(.secondary)
            }

            if !server.isDiscoverable {
                Label(
                    "Not discoverable by name — use the address above. iOS refused the "
                    + "Bonjour advertisement, usually because Local Network access is off "
                    + "for Bounce in iOS Settings › Privacy & Security.",
                    systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Pairing code") {
                Text(server.session.pairingCode)
                    .font(.system(.title2, design: .monospaced))
                    .tracking(4)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Clients

    private var clientsSection: some View {
        Section("Connected browsers") {
            if server.session.clients.isEmpty {
                Text("None yet — enter the code in a browser.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(server.session.clients) { client in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(client.displayName)
                            Text(client.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke") { server.session.revoke(client) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Encryption

    private var encryptionSection: some View {
        Section {
            Toggle("Encrypt the connection", isOn: Binding(
                get: { server.useTLS },
                set: { newValue in
                    server.useTLS = newValue
                    // The scheme is baked into the URL and the certificate into
                    // the listener, so this only takes effect on a restart.
                    if server.isRunning { server.stop(); server.start() }
                }))
            .disabled(server.isRunning && server.session.clients.isEmpty == false)

            // A browser that can't get past the certificate looks identical to a
            // broken server from the user's side, so say which it is.
            if server.isRunning, server.useTLS,
               server.refusedConnections > 2, !server.hasServedAnything {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Something is refusing the certificate",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("\(server.refusedConnections) connections closed without loading "
                         + "anything. If your browser won't offer to continue past the "
                         + "warning, turn encryption off to check the rest works.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Turn encryption off and restart") {
                        server.useTLS = false
                        server.stop()
                        server.start()
                    }
                }
                .padding(.vertical, 2)
            }

            if server.useTLS, let fingerprint = server.certificateFingerprint {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Certificate fingerprint")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)

                Button("Replace certificate") { server.resetCertificate() }
            }
        } header: {
            Text("Encryption")
        } footer: {
            if server.useTLS {
                Text("Bounce makes its own certificate, so your browser will warn you the "
                     + "first time and you'll need to continue past it. That's expected — "
                     + "no one can issue a trusted certificate for a home network address. "
                     + "You can check the fingerprint above against the one your browser "
                     + "shows. Encryption stops anyone on this network reading your "
                     + "recordings; it doesn't prove they're reaching your iPhone.")
            } else {
                Text("Off means everything — transcripts, audio, and the pairing code — "
                     + "crosses the network as plain text that any other device on it can "
                     + "read. Only turn this off on a network you control.")
            }
        }
    }

    // MARK: - Options

    /// Generate, copy and revoke the long-lived API token.
    ///
    /// Separate from the browser pairing code on purpose: that code buys a session
    /// that dies with the app, and this is a durable credential meant to be copied
    /// onto another machine. The warning is not boilerplate — this is the one thing
    /// in Bounce that hands every transcript to something the user won't be
    /// watching.
    private var apiTokenSection: some View {
        Section {
            if let freshToken {
                // The only time it's on screen. `.textSelection` so it can be
                // copied by hand if the button misbehaves.
                Text(freshToken)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy token", systemImage: "doc.on.doc") {
                    // Never `.string =` — that goes on the general pasteboard with
                    // no restrictions, which Universal Clipboard will hand to the
                    // user's other Apple devices, and any app they foreground next
                    // can read. `.localOnly` keeps it off Handoff/Universal
                    // Clipboard; the short expiration limits the window a
                    // shoulder-surfed or app-switched read is even possible in —
                    // this token "grants read access to every transcript on this
                    // iPhone until revoked."
                    UIPasteboard.general.setItems(
                        [[UTType.utf8PlainText.identifier: freshToken]],
                        options: [
                            .localOnly: true,
                            .expirationDate: Date().addingTimeInterval(60),
                        ])
                }
                Button("Done — I've saved it") { self.freshToken = nil }
                    .foregroundStyle(.secondary)
            } else if hasToken {
                LabeledContent("Token", value: APITokenStore.redactedToken)
                    .monospaced()
                Button("Replace token", systemImage: "arrow.clockwise") { generateToken() }
                Button("Revoke token", systemImage: "trash", role: .destructive) {
                    isConfirmingRevoke = true
                }
            } else {
                Button("Generate API token", systemImage: "key") { generateToken() }
            }

            if let tokenError {
                Text(tokenError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("API access")
        } footer: {
            Text(hasToken || freshToken != nil
                ? "Send it as `Authorization: Bearer <token>` — never in a URL, where it would land in logs and history. **It grants read access to every transcript on this iPhone and does not expire**; revoking is the only thing that stops it. Replacing it immediately breaks anything using the old one."
                : "Creates a long-lived token so scripts and AI agents can read your library over this network — including Claude Desktop, via the MCP endpoint. **A token grants read access to every transcript on this iPhone until you revoke it.** Unlike the browser pairing code, it survives restarts, and you'll be copying it onto another machine. Read-only: nothing with this token can delete or change a recording.")
        }
        .confirmationDialog(
            "Revoke the API token?",
            isPresented: $isConfirmingRevoke,
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) { revokeToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything using it — scripts, Claude Desktop — stops working immediately. Browsers paired with the six-digit code are unaffected.")
        }
    }

    private func generateToken() {
        do {
            // `APITokenStore.generate` mints and persists in one step, so there's
            // no window where a token exists but isn't saved.
            freshToken = try APITokenStore.generate()
            hasToken = true
            tokenError = nil
        } catch {
            // Deliberately does not interpolate the token into the message.
            tokenError = "Couldn't save the token to the keychain. \(error.localizedDescription)"
        }
    }

    private func revokeToken() {
        // Through the server, not `APITokenStore.clear()` — revoking has to close
        // any live stream the token has open, which the store can't do.
        server.revokeAPIToken()
        freshToken = nil
        hasToken = false
        tokenError = nil
    }

    private var optionsSection: some View {
        Section {
            LabeledContent("Port") {
                TextField("8080", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .onSubmit(commitPort)
                    .onChange(of: portText) { _, _ in commitPort() }
                    .disabled(server.isRunning)
            }

            Toggle("Discoverable on this network", isOn: Binding(
                get: { server.advertiseOnNetwork },
                set: { server.advertiseOnNetwork = $0 }))
            .disabled(server.isRunning)

            Picker("Switch off when idle", selection: Binding(
                get: { server.autoStopMinutes },
                set: { server.autoStopMinutes = $0 }
            )) {
                Text("After 15 minutes").tag(15)
                Text("After 30 minutes").tag(30)
                Text("After an hour").tag(60)
                Text("Never").tag(0)
            }
        } header: {
            Text("Options")
        } footer: {
            Text(optionsFooter)
        }
    }

    /// Assembled outside the view builder: inline, the conditional concatenation
    /// defeated the type-checker ("unable to type-check this expression in
    /// reasonable time").
    private var optionsFooter: String {
        if server.isRunning {
            return "Switch desktop view off to change the port or discoverability."
        }
        let stopRule: String
        if BackgroundResidency.isSupported {
            let hours = DesktopServer.backgroundHoldLimitMinutes / 60
            stopRule = "Desktop view also switches off after \(hours) hours in the "
                + "background, however many browsers are connected."
        } else {
            stopRule = "Desktop view always stops when Bounce leaves the foreground."
        }
        return "Discoverable means other devices can find Bounce by name — which also "
            + "means anything on the network will try connecting to it. Off is fine; "
            + "use the address above. The idle timer never runs while you're recording. "
            + stopRule
    }

    private func commitPort() {
        let digits = portText.filter(\.isNumber)
        if digits != portText { portText = digits }
        guard let value = UInt16(digits), value >= 1024 else { return }
        server.port = value
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            Label {
                Text(server.useTLS
                     ? "Anyone on this network who has the pairing code can read your "
                       + "recordings and transcripts. The connection is encrypted, so it "
                       + "can't be read in passing — but a determined attacker on the same "
                       + "network could still put themselves in the middle, and your "
                       + "browser would show the same warning it always does."
                     : "Anyone on this network who has the pairing code can read your "
                       + "recordings and transcripts, and the connection is unencrypted, so "
                       + "any device on the network can read them in passing.")
            } icon: {
                Image(systemName: server.useTLS ? "lock" : "lock.open")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("What this opens up")
        }
    }

    // MARK: - QR

    private static func qrCode(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Upscale before rasterising — the generator's native output is a few
        // dozen pixels across and scaling that in SwiftUI blurs the modules.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
