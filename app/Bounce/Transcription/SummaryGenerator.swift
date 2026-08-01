import Foundation
import FoundationModels
import Observation

/// Runs a `SummaryTemplate` over a transcript to produce a summary, using Apple
/// Intelligence's **on-device** model — same engine and privacy posture as the
/// Q&A feature (nothing uploaded, no key). Streams the summary as it generates.
///
/// Shares the on-device model's ~4,096-token constraint, so the transcript is
/// capped to the most recent slice; for a long recording the summary is drawn
/// from the tail. Stated in the UI.
@MainActor
@Observable
final class SummaryGenerator {

    /// Matches `TranscriptQA` so the UI can gate identically.
    enum Readiness: Equatable {
        case ready
        case unavailable(String)
        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    private static let maxTranscriptChars = 10_000

    private let model = SystemLanguageModel.default
    private(set) var isGenerating = false

    /// Set when the last `generate` run failed.
    ///
    /// The failure message is *also* yielded into the stream, so the Summary tab
    /// can show it inline without extra plumbing — but a caller that **persists**
    /// the stream's last value must check this first, or the apology text gets
    /// stored as the summary, delivered to webhooks, and shown as real output.
    private(set) var lastError: String?

    var readiness: Readiness {
        switch model.availability {
        case .available: return .ready
        case .unavailable(let reason): return .unavailable(Self.message(for: reason))
        @unknown default: return .unavailable("Apple Intelligence isn't available on this device.")
        }
    }

    var isAvailable: Bool { readiness.isReady }

    /// Stream a summary of `transcript` using `template`. Each yielded value is
    /// the cumulative text so far (Foundation Models streams snapshots).
    func generate(transcript: String, template: SummaryTemplate) -> AsyncStream<String> {
        AsyncStream { continuation in
            lastError = nil
            guard isAvailable else {
                lastError = "Apple Intelligence isn't available on this iPhone."
                continuation.finish()
                return
            }
            let context = Self.cap(transcript)

            let instructions = """
            You summarize a transcript of a recording the user made. Follow the \
            user's instruction exactly, basing everything only on the transcript. \
            Reply in plain text — you may use simple "- " bullet lines where the \
            instruction asks for a list, but never JSON or code.

            TRANSCRIPT:
            \(context)
            """
            let session = LanguageModelSession(instructions: instructions)

            isGenerating = true
            let task = Task {
                do {
                    for try await snapshot in session.streamResponse(to: template.prompt) {
                        continuation.yield(snapshot.content)
                    }
                } catch is CancellationError {
                    // normal stop
                } catch {
                    let message = "Couldn't generate this summary. "
                        + ((error as? LocalizedError)?.errorDescription ?? "")
                    lastError = message
                    continuation.yield(message)
                }
                isGenerating = false
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func cap(_ transcript: String) -> String {
        guard transcript.count > maxTranscriptChars else { return transcript }
        // Halves of the budget, derived rather than written as literals: with a
        // hardcoded 4,500/4,500 against a `maxTranscriptChars` anyone is free to
        // lower, a budget under 9,000 makes the two slices overlap — duplicating
        // text and rendering a negative count as "[… -2000 characters omitted …]".
        let half = maxTranscriptChars / 2
        let head = transcript.prefix(half)
        let tail = transcript.suffix(half)
        let omitted = transcript.count - 2 * half
        return "\(head)\n\n[… \(omitted) characters omitted …]\n\n\(tail)"
    }

    private static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "This iPhone doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings to make summaries."
        case .modelNotReady: return "The on-device model is still downloading. Try again shortly."
        @unknown default: return "Apple Intelligence isn't available right now."
        }
    }
}
