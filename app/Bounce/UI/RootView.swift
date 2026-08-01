import SwiftUI

/// Top-level routing: pair a recorder, or get on with it.
struct RootView: View {

    @Environment(AppModel.self) private var model
    @State private var selection: MainTab = .home

    /// Named `MainTab` rather than `Tab` so it doesn't shadow SwiftUI's `Tab`
    /// inside the `TabView` builder below.
    /// **Five is the practical ceiling for the Liquid Glass tab bar.** A sixth
    /// would have to merge into an existing tab rather than be added here.
    enum MainTab: Hashable {
        case home, library, tasks, ask, settings
    }

    var body: some View {
        @Bindable var model = model

        return Group {
            if !model.hasCredentials {
                // Nothing works without a token, so this comes before pairing.
                CredentialsView()
            } else if model.hasPairedDevice {
                main
            } else {
                PairingView()
            }
        }
        .animation(.smooth, value: model.hasCredentials)
        .animation(.smooth, value: model.hasPairedDevice)
        .alert(item: $model.alert)
    }

    /// `TabView` picks up the Liquid Glass tab bar automatically on iOS 26, and
    /// minimising on scroll keeps the content the focus.
    private var main: some View {
        TabView(selection: $selection) {
            Tab("Recorder", systemImage: "waveform", value: MainTab.home) {
                HomeView()
            }
            Tab("Library", systemImage: "square.stack", value: MainTab.library) {
                LibraryView()
            }
            // Between Library and Ask on purpose: tasks come *out* of the library,
            // and Ask is the odd one out that reads across everything.
            Tab("Tasks", systemImage: "checklist", value: MainTab.tasks) {
                TasksView()
            }
            Tab("Ask", systemImage: "sparkles", value: MainTab.ask) {
                AskView()
            }
            Tab("Settings", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(AccessoryBar(accessory: accessory) {
            selection = .home
            model.isRecorderPresented = true
        })
    }

    /// What the bar above the tab bar should show, or nil for "nothing worth the
    /// space".
    private var accessory: AccessoryKind? {
        // Recording takes priority: it's the persistent "you're recording"
        // control reachable from any tab. It stands down when the full recording
        // screen is already up and showing the same thing.
        if model.isRecording, !model.isRecorderPresented { return .recording }
        // Playback outranks sync/transcription progress because it's the only one
        // of the two the user can act on from here — and `RecordingDetailView` no
        // longer stops playback on disappear, so this bar is now the only in-app
        // way to stop audio after leaving that screen.
        if AudioPlayerModel.shared.currentURL != nil { return .player }
        if model.syncState.isActive || TranscriptionCoordinator.shared.isBusy { return .activity }
        return nil
    }
}

private enum AccessoryKind { case recording, player, activity }

/// Docks the activity bar above the tab bar, and — the point of this type —
/// takes its space back when there is nothing to report.
///
/// A `tabViewBottomAccessory` whose builder returns an empty view still reserves
/// its slot and draws the glass capsule, so the app sat above a permanently
/// blank bar. `isEnabled:` removes the space properly, but only exists on
/// iOS 26.1, hence the branch.
///
/// This is a `ViewModifier` rather than an `if` wrapped around the modifier at
/// the call site on purpose: a conditional there swaps the view tree every time
/// activity starts or stops, which would reset every tab's navigation stack
/// mid-task. `#available` resolves once per launch, so this branch is constant.
private struct AccessoryBar: ViewModifier {

    let accessory: AccessoryKind?
    let onOpenRecorder: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: accessory != nil) { bar }
        } else {
            content.tabViewBottomAccessory { bar }
        }
    }

    @ViewBuilder
    private var bar: some View {
        switch accessory {
        case .recording: RecordingAccessory(onOpen: onOpenRecorder)
        case .player: PlayerAccessory()
        case .activity: ActivityAccessory()
        case nil: EmptyView()
        }
    }
}

/// Floating mini-player accessory docked above the tab bar for background audio playback.
private struct PlayerAccessory: View {

    @Bindable private var player = AudioPlayerModel.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: player.isPlaying ? "waveform" : "pause.circle")
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: player.isPlaying)

            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentTitle.isEmpty ? "Playing" : player.currentTitle)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss player")
        }
        .padding(.horizontal)
    }
}

/// Persistent recording control docked above the tab bar. Tap the body to reopen
/// the full recording screen; the inline buttons pause/resume and stop without
/// leaving the current tab.
private struct RecordingAccessory: View {

    @Environment(AppModel.self) private var model
    let onOpen: () -> Void

    private var isPaused: Bool {
        if case .paused = model.recordingState { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(isPaused ? 0.4 : 1)
                .pulseWhenActive(!isPaused)

            Group {
                if isPaused {
                    Text("Paused")
                } else if let startedAt = model.recordingState.startedAt {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                } else {
                    Text("Recording")
                }
            }
            .font(.footnote.weight(.medium))
            .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                isPaused ? model.resumeRecording() : model.pauseRecording()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPaused ? "Resume" : "Pause")

            Button {
                model.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        }
        .padding(.horizontal)
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
    }
}

/// Compact status strip docked above the tab bar while work is in flight.
private struct ActivityAccessory: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.footnote)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let progress = model.syncState.progress, progress.totalFiles > 0 {
                Text("\(progress.syncedFiles)/\(progress.totalFiles)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private var label: String {
        switch model.syncState {
        case .wifiConnecting(let phase):
            return phase.label
        case .wifiTransferring:
            return "Fast transfer"
        case .syncing(let progress):
            return progress.currentFileName.map { "Syncing \($0)" } ?? "Syncing"
        default:
            return TranscriptionCoordinator.shared.isBusy ? "Transcribing" : "Working"
        }
    }
}
