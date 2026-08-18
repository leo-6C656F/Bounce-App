import Combine
import Foundation
import Observation

/// The bridge between the Combine-based SDK managers and SwiftUI.
///
/// The managers are ported straight from Plaud's reference app and kept
/// deliberately untouched — they encode a lot of BLE edge-case handling. Rather
/// than rewrite them as `@Observable`, this type subscribes to their publishers
/// and republishes plain observable properties. One clean seam, no risk to the
/// proven logic underneath.
@MainActor
@Observable
final class AppModel {

    // MARK: - Observable state

    var connectionState: DeviceConnectionState = .disconnected
    var device: PlaudDevice?
    var scannedDevices: [ScannedDevice] = []
    var recordings: [Recording] = []
    var syncState: SyncState = .idle
    var recordingState: RecordingState = .idle
    /// Live 0–1 level for the record screen's waveform.
    var micLevel: Float = 0

    /// Whether the full-screen recording view is presented. Lifted out of the
    /// Home view so the in-app recording accessory can reopen it from any tab.
    var isRecorderPresented = false

    /// Transient banner text, e.g. a delivery failure.
    var alert: AlertMessage?

    /// Tracks whether a low-battery notification is owed for the current reading.
    ///
    /// Not `@Observable` state anyone reads — it's here rather than in
    /// `DeviceManager` because the decision needs the *settings* as well as the
    /// device, and `Device/` deliberately knows nothing about them. Seeded from
    /// persistence so a relaunch doesn't re-notify; see `BatteryAlertLatch`.
    private var batteryLatch = BatteryAlertLatch(
        threshold: DeliverySettings.lowBatteryThresholdValue,
        isLatched: DeliverySettings.lowBatteryLatchedValue)

    /// Whether we can actually scan. The SDK's `startScan()` is silent when
    /// Bluetooth is denied or off, so this is surfaced rather than leaving a
    /// spinner running forever.
    var bluetoothStatus: BluetoothStatus = .ready

    // MARK: - Idle WiFi sync

    var idleSyncEnabled = false
    var idleSyncNetworks: [IdleSyncManager.Network] = []
    var idleSyncTestResults: [UInt32: IdleSyncManager.TestResult] = [:]

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // MARK: - Derived

    var pairedDevices: [PairedDeviceInfo] { RecordingStore.shared.pairedDevices }
    var hasPairedDevice: Bool { RecordingStore.shared.hasPairedDevice }
    var hasCredentials: Bool { TokenProvider.shared.hasCredentials }

    var isRecording: Bool { recordingState.isActive }

    /// Needs a capable recorder, a live connection, *and* a build signed for
    /// the WiFi entitlements. Views hide the option entirely when false.
    var canUseWiFiTransfer: Bool {
        AppCapabilities.wifiFastTransfer && device?.supportWiFi == true && connectionState.isConnected
    }

    var untranscribedCount: Int {
        recordings.filter { $0.isSynced && !$0.isTranscribed }.count
    }

    // MARK: - Wiring

    private var cancellables = Set<AnyCancellable>()
    private let deviceManager = DeviceManager.shared
    private let syncManager = SyncManager.shared
    private let recordingManager = RecordingManager.shared
    private let idleSyncManager = IdleSyncManager.shared

    init() {
        recordings = RecordingStore.shared.recordings
        subscribe()

        BluetoothMonitor.shared.start { [weak self] status in
            self?.bluetoothStatus = status
        }
    }

    private func subscribe() {
        deviceManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleConnectionStateChange($0)
                // Four publishers feed the watch's one snapshot: connection,
                // device (battery), sync and recording state. `publish()` drops
                // an unchanged payload, so calling it from all four is cheap and
                // means no state change can be the one that never reaches the
                // wrist.
                WatchBridge.shared.publish()
            }
            .store(in: &cancellables)

        deviceManager.devicePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.device = $0
                self?.checkBattery()
                WatchBridge.shared.publish()
            }
            .store(in: &cancellables)

        deviceManager.scannedDevicesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.scannedDevices = $0 }
            .store(in: &cancellables)

        syncManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.syncState = $0
                WatchBridge.shared.publish()
            }
            .store(in: &cancellables)

        syncManager.recordingsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recordings = $0 }
            .store(in: &cancellables)

        // A recording just landed on the phone: transcribe it, and let the
        // coordinator hand off to delivery when it's done.
        syncManager.didSyncPublisher
            .receive(on: DispatchQueue.main)
            .sink { recordingId in
                // Apply the live preview first so the recording is never blank
                // while the batch pass runs. It won't overwrite a real transcript.
                if let recording = RecordingStore.shared.recording(id: recordingId) {
                    let appliedTranscript = LiveTranscriptStore.shared.applyIfAvailable(
                        to: recordingId,
                        sessionId: recording.sessionId
                    )
                    let appliedHighlights = HighlightStore.shared.applyIfAvailable(
                        to: recordingId,
                        sessionId: recording.sessionId
                    )
                    // Voices named from the desktop view while it was recording.
                    let appliedNames = LiveSpeakerNameStore.shared.applyIfAvailable(
                        to: recordingId,
                        sessionId: recording.sessionId
                    )
                    // Where it was recorded, if a fix was parked while it ran.
                    let appliedPlace = PlaceStore.shared.applyIfAvailable(
                        to: recordingId,
                        sessionId: recording.sessionId
                    )
                    if appliedTranscript || appliedHighlights || appliedNames || appliedPlace {
                        SyncManager.shared.refreshLibrary()
                    }
                    // Nothing parked — the phone wasn't in range while it recorded.
                    // Take a fix now, but only for a recording that just happened,
                    // and label it as the approximation it is. No-ops when a place
                    // was applied above.
                    PlaceStore.shared.captureAtSyncIfUseful(
                        recordingId: recordingId,
                        sessionId: recording.sessionId
                    )
                }

                guard DeliverySettings.shared.transcribeOnSync else { return }
                TranscriptionCoordinator.shared.enqueue(recordingId: recordingId)
            }
            .store(in: &cancellables)

        recordingManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.recordingState = state
                // Keep the highlight badge in step with the session (0 when idle).
                self.currentHighlightCount = state.currentSessionId
                    .map { HighlightStore.shared.count(forSessionId: $0) } ?? 0
                // Mirror into the Lock Screen / Dynamic Island Live Activity.
                RecordingLiveActivityController.shared.sync(
                    state, deviceName: self.device?.name ?? "Recorder")
                WatchBridge.shared.publish()
            }
            .store(in: &cancellables)

        recordingManager.levelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.micLevel = $0 }
            .store(in: &cancellables)

        idleSyncManager.enabledPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.idleSyncEnabled = $0 }
            .store(in: &cancellables)

        idleSyncManager.networksPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.idleSyncNetworks = $0 }
            .store(in: &cancellables)

        idleSyncManager.testResultsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.idleSyncTestResults = $0 }
            .store(in: &cancellables)
    }

    private func handleConnectionStateChange(_ state: DeviceConnectionState) {
        let wasConnected = connectionState.isConnected
        connectionState = state

        // On a fresh connection, quietly check whether the recorder is holding
        // anything we don't have yet.
        if state.isConnected, !wasConnected {
            syncManager.fetchFileList()
            // The device snapshot usually arrives before the state flips, so the
            // reading that came in while disconnected was discarded. Re-check.
            checkBattery()
        }
    }

    // MARK: - Low battery

    /// Feed the current reading to the latch and notify if an episode has begun.
    ///
    /// Called on every device snapshot rather than on a timer — the SDK pushes
    /// these, so there is nothing to poll.
    ///
    /// The latch's "fire on the first in-range reading" rule is only safe because
    /// `isLatched` survives relaunch; see `BatteryAlertLatch`. That's why the flag
    /// is read back out and persisted here on every call. Drop this and the app
    /// notifies on every cold launch while the recorder is low.
    private func checkBattery() {
        guard DeliverySettings.shared.lowBatteryAlerts else { return }

        batteryLatch.threshold = DeliverySettings.shared.lowBatteryThreshold
        let fired = batteryLatch.shouldNotify(
            level: device?.batteryLevel,
            isCharging: device?.isCharging ?? false,
            isConnected: connectionState.isConnected)
        DeliverySettings.shared.lowBatteryLatched = batteryLatch.isLatched

        guard fired, let device else { return }
        NotificationCenterBridge.shared.postLowBattery(
            deviceName: device.name.isEmpty ? "Your recorder" : device.name,
            level: device.batteryLevel)
    }

    /// Forget the current low episode. For when the *recorder* changes — unpair or
    /// switch device — not for a disconnect, which the latch handles itself.
    func resetBatteryAlert() {
        batteryLatch.reset()
        DeliverySettings.shared.lowBatteryLatched = false
    }

    // MARK: - Lifecycle

    /// Bring the SDK up with a valid token. Safe to call more than once.
    @discardableResult
    func configureSDK() async -> Bool {
        let provider = TokenProvider.shared
        guard provider.hasCredentials else { return false }
        guard let token = try? await provider.validToken() else { return false }

        deviceManager.configure(
            userId: provider.userId,
            accessToken: token,
            region: provider.region
        )
        return true
    }

    func handleForeground() {
        // Before anything network-bound: a recording that was in progress while
        // the app was away may have had its byte stream cut, and the transcript
        // is frozen until it's re-opened. No-ops if bytes are still arriving, and
        // skipped while paused — there's nothing to stream.
        if case .recording = recordingState {
            LiveTranscriber.shared.resumeStreamingIfStalled()
        }
        Task {
            // Top the token up before touching the recorder, so a day-old
            // launch doesn't fail its first request.
            await TokenProvider.shared.refreshIfNeeded()
            if !DeviceManager.shared.isConfigured {
                await configureSDK()
            }
            deviceManager.rescanIfNeeded()
            // On foreground rather than a timer: this is where a task ticked off in
            // Reminders while Bounce was closed gets noticed, and where a pushed
            // task's date change is reconciled. No-ops when the setting is off or
            // permission was never granted, and — crucially — never *creates*
            // anything for a task the user hasn't explicitly pushed.
            await deliverPushedTasks()
        }
    }

    // MARK: - Pairing

    func beginPairing() {
        Task {
            guard await configureSDK() else {
                alert = AlertMessage(
                    title: "Couldn't sign in to Plaud",
                    message: TokenProvider.shared.lastError
                        ?? "Check your credentials in Settings and try again."
                )
                return
            }
            deviceManager.suppressAutoReconnect = true
            deviceManager.startScan()
        }
    }

    func endPairing() {
        deviceManager.suppressAutoReconnect = false
        deviceManager.stopScan()
    }

    func connect(to scanned: ScannedDevice) {
        deviceManager.connect(scanned)
    }

    func switchDevice(sn: String) {
        deviceManager.switchDevice(sn: sn)
    }

    func unpair() {
        deviceManager.unpair()
    }

    // MARK: - Idle WiFi sync

    func refreshIdleSync() { idleSyncManager.refresh() }
    func setIdleSyncEnabled(_ enabled: Bool) { idleSyncManager.setEnabled(enabled) }
    func saveIdleSyncNetwork(index: UInt32, ssid: String, password: String) {
        idleSyncManager.saveNetwork(index: index, ssid: ssid, password: password)
    }
    func deleteIdleSyncNetworks(indices: [UInt32]) { idleSyncManager.deleteNetworks(indices: indices) }
    func testIdleSyncNetwork(index: UInt32) { idleSyncManager.test(index: index) }
    func nextFreeIdleSyncIndex() -> UInt32 { idleSyncManager.nextFreeIndex() }

    // MARK: - Recording

    func toggleRecording() {
        switch recordingState {
        case .idle: deviceManager.startRecord()
        case .recording: deviceManager.stopRecord()
        case .paused: deviceManager.resumeRecord()
        }
    }

    func pauseRecording() { deviceManager.pauseRecord() }
    func resumeRecording() { deviceManager.resumeRecord() }
    func stopRecording() { deviceManager.stopRecord() }

    /// Highlights flagged so far in the current session. Stored (not computed)
    /// so the record screen's badge updates the instant one is added — a plain
    /// read of `HighlightStore` wouldn't trigger an observation.
    private(set) var currentHighlightCount = 0

    /// Flag the current moment. A local marker (seconds from the recording's
    /// start), parked by session id and attached to the recording once it syncs —
    /// the recorder isn't told, this is purely app-side.
    func addHighlight() {
        guard case .recording(let sessionId, let startedAt) = recordingState else { return }
        HighlightStore.shared.add(Date().timeIntervalSince(startedAt), forSessionId: sessionId)
        currentHighlightCount = HighlightStore.shared.count(forSessionId: sessionId)
        // No publisher fires for this — it is entirely app-side — so the watch's
        // count would sit one behind every mark without this.
        WatchBridge.shared.publish()
    }

    // MARK: - Sync

    func sync() { syncManager.startSync() }
    func stopSync() { syncManager.stopSync() }
    func startWiFiTransfer() { syncManager.startWiFiTransfer() }
    func stopWiFiTransfer() { syncManager.stopWiFiTransfer() }

    // MARK: - Library

    func delete(_ recording: Recording) {
        syncManager.delete(recording)
        TranscriptionCoordinator.shared.clearStatus(for: recording.id)
    }

    func rename(_ recording: Recording, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        RecordingStore.shared.update(id: recording.id) {
            if trimmed.isEmpty {
                // Clearing the title hands it back to the app — an empty title is
                // "untitled", which `AutoOrganizer` and a link are free to fill.
                $0.title = Recording.untitled
                $0.titleSource = nil
            } else {
                $0.title = trimmed
                // The user typed this by hand, so nothing automatic overwrites it —
                // not a re-transcribe, and not a manual meeting link. The Meeting
                // card's "Use meeting name" is the one-tap escape when they do want
                // the meeting's name.
                $0.titleSource = .user
            }
        }
        syncManager.refreshLibrary()
    }

    /// Set or clear where a recording was made.
    ///
    /// Writes straight through rather than going via `PlaceStore.write`, which
    /// enforces source precedence: this is the user editing their own data, and
    /// they are allowed to clear a pin or move a good one to a worse spot. Every
    /// place set here is `.manual`, which outranks the automatic sources, so
    /// nothing later overwrites it.
    func setPlace(_ place: RecordingPlace?, on recording: Recording) {
        RecordingStore.shared.update(id: recording.id) { $0.place = place }
        syncManager.refreshLibrary()
    }

    // MARK: - Calendar meeting link

    /// Link a recording to a calendar meeting the user picked by hand.
    ///
    /// Marks the link user-confirmed (`Recording.calendarLinkConfirmed`) so
    /// `AutoOrganizer` never re-guesses it on a re-transcribe, then mirrors the
    /// automatic path: it records the event's title and attendees, names an
    /// untitled recording after the meeting (part-numbered against the library),
    /// joins a recurring meeting's series, and adopts the event's location when
    /// geotagging is on and nothing better is already stored.
    func linkCalendarEvent(_ event: CandidateEvent, on recording: Recording) {
        let eventTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)

        // A recurring meeting is a series; group this session with the rest.
        // Resolved before the write because creating the series is its own write.
        var seriesId = recording.seriesId
        if let key = event.seriesKey, !eventTitle.isEmpty,
           let series = MeetingSeriesStore.shared.ensureSeries(calendarKey: key, name: eventTitle) {
            seriesId = series.id
        }

        let existingTitles = RecordingStore.shared.recordings
            .filter { $0.id != recording.id }
            .map(\.title)

        RecordingStore.shared.update(id: recording.id) { rec in
            rec.calendarLinkConfirmed = true
            rec.calendarEventTitle = eventTitle.isEmpty ? nil : eventTitle
            rec.calendarAttendees = event.attendees.isEmpty ? nil : event.attendees
            // A changed series invalidates the "since last time" recap — it was
            // written against a different history. Same rule as
            // `MeetingSeriesStore.assign`.
            if rec.seriesId != seriesId {
                rec.seriesId = seriesId
                rec.seriesRecap = nil
            }
            // Adopt the meeting's name on this manual link — unless the user typed
            // the current title themselves. This is the user *asking* to link, so
            // an app-chosen title (`.auto`) or an untitled recording takes the
            // meeting's name; only a hand-typed title (`.user`) is preserved. A
            // legacy `nil` source is treated as the user's, so an old AI title is
            // kept rather than silently overwritten — the Meeting card's "Use
            // meeting name" gives one-tap adoption when that's what they want.
            let isUntitled = RecordingTitleSelection.isUntitled(rec.title, placeholder: Recording.untitled)
            if !eventTitle.isEmpty, isUntitled || rec.titleSource == .auto {
                rec.title = RecordingTitleSelection.numbered(eventTitle, existingTitles: existingTitles)
                rec.titleSource = .auto
            }
            if DeliverySettings.shared.geotagRecordings, let place = event.place,
               rec.place?.shouldBeReplaced(by: place) ?? true {
                rec.place = place
            }
        }
        syncManager.refreshLibrary()
    }

    /// Clear a recording's calendar meeting link and remember the user did so,
    /// so `AutoOrganizer` doesn't re-link it on the next pass.
    ///
    /// The recording keeps its title (there's no former title to restore) and
    /// its series (managed separately, from the Meeting-series screen). Only the
    /// meeting association itself is removed.
    func unlinkCalendarEvent(from recording: Recording) {
        RecordingStore.shared.update(id: recording.id) { rec in
            rec.calendarLinkConfirmed = true
            rec.calendarEventTitle = nil
            rec.calendarAttendees = nil
        }
        syncManager.refreshLibrary()
    }

    /// Rename a recording to its linked meeting's name on demand.
    ///
    /// The explicit escape hatch behind `linkCalendarEvent`'s title rule: linking
    /// won't overwrite a title the user typed, so this gives them a one-tap way to
    /// take the meeting's name anyway — from the Meeting card — without having to
    /// clear their title first. A no-op when there's no linked meeting to borrow a
    /// name from. Sets the source back to `.auto`, since the title is once again the
    /// app's (the meeting's), which keeps it adoptable by a later re-link.
    func adoptMeetingTitle(for recording: Recording) {
        guard let eventTitle = recording.calendarEventTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines), !eventTitle.isEmpty
        else { return }
        let existingTitles = RecordingStore.shared.recordings
            .filter { $0.id != recording.id }
            .map(\.title)
        RecordingStore.shared.update(id: recording.id) { rec in
            rec.title = RecordingTitleSelection.numbered(eventTitle, existingTitles: existingTitles)
            rec.titleSource = .auto
        }
        syncManager.refreshLibrary()
    }

    // MARK: - Speaker suggestions

    /// Names to offer for a recording's speakers, or nil when there's no clean
    /// precedent.
    ///
    /// **This is not voice recognition and must never be presented as such.**
    /// Diarization labels are anonymous and per recording — label "1" is not the
    /// same person twice, and the engine has no enrollment API. All this does is
    /// notice that the previous recording *in the same category* had the same number
    /// of speakers and every one of them named, and offer those names in order. The
    /// caller holds the result as unconfirmed until the user accepts it.
    ///
    /// Restricted to the same category because that's the closest thing to "the same
    /// meeting again" available without voice data — a weekly standup follows a
    /// weekly standup. Across categories the ordering carries no information.
    func suggestedSpeakerNames(for recording: Recording) -> [String: String]? {
        guard let labels = recording.transcript?.speakers, !labels.isEmpty else { return nil }
        guard let category = recording.categoryName else { return nil }

        // `recordings` is newest-first, so the first match is the most recent.
        let previous = recordings.first { candidate in
            candidate.id != recording.id
                && candidate.createdAt < recording.createdAt
                && candidate.categoryName == category
                && candidate.speakerNames?.isEmpty == false
        }
        guard let previous, let previousLabels = previous.transcript?.speakers else { return nil }

        return SpeakerSuggestions.autoFill(
            speakerLabels: labels,
            previous: previous.speakerNames,
            previousLabelCount: previousLabels.count)
    }

    // MARK: - Action items

    /// Every action item across the library, newest recording first, paired with the
    /// recording it came from.
    ///
    /// Computed rather than stored: the items live on their recordings, and a second
    /// aggregated copy would be one more thing to keep in step.
    var allActionItems: [(recording: Recording, item: ActionItem)] {
        recordings.flatMap { recording in
            (recording.actionItems ?? []).map { (recording, $0) }
        }
    }

    var openActionItems: [(recording: Recording, item: ActionItem)] {
        allActionItems.filter { !$0.item.isDone }
    }

    /// Mirror action items into Apple Reminders, and read back what was ticked off
    /// there.
    ///
    /// One-way push with completion read-back, not two-way sync: Bounce creates the
    /// reminder, and ticking it in *either* app syncs. Edited text and deleted
    /// reminders resolve in Bounce's favour. Full bidirectional sync needs conflict
    /// resolution and deletion detection and tends to corrupt both sides, but
    /// "I ticked it in Reminders and Bounce didn't notice" is the failure that would
    /// annoy daily, so that one direction is worth having.
    ///
    /// Idempotent — a repeated call with nothing changed does nothing — which is
    /// what makes it safe to run on every foreground.
    /// Returns the outcome so the explicit-send path can surface it. The
    /// Bounce-side edits (link/complete/unlink) are still applied here; only the
    /// *reporting* is left to the caller, and only `pushActionItems` reports —
    /// the foreground pass discards the return and stays silent.
    @discardableResult
    func syncReminders() async -> ReminderSyncOutcome {
        let outcome = await RemindersSync.shared.sync(items: allActionItems.map(\.item))
        guard !outcome.isEmpty else { return outcome }

        let completed = Set(outcome.completed)
        let unlinked = Set(outcome.unlinked)
        // One pass over the whole library, saved once — not N whole-library
        // serializations. The closure guards itself, the way the old
        // `for recording in recordings where …` loop did.
        RecordingStore.shared.batchUpdate { rec in
            guard var items = rec.actionItems, !items.isEmpty else { return }
            for index in items.indices {
                let id = items[index].id
                if let reminderId = outcome.linked[id] { items[index].reminderId = reminderId }
                if completed.contains(id) { items[index].isDone = true }
                // Dropped rather than recreated: recreating fights a user who
                // deleted the reminder on purpose.
                if unlinked.contains(id) { items[index].reminderId = nil }
            }
            rec.actionItems = items
        }
        syncManager.refreshLibrary()
        return outcome
    }

    /// POST each new task to the task webhook, once.
    ///
    /// Separate from `DeliveryService`'s recording webhook and deliberately so: that
    /// one is multipart and carries audio, this one is small JSON per task and
    /// **never includes the transcript**, so a per-task hook can't become a bulk
    /// transcript exfiltration path.
    ///
    /// Fire-once is tracked by id in UserDefaults rather than on `ActionItem`,
    /// because that type lives in `library.json` and every field added to it is a
    /// decode-compat change. A failed POST simply isn't marked sent, so it retries
    /// on the next pass — the failure mode is a late delivery, not a lost one.
    func sendTaskWebhooks() async {
        guard TaskDestinations.isWebhookEnabled, TaskDestinations.webhookURL != nil else { return }
        let alreadySent = TaskWebhook.sentTaskIds()
        var delivered: [String] = []

        for (recording, item) in openActionItems {
            guard TaskWebhook.unsent([item], alreadySent: alreadySent).isEmpty == false else { continue }
            do {
                try await TaskWebhook.send(item, in: recording)
                delivered.append(item.id)
            } catch {
                // Logged, not surfaced: a task webhook failing is not something to
                // interrupt the user for, and it will be retried. The URL and any
                // secret are never interpolated into the message.
                TranscribeLog.log("task webhook failed for one item: \(error.localizedDescription)")
            }
        }
        TaskWebhook.markSent(delivered)
    }

    /// Put tasks that have a resolved deadline on the calendar.
    ///
    /// Only dated tasks: an undated one has no place on a calendar and belongs in
    /// Reminders. This is the one feature that makes Bounce *write* to the user's
    /// calendar — `CalendarMatcher`, which names recordings, remains strictly
    /// read-only, and the two are deliberately separate types so that stays true.
    func syncTaskCalendar() async {
        let tasks = allActionItems.map {
            CalendarTask(item: $0.item, recordingTitle: $0.recording.displayTitle)
        }
        let outcome = await TaskCalendarWriter.shared.sync(tasks: tasks)
        guard !outcome.linked.isEmpty || !outcome.unlinked.isEmpty else { return }

        let unlinked = Set(outcome.unlinked)
        // One pass, saved once — see `syncReminders`.
        RecordingStore.shared.batchUpdate { rec in
            guard var items = rec.actionItems, !items.isEmpty else { return }
            for index in items.indices {
                let id = items[index].id
                if let eventId = outcome.linked[id] { items[index].calendarEventId = eventId }
                // Dropped rather than recreated — an event the user deleted in
                // Calendar should stay deleted.
                if unlinked.contains(id) { items[index].calendarEventId = nil }
            }
            rec.actionItems = items
        }
        syncManager.refreshLibrary()
    }

    /// Progress of a retroactive task scan, as (done, total). Nil when not running.
    private(set) var actionItemScan: (done: Int, total: Int)?

    /// How many transcribed recordings have never been scanned for tasks.
    var recordingsNeedingActionItemScan: Int {
        AutoOrganizer.recordingsNeedingActionItemScan().count
    }

    /// Scan older recordings for tasks.
    ///
    /// Explicitly user-initiated rather than automatic on launch: on a library of
    /// a hundred meetings this is a hundred on-device model passes, which is not
    /// something to start behind someone's back while they're trying to use the app.
    func scanForActionItems() {
        guard actionItemScan == nil else { return }
        actionItemScan = (0, recordingsNeedingActionItemScan)
        Task {
            await AutoOrganizer.shared.scanForActionItems { done, total in
                self.actionItemScan = (done, total)
            }
            actionItemScan = nil
        }
    }

    func setActionItem(_ item: ActionItem, in recording: Recording, done: Bool) {
        RecordingStore.shared.update(id: recording.id) { rec in
            guard let index = rec.actionItems?.firstIndex(where: { $0.id == item.id }) else { return }
            rec.actionItems?[index].isDone = done
        }
        syncManager.refreshLibrary()
    }

    func deleteActionItem(_ item: ActionItem, in recording: Recording) {
        RecordingStore.shared.update(id: recording.id) { rec in
            rec.actionItems?.removeAll { $0.id == item.id }
            // Normalise back to nil so "no items" has one representation.
            if rec.actionItems?.isEmpty == true { rec.actionItems = nil }
        }
        syncManager.refreshLibrary()
    }

    /// Add an item by hand.
    ///
    /// The board request asks for this explicitly, and it's the fallback that keeps
    /// the tab useful on hardware with no Apple Intelligence, where extraction
    /// silently does nothing.
    func addActionItem(_ text: String, to recording: Recording) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        RecordingStore.shared.update(id: recording.id) { rec in
            var list = rec.actionItems ?? []
            list.append(ActionItem(text: trimmed))
            rec.actionItems = list
        }
        syncManager.refreshLibrary()
    }

    // MARK: - Pushing tasks to destinations

    /// Whether at least one task destination is switched on.
    ///
    /// Reads the **live** enable flag each destination actually gates its writes
    /// on, not `TaskDestinations.enabled`: the calendar writer owns its own flag
    /// (`TaskCalendarWriter.writeEnabled`) and `TaskDestinations.calendarEnabled`
    /// is a disconnected legacy key nothing in the delivery path reads, so trusting
    /// it would report the calendar as off even when the user has turned it on. The
    /// Tasks UI uses this to nudge the user to Settings before a send that would
    /// reach nowhere.
    var hasEnabledTaskDestination: Bool {
        RemindersSync.shared.syncEnabled
            || TaskCalendarWriter.shared.writeEnabled
            || TaskDestinations.shared.webhookEnabled
    }

    /// The explicit "send" that replaces the old auto-add.
    ///
    /// Extraction only ever *proposes* action items into the Tasks tab; nothing is
    /// written to Apple Reminders, Calendar, or a webhook until the user pushes it
    /// here. Pushing sets `pushRequested` on each item — the gate every
    /// reconciliation planner and the task webhook honour — and then runs the same
    /// delivery pass `handleForeground` uses, so approved tasks flow to whatever
    /// destinations are currently enabled (and to any enabled later).
    ///
    /// Idempotent: pushing an already-pushed task just re-runs a delivery pass that
    /// finds nothing new to do.
    func pushActionItems(_ items: [ActionItem], in recording: Recording) async {
        let ids = Set(items.map(\.id))
        guard !ids.isEmpty else { return }
        RecordingStore.shared.update(id: recording.id) { rec in
            guard var list = rec.actionItems else { return }
            for index in list.indices where ids.contains(list[index].id) {
                list[index].pushRequested = true
            }
            rec.actionItems = list
        }
        syncManager.refreshLibrary()
        let reminders = await deliverPushedTasks()

        // Keep the "Sent" badge honest. When Reminders was the only destination and
        // a creation couldn't be written (a deleted list, a failed commit), un-push
        // the affected items so they don't show "Sent" for a reminder that never
        // landed — and so the user can send them again once they fix the list. With
        // another destination also enabled the shared `pushRequested` flag is left
        // set (the push may have reached Calendar or the webhook); see
        // `ReminderSendReport.idsToUnsend`.
        let remindersOnly = RemindersSync.shared.syncEnabled
            && !TaskCalendarWriter.shared.writeEnabled
            && !TaskDestinations.shared.webhookEnabled
        let toUnsend = Set(ReminderSendReport.idsToUnsend(
            failedToCreate: reminders.failedToCreate,
            remindersIsOnlyDestination: remindersOnly))
        if !toUnsend.isEmpty {
            for r in recordings where r.actionItems?.isEmpty == false {
                RecordingStore.shared.update(id: r.id) { rec in
                    guard var list = rec.actionItems else { return }
                    for index in list.indices where toUnsend.contains(list[index].id) {
                        list[index].pushRequested = false
                    }
                    rec.actionItems = list
                }
            }
            syncManager.refreshLibrary()
        }

        // Surface the result of the explicit send. Only Reminders is reported —
        // it is the destination the user tapped Send expecting to land in, and the
        // one that used to fail silently. Nil (nothing added, nothing failed) shows
        // nothing.
        taskSendResult = ReminderSendReport.message(
            added: reminders.linked.count,
            failed: reminders.failedToCreate.count)
    }

    /// The result of the most recent explicit Send, for the Tasks screen to show
    /// and then clear. Nil when there is nothing to report. Set **only** by
    /// `pushActionItems`, never by the silent foreground pass.
    var taskSendResult: ReminderSendReport.Message?

    /// Run every enabled task-destination reconciliation pass, returning the
    /// Reminders outcome so the explicit-send path can report it.
    ///
    /// Shared by `pushActionItems` and `handleForeground`. Each pass is a no-op
    /// when its destination is off or has nothing to do, and none of them create
    /// anything for a task the user hasn't pushed — so running this on every
    /// foreground reconciles completion and dates for already-pushed tasks without
    /// ever mirroring a candidate behind the user's back. `handleForeground`
    /// discards the return; only the explicit send surfaces it.
    @discardableResult
    func deliverPushedTasks() async -> ReminderSyncOutcome {
        let reminders = await syncReminders()
        await syncTaskCalendar()
        await sendTaskWebhooks()
        return reminders
    }

    /// Add or remove a tag on one recording.
    ///
    /// Tags are stored as `RecordingCategory.id`, never names — renaming a category
    /// therefore keeps every tagged recording attached, which is the whole reason
    /// this doesn't reuse `categoryName`'s approach.
    func toggleTag(_ tagId: String, on recording: Recording) {
        RecordingStore.shared.update(id: recording.id) {
            $0.tagIds = RecordingTags.toggling(tagId, in: $0.tagIds)
        }
        syncManager.refreshLibrary()
    }

    /// The categories a recording's tag ids currently resolve to, in the order the
    /// user applied them.
    ///
    /// Dangling ids are dropped rather than rendered: `CategoryStore.remove`
    /// sweeps them, so one surviving here means something went wrong, and showing a
    /// blank chip the user can't remove is the worse failure.
    func tags(for recording: Recording) -> [RecordingCategory] {
        (recording.tagIds ?? []).compactMap { id in
            CategoryStore.shared.categories.first { $0.id == id }
        }
    }

    /// Replace every occurrence of a misheard word in one recording's transcript.
    ///
    /// Returns how many occurrences changed, so the caller can say so.
    ///
    /// Three things worth knowing:
    ///
    /// - **`livePreview` is corrected too.** The detail view shows the archived
    ///   live draft in a disclosure, and leaving the old spelling visible there
    ///   reads as the correction having failed.
    /// - **`summaries` are deliberately left alone.** They were generated from the
    ///   old text; regenerating them is expensive and would silently discard
    ///   summaries the user may have read, and editing their prose by find-replace
    ///   would corrupt sentences the model wrote around the wrong word. The sheet
    ///   says so when summaries exist.
    /// - **Timings never move** — `TranscriptEdit` only rewrites segment text — so
    ///   tap-to-seek keeps working and no cache keyed on segment count is
    ///   invalidated.
    @discardableResult
    func correctWord(
        in recording: Recording,
        from needle: String,
        to replacement: String,
        caseSensitive: Bool = false,
        addToVocabulary: Bool = false
    ) -> Int {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, needle != replacement else { return 0 }

        var changed = 0
        var touchedAnything = false
        RecordingStore.shared.update(id: recording.id) { stored in
            if let transcript = stored.transcript {
                let result = TranscriptEdit.replacing(
                    needle, with: replacement, in: transcript, caseSensitive: caseSensitive)
                // Compared on the value, not on `count`. A non-zero count can still
                // leave the transcript identical — a case-only difference that the
                // capitalisation rule then undoes — and writing that would
                // republish the whole library for nothing.
                if result.transcript != transcript {
                    stored.transcript = result.transcript
                    touchedAnything = true
                }
                changed += result.count
            }
            if let preview = stored.livePreview {
                let result = TranscriptEdit.replacing(
                    needle, with: replacement, in: preview, caseSensitive: caseSensitive)
                if result.transcript != preview {
                    stored.livePreview = result.transcript
                    touchedAnything = true
                }
                // Not added to `changed`: the draft is a second copy of the same
                // speech, so counting it would report double what the user sees.
            }
        }
        // Only republish when something moved. The phone's sheet can't reach a
        // zero-change call (its Replace button requires a match) but
        // `WebAPI`'s /correct route can, and a no-op refresh there invalidates
        // every observing view for nothing.
        if touchedAnything { syncManager.refreshLibrary() }

        if addToVocabulary { addToSonioxVocabulary(replacement) }
        return changed
    }

    /// Teach the correction to Soniox so future recordings get it right.
    ///
    /// `DeliverySettings.sonioxVocabularyTerms` is already read by
    /// `Soniox.contextPayload()` on both the batch and live paths, so appending
    /// here is the whole integration — there is no second hook to wire.
    private func addToSonioxVocabulary(_ term: String) {
        let settings = DeliverySettings.shared
        let existing = settings.sonioxVocabularyRaw
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Case-insensitive, or correcting the same name twice with different
        // capitalisation grows the list with duplicates the user has to prune.
        guard !existing.contains(where: { $0.compare(term, options: .caseInsensitive) == .orderedSame })
        else { return }
        settings.sonioxVocabularyRaw = (existing + [term]).joined(separator: ", ")
    }

    /// Store display names for diarized speakers ("1" → "Leo"). Per recording:
    /// Soniox's speaker labels aren't stable across recordings, so there is no
    /// identity to attach a name to globally.
    func setSpeakerNames(_ recording: Recording, names: [String: String]) {
        let cleaned = names.compactMapValues { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        RecordingStore.shared.update(id: recording.id) {
            $0.speakerNames = cleaned.isEmpty ? nil : cleaned
        }
        syncManager.refreshLibrary()
    }

    /// Assign (or clear, with nil) the recording's category.
    ///
    /// `Recording.categoryName` stores the category's **name**, not its id —
    /// matching what `AutoOrganizer` writes — so the name is resolved through
    /// `CategoryStore` first and an unknown one is refused rather than stored
    /// as a dangling label.
    /// Returns false when `name` matches no category, so a caller that can
    /// report the failure — the desktop view — isn't left toasting "Saved" over
    /// a write that never happened.
    @discardableResult
    func setCategory(_ recording: Recording, name: String?) -> Bool {
        let resolved: String?
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let category = CategoryStore.shared.category(named: name) else { return false }
            resolved = category.name
        } else {
            resolved = nil
        }
        RecordingStore.shared.update(id: recording.id) { $0.categoryName = resolved }
        syncManager.refreshLibrary()
        return true
    }

    /// Whether a chapter pass could run on this recording right now.
    ///
    /// Read by the detail view to decide whether to offer "Find chapters" at all,
    /// rather than offering it and failing silently — every guard in
    /// `ChapterGenerator` exits without a message, which is right for the
    /// automatic pass and wrong for a button the user pressed.
    func canFindChapters(_ recording: Recording) -> Bool {
        guard ChapterGenerator.shared.isAvailable else { return false }
        guard let transcript = recording.transcript, !transcript.isLivePreview else { return false }
        return recording.duration >= ChapterGenerator.minimumDuration
    }

    /// Chapter pass, run by hand from the transcript tab.
    ///
    /// Exists because the automatic pass only runs at transcription time: a
    /// library transcribed before chapters existed would otherwise never get
    /// them, which is the same "new feature looks broken on an established
    /// library" problem `recordingsNeedingActionItemScan` solves for tasks.
    func findChapters(for recording: Recording) async {
        guard let transcript = recording.transcript else { return }
        await AutoOrganizer.shared.generateChapters(
            recordingId: recording.id,
            transcript: transcript,
            duration: recording.duration)
    }

    /// Run one summary template over a recording's transcript and store the
    /// result, replacing any previous run of the same template.
    ///
    /// Shared by the detail view's Summary tab and the desktop view, so both
    /// produce identical records; `SummaryTabView` additionally streams the
    /// partials for display, which is why it drives the generator itself rather
    /// than calling this.
    @discardableResult
    func generateSummary(for recordingId: String, template: SummaryTemplate) async -> Summary? {
        guard let recording = RecordingStore.shared.recording(id: recordingId),
              let transcript = recording.transcript?.plainText, !transcript.isEmpty
        else { return nil }

        let generator = SummaryGenerator()
        var text = ""
        for await partial in generator.generate(transcript: transcript, template: template) {
            text = partial
        }
        // A failed run yields its apology text into the stream so the Summary
        // tab can show it inline. Persisting that would store "Couldn't generate
        // this summary…" as a real summary and deliver it onward.
        guard generator.lastError == nil, !text.isEmpty else { return nil }

        let summary = Summary(
            templateId: template.id,
            templateName: template.name,
            text: text,
            createdAt: Date())
        RecordingStore.shared.update(id: recordingId) { rec in
            var list = rec.summaries ?? []
            list.removeAll { $0.templateId == template.id }
            list.append(summary)
            rec.summaries = list
        }
        syncManager.refreshLibrary()
        return summary
    }

    func transcribe(_ recording: Recording) {
        TranscriptionCoordinator.shared.enqueue(recordingId: recording.id)
    }

    /// Re-run transcription even though a transcript already exists — e.g. after
    /// switching the transcription engine in Settings.
    func retranscribe(_ recording: Recording) {
        TranscriptionCoordinator.shared.enqueue(recordingId: recording.id, force: true)
    }

    /// Transcribe everything synced but not yet transcribed.
    func transcribeAllPending() {
        for recording in recordings where recording.isSynced && !recording.isTranscribed {
            TranscriptionCoordinator.shared.enqueue(recordingId: recording.id)
        }
    }

    // MARK: - Delivery

    func send(_ recording: Recording, to destination: Destination) {
        Task {
            do {
                try await DeliveryService.shared.deliver(recording, to: destination)
            } catch {
                alert = AlertMessage(
                    title: "Couldn't send to \(destination.label)",
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    func sendToAll(_ recording: Recording) {
        Task {
            let outcomes = await DeliveryService.shared.deliverToAllDestinations(recording)
            let failures = outcomes.filter { !$0.succeeded }
            guard !failures.isEmpty else { return }
            let detail = failures
                .map { "\($0.destination.label): \(($0.error as? LocalizedError)?.errorDescription ?? "failed")" }
                .joined(separator: "\n")
            alert = AlertMessage(title: "Some destinations failed", message: detail)
        }
    }

    /// Fresh copy from the store, so detail views stay current after edits.
    func current(_ recording: Recording) -> Recording {
        RecordingStore.shared.recording(id: recording.id) ?? recording
    }
}
