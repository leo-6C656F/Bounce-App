import AppIntents
import Foundation

/// Shortcuts / Siri surface.
///
/// This is the real "send it wherever I want" unlock: rather than Bounce
/// integrating with every service directly, it exposes recordings and
/// transcripts to Shortcuts, which can then route them into anything with a
/// Shortcuts action — Slack, Notion, Obsidian, Drive, Mail, an SSH command.
/// A personal automation can run "when I get home, send today's recordings to X"
/// without a line of code here.

// MARK: - Entity

struct RecordingEntity: AppEntity, Identifiable {

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Recording" }
    static var defaultQuery = RecordingQuery()

    let id: String
    let title: String
    let recordedAt: Date
    let durationSeconds: Double
    let transcript: String?

    init(_ recording: Recording) {
        id = recording.id
        title = recording.displayTitle
        recordedAt = recording.createdAt
        durationSeconds = recording.duration
        transcript = recording.transcript?.plainText
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(recordedAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }
}

struct RecordingQuery: EntityQuery {

    @MainActor
    func entities(for identifiers: [String]) async throws -> [RecordingEntity] {
        identifiers.compactMap { RecordingStore.shared.recording(id: $0) }.map(RecordingEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [RecordingEntity] {
        RecordingStore.shared.recordings.prefix(10).map(RecordingEntity.init)
    }
}

// MARK: - Destination enum

enum DestinationAppEnum: String, AppEnum {
    case webhook
    case folder

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Destination" }

    static var caseDisplayRepresentations: [DestinationAppEnum: DisplayRepresentation] = [
        .webhook: "Webhook",
        .folder: "Folder",
    ]

    var destination: Destination {
        switch self {
        case .webhook: return .webhook
        case .folder: return .folder
        }
    }
}

// MARK: - Intents

/// "Get the latest Bounce transcript" — the workhorse for automations.
struct LatestTranscriptIntent: AppIntent {

    static var title: LocalizedStringResource { "Get Latest Transcript" }
    static var description: IntentDescription {
        IntentDescription("Returns the transcript of your most recent transcribed recording.")
    }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard DeliverySettings.shared.shortcutsDataAccessEnabled else { throw IntentError.shortcutsDataAccessDisabled }
        let latest = RecordingStore.shared.recordings.first { $0.isTranscribed }
        guard let transcript = latest?.transcript else {
            return .result(value: "")
        }
        return .result(value: transcript.plainText)
    }
}

/// "Get transcript of <recording>".
struct TranscriptForRecordingIntent: AppIntent {

    static var title: LocalizedStringResource { "Get Transcript" }
    static var description: IntentDescription {
        IntentDescription("Returns the transcript text for a specific recording.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Recording")
    var recording: RecordingEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the transcript of \(\.$recording)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard DeliverySettings.shared.shortcutsDataAccessEnabled else { throw IntentError.shortcutsDataAccessDisabled }
        return .result(value: recording.transcript ?? "")
    }
}

/// "Transcribe <recording>" — force transcription on demand.
struct TranscribeRecordingIntent: AppIntent {

    static var title: LocalizedStringResource { "Transcribe Recording" }
    static var description: IntentDescription {
        IntentDescription("Transcribes a recording on this device and returns the text.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Recording")
    var recording: RecordingEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$recording)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard DeliverySettings.shared.shortcutsDataAccessEnabled else { throw IntentError.shortcutsDataAccessDisabled }
        guard let stored = RecordingStore.shared.recording(id: recording.id) else {
            throw IntentError.unknownRecording
        }
        let transcript = try await TranscriptionCoordinator.shared.transcribe(stored)
        return .result(value: transcript.plainText)
    }
}

/// "Send <recording> to <destination>".
struct SendRecordingIntent: AppIntent {

    static var title: LocalizedStringResource { "Send Recording" }
    static var description: IntentDescription {
        IntentDescription("Sends a recording to one of your configured Bounce destinations.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Recording")
    var recording: RecordingEntity

    @Parameter(title: "Destination")
    var destination: DestinationAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$recording) to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard DeliverySettings.shared.shortcutsDataAccessEnabled else { throw IntentError.shortcutsDataAccessDisabled }
        guard let stored = RecordingStore.shared.recording(id: recording.id) else {
            throw IntentError.unknownRecording
        }
        try await DeliveryService.shared.deliver(stored, to: destination.destination)
        return .result()
    }
}

/// "Sync my recorder" — pull anything new off the device.
struct SyncRecorderIntent: AppIntent {

    static var title: LocalizedStringResource { "Sync Recorder" }
    static var description: IntentDescription {
        IntentDescription("Pulls any new recordings off your Plaud recorder. Requires the recorder to be in range.")
    }
    /// Needs the app foregrounded: BLE work can't run from an extension.
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        SyncManager.shared.startSync()
        return .result()
    }
}

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case unknownRecording
    case shortcutsDataAccessDisabled

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unknownRecording: return "That recording no longer exists."
        case .shortcutsDataAccessDisabled:
            return "Shortcuts access to transcripts is turned off in Bounce's Integrations settings."
        }
    }
}

// MARK: - Shortcuts

struct BounceShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LatestTranscriptIntent(),
            phrases: [
                "Get my latest \(.applicationName) transcript",
                "What did I record in \(.applicationName)",
            ],
            shortTitle: "Latest Transcript",
            systemImageName: "text.quote"
        )
        AppShortcut(
            intent: SyncRecorderIntent(),
            phrases: [
                "Sync my \(.applicationName) recorder",
                "\(.applicationName) sync",
            ],
            shortTitle: "Sync Recorder",
            systemImageName: "arrow.trianglehead.2.clockwise"
        )
    }
}
