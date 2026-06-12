import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Foundation Models backend ("Apple Intelligence").
///
/// Free, fully local, key-free: it runs on Apple's built-in system language model, so nothing ever
/// leaves the Mac and there's no provider to pay. Requires macOS 26+ on an Apple-Intelligence-capable
/// device; on anything older (or with Apple Intelligence turned off) it reports itself unavailable
/// with a clear, actionable reason instead of failing cryptically.
///
/// Implemented against Apple's public `FoundationModels` API (`SystemLanguageModel` /
/// `LanguageModelSession`) — independent of any third-party code.
struct AppleFoundationClient: LLMClient {
    var temperature: Double? = nil
    var maxTokens: Int? = nil

    /// There's no key to check — "validating" the on-device model just means it's usable right now.
    func validate(apiKey: String) async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return
            case .unavailable(let reason):
                throw LLMError.message(Self.reason(reason))
            @unknown default:
                throw LLMError.message("Apple Intelligence is unavailable on this Mac.")
            }
        }
        #endif
        throw LLMError.message("Apple Intelligence needs macOS 26 or later on an Apple-silicon Mac.")
    }

    func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let task = Task {
                    do {
                        let availability = SystemLanguageModel.default.availability
                        guard case .available = availability else {
                            if case .unavailable(let reason) = availability {
                                throw LLMError.message(Self.reason(reason))
                            }
                            throw LLMError.message("Apple Intelligence is unavailable right now.")
                        }

                        // System messages become the session's instructions; everything else is the prompt.
                        let system = messages.filter { $0.role == .system }.map(\.text)
                            .joined(separator: "\n\n")
                        let prompt = Self.renderPrompt(messages)

                        let session = system.isEmpty
                            ? LanguageModelSession()
                            : LanguageModelSession(instructions: Instructions(system))

                        let options = Self.options(temperature: temperature, maxTokens: maxTokens)

                        // FoundationModels streams a CUMULATIVE snapshot each step (not deltas), so we
                        // diff against what we've already emitted to recover just the newly-added text.
                        var emitted = ""
                        for try await snapshot in session.streamResponse(to: prompt, options: options) {
                            try Task.checkCancellation()
                            let cumulative = snapshot.content
                            guard cumulative.count > emitted.count else { continue }
                            continuation.yield(.text(String(cumulative.dropFirst(emitted.count))))
                            emitted = cumulative
                        }

                        // The framework doesn't surface token counts. It's free + on-device, so this only
                        // feeds the (always-$0) usage display — a rough ~4-chars/token estimate.
                        continuation.yield(.usage(input: prompt.count / 4, output: emitted.count / 4))
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            continuation.finish(throwing:
                LLMError.message("Apple Intelligence needs macOS 26 or later on an Apple-silicon Mac."))
        }
    }

    /// Flatten the conversation into a single prompt. System turns are handled separately as the
    /// session's instructions; the common case is one user question, but multi-turn (peer-review /
    /// follow-up) context is rendered as a labeled transcript so the model still sees it.
    private static func renderPrompt(_ messages: [ChatMessage]) -> String {
        let turns = messages.filter { $0.role != .system }
        if turns.count <= 1 { return turns.last?.text ?? "" }
        return turns
            .map { $0.role == .assistant ? "Assistant: \($0.text)" : "User: \($0.text)" }
            .joined(separator: "\n\n")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func options(temperature: Double?, maxTokens: Int?) -> GenerationOptions {
        switch (temperature, maxTokens) {
        case let (t?, m?):  return GenerationOptions(temperature: t, maximumResponseTokens: m)
        case let (t?, nil): return GenerationOptions(temperature: t)
        case let (nil, m?): return GenerationOptions(maximumResponseTokens: m)
        default:            return GenerationOptions()
        }
    }

    @available(macOS 26.0, *)
    private static func reason(_ r: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch r {
        case .deviceNotEligible:           return "This Mac isn't eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings to use this seat."
        case .modelNotReady:               return "Apple Intelligence is still downloading its model — try again shortly."
        @unknown default:                  return "Apple Intelligence is unavailable right now."
        }
    }
    #endif
}
