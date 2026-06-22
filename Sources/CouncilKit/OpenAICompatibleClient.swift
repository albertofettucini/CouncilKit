import Foundation

/// Talks to any OpenAI-style `/chat/completions` endpoint. Used for both
/// GPT (api.openai.com) and Gemini (Google's OpenAI-compatible endpoint).
struct OpenAICompatibleClient: LLMClient {
    let endpoint: URL
    let model: String
    var temperature: Double? = nil
    var maxTokens: Int? = nil

    /// Reasoning models (OpenAI o-series, DeepSeek R1, any "…-reasoning" variant) reject a custom
    /// `temperature` — they only run at their fixed setting, and sending one 400s the whole call.
    /// Detect them by id so we silently drop the override instead of failing the request.
    private var isReasoningModel: Bool {
        let name = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        if name.contains("reason") { return true }                      // deepseek-reasoner, sonar-reasoning, grok-…-reasoning
        if let f = name.first, f == "o", name.dropFirst().first?.isNumber == true { return true }  // o1 / o3 / o4-mini …
        return false
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
        let body = RequestBody(model: model,
                               messages: [.init(role: "user", content: .text("Hi"))],
                               max_tokens: 1)
        request.httpBody = try JSONEncoder().encode(body)
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
        let wire = messages.map { RequestBody.Message(role: $0.role.rawValue, content: .text($0.text)) }
        let body = RequestBody(model: model, messages: wire, max_tokens: 400,
                               response_format: jsonMode ? .init(type: "json_object") : nil)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.message(HTTPError.describe(http.statusCode, String(data: data, encoding: .utf8) ?? ""))
        }
        return (try? JSONDecoder().decode(JudgeResponse.self, from: data))?.choices.first?.message.content ?? ""
    }

    private struct JudgeResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Msg }
        struct Msg: Decodable { let content: String }
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
                    let knownUsageHost: Bool = {
                        guard let h = endpoint.host else { return false }
                        return h.hasSuffix("openai.com") || h.hasSuffix("openrouter.ai") || h.hasSuffix("googleapis.com")
                    }()
                    let body = RequestBody(model: model, messages: wire, max_tokens: maxTokens, stream: true,
                                           stream_options: knownUsageHost ? .init(include_usage: true) : nil,
                                           temperature: isReasoningModel ? nil : temperature)
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line; if errBody.count > 1200 { break } }
                        throw LLMError.message(HTTPError.describe(http.statusCode, errBody))
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let ev = try? JSONDecoder().decode(StreamEvent.self, from: data) else { continue }
                        if let c = ev.choices?.first?.delta?.content, !c.isEmpty { continuation.yield(.text(c)) }
                        if let u = ev.usage {
                            continuation.yield(.usage(input: u.prompt_tokens ?? 0, output: u.completion_tokens ?? 0))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct StreamEvent: Decodable {
        let choices: [Choice]?
        let usage: Usage?
        struct Choice: Decodable { let delta: Delta? }
        struct Delta: Decodable { let content: String? }
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        var max_tokens: Int? = nil          // omitted when nil; set to 1 for validation
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
