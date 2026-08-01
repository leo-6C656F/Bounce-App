import SwiftUI

/// One recording, as it appears in Home and Library.
struct RecordingRow: View {

    let recording: Recording

    /// Cached peak envelope, or empty. Rows never trigger a decode — see
    /// `WaveformCache.cached(for:)` — so this stays empty until the detail view
    /// or the library prewarm has built one, and the sparkline simply isn't
    /// drawn until then.
    @State private var peaks: [UInt8] = []

    private var status: TranscriptionCoordinator.Status? {
        TranscriptionCoordinator.shared.status(for: recording)
    }

    var body: some View {
        HStack(spacing: 12) {
            CategoryGlyph(categoryName: recording.categoryName)

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.displayTitle)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(recording.durationText)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let status {
                    HStack(spacing: 5) {
                        if status.isWorking {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(status.label)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if !peaks.isEmpty {
                // No playhead here — `progress: 1` paints every bar in the
                // sparkline style, making this the recording's shape rather
                // than a second progress indicator competing with the badges.
                WaveformView(
                    peaks: peaks,
                    progress: 1,
                    barWidth: 2,
                    barSpacing: 1,
                    playedStyle: AnyShapeStyle(.tertiary))
                .frame(width: 46, height: 22)
            }

            badges
        }
        // A list row's disclosure indicator is supplied by `NavigationLink`
        // itself; this only needs the status badges, not a manual chevron.
        .accessibilityElement(children: .combine)
        .task(id: recording.audioFilename) {
            guard let url = RecordingStore.shared.audioURL(for: recording) else { return }
            // Re-check a few times rather than once: `LibraryView`'s prewarm
            // builds envelopes serially in the background, so a row that
            // appeared before its turn came round would otherwise sit blank
            // until it was scrolled away and recycled. Bounded, and the task
            // dies with the row.
            for attempt in 0..<6 {
                if let cached = await WaveformCache.shared.cached(for: url) {
                    peaks = cached
                    return
                }
                if attempt < 5 { try? await Task.sleep(for: .seconds(2)) }
                if Task.isCancelled { return }
            }
        }
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if !recording.deliveredTo.isEmpty {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Sent")
            }
            if recording.isTranscribed {
                Image(systemName: "text.quote")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Transcribed")
            } else if !recording.isSynced {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Still on the recorder")
            }
        }
        .font(.caption)
    }
}
