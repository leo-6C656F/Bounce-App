import Foundation

/// Shared constants, credential storage, and token decoding for the Soniox
/// cloud transcription engine.
///
/// ## Why this is opt-in and off by default
///
/// Bounce's whole premise is on-device transcription — audio never leaves the
/// phone. Soniox is a **cloud** service: choosing it uploads decrypted audio to
/// Soniox's servers. That is a deliberate, user-made tradeoff (better accuracy,
/// more languages, real-time streaming) and the Settings UI says so plainly. The
/// default engine stays `.local`.
enum Soniox {

    /// Real-time streaming STT over WebSocket.
    static let realtimeURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    /// Async file transcription over REST.
    static let apiBaseURL = URL(string: "https://api.soniox.com")!

    static let realtimeModel = "stt-rt-v5"
    static let asyncModel = "stt-async-v5"

    /// The recorder's decoded PCM: 16 kHz mono signed 16-bit little-endian.
    static let audioFormat = "pcm_s16le"
    static let sampleRate = 16_000
    static let channels = 1

    // MARK: - Credentials

    /// API key storage. Held in the keychain with the same `ThisDeviceOnly`,
    /// non-synced attributes as the Plaud credentials (see `KeychainStore`), so a
    /// backup or another device on the Apple ID can't lift it. `nonisolated`
    /// throughout so the batch transcriber can read it off the main actor.
    enum Credentials {
        private static let key = "soniox_api_key"

        static var apiKey: String? {
            guard let data = KeychainStore.loadData(for: key),
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty
            else { return nil }
            return value
        }

        static var hasKey: Bool { apiKey != nil }

        static func save(_ value: String) throws {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { clear(); return }
            try KeychainStore.saveData(Data(trimmed.utf8), for: key)
        }

        static func clear() { KeychainStore.delete(key) }
    }

    // MARK: - Errors

    enum Failure: LocalizedError {
        case noAPIKey
        case http(Int, String)
        case badResponse(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No Soniox API key. Add one in Settings, or switch transcription back to on-device."
            case .http(let code, let detail):
                return "Soniox returned \(code). \(detail)"
            case .badResponse(let detail):
                return "Unexpected response from Soniox. \(detail)"
            case .timedOut:
                return "Soniox transcription timed out."
            }
        }
    }

    // MARK: - Wire types

    /// One token from either the real-time or async API. `isFinal` is absent on
    /// async results (everything is final there) and present on real-time ones.
    struct Token: Decodable {
        let text: String
        let isFinal: Bool?
        let startMs: Int?
        let endMs: Int?
        let speaker: String?
        /// Detected language code ("en"), present when language identification
        /// is enabled.
        let language: String?
        /// "original" or "translation" when real-time translation is on; absent
        /// otherwise.
        let translationStatus: String?

        enum CodingKeys: String, CodingKey {
            case text
            case isFinal = "is_final"
            case startMs = "start_ms"
            case endMs = "end_ms"
            case speaker
            case language
            case translationStatus = "translation_status"
        }
    }

    /// A real-time WebSocket result message, or an async transcript payload.
    struct Result: Decodable {
        let tokens: [Token]?
        let finished: Bool?
        let errorCode: Int?
        let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case tokens
            case finished
            case errorCode = "error_code"
            case errorMessage = "error_message"
        }
    }

    // MARK: - Request options

    /// `language_hints` for a request: the user's configured hint list when set,
    /// otherwise the single transcription-locale language, matching the old
    /// behaviour.
    static func languageHints(for locale: Locale) -> [String] {
        let configured = DeliverySettings.sonioxLanguageHints
        if !configured.isEmpty { return configured }
        return locale.language.languageCode.map { [$0.identifier] } ?? []
    }

    /// The `context` payload carrying the user's custom vocabulary, or nil when
    /// none is configured.
    static func contextPayload() -> [String: Any]? {
        let terms = DeliverySettings.sonioxVocabularyTerms
        guard !terms.isEmpty else { return nil }
        return ["terms": terms]
    }

    /// Majority language across tokens, from language identification — used to
    /// tag the transcript with what was actually spoken rather than what was
    /// requested.
    static func dominantLanguage(in tokens: [Token]) -> String? {
        let counts = tokens.compactMap(\.language)
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Token → segments

    /// Control tokens the real-time stream interleaves with speech.
    ///
    /// `<end>` is the endpoint marker — endpoint detection is on for the live
    /// path, which is why it appears at all — and `<fin>` closes the stream.
    /// Neither is speech. They were being appended to the transcript verbatim,
    /// so the live preview read "…that's their two best. `<end>`".
    static let controlTokens = ["<end>", "<fin>"]

    static func isControlToken(_ text: String) -> Bool {
        controlTokens.contains(text.trimmingCharacters(in: .whitespaces))
    }

    /// Turn a flat token list into timed `TranscriptSegment`s, splitting on
    /// sentence-ending punctuation **and on speaker change**, so the result reads
    /// as phrases, each tagged with its speaker (when diarization is on) for
    /// block grouping. Tokens are sub-word ("Hel", "lo"), so text is the
    /// concatenation; times come from the first/last token of each phrase.
    static func segments(from tokens: [Token]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var buffer = ""
        var start: Int?
        var end: Int?
        var speaker: String?

        func emit() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            let startMs = start
            let endMs = end
            let phraseSpeaker = speaker
            buffer = ""
            start = nil
            end = nil
            guard !text.isEmpty else { return }
            let startS = Double(startMs ?? 0) / 1000
            let endS = Double(endMs ?? startMs ?? 0) / 1000
            segments.append(TranscriptSegment(
                text: text, start: startS, end: max(endS, startS), speaker: phraseSpeaker))
        }

        for token in tokens {
            // An endpoint marker closes the phrase rather than joining it. This
            // is better segmentation than punctuation alone — it's where the
            // engine heard someone stop talking.
            if isControlToken(token.text) {
                if !buffer.isEmpty { emit() }
                continue
            }
            // A speaker change closes the current phrase before the new one opens.
            if let tokenSpeaker = token.speaker, tokenSpeaker != speaker, !buffer.isEmpty {
                emit()
            }
            if let tokenSpeaker = token.speaker { speaker = tokenSpeaker }
            if start == nil { start = token.startMs }
            if let e = token.endMs { end = e }
            buffer += token.text
            if let last = token.text.last, ".?!。？！".contains(last) {
                emit()
            }
        }
        emit()
        return segments
    }
}
