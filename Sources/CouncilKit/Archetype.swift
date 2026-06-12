import Foundation

/// A stable identifier carried by each seat. It originally drove per-persona prompts, but prompts
/// are now user-editable (shared + per-seat system prompts), so this is kept only for seat identity
/// and for Codable stability of already-saved seat configs.
public enum Archetype: String, CaseIterable, Identifiable, Codable {
    case sage
    case strategist
    case scientist

    public var id: String { rawValue }
}
