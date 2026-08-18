import SwiftUI

/// The calendar meeting a recording is linked to, on the detail screen, and the
/// way to link, change, or clear it by hand.
///
/// Automatic matching links a recording to a meeting only when it is confident
/// (see `CalendarMatching.evaluate`). This card is the other half: when the
/// recorder's clock drifted, the meeting ran long, or two meetings are equally
/// plausible, the match is left unmade and the user finishes it here — picking
/// from the meetings that happened before, during and after the recording.
///
/// Renders nothing when there is no link *and* the calendar feature is off — the
/// same call `PlaceCard` and `SeriesCard` make, so a library recorded without
/// the feature isn't littered with empty prompts.
struct MeetingCard: View {

    let recording: Recording
    @Environment(AppModel.self) private var model
    @State private var isPicking = false

    private var linkedTitle: String? {
        guard let title = recording.calendarEventTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
    }

    /// Whether offering "Use meeting name" would do anything — a meeting is linked
    /// and the recording isn't already called that. Keeps the action off the card
    /// when it would be a no-op (an untitled recording, or one linking already
    /// adopted the name).
    private var canAdoptMeetingName: Bool {
        guard let linkedTitle else { return false }
        let current = recording.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.caseInsensitiveCompare(linkedTitle) != .orderedSame
    }

    var body: some View {
        Group {
            if let linkedTitle {
                linked(linkedTitle)
            } else if DeliverySettings.shared.calendarTitles {
                linkButton
            }
        }
        .sheet(isPresented: $isPicking) {
            MeetingPicker(recording: recording)
        }
    }

    private func linked(_ title: String) -> some View {
        ContentCard {
            Button {
                isPicking = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // One-tap adoption of the meeting's name, without opening the picker —
            // the escape hatch behind the link rule that won't overwrite a title
            // the user typed. Hidden when the recording is already called that.
            .contextMenu {
                if canAdoptMeetingName {
                    Button("Use meeting name", systemImage: "textformat") {
                        model.adoptMeetingTitle(for: recording)
                    }
                }
            }
        }
    }

    private var linkButton: some View {
        ContentCard {
            Button {
                isPicking = true
            } label: {
                Label("Link to a meeting", systemImage: "calendar.badge.plus")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    /// "Linked meeting", plus the attendee count when we captured one — it's the
    /// reassurance that this is the right one, and where the speaker-name
    /// suggestions come from.
    private var subtitle: String {
        let count = recording.calendarAttendees?.count ?? 0
        guard count > 0 else { return "Linked meeting" }
        return count == 1 ? "Linked meeting · 1 attendee" : "Linked meeting · \(count) attendees"
    }
}

/// Pick the calendar meeting a recording belongs to, from the ones around it.
///
/// The meetings are grouped **Before / During / After** the recording's own time
/// window, which is exactly how the user thinks about it ("it was the 2 o'clock,
/// the one right after lunch"). Tapping one links it and makes the link stick —
/// `AppModel.linkCalendarEvent` marks it user-confirmed so a re-transcribe never
/// overwrites it.
///
/// Respects the existing permission flow: with no calendar access it offers the
/// same request `IntegrationsSettingsView` does rather than silently showing an
/// empty list.
struct MeetingPicker: View {

    let recording: Recording

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var calendar = CalendarMatcher.shared
    @State private var events: [CandidateEvent] = []
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            Group {
                if calendar.canReadEvents {
                    eventList
                } else {
                    accessPrompt
                }
            }
            .navigationTitle("Link a meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            calendar.refreshAuthorizationStatus()
            await load()
        }
    }

    // MARK: - The list

    @ViewBuilder
    private var eventList: some View {
        Form {
            group("During the recording", events: during)
            group("Before", events: before)
            group("After", events: after)

            if hasLoaded, during.isEmpty, before.isEmpty, after.isEmpty {
                Section {
                    Text("No meetings found in your calendars around this recording. It was made from \(windowText).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let meetingTitle = adoptableMeetingTitle {
                Section {
                    Button("Use “\(meetingTitle)” as the title", systemImage: "textformat") {
                        model.adoptMeetingTitle(for: recording)
                        dismiss()
                    }
                } footer: {
                    Text("Renames this recording to the meeting's name. Linking a meeting leaves a title you typed yourself alone — this takes the meeting's name anyway.")
                }
            }

            if recording.calendarEventTitle != nil {
                Section {
                    Button("Remove link", systemImage: "minus.circle", role: .destructive) {
                        model.unlinkCalendarEvent(from: recording)
                        dismiss()
                    }
                } footer: {
                    Text("Clears the meeting from this recording. Its title, series and location are kept.")
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, events: [CandidateEvent]) -> some View {
        if !events.isEmpty {
            Section(title) {
                ForEach(events, id: \.self) { event in
                    Button {
                        model.linkCalendarEvent(event, on: recording)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                    .lineLimit(1)
                                Text(timeRange(event))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isLinked(event) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var accessPrompt: some View {
        Form {
            Section {
                Button("Allow calendar access") {
                    Task {
                        await calendar.requestAccess()
                        await load()
                    }
                }
            } footer: {
                Text("Bounce needs access to your calendars to show the meetings around this recording. It only reads events — it never adds, edits, or deletes anything.")
            }
        }
    }

    /// The linked meeting's name, but only when adopting it would change the
    /// title — so the button doesn't offer to rename a recording to what it's
    /// already called.
    private var adoptableMeetingTitle: String? {
        guard let title = recording.calendarEventTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        let current = recording.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.caseInsensitiveCompare(title) == .orderedSame ? nil : title
    }

    // MARK: - Grouping

    private var recordingEnd: Date {
        recording.createdAt.addingTimeInterval(max(0, recording.duration))
    }

    /// Overlaps the recording's own window.
    private var during: [CandidateEvent] {
        events.filter { $0.start < recordingEnd && $0.effectiveEnd > recording.createdAt }
    }

    /// Ended before the recording began. Newest first — the meeting just before
    /// is the likeliest pick, so it sits at the top of the group.
    private var before: [CandidateEvent] {
        events
            .filter { $0.effectiveEnd <= recording.createdAt }
            .sorted { $0.start > $1.start }
    }

    /// Started after the recording ended.
    private var after: [CandidateEvent] {
        events
            .filter { $0.start >= recordingEnd }
            .sorted { $0.start < $1.start }
    }

    // MARK: - Helpers

    private func load() async {
        guard calendar.canReadEvents else { return }
        events = await calendar.surroundingEvents(
            recordingStart: recording.createdAt,
            duration: recording.duration)
        hasLoaded = true
    }

    /// Best-effort: the stored link keeps the event's title, so match on that.
    private func isLinked(_ event: CandidateEvent) -> Bool {
        guard let linked = recording.calendarEventTitle else { return false }
        return event.title.caseInsensitiveCompare(linked) == .orderedSame
    }

    private func timeRange(_ event: CandidateEvent) -> String {
        // A zero-length event has start == effectiveEnd, which isn't a valid
        // range to format as an interval — show the single instant instead.
        guard event.effectiveEnd > event.start else {
            return event.start.formatted(date: .abbreviated, time: .shortened)
        }
        return (event.start..<event.effectiveEnd).formatted(date: .abbreviated, time: .shortened)
    }

    private var windowText: String {
        recording.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
