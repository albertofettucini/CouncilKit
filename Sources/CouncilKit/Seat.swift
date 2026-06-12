import Foundation

/// One seat at the council table. The provider is chosen by the user in the panel ("PICK YOUR
/// MODEL"); until then it is nil. The API key itself is not stored here — it lives in the
/// Keychain, addressed by `provider.keychainAccount`.
public struct Seat: Identifiable, Codable {
    public let id: Int
    public var archetype: Archetype
    /// nil = the user hasn't picked a model for this seat yet (panel shows "PICK YOUR MODEL").
    public var provider: LLMProvider?
    /// The model id this seat calls. Empty when no provider is picked.
    public var model: String
    /// Optional per-seat system prompt override. When nil/empty, the shared prompt is used.
    public var systemPrompt: String?
    /// Optional per-seat sampling parameters. nil = the provider's default.
    public var temperature: Double?
    public var maxTokens: Int?

    public init(id: Int, archetype: Archetype, provider: LLMProvider? = nil,
         model: String? = nil, systemPrompt: String? = nil) {
        self.id = id
        self.archetype = archetype
        self.provider = provider
        self.model = model ?? (provider?.defaultModel ?? "")
        self.systemPrompt = systemPrompt
    }

    // Backwards-compatible decoding: missing fields fall back to defaults instead of failing
    // to decode (which would wipe config).
    public enum CodingKeys: String, CodingKey { case id, archetype, provider, model, systemPrompt, temperature, maxTokens }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        archetype = (try? c.decode(Archetype.self, forKey: .archetype)) ?? .sage
        provider = try c.decodeIfPresent(LLMProvider.self, forKey: .provider)
        let savedModel = try c.decodeIfPresent(String.self, forKey: .model)
        model = (savedModel?.isEmpty == false) ? savedModel! : (provider?.defaultModel ?? "")
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
    }
}
