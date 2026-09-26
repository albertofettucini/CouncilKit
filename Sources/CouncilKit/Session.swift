import Foundation

/// One deliberation round: a question, each advisor's answer, their peer reviews, and the
/// (optional) divergence + synthesis generated for THIS round. Each round keeps its own
/// analyses, so asking a follow-up never wipes an earlier round's work.
public struct Round: Codable, Identifiable {
    public var id = UUID()
    public var question: String
    public var answers: [Int: String] = [:]
    public var peerReviews: [Int: String] = [:]
    public var divergence: String?
    public var synthesis: String?
    /// "Divergence verdict" the analyst computes in the SAME divergence call: how much the advisors
    /// agree on the bottom line (0–100), how many distinct camps, and which advisor is the outlier
    /// (a panel name, or nil). Measures agreement, NOT correctness — they can share a blind spot.
    public var divergenceScore: Int?
    public var divergenceCamps: Int?
    public var outlier: String?
    /// Seat id of the outlier, resolved at verdict time from the anonymous label — robust against
    /// label-case drift and duplicate providers (name matching alone can pick the wrong seat).
    public var outlierSeatID: Int?
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var costUSD: Double = 0
    /// Which provider produced each seat's answer (seat id → panel name), so a reopened session
    /// still shows "CLAUDE" on the panel even if that seat is currently unassigned.
    public var answerProviders: [Int: String] = [:]
    /// One-round "rebuttal" (bounded debate): each advisor's revised — or held — answer after seeing
    /// where the council diverged. Empty until the user runs the debate round. Persisted.
    public var rebuttals: [Int: String] = [:]
    /// True if this round's question carried an attached image or document.
    public var hadAttachment: Bool = false
    /// The attached DOCUMENT's text, kept so Regenerate (and any later re-run of this round) asks
    /// the model the same question it was asked the first time. Capped on the way in — see
    /// `CouncilLimits.maxStoredAttachmentCharacters`; beyond that the round keeps only the flag,
    /// exactly as every pre-1.2 round does. Images are still not persisted (they'd bloat sessions
    /// by megabytes), so an image round remains un-regenerable.
    public var attachedDocument: String? = nil
    /// Which answers deliberate (peer review → divergence → synthesis) in this round. nil = all of
    /// them (the default, and every pre-1.2 session). May include `guestSeatID`.
    public var includedSeatIDs: [Int]? = nil
    /// The neutral chair's post-debate summary, when a chair is configured. nil otherwise.
    public var chairSummary: String? = nil
    /// Which provider actually chaired this round — the Settings chair can change afterwards, and
    /// a summary must keep naming the model that wrote it.
    public var chairProvider: String? = nil

    /// Reserved seat id for a pasted GUEST answer (an external AI's answer joining the round as an
    /// anonymous advisor). Lives inside the ordinary `answers`/`answerProviders` dictionaries, so
    /// older builds decode these sessions unchanged — they just don't display the guest. Real seats
    /// are 0–2; -1 is the devil's-advocate "none" sentinel; 1000 is the chair.
    public static let guestSeatID = 99

    /// The pasted guest answer for this round, if any.
    public var guestAnswer: String? { answers[Round.guestSeatID].flatMap { $0.isEmpty ? nil : $0 } }
    /// The guest's display name (user-supplied, shown only AFTER blind deliberation) — "Guest" default.
    public var guestName: String { answerProviders[Round.guestSeatID] ?? "Guest" }

    /// Seat ids that have a non-empty answer in this round.
    public var answeredSeatIDs: Set<Int> { Set(answers.filter { !$0.value.isEmpty }.keys) }

    public enum CodingKeys: String, CodingKey {
        case id, question, answers, peerReviews, divergence, synthesis
        case inputTokens, outputTokens, costUSD, answerProviders
        case divergenceScore, divergenceCamps, outlier, outlierSeatID, rebuttals, hadAttachment
        case includedSeatIDs, chairSummary, chairProvider, attachedDocument
    }
    public init(question: String) { self.question = question }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        question = (try? c.decode(String.self, forKey: .question)) ?? ""
        answers = (try? c.decode([Int: String].self, forKey: .answers)) ?? [:]
        peerReviews = (try? c.decode([Int: String].self, forKey: .peerReviews)) ?? [:]
        divergence = try? c.decodeIfPresent(String.self, forKey: .divergence)
        synthesis = try? c.decodeIfPresent(String.self, forKey: .synthesis)
        inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? 0
        outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? 0
        costUSD = (try? c.decode(Double.self, forKey: .costUSD)) ?? 0
        answerProviders = (try? c.decode([Int: String].self, forKey: .answerProviders)) ?? [:]
        divergenceScore = try? c.decodeIfPresent(Int.self, forKey: .divergenceScore)
        divergenceCamps = try? c.decodeIfPresent(Int.self, forKey: .divergenceCamps)
        outlier = try? c.decodeIfPresent(String.self, forKey: .outlier)
        outlierSeatID = try? c.decodeIfPresent(Int.self, forKey: .outlierSeatID)
        rebuttals = (try? c.decode([Int: String].self, forKey: .rebuttals)) ?? [:]
        hadAttachment = (try? c.decode(Bool.self, forKey: .hadAttachment)) ?? false
        includedSeatIDs = try? c.decodeIfPresent([Int].self, forKey: .includedSeatIDs)
        chairSummary = try? c.decodeIfPresent(String.self, forKey: .chairSummary)
        chairProvider = try? c.decodeIfPresent(String.self, forKey: .chairProvider)
        attachedDocument = try? c.decodeIfPresent(String.self, forKey: .attachedDocument)
    }
}

/// A saved council session — a list of rounds plus each seat's conversation context. Stored
/// locally as one JSON file per session in the app container. No server, no cloud.
public struct Session: Codable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var rounds: [Round]
    public var history: [Int: [ChatMessage]]
    /// Decision journal (local-only): what the user actually chose after consulting this council, and
    /// later how it turned out. Optional → older saved sessions decode fine (synthesized Codable).
    public var decision: String? = nil
    public var decisionAt: Date? = nil
    public var outcome: String? = nil
    public var outcomeAt: Date? = nil
    /// Outcome reminder: nudge the user to record how the decision turned out once this date passes.
    /// Mirrored into a local macOS notification when permitted (see ReminderNotifications.swift);
    /// the in-app "outcome due" list works either way. Cleared when the outcome is logged.
    public var remindAt: Date? = nil
    /// Set when this decision was written into Engram (the maker's local memory app) — flips the
    /// journal button to its "remembered" state and lets a later outcome supersede the memory.
    public var engramMemoryID: UUID? = nil
    public var engramRememberedAt: Date? = nil

    /// Text used for searching this session (title + every question + every answer + the journal).
    public var searchHaystack: String {
        var s = title
        for r in rounds {
            s += " " + r.question
            for a in r.answers.values { s += " " + a }
        }
        if let d = decision { s += " " + d }
        if let o = outcome { s += " " + o }
        return s.lowercased()
    }

    public var totalCostUSD: Double { rounds.reduce(0) { $0 + $1.costUSD } }
}
