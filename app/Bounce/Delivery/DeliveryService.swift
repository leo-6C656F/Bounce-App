import Foundation

/// Sends a recording — audio, transcript, or both — to the configured
/// destinations.
///
/// The share sheet is deliberately *not* handled here: SwiftUI's `ShareLink`
/// does that natively (and picks up Liquid Glass for free), so it lives in the
/// views. What this type covers is the unattended paths: webhook POST and
/// folder export, both of which can run without any UI.
struct DeliveryService {

    static let shared = DeliveryService()

    enum Failure: LocalizedError {
        case nothingToSend
        case audioMissing
        case notConfigured(Destination)
        case http(Int, String)
        case folderUnavailable

        var errorDescription: String? {
            switch self {
            case .nothingToSend:
                return "There's nothing to send yet."
            case .audioMissing:
                return "The audio file for this recording is missing."
            case .notConfigured(let destination):
                return "\(destination.label) isn't set up yet."
            case .http(let code, let body):
                let detail = body.isEmpty ? "" : " \(body.prefix(200))"
                return "The webhook returned HTTP \(code).\(detail)"
            case .folderUnavailable:
                return "Couldn't open the destination folder. Pick it again in Settings."
            }
        }
    }

    /// Result of one delivery attempt.
    struct Outcome {
        let destination: Destination
        let error: Error?
        var succeeded: Bool { error == nil }
    }

    // MARK: - Entry points

    /// Send to every configured destination. Failures are collected, not thrown,
    /// so one broken destination doesn't block the others.
    @MainActor
    func deliverToAllDestinations(_ recording: Recording) async -> [Outcome] {
        let destinations = DeliverySettings.shared.activeDestinations
        var outcomes: [Outcome] = []
        for destination in destinations {
            do {
                try await deliver(recording, to: destination)
                outcomes.append(Outcome(destination: destination, error: nil))
            } catch {
                outcomes.append(Outcome(destination: destination, error: error))
            }
        }
        return outcomes
    }

    @MainActor
    func deliver(_ recording: Recording, to destination: Destination) async throws {
        let settings = DeliverySettings.shared
        let payload = try Payload(recording: recording, settings: settings)

        switch destination {
        case .webhook:
            guard let url = settings.webhookURL else { throw Failure.notConfigured(.webhook) }
            try await postWebhook(payload, to: url, secret: settings.webhookSecret)
        case .folder:
            guard let folder = settings.resolveFolder() else { throw Failure.folderUnavailable }
            defer { folder.stopAccessingSecurityScopedResource() }
            try writeToFolder(payload, in: folder)
        }

        RecordingStore.shared.update(id: recording.id) { stored in
            if !stored.deliveredTo.contains(destination.rawValue) {
                stored.deliveredTo.append(destination.rawValue)
            }
        }
        SyncManager.shared.refreshLibrary()
    }

    // MARK: - Payload

    /// Everything needed to send one recording, resolved once up front.
    struct Payload {
        let recording: Recording
        let audioURL: URL?
        let transcriptText: String?
        /// Filename stem shared by the audio and text files, e.g.
        /// "2026-07-29 14-05 Quarterly review".
        let basename: String
        /// Resolved here rather than read from `DeliverySettings.shared` at send
        /// time: the settings object is `@MainActor` and the send paths are not,
        /// so reaching for it there would mean an actor hop mid-request — and the
        /// user could change the format between rendering the text and naming the
        /// file, producing a `.txt` containing Markdown.
        let transcriptFormat: TranscriptFormat

        @MainActor
        init(recording: Recording, settings: DeliverySettings) throws {
            let content = settings.payloadContent

            let audio = content.includesAudio ? RecordingStore.shared.audioURL(for: recording) : nil
            if content.includesAudio, audio == nil { throw Failure.audioMissing }

            let text: String? = {
                guard content.includesTranscript else { return nil }
                // The recording-aware overload, so Markdown gets its frontmatter.
                return settings.transcriptFormat.render(recording)
            }()

            if audio == nil, text == nil { throw Failure.nothingToSend }

            self.recording = recording
            self.audioURL = audio
            self.transcriptText = text
            self.basename = Payload.makeBasename(for: recording)
            self.transcriptFormat = settings.transcriptFormat
        }

        private static func makeBasename(for recording: Recording) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH-mm"
            let stamp = formatter.string(from: recording.createdAt)

            let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            let title = recording.displayTitle
                .components(separatedBy: illegal)
                .joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(60)

            return title.isEmpty ? stamp : "\(stamp) \(title)"
        }
    }

    // MARK: - Webhook

    /// `multipart/form-data` POST so a single request carries the metadata JSON,
    /// the transcript, and the audio file. That shape works unchanged with
    /// n8n, Zapier, Make, and a plain server handler.
    private func postWebhook(_ payload: Payload, to url: URL, secret: String) async throws {
        let boundary = "Bounce-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        if !secret.isEmpty {
            request.setValue(secret, forHTTPHeaderField: "X-Bounce-Secret")
        }

        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        func appendFile(_ name: String, filename: String, mimeType: String, data: Data) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.append("Content-Type: \(mimeType)\r\n\r\n")
            body.append(data)
            body.append("\r\n")
        }

        if let metadata = try? JSONEncoder.iso8601.encode(WebhookMetadata(payload.recording)),
           let json = String(data: metadata, encoding: .utf8) {
            appendField("metadata", json)
        }

        if let text = payload.transcriptText {
            appendField("transcript", text)
            appendFile(
                "transcript_file",
                filename: "\(payload.basename).\(payload.transcriptFormat.fileExtension)",
                mimeType: payload.transcriptFormat.mimeType,
                data: Data(text.utf8)
            )
        }

        if let audioURL = payload.audioURL {
            let data = try Data(contentsOf: audioURL)
            appendFile(
                "audio",
                filename: "\(payload.basename).\(audioURL.pathExtension)",
                mimeType: Self.mimeType(forExtension: audioURL.pathExtension),
                data: data
            )
        }

        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, String(data: responseData, encoding: .utf8) ?? "")
        }
    }

    /// JSON sidecar describing the recording. Kept flat and snake_cased so it
    /// is easy to map in no-code tools.
    private struct WebhookMetadata: Encodable {
        let id: String
        let title: String
        let recorded_at: Date
        let duration_seconds: Double
        let device_serial: String
        let transcript_locale: String?
        let segments: [Segment]?

        struct Segment: Encodable {
            let start: Double
            let end: Double
            let text: String
        }

        init(_ recording: Recording) {
            id = recording.id
            title = recording.displayTitle
            recorded_at = recording.createdAt
            duration_seconds = recording.duration
            device_serial = recording.deviceSN
            transcript_locale = recording.transcript?.localeIdentifier
            segments = recording.transcript?.segments.map {
                Segment(start: $0.start, end: $0.end, text: $0.text)
            }
        }
    }

    // MARK: - Folder

    private func writeToFolder(_ payload: Payload, in folder: URL) throws {
        if let audioURL = payload.audioURL {
            let destination = folder.appendingPathComponent("\(payload.basename).\(audioURL.pathExtension)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: audioURL, to: destination)
        }

        if let text = payload.transcriptText {
            let destination = folder
                .appendingPathComponent("\(payload.basename).\(payload.transcriptFormat.fileExtension)")
            try Data(text.utf8).write(to: destination, options: .atomic)
        }
    }

    // MARK: - Helpers

    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "opus", "ogg": return "audio/ogg"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Small conveniences

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return encoder
    }
}
