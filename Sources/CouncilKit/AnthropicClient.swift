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

    /// The cap sent when the seat sets none. Anthropic REQUIRES max_tokens, and on the models that
    /// think before they answer the cap covers the thinking too. So the default leaves room for
    /// both: a low cap cuts long council answers off mid-sentence (the answer is then marked cut
    /// off, but still cut). It is a ceiling, not a spend: a model stops when it is done.
    static let defaultMaxTokens = 16_000

    /// Claude models from Opus 4.7 on refuse a request that sets `temperature` (HTTP 400), so it
    /// goes only to the older families that still take it. An id this list doesn't know gets none:
    /// a setting left out is a smaller failure than a refused answer.
    static func takesTemperature(_ model: String) -> Bool {
        let id = model.lowercased()
        return ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5", "claude-opus-4-5", "claude-sonnet-4-5"]
            .contains { id.hasPrefix($0) }
    }

    /// The JSON body of a streaming call. No I/O, so a test can read what would be sent.
    func streamBody(for messages: [ChatMessage]) throws -> Data {
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
        let body = RequestBody(model: model, max_tokens: maxTokens ?? Self.defaultMaxTokens, system: system,
                               messages: convo, stream: true,
                               temperature: Self.takesTemperature(model) ? temperature : nil)
        return try JSONEncoder().encode(body)
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
                    request.httpBody = try streamBody(for: messages)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line; if errBody.count > 1200 { break } }
                        throw LLMError.message(HTTPError.describe(http.statusCode, errBody))
                    }
                    var reader = EventReader()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for chunk in try reader.read(line) { continuation.yield(chunk) }
                    }
                    for chunk in reader.finish() { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads the Messages API's server-sent events one line at a time and says what each line
    /// carries. No I/O, so a test can feed it recorded lines.
    struct EventReader {
        private var input = 0, output = 0
        private var stopSent = false
        private var sawMessageStop = false

        /// The chunks one line carries.
        mutating func read(_ line: String) throws -> [StreamChunk] {
            guard line.hasPrefix("data:") else { return [] }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let ev = try? JSONDecoder().decode(StreamEvent.self, from: data) else { return [] }
            // A mid-stream error event (overloaded etc.) must FAIL the call — otherwise the
            // partial text would be committed to history as if it were a complete answer.
            if ev.type == "error" {
                throw LLMError.message(ev.error?.message ?? "The provider returned an error mid-stream.")
            }
            var out: [StreamChunk] = []
            if let t = ev.delta?.text { out.append(.text(t)) }
            // Prefer the latest top-level usage (message_delta reports the revised cumulative
            // total, incl. cache tokens); fall back to message_start's nested usage.
            if let i = ev.usage?.input_tokens ?? ev.message?.usage?.input_tokens { input = i }
            if let o = ev.usage?.output_tokens { output = o }
            // message_delta carries why the response ended; pass it on the moment it arrives.
            if let reason = ev.delta?.stop_reason, !stopSent {
                stopSent = true
                out.append(.stop(Self.stopReason(reason)))
            }
            if ev.type == "message_stop" { sawMessageStop = true }
            // An event with nothing to keep (a ping, a thinking block opening, a thinking or
            // signature delta) still proves the model is working. The current models think before
            // they answer, and the thinking arrives as events with no text in them.
            return out.isEmpty ? [.heartbeat] : out
        }

        /// The closing chunks once the lines run out: the end signal if no line gave one, then usage.
        func finish() -> [StreamChunk] {
            // Anthropic closes every good stream with message_stop. One that ended without it (or
            // a stop reason) lost its connection partway, however cleanly the socket closed.
            let stop: [StreamChunk] = stopSent ? [] : [.stop(sawMessageStop ? .finished : .endedEarly)]
            return stop + [.usage(input: input, output: output)]
        }

        static func stopReason(_ raw: String) -> StreamChunk.StopReason {
            switch raw {
            case "end_turn", "stop_sequence": return .finished
            case "max_tokens", "model_context_window_exceeded": return .lengthLimit
            default: return .unknown   // refusal, pause_turn…: nothing the engine can mark
            }
        }
    }

    private struct StreamEvent: Decodable {
        let type: String?
        let delta: Delta?
        let message: StartMessage?
        let usage: Usage?
        let error: ErrorPayload?
        struct Delta: Decodable { let text: String?; let stop_reason: String? }
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
