import Foundation

/// Talks to Anthropic's native Messages API (`/v1/messages`), which uses a
/// different shape than OpenAI: `x-api-key` + `anthropic-version` headers,
/// a top-level `system` field, and a `content` array in the response.
struct AnthropicClient: LLMClient {
    let model: String
    var temperature: Double? = nil
    var maxTokens: Int? = nil
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func validate(apiKey: String) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Smallest possible call: 1 output token. We only care about the HTTP status.
        let body = RequestBody(model: model, max_tokens: 1, system: "ping",
                               messages: [.init(role: "user", content: .text("Hi"))])
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try KeyValidation.interpret(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let system = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
                    let convo: [RequestBody.Message] = messages.compactMap { msg in
                        guard msg.role != .system else { return nil }
                        let role = msg.role == .assistant ? "assistant" : "user"
                        if let image = msg.image, msg.role == .user {
                            return RequestBody.Message(role: role, content: .blocks([
                                Block(type: "image", source: .init(type: "base64", media_type: image.mediaType, data: image.base64)),
                                Block(type: "text", text: msg.text)
                            ]))
                        }
                        return RequestBody.Message(role: role, content: .text(msg.text))
                    }
                    // Anthropic REQUIRES max_tokens. The default must be generous — a low cap silently
                    // truncates long council answers mid-sentence with no error surfaced.
                    let body = RequestBody(model: model, max_tokens: maxTokens ?? 8192, system: system,
                                           messages: convo, stream: true, temperature: temperature)
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line; if errBody.count > 1200 { break } }
                        throw LLMError.message(HTTPError.describe(http.statusCode, errBody))
                    }
                    var input = 0, output = 0
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let ev = try? JSONDecoder().decode(StreamEvent.self, from: data) else { continue }
                        // A mid-stream error event (overloaded etc.) must FAIL the call — otherwise the
                        // partial text would be committed to history as if it were a complete answer.
                        if ev.type == "error" {
                            throw LLMError.message(ev.error?.message ?? "The provider returned an error mid-stream.")
                        }
                        if let t = ev.delta?.text { continuation.yield(.text(t)) }
                        // Prefer the latest top-level usage (message_delta reports the revised cumulative
                        // total, incl. cache tokens); fall back to message_start's nested usage.
                        if let i = ev.usage?.input_tokens ?? ev.message?.usage?.input_tokens { input = i }
                        if let o = ev.usage?.output_tokens { output = o }
                    }
                    continuation.yield(.usage(input: input, output: output))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct StreamEvent: Decodable {
        let type: String?
        let delta: Delta?
        let message: StartMessage?
        let usage: Usage?
        let error: ErrorPayload?
        struct Delta: Decodable { let text: String? }
        struct StartMessage: Decodable { let usage: Usage? }
        struct Usage: Decodable { let input_tokens: Int?; let output_tokens: Int? }
        struct ErrorPayload: Decodable { let message: String? }
    }

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
        var stream: Bool? = nil
        var temperature: Double? = nil
        struct Message: Encodable { let role: String; let content: Content }
    }

    /// Message content is either a bare string (text-only) or an array of blocks (with image).
    private enum Content: Encodable {
        case text(String)
        case blocks([Block])
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s):    try c.encode(s)
            case .blocks(let b):  try c.encode(b)
            }
        }
    }

    private struct Block: Encodable {
        let type: String
        var text: String? = nil
        var source: ImageSource? = nil      // nil fields are omitted by the synthesized encoder
    }

    private struct ImageSource: Encodable {
        let type: String                    // "base64"
        let media_type: String
        let data: String
    }
}
