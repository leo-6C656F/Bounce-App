import Foundation
import FoundationModels
import Observation

/// Answers questions about a transcript using Apple Intelligence's **on-device**
/// language model (the Foundation Models framework, iOS 26+).
///
/// Same privacy posture as the on-device transcriber: the transcript and the
/// questions never leave the phone. No key, no entitlement — just a runtime
/// availability check, because the model only exists on Apple-Intelligence-capable
/// hardware (A17 Pro / M1 and later) with the feature switched on.
///
/// ## The context window is the constraint
///
/// The on-device model has a ~4,096-token budget shared across the instructions,
/// the question, and the answer — roughly 12–16k characters *total*. A long
/// meeting transcript won't fit, so the transcript is grounded as the session's
/// instructions capped to `maxTranscriptChars`, keeping **both ends** — the head
/// carries why a meeting was called and its agenda, the tail carries what was
/// decided, and a tail-only cap (what this did originally) loses the first half
/// of that. The middle is replaced by a marked-up gap so the model can see that
/// something was cut rather than reading across the seam. For very long
/// recordings this means answers skip the middle; that limit is stated in the UI
/// rather than hidden. A future pass could summarise-then-answer or retrieve the
/// relevant chunk.
@MainActor
@Observable
final class TranscriptQA {

    enum Readiness: Equatable {
        case ready
        case unavailable(String)

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    /// Leaves ~1k tokens of the 4,096 budget for the boilerplate instructions,
    /// the question, and the streamed answer. ~3.5 chars/token in English.
    private static let maxTranscriptChars = 10_000

    private let model = SystemLanguageModel.default
    private var session: LanguageModelSession?
    private var groundedOn = ""

    private(set) var isAnswering = false

    /// Whether the on-device model can be used right now, with a reason if not.
    var readiness: Readiness {
        switch model.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            return .unavailable(Self.message(for: reason))
        @unknown default:
            return .unavailable("Apple Intelligence isn't available on this device.")
        }
    }

    var isAvailable: Bool { readiness.isReady }

    // MARK: - Session

    /// Point the model at a transcript. Cheap to call repeatedly — it rebuilds the
    /// grounded session only when the (capped) transcript actually changed, so a
    /// live transcript can refresh this as it grows without thrashing.
    func ground(on transcript: String) {
        guard isAvailable else { return }
        let context = Self.cap(transcript)
        guard context != groundedOn else { return }
        groundedOn = context

        // Routed through `PromptStore` so Settings › AI › Prompts can edit it;
        // `PromptDefaults.qaGrounding` is the fallback for the impossible case of
        // the catalogue having lost the id.
        let values = ["transcript": context]
        let edited = PromptStore.shared.filled(PromptID.qaGrounding, with: values)
        let instructions = edited.isEmpty
            ? PromptTemplating.filled(PromptDefaults.qaGrounding, with: values)
            : edited
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        self.session = session
        TranscribeLog.log("qa: grounded on \(context.count) chars")
    }

    /// Stream an answer. Each yielded value is the **cumulative** answer so far
    /// (Foundation Models streams snapshots, not deltas), so a view can assign it
    /// straight to its text state.
    func answer(to question: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAvailable, let session, !session.isResponding, !trimmed.isEmpty else {
                continuation.finish()
                return
            }
            isAnswering = true
            let task = Task {
                do {
                    for try await snapshot in session.streamResponse(to: trimmed) {
                        continuation.yield(snapshot.content)
                    }
                } catch is CancellationError {
                    // Normal stop.
                } catch {
                    continuation.yield("Sorry — I couldn't answer that. "
                        + ((error as? LocalizedError)?.errorDescription ?? ""))
                }
                isAnswering = false
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    /// Preserves both the head (intro, agenda, purpose) and the tail (conclusions, action items)
    /// when the transcript exceeds the token budget.
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
        case .deviceNotEligible:
            return "This iPhone doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to ask questions."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again shortly."
        @unknown default:
            return "Apple Intelligence isn't available right now."
        }
    }
}
