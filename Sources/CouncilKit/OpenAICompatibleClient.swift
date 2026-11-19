import Foundation

/// Talks to any OpenAI-style `/chat/completions` endpoint. Used for both
/// GPT (api.openai.com) and Gemini (Google's OpenAI-compatible endpoint).
struct OpenAICompatibleClient: LLMClient {
    let endpoint: URL
    let model: String
    var temperature: Double? = nil
    var maxTokens: Int? = nil

    /// Reasoning models (OpenAI o-series and GPT-6, any "…-reasoning" variant) reject a custom
    /// `temperature` — they only run at their fixed setting, and sending one 400s the whole call.
    /// Detect them by id so we silently drop the override instead of failing the request.
    private var isReasoningModel: Bool {
        let name = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        if name.contains("reason") { return true }                      // sonar-reasoning-pro, grok-…-reasoning
        if let f = name.first, f == "o", name.dropFirst().first?.isNumber == true { return true }  // o1 / o3 / o4-mini …
        if name.hasPrefix("gpt-6") { return true }                      // OpenAI: omit temperature on GPT-6.2 Astra and Sol
        return false
    }

    /// OpenAI's own API takes the output cap as `max_completion_tokens`: it has deprecated
    /// `max_tokens`, and its reasoning models refuse it. Every other host keeps the older name,
    /// the one they all understand.
    private var capsWithMaxCompletionTokens: Bool {
        guard let host = endpoint.host?.lowercased() else { return false }
        return host == "api.openai.com" || host.hasSuffix(".openai.com")
    }

    /// The cap for the one-shot verdict. The JSON itself is short, but on a model that reasons
    /// before it answers the cap covers the reasoning too, and 400 was spent before the first brace.
    static let verdictMaxTokens = 1500

    /// How long the one-shot verdict may take to come back.
    static let verdictTimeoutSeconds: TimeInterval = 120

    private func body(_ messages: [RequestBody.Message], cap: Int?) -> RequestBody {
        RequestBody(model: model, messages: messages,
                    max_tokens: capsWithMaxCompletionTokens ? nil : cap,
                    max_completion_tokens: capsWithMaxCompletionTokens ? cap : nil)
    }

    /// OpenRouter ranks apps and (for some models) gates on attribution headers; a no-op for every
    /// other host. The referer is just our public repo, so nothing personal is sent.
    private func applyAttribution(to request: inout URLRequest) {
        guard endpoint.host?.contains("openrouter.ai") == true else { return }
        request.setValue("https://github.com/albertofettucini/Council", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Council", forHTTPHeaderField: "X-Title")
    }

    func validate(apiKey: String) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyAttribution(to: &request)
        // Smallest possible call: 1 output token. We only care about the HTTP status.
        request.httpBody = try JSONEncoder().encode(body([.init(role: "user", content: .text("Hi"))], cap: 1))
        let (data, response) = try await URLSession.shared.data(for: request)
        try KeyValidation.interpret(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    /// JSON-mode one-shot used for the divergence verdict — forces valid JSON so even a small local
    /// model (Ollama) returns a clean, parseable object instead of a dropped free-form line.
    /// Not every OpenAI-compatible provider supports `response_format` (some 400 on it) — on any
    /// failure we retry once WITHOUT it, since capable models follow the JSON instruction anyway.
    func judge(messages: [ChatMessage], apiKey: String) async throws -> String {
        do { return try await judgeOnce(messages, apiKey: apiKey, jsonMode: true) }
        catch {
            // Retry without JSON mode for the "provider doesn't support response_format" case (the
            // reason this two-attempt path exists). Fail fast on errors a no-JSON retry can't fix —
            // a 401/403/404 would just fail identically, doubling the latency of a doomed call.
            let m = error.localizedDescription.lowercased()
            if m.contains("401") || m.contains("403") || m.contains("404")
                || m.contains("unauthorized") || m.contains("not found") { throw error }
            return try await judgeOnce(messages, apiKey: apiKey, jsonMode: false)
        }
    }

    private func judgeOnce(_ messages: [ChatMessage], apiKey: String, jsonMode: Bool) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyAttribution(to: &request)
        request.httpBody = try verdictBody(for: messages, jsonMode: jsonMode)
        // One shot, so nothing arrives until the whole answer is ready, and a model that reasons
        // first can take longer than the default 60 seconds to get there.
        request.timeoutInterval = Self.verdictTimeoutSeconds
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.message(HTTPError.describe(http.statusCode, String(data: data, encoding: .utf8) ?? ""))
        }
        return Self.verdictText(in: data)
    }

    /// The JSON body of the one-shot verdict call. No I/O, so a test can read what would be sent.
    func verdictBody(for messages: [ChatMessage], jsonMode: Bool) throws -> Data {
        var body = body(messages.map { RequestBody.Message(role: $0.role.rawValue, content: .text($0.text)) },
                        cap: Self.verdictMaxTokens)
        body.response_format = jsonMode ? .init(type: "json_object") : nil
        return try JSONEncoder().encode(body)
    }

    /// The text of a one-shot response; empty when there is none.
    static func verdictText(in data: Data) -> String {
        (try? JSONDecoder().decode(JudgeResponse.self, from: data))?.choices.first?.message.content.text ?? ""
    }

    private struct JudgeResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Msg }
        struct Msg: Decodable { let content: AnswerText }
    }

    /// The JSON body of a streaming call. No I/O, so a test can read what would be sent.
    func streamBody(for messages: [ChatMessage]) throws -> Data {
        let wire: [RequestBody.Message] = messages.map { msg in
            if let image = msg.image, msg.role == .user {
                return RequestBody.Message(role: msg.role.rawValue, content: .parts([
                    Part(type: "text", text: msg.text),
                    Part(type: "image_url", image_url: .init(url: "data:\(image.mediaType);base64,\(image.base64)"))
                ]))
            }
            return RequestBody.Message(role: msg.role.rawValue, content: .text(msg.text))
        }
        // `stream_options` is an OpenAI extension. Send it only to hosts known to honor it
        // (so we still get usage from OpenAI / OpenRouter / Gemini); omit it for arbitrary
        // custom servers (llama.cpp / vLLM / LM Studio), some of which 400 on unknown fields
        // — which would abort the whole answer just to chase best-effort token counts.
        var body = body(wire, cap: maxTokens)
        body.stream = true
        body.stream_options = isKnownHost ? .init(include_usage: true) : nil
        body.temperature = isReasoningModel ? nil : temperature
        return try JSONEncoder().encode(body)
    }

    func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    applyAttribution(to: &request)
                    request.httpBody = try streamBody(for: messages)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line; if errBody.count > 1200 { break } }
                        throw LLMError.message(HTTPError.describe(http.statusCode, errBody))
                    }
                    var reader = EventReader(marksItsEnd: isKnownHost)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for chunk in reader.read(line) { continuation.yield(chunk) }
                        // A failure reported inside the stream must FAIL the call, as it does for
                        // Claude: otherwise the text so far would be saved as a whole answer.
                        if let message = reader.failure { throw LLMError.message(message) }
                        if reader.done { break }
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

    /// The hosted APIs above: they honor `stream_options`, and they always end a good stream with a
    /// finish reason or `[DONE]`. Arbitrary custom servers are promised neither.
    private var isKnownHost: Bool {
        guard let h = endpoint.host else { return false }
        return h.hasSuffix("openai.com") || h.hasSuffix("openrouter.ai") || h.hasSuffix("googleapis.com")
    }

    /// Reads `/chat/completions` server-sent events one line at a time and says what each line
    /// carries. No I/O, so a test can feed it recorded lines.
    struct EventReader {
        /// The host always marks its end (see `isKnownHost`), so a stream that just stops ended early.
        let marksItsEnd: Bool
        private var stopSent = false
        /// `[DONE]` arrived: the server ended the stream itself.
        private(set) var done = false
        /// The provider's own message when it reported a failure inside the stream (after an HTTP
        /// 200), in an event that carries an error and no choices.
        private(set) var failure: String?

        init(marksItsEnd: Bool) { self.marksItsEnd = marksItsEnd }

        /// The chunks one line carries.
        mutating func read(_ line: String) -> [StreamChunk] {
            // A comment line (": keep-alive", ": OPENROUTER PROCESSING") is the server saying it is
            // still working on the request.
            if line.hasPrefix(":") { return [.heartbeat] }
            guard line.hasPrefix("data:") else { return [] }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { done = true; return [] }
            guard let data = payload.data(using: .utf8),
                  let ev = try? JSONDecoder().decode(StreamEvent.self, from: data) else { return [] }
            // An error with no choices beside it is the server giving up partway. (OpenRouter sends
            // its error together with an "error" finish reason, which is read below instead.)
            if let error = ev.error, (ev.choices ?? []).isEmpty {
                failure = error.message
                return []
            }
            var out: [StreamChunk] = []
            if let c = ev.choices?.first?.delta?.content?.text, !c.isEmpty { out.append(.text(c)) }
            // Some servers send "" as the reason on every chunk until the last: that is no reason
            // yet, and taking it for one would hide the real "length" that follows.
            if let reason = ev.choices?.first?.finish_reason, !reason.isEmpty, !stopSent {
                stopSent = true
                out.append(.stop(Self.stopReason(reason)))
            }
            if let u = ev.usage {
                out.append(.usage(input: u.prompt_tokens ?? 0, output: u.completion_tokens ?? 0))
            }
            // An event with no answer text in it (the opening role chunk, a reasoning delta in its
            // own field) still proves the model is working. Reasoning models send many of these
            // before their first word.
            return out.isEmpty ? [.heartbeat] : out
        }

        /// The end signal once the lines run out, if no line gave one. A custom server that sends
        /// no reason gets no marker; a known host that went quiet without one ended early.
        func finish() -> [StreamChunk] {
            guard !stopSent else { return [] }
            return [.stop(done || !marksItsEnd ? .unknown : .endedEarly)]
        }

        static func stopReason(_ raw: String) -> StreamChunk.StopReason {
            switch raw {
            case "stop": return .finished
            // Mistral says "model_length" when the model's context length cut the response off.
            case "length", "max_tokens", "model_length": return .lengthLimit
            // OpenRouter reports a failure partway through as an "error" finish; DeepSeek says
            // "insufficient_system_resource" when it had to cut a response short.
            case "error", "insufficient_system_resource": return .endedEarly
            default: return .unknown   // content_filter, tool_calls…: nothing the engine can mark
            }
        }
    }

    private struct StreamEvent: Decodable {
        let choices: [Choice]?
        let usage: Usage?
        let error: StreamError?
        struct Choice: Decodable { let delta: Delta?; let finish_reason: String? }
        struct Delta: Decodable { let content: AnswerText? }
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
    }

    /// A failure a server reports inside the stream: `{"message": "…"}` or a bare string.
    private struct StreamError: Decodable {
        let message: String
        private enum Keys: String, CodingKey { case message }
        init(from decoder: Decoder) throws {
            if let c = try? decoder.container(keyedBy: Keys.self),
               let m = try? c.decode(String.self, forKey: .message), !m.isEmpty {
                message = m
            } else if let s = try? decoder.singleValueContainer().decode(String.self), !s.isEmpty {
                message = s
            } else {
                message = "The provider returned an error mid-stream."
            }
        }
    }

    /// The answer text in a `content` field. Almost always a plain string. Mistral's reasoning
    /// models send a list of parts instead while they think, and once more as the answer starts:
    /// the thinking parts are left out and the text parts kept, so the thinking never reaches the
    /// answer and the answer's first words are not lost with it. Anything else reads as no text
    /// rather than failing the whole event.
    struct AnswerText: Decodable {
        let text: String
        private struct Piece: Decodable { let type: String?; let text: String? }
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                text = s
            } else if let pieces = try? c.decode([Piece].self) {
                text = pieces.filter { $0.type == "text" }.compactMap(\.text).joined()
            } else {
                text = ""
            }
        }
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        var max_tokens: Int? = nil          // omitted when nil; set to 1 for validation
        var max_completion_tokens: Int? = nil   // the same cap, under the name OpenAI's own API takes
        var stream: Bool? = nil
        var stream_options: StreamOptions? = nil
        var temperature: Double? = nil
        var response_format: ResponseFormat? = nil
        struct Message: Encodable { let role: String; let content: Content }
        struct StreamOptions: Encodable { let include_usage: Bool }
        struct ResponseFormat: Encodable { let type: String }
    }

    /// Either a plain string (text-only) or an array of parts (with image).
    private enum Content: Encodable {
        case text(String)
        case parts([Part])
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s):   try c.encode(s)
            case .parts(let p):  try c.encode(p)
            }
        }
    }

    private struct Part: Encodable {
        let type: String
        var text: String? = nil
        var image_url: ImageURL? = nil      // nil fields are omitted by the synthesized encoder
    }

    private struct ImageURL: Encodable { let url: String }
}
