import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Elapsed time for the **paused** state, matching what `Text(timerInterval:)`
/// shows while running: `m:ss` under an hour, `h:mm:ss` over it.
///
/// A fixed `.minuteSecond` pattern rendered a 92-minute recording as "92:14",
/// and — worse — meant a long recording changed format the moment you paused
/// it, since the running line rolls over on its own. The widget target compiles
/// only `BounceWidgets/` plus two `LiveActivity/` files (see `project.yml`), so
/// it can't reach the app's `TimeInterval.timecodeText`; this is the local
/// equivalent.
private func pausedTimecode(_ seconds: TimeInterval) -> String {
    let pattern: Duration.TimeFormatStyle.Pattern =
        seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
    return Duration.seconds(seconds).formatted(.time(pattern: pattern))
}

/// Lock Screen + Dynamic Island UI for an in-progress recording, with Pause/
/// Resume and Stop that drive the app via `LiveActivityIntent` (see
/// `RecordingIntents`).
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activitySystemActionForegroundColor(.red)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.deviceName).lineLimit(1)
                    } icon: {
                        Image(systemName: "record.circle").foregroundStyle(.red)
                    }
                    .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timeText(context).font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        pauseResumeButton(context)
                        stopButton
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(.red)
            } compactTrailing: {
                timeText(context)
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .frame(minWidth: 44)
            } minimal: {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
    }

    @ViewBuilder
    private func timeText(_ context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        if context.state.isPaused {
            Text(pausedTimecode(context.state.pausedElapsed))
        } else {
            Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
        }
    }

    private func pauseResumeButton(_ context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        Group {
            if context.state.isPaused {
                Button(intent: ResumeRecordingIntent()) {
                    Label("Resume", systemImage: "play.fill")
                }
            } else {
                Button(intent: PauseRecordingIntent()) {
                    Label("Pause", systemImage: "pause.fill")
                }
            }
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    private var stopButton: some View {
        Button(intent: StopRecordingIntent()) {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .opacity(context.state.isPaused ? 0.4 : 1)
                    Text(context.state.isPaused ? "Paused" : "Recording · on device")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if context.state.isPaused {
                    Text(pausedTimecode(context.state.pausedElapsed))
                        .font(.title2.monospacedDigit())
                } else {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .font(.title2.monospacedDigit())
                }
            }

            Spacer()

            HStack(spacing: 10) {
                if context.state.isPaused {
                    Button(intent: ResumeRecordingIntent()) {
                        Image(systemName: "play.fill").frame(width: 36, height: 36)
                    }
                } else {
                    Button(intent: PauseRecordingIntent()) {
                        Image(systemName: "pause.fill").frame(width: 36, height: 36)
                    }
                }
                Button(intent: StopRecordingIntent()) {
                    Image(systemName: "stop.fill").frame(width: 36, height: 36)
                }
                .tint(.red)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
        }
        .padding()
    }
}
