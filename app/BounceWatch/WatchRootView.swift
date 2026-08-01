import SwiftUI

/// The whole watch app: one screen, one primary button.
///
/// Scoped hard on purpose. A watch is used at arm's length in a meeting someone
/// is already in — the useful actions are start, stop, mark this moment, and
/// "did it actually start?". Browsing a library on a wrist is not a thing anyone
/// does, and the transcripts stay on the phone.
struct WatchRootView: View {

    @Environment(WatchConnector.self) private var connector

    private var snapshot: WatchLink.Snapshot { connector.snapshot }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                primaryButton
                secondaryButtons
                status
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Bounce")
        .task { connector.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 2) {
            Text(snapshot.deviceName ?? "No recorder")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(snapshot.isConnected ? .primary : .secondary)

            HStack(spacing: 4) {
                Circle()
                    .fill(snapshot.isConnected ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(snapshot.isConnected ? "Connected" : "Disconnected")
                if let battery = snapshot.batteryPercent, snapshot.isConnected {
                    Text("· \(battery)%")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Primary

    /// One button whose meaning comes from `Snapshot.primaryActionTitle`, so the
    /// watch can never label it differently from what `toggleRecording` will
    /// actually do on the phone.
    private var primaryButton: some View {
        Button {
            connector.send(.toggleRecording)
        } label: {
            HStack(spacing: 8) {
                if connector.isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: snapshot.isActive ? "stop.fill" : "record.circle")
                }
                Text(snapshot.primaryActionTitle)
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(snapshot.isActive ? .red : .bounceWatch)
        // Disabled rather than hidden when there's nothing to record with: a
        // button that vanishes reads as a bug, one that's dimmed reads as a
        // state — and the line underneath says which.
        .disabled(!snapshot.isConnected || connector.isSending)
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        if snapshot.isActive {
            HStack(spacing: 8) {
                Button {
                    connector.send(.highlight)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "bookmark.fill")
                        if snapshot.highlightCount > 0 {
                            Text("\(snapshot.highlightCount)")
                                .font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .tint(.orange)
                .accessibilityLabel("Mark this moment")

                Button {
                    connector.send(.pauseRecording)
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                // Pausing a paused recording is meaningless; resuming is what
                // the primary button already offers in that state.
                .disabled(snapshot.phase == .paused)
                .accessibilityLabel("Pause")
            }
            .buttonStyle(.bordered)
            .disabled(connector.isSending)
        } else {
            Button {
                connector.send(.sync)
            } label: {
                Label("Sync", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!snapshot.isConnected || connector.isSending)
        }
    }

    // MARK: - Status

    /// One line, and the order of precedence matters: an unreachable phone
    /// explains everything else on the screen, so it wins.
    @ViewBuilder
    private var status: some View {
        if let message = connector.unreachableMessage {
            statusLine(message, symbol: "iphone.slash", tint: .orange)
        } else if let message = snapshot.lastMessage {
            statusLine(message, symbol: "exclamationmark.circle", tint: .orange)
        } else if let sync = snapshot.syncStatus {
            statusLine(sync, symbol: "arrow.down.circle", tint: .secondary)
        } else if snapshot.phase == .recording, let startedAt = snapshot.startedAt {
            // A local timer from the phone's start date, rather than the phone
            // sending a tick a second: the watch can count on its own, and
            // waking it once a second to redraw a clock is a battery bill for
            // nothing.
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                Text(startedAt, style: .timer)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.red)
        } else if snapshot.phase == .paused {
            statusLine("Paused", symbol: "pause.circle", tint: .secondary)
        } else if !snapshot.isConnected {
            statusLine("Open Bounce on your iPhone to connect.", symbol: "iphone", tint: .secondary)
        }
    }

    private func statusLine(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
