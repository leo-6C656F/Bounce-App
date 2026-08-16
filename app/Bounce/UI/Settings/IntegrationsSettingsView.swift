import SwiftUI
import UniformTypeIdentifiers

/// Consolidated integrations hub: Calendar matching, Task calendar events,
/// Apple Reminders sync, File/Folder delivery, Webhook endpoints, and Shortcuts.
struct IntegrationsSettingsView: View {

    @Environment(AppModel.self) private var model
    private var settings: DeliverySettings { DeliverySettings.shared }
    @State private var reminders = RemindersSync.shared
    @State private var destinations = TaskDestinations.shared
    @State private var taskCalendar = TaskCalendarWriter.shared
    @State private var calendar = CalendarMatcher.shared
    @State private var location = LocationCapture.shared

    @State private var isPickingFolder = false

    var body: some View {
        Form {
            calendarSection
            locationSection
            taskCalendarSection
            remindersSection
            autoDeliverySection
            webhookSection
            taskWebhookSection
            folderSection
            automationSection
        }
        .navigationTitle("Integrations & Delivery")
        .toolbarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result { settings.setFolder(url) }
        }
    }

    // MARK: - Calendar Matching (Meeting Titles & Attendees)

    /// Calendar-derived titles and attendee suggestions.
    ///
    /// Not a model feature — it's about how recordings get named as they arrive,
    /// which is why it sits with the other integrations rather than under AI.
    private var calendarSection: some View {
        Section {
            Toggle("Auto-title recordings from Calendar", isOn: Binding(
                get: { settings.calendarTitles },
                set: { enabling in
                    guard enabling else {
                        settings.calendarTitles = false
                        return
                    }
                    Task {
                        // Requested here, on first enable — never at launch. A prompt
                        // the user can't connect to something they just did gets
                        // denied, and a denial is permanent from the app's side.
                        // Reading events needs FULL calendar access; write-only is
                        // refused.
                        let granted = await CalendarMatcher.shared.requestAccess()
                        // Never leave the toggle on when it can't do anything.
                        settings.calendarTitles = granted
                    }
                }
            ))
            .disabled(calendarDenied)
        } header: {
            Text("Meeting matching")
        } footer: {
            Text(calendarDenied
                 ? "Bounce doesn't have full calendar access. Grant it in iOS Settings › Privacy & Security › Calendars › Bounce to use this. Reading events needs full access — write-only isn't enough."
                 : "When a recording overlaps a meeting in any calendar on this iPhone \u{2014} including Google or Exchange accounts \u{2014} Bounce names it after that meeting and offers the attendees when you name speakers. It only names recordings you haven't titled yourself, never writes to your calendar, and nothing leaves this iPhone.")
        }
    }

    private var calendarDenied: Bool {
        let status = calendar.authorizationStatus
        return status == .denied || status == .restricted || status == .writeOnly
    }

    // MARK: - Location

    /// Geotagging, and the Map mode in Library it feeds.
    ///
    /// Sits directly under calendar matching because the two share a source: a
    /// matched event's location is one of the three ways a recording gets a pin,
    /// and it only applies when both switches are on.
    private var locationSection: some View {
        Section {
            Toggle("Tag recordings with where they happened", isOn: Binding(
                get: { settings.geotagRecordings },
                set: { enabling in
                    guard enabling else {
                        // Deliberately does **not** erase places already stored.
                        // They're the user's data, and a switch quietly deleting
                        // a month of pins is not a trade anyone agreed to.
                        settings.geotagRecordings = false
                        return
                    }
                    Task {
                        // First enable, never at launch — same rule as calendar
                        // access above.
                        let granted = await LocationCapture.shared.requestAccess()
                        settings.geotagRecordings = granted
                    }
                }
            ))
            .disabled(location.isDenied)
        } header: {
            Text("Location")
        } footer: {
            Text(location.isDenied
                 ? "Bounce doesn't have location access. Grant it in iOS Settings › Privacy & Security › Location Services › Bounce to use this. You can still set a recording's location by hand from its detail screen."
                 : "A recording gets a location when this iPhone is connected to your recorder as it starts recording — that's where the recording actually happened. If it isn't connected, Bounce falls back to the location of a matching calendar event, or to where you were when the file synced, which it labels as approximate. See them all in Library › Map, and change any of them by hand. Locations stay on this iPhone and are never included in webhook or folder deliveries.")
        }
    }

    // MARK: - Task Calendar Writer

    /// Put dated tasks on the calendar.
    ///
    /// **The only place Bounce writes to the user's calendar.** Off by default, and
    /// the footer says plainly that it only ever touches events it created — that's
    /// the reassurance someone needs before granting write access to a calendar they
    /// share with colleagues.
    private var taskCalendarSection: some View {
        Section {
            Toggle("Add dated tasks to Calendar", isOn: Binding(
                get: { taskCalendar.writeEnabled },
                set: { enabling in
                    guard enabling else {
                        taskCalendar.writeEnabled = false
                        return
                    }
                    Task {
                        // On first enable, never at launch — same reasoning as
                        // `calendarSection`.
                        let granted = await taskCalendar.requestAccess()
                        // Never leave a toggle on that can't do anything.
                        taskCalendar.writeEnabled = granted
                        if granted { await model.syncTaskCalendar() }
                    }
                }
            ))
            .disabled(taskCalendarDenied)

            if taskCalendar.writeEnabled, !taskCalendar.availableCalendars.isEmpty {
                Picker("Target calendar", selection: Binding(
                    get: { taskCalendar.targetCalendarIdentifier ?? taskCalendar.targetCalendar?.id ?? "" },
                    set: { taskCalendar.targetCalendarIdentifier = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(taskCalendar.availableCalendars) { calendar in
                        Text(calendar.title).tag(calendar.id)
                    }
                }
            }
        } header: {
            Text("Task calendar events")
        } footer: {
            Text(taskCalendarDenied
                 ? "Calendar write access disabled. Grant access in iOS Settings › Privacy & Security › Calendars › Bounce."
                 : "Tasks you send from the Tasks tab that have a specific deadline are added as calendar events — nothing is added automatically. Bounce only manages events it created and never modifies your personal events.")
        }
    }

    private var taskCalendarDenied: Bool {
        let status = taskCalendar.authorizationStatus
        return status == .denied || status == .restricted || status == .writeOnly
    }

    // MARK: - Reminders Sync

    /// Mirror tasks into Apple Reminders.
    ///
    /// **Off by default**, and that's deliberate rather than cautious boilerplate:
    /// this writes into another app's data. Permission is requested on first enable,
    /// never at launch, and Reminders is a *separate* grant from Calendars even
    /// though both are EventKit.
    private var remindersSection: some View {
        Section {
            Toggle("Mirror tasks to Apple Reminders", isOn: Binding(
                get: { reminders.syncEnabled },
                set: { enabling in
                    guard enabling else {
                        reminders.syncEnabled = false
                        return
                    }
                    Task {
                        // On first enable, never at launch. Reminders is a separate
                        // EventKit grant from Calendars — granting one says nothing
                        // about the other.
                        let granted = await reminders.requestAccess()
                        // Never leave a toggle on that can't do anything.
                        reminders.syncEnabled = granted
                        if granted { await model.syncReminders() }
                    }
                }
            ))
            .disabled(remindersDenied)

            if reminders.syncEnabled, !reminders.availableLists.isEmpty {
                Picker("Target list", selection: Binding(
                    get: { reminders.targetListIdentifier ?? reminders.targetList?.id ?? "" },
                    set: { reminders.targetListIdentifier = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(reminders.availableLists) { list in
                        Text(list.title).tag(list.id)
                    }
                }
            }
        } header: {
            Text("Apple Reminders")
        } footer: {
            Text(remindersDenied
                 ? "Reminders access disabled. Grant access in iOS Settings › Privacy & Security › Reminders › Bounce."
                 : "Bounce never adds tasks to Reminders on its own. Review the action items in the Tasks tab and tap Send on the ones you want — those, and only those, are added here, with their due date when one was mentioned. Completing a task in either app updates the status in both.")
        }
    }

    private var remindersDenied: Bool {
        let status = reminders.authorizationStatus
        return status == .denied || status == .restricted || status == .writeOnly
    }

    // MARK: - Automatic Delivery

    private var autoDeliverySection: some View {
        Section {
            Toggle("Send automatically after processing", isOn: Binding(
                get: { settings.autoDeliver },
                set: { settings.autoDeliver = $0 }
            ))
            .disabled(settings.activeDestinations.isEmpty)

            Picker("Included payload", selection: Binding(
                get: { settings.payloadContent },
                set: { settings.payloadContent = $0 }
            )) {
                ForEach(PayloadContent.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Automatic delivery")
        } footer: {
            Text(settings.activeDestinations.isEmpty
                 ? "Enable a folder or webhook destination below to activate automatic delivery."
                 : "Automatically forwards completed transcripts and files to configured destinations.")
        }
    }

    // MARK: - Recording Webhook

    private var webhookSection: some View {
        Section {
            Toggle("Enable transcript webhook", isOn: Binding(
                get: { settings.webhookEnabled },
                set: { settings.webhookEnabled = $0 }
            ))
            if settings.webhookEnabled {
                WebhookURLField(
                    placeholder: "https://example.com/webhook",
                    currentValue: settings.webhookURLString,
                    commit: { settings.webhookURLString = $0 })

                SecureField("Shared secret (optional)", text: Binding(
                    get: { settings.webhookSecret },
                    set: { settings.webhookSecret = $0 }
                ))
                if settings.webhookSecretPersistFailed {
                    Label("Couldn't save the secret securely — it will be lost on next launch. Try again.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Recording Webhook")
        } footer: {
            if settings.webhookEnabled {
                Text("Sends HTTP POST payload containing transcript text, metadata JSON, and audio file. Secret sent as `X-Bounce-Secret` header.")
            }
        }
    }

    // MARK: - Task Webhook

    private var taskWebhookSection: some View {
        Section {
            Toggle("Enable task webhook", isOn: Binding(
                get: { destinations.webhookEnabled },
                set: { destinations.webhookEnabled = $0 }
            ))
            if destinations.webhookEnabled {
                WebhookURLField(
                    placeholder: "https://example.com/tasks",
                    currentValue: destinations.webhookURLString,
                    commit: { destinations.webhookURLString = $0 })

                SecureField("Shared secret (optional)", text: Binding(
                    get: { destinations.webhookSecret },
                    set: { destinations.webhookSecret = $0 }
                ))
                if destinations.webhookSecretPersistFailed {
                    Label("Couldn't save the secret securely — it will be lost on next launch. Try again.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Task Webhook")
        } footer: {
            if destinations.webhookEnabled {
                Text("Sends the action items you send from the Tasks tab to external task services like Todoist, Linear, Notion, or custom endpoints as individual JSON objects — nothing is sent automatically. Full transcript audio is not sent.")
            }
        }
    }

    // MARK: - Folder Export

    private var folderSection: some View {
        Section {
            if let name = settings.folderName {
                HStack {
                    Label(name, systemImage: "folder.fill")
                    Spacer()
                    Button("Change") { isPickingFolder = true }
                        .buttonStyle(.borderless)
                }
                Button("Disconnect folder", role: .destructive) {
                    settings.clearFolder()
                }
            } else {
                Button("Choose target folder…", systemImage: "folder.badge.plus") {
                    isPickingFolder = true
                }
            }
        } header: {
            Text("Files & iCloud Drive sync")
        } footer: {
            Text("Saves Markdown transcripts, notes, and audio files directly to a designated folder in Files or iCloud Drive (e.g. for Obsidian or Logseq vaults).")
        }
    }

    // MARK: - Shortcuts Automation

    private var automationSection: some View {
        Section {
            Label("Shortcuts App Support", systemImage: "app.connected.to.app.below.fill")
            Toggle("Allow transcript access", isOn: Binding(
                get: { settings.shortcutsDataAccessEnabled },
                set: { settings.shortcutsDataAccessEnabled = $0 }
            ))
        } header: {
            Text("Apple Shortcuts")
        } footer: {
            Text("Exposes Shortcuts actions including Get Latest Transcript, Transcribe Recording, Send Recording, and Sync Recorder for custom automation workflows. A personal automation can run these with your phone locked and no confirmation. Turn off \"Allow transcript access\" to keep Sync Recorder working (it moves no data) while blocking the actions that return or send transcript content.")
        }
    }
}

/// A webhook URL field that doesn't commit on every keystroke.
///
/// This field is "the single most dangerous patchable field" in the app — a
/// change silently redirects every future recording/task delivery to wherever
/// it now points, with no other signal to the user that it happened. Editing
/// a `Binding` straight into `DeliverySettings`/`TaskDestinations` (the
/// previous shape here) commits each keystroke immediately, so a bumped key or
/// a paste-then-undo could already have repointed delivery before the user
/// finished. This buffers edits in local `draft` state and only writes through
/// `commit` after the user finishes (submit or tapping away) *and* confirms —
/// mirroring the one-time warning a destructive action gets elsewhere in the app.
private struct WebhookURLField: View {
    let placeholder: String
    let currentValue: String
    let commit: (String) -> Void

    @State private var draft: String = ""
    @State private var pendingConfirmation = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $draft)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isFocused)
                .onSubmit { requestCommitIfChanged() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { requestCommitIfChanged() }
                }

            // `http`, not `https` — every transcript this endpoint receives
            // travels in cleartext, readable by anything on the same network.
            if let scheme = URL(string: draft)?.scheme?.lowercased(), scheme == "http" {
                Label("Sent unencrypted — this endpoint doesn't use HTTPS.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { draft = currentValue }
        // Resync if the persisted value changes out from under this view —
        // e.g. a paired browser PATCHing `/api/settings` while this screen is
        // open. Only while not focused: overwriting what the user is
        // mid-typing would be its own bug, and `requestCommitIfChanged`
        // already compares against the *current* `currentValue` on submit, so
        // skipping the resync while focused doesn't reintroduce the
        // stale-revert this guards against.
        .onChange(of: currentValue) { _, newValue in
            if !isFocused { draft = newValue }
        }
        .alert("Change delivery destination?", isPresented: $pendingConfirmation) {
            Button("Cancel", role: .cancel) { draft = currentValue }
            Button("Confirm") { commit(draft) }
        } message: {
            if let host = URL(string: draft)?.host, !host.isEmpty {
                Text("Recordings will now be sent to \(host) automatically.")
            } else {
                Text("This changes where recordings are sent automatically.")
            }
        }
    }

    private func requestCommitIfChanged() {
        guard draft != currentValue else { return }
        // Clearing the field only disables delivery — nothing new starts
        // receiving data, so that direction needs no confirmation.
        if draft.trimmingCharacters(in: .whitespaces).isEmpty {
            commit(draft)
            return
        }
        pendingConfirmation = true
    }
}
