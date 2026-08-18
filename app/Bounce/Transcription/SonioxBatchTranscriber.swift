import Foundation

/// Transcribes a finished audio file through Soniox's async REST API.
///
/// The counterpart to `LocalTranscriber` for the cloud engine. Same output — a
/// `Transcript` of timed segments — so `TranscriptionCoordinator` can pick either
/// without caring which produced the result.
///
/// The flow, all Bearer-authenticated with the stored API key:
///
///   1. `POST /v1/files`            upload the MP3, get a file id
///   2. `POST /v1/transcriptions`   start the job against that file
///   3. `GET  /v1/transcriptions/{id}`         poll until `completed`
///   4. `GET  /v1/transcriptions/{id}/transcript`   fetch tokens
///   5. `DELETE` the transcription and the file (best-effort cleanup)
///
/// The audio is uploaded to Soniox — this is the cloud path, chosen explicitly in
/// Settings. On any failure the caller falls back to on-device.
struct SonioxBatchTranscriber: Sendable {

    static let shared = SonioxBatchTranscriber()
    private init() {}

    /// Same shape as `LocalTranscriber.transcribe`, so the coordinator can call
    /// either. `onPhase` maps the cloud stages onto the existing UI phases.
    func transcribe(
        audioAt url: URL,
        locale: Locale = .current,
        onPhase: @Sendable (LocalTranscriber.Phase) -> Void = { _ in }
    ) async throws -> Transcript {

        guard let apiKey = Soniox.Credentials.apiKey else { throw Soniox.Failure.noAPIKey }
        TranscribeLog.log("soniox: batch \(url.lastPathComponent) locale=\(locale.identifier)")

        onPhase(.transcribing)

        let fileId = try await uploadFile(at: url, apiKey: apiKey)
        defer { Task { await deleteFile(fileId, apiKey: apiKey) } }

        let transcriptionId = try await createTranscription(
            fileId: fileId, locale: locale, apiKey: apiKey)
        defer { Task { await deleteTranscription(transcriptionId, apiKey: apiKey) } }

        try await waitUntilComplete(transcriptionId, apiKey: apiKey)
        let tokens = try await fetchTranscript(transcriptionId, apiKey: apiKey)

        let segments = Soniox.segments(from: tokens)
        guard !segments.isEmpty else { throw LocalTranscriber.Failure.noSpeechDetected }

        TranscribeLog.log("soniox: ✓ \(segments.count) segment(s), "
            + "\(segments.map(\.text).joined(separator: " ").count) chars")

        // Prefer the language Soniox actually detected over the one requested —
        // with multiple language hints they can legitimately differ.
        let detected = Soniox.dominantLanguage(in: tokens)

        return Transcript(
            segments: segments,
            localeIdentifier: detected ?? locale.identifier(.bcp47),
            createdAt: Date()
        )
    }

    // MARK: - Steps

    private func uploadFile(at url: URL, apiKey: String) async throws -> String {
        let boundary = "BounceBoundary-\(UUID().uuidString)"
        let prefix = Data((
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n"
            + "Content-Type: audio/mpeg\r\n\r\n"
        ).utf8)
        let suffix = Data("\r\n--\(boundary)--\r\n".utf8)

        // Assemble the multipart envelope on disk rather than in RAM. Holding the
        // whole recording as `Data` — once loaded from disk, once appended into
        // `body`, once more for URLSession's in-memory body — peaked at ~2–3× the
        // file size and was jetsam-eligible on a long recording (S-15). The audio
        // is streamed in a chunk at a time, and `upload(fromFile:)` below streams
        // the envelope back off disk, so peak memory is one chunk.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("soniox-upload-\(UUID().uuidString)")
        try await Task.detached(priority: .utility) {
            guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
                throw Soniox.Failure.badResponse("couldn't stage upload file")
            }
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: prefix)
            let source = try FileHandle(forReadingFrom: url)
            defer { try? source.close() }
            while true {
                let chunk = try source.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
            }
            try handle.write(contentsOf: suffix)
        }.value
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var request = URLRequest(url: Soniox.apiBaseURL.appending(path: "v1/files"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authorize(&request, apiKey)
        // Longer than `authorize`'s default 30s — this one carries the whole
        // recording's audio, which can legitimately take longer to upload than
        // a small JSON call over a weak connection.
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: tempURL)
        let json = try Self.decodeJSON(data, response)
        guard let id = json["id"] as? String else {
            throw Soniox.Failure.badResponse("file upload returned no id")
        }
        return id
    }

    private func createTranscription(
        fileId: String, locale: Locale, apiKey: String
    ) async throws -> String {
        var payload: [String: Any] = [
            "model": Soniox.asyncModel,
            "file_id": fileId,
            "enable_speaker_diarization": true,
            // Tags each token with its detected language, so the transcript can
            // record what was actually spoken (see `Soniox.dominantLanguage`).
            "enable_language_identification": true,
        ]
        let hints = Soniox.languageHints(for: locale)
        if !hints.isEmpty {
            payload["language_hints"] = hints
        }
        if let context = Soniox.contextPayload() {
            payload["context"] = context
        }

        var request = URLRequest(url: Soniox.apiBaseURL.appending(path: "v1/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, apiKey)

        let body = try JSONSerialization.data(withJSONObject: payload)
        let json = try await send(request, body: body)
        guard let id = json["id"] as? String else {
            throw Soniox.Failure.badResponse("create transcription returned no id")
        }
        return id
    }

    /// Poll status until terminal. Interval and cap are generous — a long
    /// recording takes a while server-side — but bounded so a stuck job can't
    /// hang the queue forever.
    private func waitUntilComplete(_ id: String, apiKey: String) async throws {
        let path = "v1/transcriptions/\(id)"
        for _ in 0..<300 {   // ~10 min at 2s
            var request = URLRequest(url: Soniox.apiBaseURL.appending(path: path))
            authorize(&request, apiKey)
            let json = try await send(request, body: nil)

            switch json["status"] as? String {
            case "completed":
                return
            case "error":
                throw Soniox.Failure.badResponse(json["error_message"] as? String ?? "transcription failed")
            default:
                try? await Task.sleep(for: .seconds(2))
            }
        }
        throw Soniox.Failure.timedOut
    }

    private func fetchTranscript(_ id: String, apiKey: String) async throws -> [Soniox.Token] {
        var request = URLRequest(
            url: Soniox.apiBaseURL.appending(path: "v1/transcriptions/\(id)/transcript"))
        authorize(&request, apiKey)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        let result = try JSONDecoder().decode(Soniox.Result.self, from: data)
        return result.tokens ?? []
    }

    private func deleteTranscription(_ id: String, apiKey: String) async {
        var request = URLRequest(url: Soniox.apiBaseURL.appending(path: "v1/transcriptions/\(id)"))
        request.httpMethod = "DELETE"
        authorize(&request, apiKey)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func deleteFile(_ id: String, apiKey: String) async {
        var request = URLRequest(url: Soniox.apiBaseURL.appending(path: "v1/files/\(id)"))
        request.httpMethod = "DELETE"
        authorize(&request, apiKey)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - HTTP helpers

    /// Every request funnels through here, so this is the one place to bound
    /// them all — previously none of these set an explicit `timeoutInterval`
    /// and rode out `URLSession`'s system default (60s per request), which
    /// means a connection that's accepted but never responds holds a slot far
    /// longer than a user would expect before this falls back to on-device.
    /// 30s is generous for a small JSON call; `uploadFile` overrides it for
    /// the one request that's genuinely large.
    private func authorize(_ request: inout URLRequest, _ apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
    }

    /// Send a request (optionally with a body via upload) and return the decoded
    /// JSON object, having checked the status code.
    private func send(_ request: URLRequest, body: Data?) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        if let body {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        return try Self.decodeJSON(data, response)
    }

    /// Check the status code and decode a JSON object. Shared by `send` and the
    /// file-streaming `uploadFile`, which doesn't route through `send`.
    private static func decodeJSON(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        try check(response, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Soniox.Failure.badResponse("response was not a JSON object")
        }
        return json
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw Soniox.Failure.badResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .flatMap { $0["message"] as? String } ?? ""
            throw Soniox.Failure.http(http.statusCode, message)
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
