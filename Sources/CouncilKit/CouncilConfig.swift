import Foundation

/// A shareable council setup — the composition of a council WITHOUT any secrets. It captures
/// which provider/model sits in each seat, each seat's persona (system prompt) and sampling, the
/// shared prompt, and which seats synthesize / play devil's advocate. API keys are NEVER part of
/// this — they live only in the Keychain, per machine. Export → council.json → share → import.
public struct CouncilConfig: Codable, Identifiable {
    public var id = UUID()
    public var name: String
    public var detail: String?              // a one-line description (shown for presets)
    public var seats: [SeatConfig]
    public var sharedSystemPrompt: String
    /// Index into `seats` (0-based) of the synthesizer / devil's advocate. nil = none / default.
    public var synthesizerSeatIndex: Int?
    public var devilsAdvocateSeatIndex: Int?

    public struct SeatConfig: Codable {
        var provider: LLMProvider?    // nil = an intentionally-empty seat the importer fills in
        var model: String
        var systemPrompt: String?
        var temperature: Double?
        var maxTokens: Int?
    }

    /// Marker written into the file so we can sanity-check an import.
    public var schema: String = "council.v1"

    public enum CodingKeys: String, CodingKey {
        case id, name, detail, seats, sharedSystemPrompt
        case synthesizerSeatIndex, devilsAdvocateSeatIndex, schema
    }

    public init(id: UUID = UUID(), name: String, detail: String? = nil, seats: [SeatConfig],
         sharedSystemPrompt: String, synthesizerSeatIndex: Int? = nil,
         devilsAdvocateSeatIndex: Int? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.seats = seats
        self.sharedSystemPrompt = sharedSystemPrompt
        self.synthesizerSeatIndex = synthesizerSeatIndex
        self.devilsAdvocateSeatIndex = devilsAdvocateSeatIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Imported council"
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        seats = (try? c.decode([SeatConfig].self, forKey: .seats)) ?? []
        sharedSystemPrompt = (try? c.decode(String.self, forKey: .sharedSystemPrompt)) ?? ""
        synthesizerSeatIndex = try? c.decodeIfPresent(Int.self, forKey: .synthesizerSeatIndex)
        devilsAdvocateSeatIndex = try? c.decodeIfPresent(Int.self, forKey: .devilsAdvocateSeatIndex)
        schema = (try? c.decode(String.self, forKey: .schema)) ?? "council.v1"
    }
}

// MARK: - Bundled presets

extension CouncilConfig {
    /// One curated starting point. Models default to a strong trio; the importer keeps whatever
    /// keys it already has, and any seat can be re-picked afterward.
    public static let presets: [CouncilConfig] = [
        CouncilConfig(
            name: "Code Review Council",
            detail: "Three engineers review your code from different angles.",
            seats: [
                .init(provider: .claude, model: LLMProvider.claude.defaultModel,
                      systemPrompt: "You are a senior engineer reviewing code for correctness and edge cases. Point out concrete bugs, race conditions, and failure modes. Cite the exact line or construct. Be terse.",
                      temperature: 0.3, maxTokens: nil),
                .init(provider: .openAI, model: LLMProvider.openAI.defaultModel,
                      systemPrompt: "You are a staff engineer reviewing code for design, readability, and maintainability. Suggest simpler structures and call out over-engineering. Be pragmatic.",
                      temperature: 0.4, maxTokens: nil),
                .init(provider: .gemini, model: LLMProvider.gemini.defaultModel,
                      systemPrompt: "You are a security-minded reviewer. Look for injection, auth, data-leak, and dependency risks. Rank issues by real-world severity.",
                      temperature: 0.3, maxTokens: nil)
            ],
            sharedSystemPrompt: "Review the code the user shares. Be specific and honest; do not rubber-stamp.",
            synthesizerSeatIndex: 0),
        CouncilConfig(
            name: "Startup Red Team",
            detail: "A panel that stress-tests your idea instead of cheering it.",
            seats: [
                .init(provider: .claude, model: LLMProvider.claude.defaultModel,
                      systemPrompt: "You are a skeptical seed investor. Attack the business model: unit economics, moat, distribution. Ask the question that kills the deal.",
                      temperature: 0.7, maxTokens: nil),
                .init(provider: .grok, model: LLMProvider.grok.defaultModel,
                      systemPrompt: "You are a blunt operator who has shipped products. Poke holes in execution: timeline, hiring, who actually builds this. No hype.",
                      temperature: 0.8, maxTokens: nil),
                .init(provider: .openAI, model: LLMProvider.openAI.defaultModel,
                      systemPrompt: "You are a target customer who is hard to win. Explain why you wouldn't switch, what would make you, and what you'd pay.",
                      temperature: 0.7, maxTokens: nil)
            ],
            sharedSystemPrompt: "Pressure-test the user's startup idea. Be rigorous and specific, never flattering.",
            synthesizerSeatIndex: 0, devilsAdvocateSeatIndex: 1),
        CouncilConfig(
            name: "Devil's Advocate Panel",
            detail: "Every advisor argues against the emerging consensus.",
            seats: [
                .init(provider: .claude, model: LLMProvider.claude.defaultModel,
                      systemPrompt: "Steelman the opposite of whatever the user seems to believe, then argue it as strongly as you honestly can.",
                      temperature: 0.8, maxTokens: nil),
                .init(provider: .gemini, model: LLMProvider.gemini.defaultModel,
                      systemPrompt: "Find the strongest counter-evidence and the most likely way this goes wrong. Be specific about mechanisms.",
                      temperature: 0.8, maxTokens: nil),
                .init(provider: .openAI, model: LLMProvider.openAI.defaultModel,
                      systemPrompt: "Take the unpopular position. Surface the risks everyone is ignoring. Do not hedge.",
                      temperature: 0.8, maxTokens: nil)
            ],
            sharedSystemPrompt: "Challenge the user's thinking. Disagreement is the job; do not converge for comfort.",
            synthesizerSeatIndex: 0, devilsAdvocateSeatIndex: 0),
        CouncilConfig(
            name: "Socratic Tutor",
            detail: "Three teachers explain, then question, then check understanding.",
            seats: [
                .init(provider: .claude, model: LLMProvider.claude.defaultModel,
                      systemPrompt: "You are a patient tutor. Explain the concept from first principles with one vivid analogy. Then ask one question that checks understanding.",
                      temperature: 0.6, maxTokens: nil),
                .init(provider: .gemini, model: LLMProvider.gemini.defaultModel,
                      systemPrompt: "You are a rigorous tutor. Give the precise, technically-correct account and name the common misconception to avoid.",
                      temperature: 0.4, maxTokens: nil),
                .init(provider: .openAI, model: LLMProvider.openAI.defaultModel,
                      systemPrompt: "You are a Socratic guide. Don't give the answer outright — ask the sequence of questions that leads the learner to it.",
                      temperature: 0.7, maxTokens: nil)
            ],
            sharedSystemPrompt: "Help the user genuinely understand, not just get an answer.",
            synthesizerSeatIndex: 0)
    ]
}
