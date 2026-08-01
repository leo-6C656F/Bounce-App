import SwiftUI

/// A day's recordings, hung off a spine, with each bar's height its duration.
///
/// **The bar is the feature.** A list row tells you a recording exists; this
/// tells you the shape of a day — that the 42-minute client call dwarfs four
/// notes around it, and that the afternoon was quiet. `DurationBar` maps length
/// through a square root so a seven-second reminder is still visible next to a
/// long meeting; see the note there for why that isn't linear.
///
/// Laid out as three columns — time, spine, content — rather than absolute
/// positions, so the vertical line is just each row's spine column drawn
/// edge-to-edge and consecutive rows join up without any coordinate maths.
struct RecordingTimeline: View {

    let groups: [RecordingDayGroup]
    /// Namespace for the zoom transition into the detail screen, owned by the
    /// caller — a namespace can't be shared across navigation contexts.
    let zoom: Namespace.ID
    var onDelete: (Recording) -> Void
    var onTranscribe: (Recording) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.day) { group in
                    DayMarker(group: group)
                    ForEach(group.recordings) { recording in
                        NavigationLink {
                            RecordingDetailView(
                                recording: recording,
                                zoomSource: ZoomTransitionSource(id: recording.id, namespace: zoom))
                        } label: {
                            TimelineRow(recording: recording)
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: recording.id, in: zoom)
                        .contextMenu {
                            if recording.isSynced, !recording.isTranscribed {
                                Button("Transcribe", systemImage: "text.quote") {
                                    onTranscribe(recording)
                                }
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                onDelete(recording)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

/// One day's heading, sitting on the spine.
private struct DayMarker: View {

    let group: RecordingDayGroup

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Color.clear.frame(width: TimelineMetrics.timeColumn)

            ZStack {
                spineLine
                Circle()
                    .fill(.tint)
                    .frame(width: 11, height: 11)
                    // A ring in the page colour, so the dot reads as sitting on
                    // the line rather than being pierced by it.
                    .background(Circle().fill(Color(.systemBackground)).frame(width: 17, height: 17))
            }
            .frame(width: TimelineMetrics.spineColumn)

            HStack(spacing: 8) {
                SectionLabel(group.title, tint: .primary)
                Spacer(minLength: 0)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 12)
        }
        .frame(height: 44)
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let count = group.recordings.count
        let minutes = Int((group.recordings.reduce(0) { $0 + $1.duration } / 60).rounded())
        let recordings = "\(count) recording\(count == 1 ? "" : "s")"
        return minutes > 0 ? "\(recordings) · \(minutes) min" : recordings
    }

    private var spineLine: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
    }
}

/// One recording on the spine.
private struct TimelineRow: View {

    let recording: Recording

    private var category: RecordingCategory? {
        guard let name = recording.categoryName else { return nil }
        return CategoryStore.shared.category(named: name)
    }

    private var tint: Color {
        recording.categoryName == nil ? .secondary : CategoryStyle.color(for: category)
    }

    private var openTasks: Int {
        recording.actionItems?.filter { !$0.isDone }.count ?? 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(recording.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: TimelineMetrics.timeColumn, alignment: .trailing)
                .padding(.trailing, 10)
                .padding(.top, 2)

            ZStack(alignment: .top) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                DurationBar(duration: recording.duration, tint: tint)
            }
            .frame(width: TimelineMetrics.spineColumn)

            content
                .padding(.leading, 12)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(recording.displayTitle)
                    .font(.body)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                SparklineLoader(recording: recording) { peaks in
                    if !peaks.isEmpty {
                        Sparkline(peaks: peaks, tint: tint)
                            .frame(width: 110, height: 16)
                    }
                }

                Text(recording.durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if openTasks > 0 {
                    StatusDot(.accentColor, diameter: 5)
                    Text("\(openTasks) task\(openTasks == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }

                Spacer(minLength: 0)

                badges
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
            if !recording.isSynced {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Still on the recorder")
            } else if !recording.isTranscribed {
                Image(systemName: "text.quote")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Not transcribed")
            }
        }
        .font(.caption)
    }

    private var accessibilityLabel: String {
        var parts = [recording.displayTitle]
        parts.append(recording.createdAt.formatted(date: .omitted, time: .shortened))
        if recording.duration > 0 { parts.append(recording.duration.spokenTimecode) }
        if let name = category?.name { parts.append(name) }
        if openTasks > 0 { parts.append("\(openTasks) open task\(openTasks == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

/// Column widths, in one place so the day markers and the rows can't drift out
/// of alignment — the spine is only continuous if every row puts it in exactly
/// the same column.
private enum TimelineMetrics {
    static let timeColumn: CGFloat = 46
    static let spineColumn: CGFloat = 18
}

/// A day's worth of recordings.
///
/// Shared between the timeline and the calendar's day sections rather than being
/// private to `LibraryView`, so both render the same grouping.
struct RecordingDayGroup {
    let day: Date
    let title: String
    let recordings: [Recording]
}
