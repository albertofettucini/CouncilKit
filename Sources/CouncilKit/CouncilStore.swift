import Foundation
import Observation
import AppKit
import UserNotifications

/// Per-seat live state (applies to the round currently being generated).
public enum SeatStatus: Equatable { case idle, loading, failed(String) }

/// Result of a "test connection" probe against a local/self-hosted endpoint (Settings → Models).
public enum EndpointTestResult: Equatable { case ok(Int); case failed(String) }

/// Shared engine limits, owned here so every surface (app, CLI, future MCP) enforces the same rule.
public enum CouncilLimits {
    /// Conservative cap for an attached document, in characters (~25k tokens). Past this, surfaces
    /// must REJECT with a clear error — never silently truncate.
    public static let maxDocumentCharacters = 100_000
    /// nil if the document is within the cap, else a clear, specific error message.
    public static func documentError(_ text: String) -> String? {
        let n = text.count
        guard n > maxDocumentCharacters else { return nil }
        return "Document is \(n) characters — the limit is \(maxDocumentCharacters). Trim it or paste a smaller excerpt."
    }
    /// Same cap for a pasted GUEST answer (it rides in every reviewer's context like a document).
    public static func guestError(_ text: String) -> String? {
        let n = text.count
        guard n > maxDocumentCharacters else { return nil }
        return "The guest answer is \(n) characters — the limit is \(maxDocumentCharacters). Trim it or paste the part that matters."
    }

    /// How long a seat may produce NOTHING before the council gives up on it and finishes the round
    /// without it. This is a STALL limit, not a total-duration cap: a genuinely slow model that
    /// keeps streaming is never cut off, however long it takes. It exists because one wedged
    /// backend (a local server that accepted the connection and went quiet, a dead tunnel) used to
    /// hold every other advisor's finished answer hostage indefinitely.
    ///
    /// The default is generous on purpose — a cold local model can take a while to load before its
    /// first token — but it is settable for tighter environments (CI).
    public static var stallTimeoutSeconds: Double = 90

    /// How long a seat may show signs of life without adding a word to its answer before the
    /// council stops waiting for it. A model that thinks first sends pings and thinking events,
    /// and those keep the stall limit above from firing; this is the bound for one that never
    /// gets to the answer (a queue that only sends keep-alives, a server that pings forever).
    /// Without it such a seat would hold the round until someone pressed Stop, and the CLI has no
    /// Stop. Ten minutes is far longer than a model needs to start answering a council question.
    public static var thinkingTimeoutSeconds: Double = 600

    /// How much of an attached document a round keeps so it can be re-asked identically. Sessions
    /// are plain JSON on disk and every save re-encodes the whole thing, so a 100k-character
    /// document in every round would make history heavy; past this size the round keeps only the
    /// fact that there WAS an attachment and Regenerate stays disabled, as before.
    public static let maxStoredAttachmentCharacters = 20_000
}

/// A pasted external answer (e.g. copied from ChatGPT or Gemini on the web) joining a round as an
/// anonymous advisor: it is blind-reviewed by the real seats, counts in divergence/camps/outlier,
/// and appears in synthesis/dissent — but it never generates anything itself. The optional `name`
/// is shown only AFTER deliberation (the reviewing models never see it).
public struct GuestAnswer: Sendable, Equatable {
    public var name: String?
    public var text: String
    public init(name: String? = nil, text: String) {
        self.name = name
        self.text = text
    }
}

/// Serializes the streaming pump's fire-and-forget UI flushes: at most ONE hop to the MainActor is
/// in flight per stream (extra ticks are dropped, not queued — a blocked main thread never builds a
/// backlog), and `waitUntilIdle` lets the caller order its authoritative final flush after any
/// stragglers.
actor FlushGate {
    private var busy = false
    func tryEnter() -> Bool { if busy { return false }; busy = true; return true }
    func leave() { busy = false }
    func waitUntilIdle() async { while busy { await Task.yield() } }
}

/// Liveness clocks for one streaming call, so a watchdog can tell "slow" from "hung". Every chunk
/// touches the first, and the watchdog fires when nothing at all has arrived for the stall limit.
/// Only a chunk that moves the answer on (text, usage, an end signal) touches the second, so a
/// call that sends signs of life and nothing else is still bounded, by the thinking limit.
actor StreamLiveness {
    private var last = DispatchTime.now().uptimeNanoseconds
    private var lastProgress = DispatchTime.now().uptimeNanoseconds
    private(set) var timedOut = false
    /// The watchdog fired on the thinking limit: signs of life kept coming, the answer did not.
    private(set) var stillWorking = false
    func touch(progress: Bool) {
        last = DispatchTime.now().uptimeNanoseconds
        if progress { lastProgress = last }
    }
    func idleNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds &- last }
    func stuckNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds &- lastProgress }
    func markTimedOut(stillWorking: Bool = false) { timedOut = true; self.stillWorking = stillWorking }
}

/// What one stream attempt produced. Sendable, so the pump can run as its own task and be raced
/// against the stall watchdog; failures are pre-classified because the raw `Error` is not Sendable
/// and the caller only ever needed the classification.
struct PumpOutcome: Sendable {
    var text = ""
    var input = 0
    var output = 0
    var failure: PumpFailure?
    /// Why the provider said the response ended; nil when it said nothing before the stream ended.
    /// `.lengthLimit` with no failure is a cut-off answer: the text is kept, it is not an error.
    var stop: StreamChunk.StopReason?
}

enum PumpFailure: Sendable {
    case cancelled              // the user pressed Stop — keep whatever streamed, no error
    case stalled(String)        // went quiet, or the stream ended early; do NOT retry a wedged backend
    case transient(String)      // a connection blip — worth exactly one automatic retry
    case permanent(String)
}

/// Central app state. A session is a list of `Round`s; each round keeps its own answers,
/// peer reviews, divergence and synthesis. The user navigates rounds; nothing is wiped.
@MainActor
@Observable
public final class CouncilStore {
    public var seats: [Seat]
    public var status: [Int: SeatStatus] = [:]
    /// Live streaming text per seat for the round being generated. Token writes land HERE, not in
    /// `rounds`, so a ~30fps stream doesn't invalidate every view that reads `rounds` (round navigator,
    /// dashboard, cost line…) — only the panels, which read it via `viewedAnswer`. Committed to
    /// `rounds[idx].answers` in finishAnswer.
    public var liveAnswers: [Int: String] = [:]
    /// Live streaming buffers for the DELIBERATION stages, mirroring `liveAnswers`: partial text
    /// lands here (RAW — de-anonymized only once, at commit), so a token tick doesn't mutate
    /// `rounds` and invalidate every rounds-reader in both windows ~30×/sec. Committed into the
    /// round in each stage's finish block, then cleared.
    public var livePeerReviews: [Int: String] = [:]
    public var liveRebuttals: [Int: String] = [:]
    public var liveDivergence: String?
    public var liveSynthesis: String?
    public var liveChairSummary: String?
    /// All rounds in the current session, oldest → newest.
    public var rounds: [Round] = []
    /// Which round the UI is showing (analyses + answers are read from this round).
    public var viewingRound = 0
    /// True while a divergence/synthesis round is running.
    public var deliberationBusy = false
    /// CLI `--no-save`: when false, finished sessions are not written to disk. Always true in the app.
    public var persistenceEnabled = true
    /// Human-readable stage the auto-pipeline is generating right now (nil = idle).
    /// Drives the flow page's quiet inline progress hint.
    public var pipelineStage: String?
    /// Which round index is currently generating answers/peer-reviews (nil = none). The panel
    /// spinner keys off this so it shows on the round actually working, not just the latest.
    public var generatingRound: Int?
    /// Transient (NEVER persisted) error from the last divergence / synthesis attempt. We never
    /// write an error string into a round's content — a failed network call must not become
    /// permanent "analysis" saved to disk. Shown briefly in the canvas, cleared on retry/nav.
    public var divergenceError: String?
    public var synthesisError: String?
    /// Same contract for the chair's post-debate summary: a failed call must be visible, not a
    /// silently missing card after the UI promised "+1 chair summary".
    public var chairError: String?
    /// Same contract for peer review and the debate, one line per seat whose review (or final take)
    /// didn't finish: it is never saved, and the seat's ANSWER keeps its own status — a review that
    /// failed is not an answer that failed.
    public var peerReviewError: String?
    public var rebuttalError: String?
    /// Bumped whenever a key is saved; refreshes the key cache so views re-evaluate `hasKey`.
    public var keyRevision = 0 { didSet { refreshKeyCache() } }
    /// True when macOS notifications are switched off for Council — the journal card shows a hint
    /// and the in-app "outcome due" list carries the reminder instead. Updated on every sync.
    public var reminderNotificationsDenied = false
    /// Set when the user clicks an outcome-reminder notification; the journal view consumes it (and
    /// clears it) when it appears — so a click still lands when no window was open at the time.
    public var pendingReminderSession: UUID? = nil
    /// Cached set of providers that currently have a key — so `hasKey`/`keyExists` never hit the
    /// Keychain from a view body (12 synchronous Keychain reads per render = the scroll jank).
    /// Rebuilt only when a key actually changes, not on every render.
    private(set) var keyCache: Set<LLMProvider> = []
    public func refreshKeyCache() {
        var s: Set<LLMProvider> = []
        for p in LLMProvider.allCases where p.requiresAPIKey {
            if let k = (try? KeychainStore.read(account: p.keychainAccount)) ?? nil, !k.isEmpty { s.insert(p) }
        }
        keyCache = s
    }

    /// Live model lists fetched per provider: Ollama's installed models (/api/tags), OpenRouter's
    /// public catalogue (/models), and any keyed provider's accessible models (/models with the key).
    /// Drives the picker so it offers what the user can actually use; empty for a provider falls back
    /// to that provider's fixed suggestion list.
    public var providerModels: [LLMProvider: [String]] = [:]

    public func refreshModels(for provider: LLMProvider) async {
        guard let url = provider.modelsEndpoint else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        // Ollama + custom servers need no auth; OpenRouter's list is public (send a key only if we
        // have one); every other keyed provider needs its key to list what it can actually reach.
        switch provider {
        case .ollama, .custom1, .custom2:
            break
        case .claude:
            guard let k = storedKey(for: provider) else { return }
            req.setValue(k, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openRouter:
            if let k = storedKey(for: provider) { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        default:
            guard let k = storedKey(for: provider) else { return }
            req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let ids = Self.parseModelList(data)
            if !ids.isEmpty, ids != providerModels[provider] { providerModels[provider] = ids }
        } catch {
            // Unreachable / no key — keep whatever we have; the picker falls back to suggestions.
        }
    }

    /// Explicit "test connection" for a local/self-hosted endpoint (Ollama or a custom slot —
    /// Settings → Models). Unlike refreshModels, it reports a result the UI can show, and on
    /// success seeds providerModels so the picker immediately shows the server's real models.
    public func testEndpoint(for provider: LLMProvider) async -> EndpointTestResult {
        guard let url = provider.modelsEndpoint else { return .failed("Set a valid URL first.") }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed("No response from that address.") }
            guard http.statusCode == 200 else { return .failed("Reached it, but it returned HTTP \(http.statusCode).") }
            let ids = Self.parseModelList(data)
            if !ids.isEmpty { providerModels[provider] = ids }
            return .ok(ids.count)
        } catch {
            let host = provider.customSlot.map(LLMProvider.customHost) ?? LLMProvider.ollamaHost
            return .failed("Couldn't reach \(host) — is the server running and reachable from this Mac?")
        }
    }

    private func storedKey(for provider: LLMProvider) -> String? {
        guard let k = (try? KeychainStore.read(account: provider.keychainAccount)) ?? nil, !k.isEmpty else { return nil }
        return k
    }

    /// Both shapes we encounter: OpenAI-style `{"data":[{"id":…}]}` and Ollama `{"models":[{"name":…}]}`.
    private static func parseModelList(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let arr = obj["data"] as? [[String: Any]] { return arr.compactMap { $0["id"] as? String }.sorted() }
        if let arr = obj["models"] as? [[String: Any]] { return arr.compactMap { $0["name"] as? String }.sorted() }
        return []
    }

    /// Full per-seat conversation (user/assistant turns, no system). Replayed on Round 1 calls
    /// so each model has its own prior context across rounds.
    private var history: [Int: [ChatMessage]] = [:]

    /// Shared Round-1 system prompt — the "advisor" instruction, user-editable. A seat can
    /// override it (see `Seat.systemPrompt`). Persisted in UserDefaults (non-sensitive).
    public var sharedSystemPrompt: String = CouncilStore.defaultSystemPrompt {
        didSet { guard persistenceEnabled else { return }; UserDefaults.standard.set(sharedSystemPrompt, forKey: Self.promptKey) }
    }

    /// Which seat generates divergence + synthesis (and so spends that provider's credit). Persisted.
    public var synthesizerSeatID: Int = 0 {
        didSet { guard persistenceEnabled else { return }; UserDefaults.standard.set(synthesizerSeatID, forKey: Self.synthKey) }
    }

    /// Which seat (if any) plays devil's advocate — in peer review it steelmans then attacks the
    /// emerging consensus instead of looking for agreement. -1 = none. Persisted.
    public var devilsAdvocateSeatID: Int = -1 {
        didSet { guard persistenceEnabled else { return }; UserDefaults.standard.set(devilsAdvocateSeatID, forKey: Self.devilKey) }
    }

    /// Optional NEUTRAL CHAIR: a fourth, out-of-band seat that runs divergence + verdict + synthesis
    /// (and a short post-debate summary) but never answers the question — structural neutrality
    /// instead of one advisor grading a debate it argued in. nil = an advisor synthesizes (the
    /// default; behavior is byte-for-byte pre-chair). Persisted.
    public var chairSeat: Seat? = nil {
        didSet {
            guard persistenceEnabled else { return }
            if let c = chairSeat, let data = try? JSONEncoder().encode(c) {
                UserDefaults.standard.set(data, forKey: Self.chairKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.chairKey)
            }
        }
    }

    /// The Council app's own bundle id — the one process allowed to turn off macOS Keychain dialogs
    /// process-wide (see KeychainStore.suppressSystemPrompts), and the one that reads the saved
    /// history at construction (see `init(loadHistory:)`).
    static let appBundleID = "com.joseph.Council"

    /// Whether a store built without an explicit `loadHistory` reads the saved history: only in the
    /// Council app itself. An exact match, because "has a bundle id" is not enough: the test runner,
    /// a fork and any app embedding CouncilKit all have one.
    static func loadsHistoryAutomatically(bundleID: String?) -> Bool {
        bundleID == appBundleID
    }

    /// Test seam: the bundle id the history gate sees instead of the running process's, so a test
    /// can stand in for the app (or a foreign host) without being one. Internal, and never set
    /// outside the test target. Nothing else reads it: Keychain handling still sees the real id.
    static var hostBundleIDForTesting: String?

    private let seatsKey = "council.seats.v7"   // v7: ship default divergence personas
    private static let promptKey = "council.systemPrompt"
    private static let synthKey = "council.synthesizerSeat"
    private static let devilKey = "council.devilsAdvocate"
    private static let chairKey = "council.chairSeat"
    public static let defaultSystemPrompt =
        "You are one of several AI advisors on a council. Answer the user's question directly, clearly, and concisely, in your own voice. Be honest; never flatter."

    /// Default per-seat personas. Three GENERAL-PURPOSE lenses (not domain-specific) so the council
    /// genuinely diverges on any non-trivial question out of the box — each still gives a complete
    /// answer, just from a different angle. Users can edit or clear these in Settings.
    public static let personaAnalyst = """
    You are the analyst on a council of advisors. Reason from first principles: name the core \
    variables, state your assumptions, and show the logic that leads to your answer. Give a \
    complete, well-structured answer to the user's question, and be honest about tradeoffs and \
    uncertainty — if the real answer is "it depends," say exactly what it depends on. Don't hedge \
    to sound agreeable. Be concise and in your own voice.
    """
    public static let personaPractitioner = """
    You are the practitioner on a council of advisors. Answer from real-world experience: what \
    actually happens in practice, the second-order effects, the practical constraints, and what \
    most people get wrong. Give a complete, decisive answer to the user's question, grounded in how \
    this plays out for real, and prefer concrete specifics over abstractions. Be concise and in \
    your own voice; no flattery.
    """
    public static let personaSkeptic = """
    You are the skeptic on a council of advisors. Challenge the easy answer: question the framing, \
    surface the strongest counter-case, and name the risks and failure modes the others will likely \
    miss. Still give a complete answer to the user's question — take the position you actually find \
    most defensible, even if it's unpopular — but make the costs and downsides explicit. Be specific \
    and intellectually honest, never contrarian just for show. Concise, in your own voice.
    """

    static let peerReviewPrompt = """
    You are one of several AI advisors on a council and you have already given your own answer. \
    Below are the other advisors' answers to the same question, anonymized. Review them critically: \
    state clearly where you AGREE and where you DISAGREE, and why. If one of them changed your mind, \
    say so and refine your view. If you still disagree, hold your ground and explain — do NOT cave to \
    consensus just to agree. Be concise, honest, and in your own voice.
    """

    static let adversaryReviewPrompt = """
    You are the council's Devil's Advocate. Your job is NOT to find agreement — it is to stress-test \
    the emerging consensus. First steelman the position the other advisors seem to share: state it in \
    its strongest, fairest form. Then attack it — surface the strongest objections, the overlooked \
    risks, the failure modes, and the best case for the opposite conclusion. Be specific and \
    intellectually honest: if the consensus genuinely survives scrutiny, say exactly what would have \
    to be true for it to be wrong. Do NOT soften your critique just to be agreeable.
    """

    static let divergencePrompt = """
    You are the council's analyst. You are given the advisors' answers to a question. Map the \
    deliberation in two clearly-headed markdown sections: "## Agreement" (points most or all advisors \
    share) and "## Divergence" (where they disagree — name which advisor holds which view, and why). \
    Be specific and concise. Do NOT pick a winner; just map the landscape honestly.
    """

    /// Sentinel that separates the readable divergence map from its machine-readable verdict when
    /// both come from one call. Chosen to be something no model would produce on its own, and
    /// stripped from the text before it is ever shown or saved.
    nonisolated static let verdictSentinel = "<<<COUNCIL_VERDICT>>>"

    /// Divergence + verdict in ONE call, for backends that can be trusted to keep a strict tail
    /// (see `LLMProvider.supportsMergedVerdict`). Same narrative contract as `divergencePrompt`,
    /// plus the JSON `verdictPrompt` would otherwise ask for in a second pass over the same context.
    static let divergenceWithVerdictPrompt = """
    You are the council's analyst. You are given the advisors' answers to a question. Map the \
    deliberation in two clearly-headed markdown sections: "## Agreement" (points most or all advisors \
    share) and "## Divergence" (where they disagree — name which advisor holds which view, and why). \
    Be specific and concise. Do NOT pick a winner; just map the landscape honestly.

    Then, after the markdown and NOTHING after it, output the line \(verdictSentinel) on its own, \
    followed by a single JSON object and nothing else:
    {"agreement": <integer 0-100, how much they agree on the bottom-line conclusion>, "camps": <integer number of distinct positions>, "outlier": <the single advisor label most apart, e.g. "Advisor B", or null>}
    Agreement measures consensus, not correctness.
    """

    /// Tiny structured-verdict prompt, run as a SEPARATE json-mode call (reliable even on small local
    /// models) so the score never depends on a free-form line the model might drop.
    static let verdictPrompt = """
    You are a meticulous judge. Given the advisors' answers, output ONLY a JSON object and nothing else:
    {"agreement": <integer 0-100, how much they agree on the bottom-line conclusion>, "camps": <integer number of distinct positions>, "outlier": <the single advisor label most apart, e.g. "Advisor B", or null>}
    Agreement measures consensus, not correctness.
    """

    static let synthesisPrompt = """
    You are the council's synthesizer. Given the advisors' answers, produce a final synthesis in \
    markdown with three parts: first a section "## What the council settled" — the points the \
    advisors genuinely share, naming who agrees on each (if nothing is settled, say so); then a \
    section "## What you still have to decide" — the open trade-offs the answers leave to the human, \
    and the strongest dissent; then a section "## Where they diverged" that explicitly preserves the \
    dissent — note where advisors disagreed and why, without flattening it into false consensus. Do \
    not pick a winner or add a recommendation of your own. Write out every advisor's label in full, \
    even in a list ("Advisor A and Advisor B", never "Advisors A and B"). The human decides: give \
    them a clear map, not a command.
    """

    static let chairSummaryPrompt = """
    You are the council's neutral chair. You did not answer the question yourself and you hold no \
    position. Given the advisors' original answers and their final takes after debate, write a short \
    neutral map of the debate in markdown: who moved and why, who held and why, and which single \
    disagreement remains most load-bearing for the decision. Refer to advisors by the names used in \
    the transcript. Do NOT pick a winner and do NOT add your own answer — you are the chair, not an \
    advisor. Be concise.
    """

    // MARK: Stage request templates
    //
    // The user-message text each stage wraps around its live inputs. It lives here, next to the
    // stage briefs, so every fixed word the engine sends to a model is in one place, and in the
    // prompt catalog below.

    /// The question a round records when the user typed none and attached only a document or an image.
    static let documentOnlyQuestion = "Analyze the attached document."
    static let imageOnlyQuestion = "Describe and assess this image."

    /// A question with its attached document folded in, as every seat receives it. The round itself
    /// saves only the question.
    static func documentPrompt(_ question: String, document: String) -> String {
        "\(question)\n\n--- ATTACHED DOCUMENT ---\n\n\(document)"
    }

    /// What a peer review can show of the attachment the round's answers were written with.
    enum ReviewAttachment {
        /// No attachment in this round or any earlier one.
        case none
        /// The round's own kept document (see `CouncilLimits.maxStoredAttachmentCharacters`).
        case document(String)
        /// The round had an attachment Council didn't keep: an image, or a document over the limit.
        case notKept
        /// The round has no attachment, but an earlier round in the session did.
        case notInThisRound
    }

    /// A reviewer's system message: the seat's own persona, then the review brief. The brief goes
    /// last so the stage instruction wins where the two pull apart.
    static func reviewerSystemPrompt(persona: String, brief: String) -> String {
        "\(persona)\n\n\(brief)"
    }

    /// Peer review: the question as the council was asked it, with the round's document (or a
    /// plain note when the reviewer can't see an attachment the answers had, or had in an earlier
    /// round), then the reviewer's own answer and the other positions, anonymized.
    static func peerReviewRequest(question: String, attachment: ReviewAttachment,
                                  ownAnswer: String, others: String) -> String {
        let asked: String
        switch attachment {
        case .none:
            asked = question
        case .document(let document):
            // Same fold as the answers got. The answers follow, so the document's end is marked.
            asked = documentPrompt(question, document: document) + "\n\n--- END OF DOCUMENT ---"
        case .notKept:
            asked = question + "\n\nNote: the advisors answered with an attachment (an image or a long "
                + "document) that is not included here, so don't assume what it contains."
        case .notInThisRound:
            asked = question + "\n\nNote: a document or image attached to an earlier question is not in "
                + "this round. The advisors answered without it and it is not included here, so don't "
                + "assume what it contains."
        }
        return """
        The council was asked:

        \(asked)

        Your own answer was:

        \(ownAnswer)

        The other advisors answered the same question as follows:

        \(others)

        Review their answers: where do you agree, where do you disagree, and would you refine your own answer? Be specific.
        """
    }

    /// The debate round: the question, the seat's own answer, and where the others landed.
    static func rebuttalRequest(question: String, ownAnswer: String, others: String) -> String {
        """
        The council was asked:

        \(question)

        Your earlier answer:

        \(ownAnswer)

        Here is where the other advisors landed (anonymized):

        \(others)

        Reconsider in light of the disagreement. If another position exposes a real weakness in \
        yours, revise — and say what changed and why. If you still hold your position, say so and \
        give the strongest reason it survives the critique. Be decisive; this is your final take.
        """
    }

    /// What divergence, its verdict and synthesis all read: the question and every position, anonymized.
    static func analysisRequest(question: String, answers: String) -> String {
        "Question:\n\(question)\n\nThe advisors' answers (anonymized):\n\n\(answers)"
    }

    /// One advisor's part of the debate transcript the chair reads, under its real name. A nil
    /// `finalTake` means it took no part in the debate round.
    static func chairDebateBlock(name: String, firstSaid: String, finalTake: String?) -> String {
        var b = "\(name) first said:\n\(firstSaid)"
        if let finalTake {
            b += "\n\n\(name)'s final take after debate:\n\(finalTake)"
        } else {
            // Never let silence read as "held its position": the guest is a static paste and a
            // seat may simply have failed. Say which it is, and the prompt forbids guessing.
            b += "\n\n\(name) did not take part in the debate round, so it has no final take."
        }
        return b
    }

    /// The chair's request: the question, then every advisor's block.
    static func chairSummaryRequest(question: String, blocks: [String]) -> String {
        "The council was asked:\n\(question)\n\nThe debate:\n\n\(blocks.joined(separator: "\n\n---\n\n"))"
    }

    /// Every fixed text the engine sends to a model, by name: the default advisor prompt and
    /// personas, the facade's devil's advocate, the stage briefs, the verdict sentinel, and the
    /// request templates above, rendered with {placeholders} where live text goes. The tests pin a
    /// SHA-256 of each entry for the current `CouncilKit.promptVersion`, plus the full transcript of
    /// a scripted round (which also covers the blind-label blocks and how each stage assembles its
    /// messages). Change any of this text and the version moves with it.
    static var promptCatalog: [(name: String, text: String)] {
        [
            ("defaultSystemPrompt", defaultSystemPrompt),
            ("personaAnalyst", personaAnalyst),
            ("personaPractitioner", personaPractitioner),
            ("personaSkeptic", personaSkeptic),
            ("facadeDevilsAdvocatePersona", Persona.devilsAdvocatePrompt),
            ("peerReviewPrompt", peerReviewPrompt),
            ("adversaryReviewPrompt", adversaryReviewPrompt),
            ("divergencePrompt", divergencePrompt),
            ("divergenceWithVerdictPrompt", divergenceWithVerdictPrompt),
            ("verdictPrompt", verdictPrompt),
            ("verdictSentinel", verdictSentinel),
            ("synthesisPrompt", synthesisPrompt),
            ("chairSummaryPrompt", chairSummaryPrompt),
            ("documentOnlyQuestion", documentOnlyQuestion),
            ("imageOnlyQuestion", imageOnlyQuestion),
            ("documentPrompt", documentPrompt("{question}", document: "{document}")),
            ("reviewerSystemPrompt", reviewerSystemPrompt(persona: "{persona}", brief: "{review brief}")),
            ("peerReviewRequest", peerReviewRequest(question: "{question}", attachment: .none,
                                                    ownAnswer: "{own answer}", others: "{other answers}")),
            ("peerReviewRequestWithDocument", peerReviewRequest(question: "{question}", attachment: .document("{document}"),
                                                                ownAnswer: "{own answer}", others: "{other answers}")),
            ("peerReviewRequestAttachmentNotKept", peerReviewRequest(question: "{question}", attachment: .notKept,
                                                                     ownAnswer: "{own answer}", others: "{other answers}")),
            ("peerReviewRequestAttachmentNotInThisRound", peerReviewRequest(question: "{question}", attachment: .notInThisRound,
                                                                            ownAnswer: "{own answer}", others: "{other answers}")),
            ("rebuttalRequest", rebuttalRequest(question: "{question}", ownAnswer: "{own answer}",
                                                others: "{other answers}")),
            ("analysisRequest", analysisRequest(question: "{question}", answers: "{answers}")),
            ("chairDebateBlock", chairDebateBlock(name: "{name}", firstSaid: "{answer}", finalTake: "{final take}")),
            ("chairDebateBlockWithoutFinalTake", chairDebateBlock(name: "{name}", firstSaid: "{answer}", finalTake: nil)),
            ("chairSummaryRequest", chairSummaryRequest(question: "{question}", blocks: ["{block}", "{block}"])),
        ]
    }

    /// A store with the saved seat lineup and roles.
    ///
    /// - Parameter loadHistory: whether to read the saved sessions and open the newest one. Leave
    ///   it nil and only the Council app does (its exact bundle id); every other host (the `council`
    ///   CLI, the `Council` facade, tests, an app embedding CouncilKit) starts with an empty
    ///   `sessions` list and a fresh session. A fork built under another bundle id passes `true` to
    ///   keep its history; anyone else can call `loadSessions()` deliberately.
    public init(loadHistory: Bool? = nil) {
        if let data = UserDefaults.standard.data(forKey: seatsKey),
           let saved = try? JSONDecoder().decode([Seat].self, from: data), saved.count == 3 {
            seats = saved
        } else {
            // Start unassigned (each panel shows PICK YOUR MODEL) but with distinct default
            // personas, so the council genuinely diverges from the very first question.
            seats = [
                Seat(id: 0, archetype: .sage,       systemPrompt: Self.personaAnalyst),
                Seat(id: 1, archetype: .scientist,  systemPrompt: Self.personaPractitioner),
                Seat(id: 2, archetype: .strategist, systemPrompt: Self.personaSkeptic)
            ]
        }
        if let savedPrompt = UserDefaults.standard.string(forKey: Self.promptKey), !savedPrompt.isEmpty {
            sharedSystemPrompt = savedPrompt
        }
        if let n = UserDefaults.standard.object(forKey: Self.synthKey) as? Int { synthesizerSeatID = n }
        if let n = UserDefaults.standard.object(forKey: Self.devilKey) as? Int { devilsAdvocateSeatID = n }
        if let data = UserDefaults.standard.data(forKey: Self.chairKey),
           let c = try? JSONDecoder().decode(Seat.self, from: data), c.id == Seat.chairID {
            chairSeat = c
        }
        // Only the APP warms the key cache (it shows all providers' status). A bare CLI process
        // doing this would hit the Keychain for every provider at launch — a wall of permission
        // prompts. The CLI reads lazily, only for seats it actually uses (see keyExists).
        //
        // Suppress system Keychain dialogs FIRST: this warm-up is the process's earliest read, so
        // after an update (ad-hoc signing ⇒ new code identity ⇒ the previous build's items are
        // foreign) it is exactly where macOS would otherwise stack a password dialog per provider,
        // long before the app's own re-enter sheet gets a chance. Suppressed, those reads fail
        // silently and `staleKeychainProviders()` turns them into ONE calm prompt.
        // Gated on Council itself, not merely "has a bundle id": suppressing the system's Keychain
        // dialogs is process-wide and permanent, so a THIRD-PARTY app embedding CouncilKit must
        // never have it done to it as a side effect of constructing the engine.
        if Bundle.main.bundleIdentifier == Self.appBundleID {
            KeychainStore.suppressSystemPrompts()
        }
        if Bundle.main.bundleIdentifier != nil { refreshKeyCache() }
        // Reading history is the app's job. A non-app process used to decode the user's whole
        // sessions folder (another app's container, for the CLI) and briefly hold their newest
        // session as its own, just to throw it away. The reminder sync describes that loaded
        // journal, so it sits behind the same gate.
        let readsHistory = loadHistory
            ?? Self.loadsHistoryAutomatically(bundleID: Self.hostBundleIDForTesting ?? Bundle.main.bundleIdentifier)
        if readsHistory {
            loadSessions()
            syncReminderNotifications()   // journal (now loaded) → pending notifications; no-op in tests
        }
    }

    public func saveSeats() {
        // A non-persisting store (the CouncilKit facade, or `council --no-save`) must not overwrite the
        // app's saved seat lineup. Persistence is gated consistently on persistenceEnabled.
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(seats) {
            UserDefaults.standard.set(data, forKey: seatsKey)
        }
    }

    // MARK: - Shareable council config (export / import / presets)

    /// Capture the current setup as a shareable config (no keys — see CouncilConfig).
    public func currentConfig(name: String) -> CouncilConfig {
        let seatConfigs = seats.map { s in
            CouncilConfig.SeatConfig(provider: s.provider, model: s.model,
                                     systemPrompt: s.systemPrompt,
                                     temperature: s.temperature, maxTokens: s.maxTokens)
        }
        let synthIdx = seats.firstIndex { $0.id == synthesizerSeatID }
        let devilIdx = seats.firstIndex { $0.id == devilsAdvocateSeatID }
        let chairConfig = chairSeat.map { c in
            CouncilConfig.SeatConfig(provider: c.provider, model: c.model,
                                     systemPrompt: nil, temperature: nil, maxTokens: nil)
        }
        return CouncilConfig(name: name.isEmpty ? "My council" : name,
                             seats: seatConfigs,
                             sharedSystemPrompt: sharedSystemPrompt,
                             synthesizerSeatIndex: synthIdx,
                             devilsAdvocateSeatIndex: devilIdx,
                             chair: chairConfig)
    }

    /// Apply a shared/preset config to the live seats. Keeps existing seat ids, maps each
    /// SeatConfig onto a seat by position. Keys are untouched (loaded from Keychain as needed).
    public func applyConfig(_ config: CouncilConfig) {
        for i in seats.indices {
            if let sc = config.seats.indices.contains(i) ? config.seats[i] : nil {
                seats[i].provider = sc.provider
                // A shared lineup can be older than a provider's current models: a retired id
                // moves to its replacement, as it does for a saved seat.
                let chosen = sc.model.isEmpty ? (sc.provider?.defaultModel ?? "") : sc.model
                seats[i].model = sc.provider?.current(chosen) ?? chosen
                seats[i].systemPrompt = sc.systemPrompt
                // Clamp imported sampling through the same bounds as the manual setters, so a
                // hand-edited/malicious file can't set e.g. maxTokens: 100000000 or temperature: 9.
                seats[i].temperature = sc.temperature.map { min(max($0, 0), 2) }
                seats[i].maxTokens = sc.maxTokens.flatMap { $0 > 0 ? min($0, 64_000) : nil }
            } else {
                // Config specifies fewer seats than we have → clear the trailing ones rather than
                // leaving a stale provider/persona from the previous council.
                seats[i].provider = nil
                seats[i].model = ""
                seats[i].systemPrompt = nil
                seats[i].temperature = nil
                seats[i].maxTokens = nil
            }
        }
        sharedSystemPrompt = config.sharedSystemPrompt.isEmpty ? sharedSystemPrompt : config.sharedSystemPrompt
        if let s = config.synthesizerSeatIndex, seats.indices.contains(s) { synthesizerSeatID = seats[s].id }
        if let d = config.devilsAdvocateSeatIndex, seats.indices.contains(d) { devilsAdvocateSeatID = seats[d].id }
        else { devilsAdvocateSeatID = -1 }
        // A config that carries a chair sets one. A config that DOESN'T (every pre-1.2 file, and
        // all four bundled presets) leaves the user's chair alone — silently unseating a paid
        // moderator because a shared lineup predates the feature is a change nobody asked for.
        if let cc = config.chair, let p = cc.provider {
            setChair(p, model: cc.model.isEmpty ? nil : p.current(cc.model))
        }
        saveSeats()
        keyRevision += 1
    }

    public func setSeatPrompt(_ prompt: String?, seatID: Int) {
        guard let idx = seats.firstIndex(where: { $0.id == seatID }) else { return }
        seats[idx].systemPrompt = (prompt?.isEmpty == false) ? prompt : nil
        saveSeats()
    }

    // MARK: - Keys

    public var isConfigured: Bool { seats.allSatisfy(hasKey) }

    /// Per-seat API keys supplied directly in code (the CouncilKit facade), consulted BEFORE the
    /// Keychain at request time. Non-persisted — scoped to a single in-memory store.
    public var transientKeys: [Int: String] = [:]

    /// Per-seat custom OpenAI-compatible chat endpoints supplied in code (the CouncilKit facade), used
    /// instead of the persisted `council.custom{N}.host` UserDefaults. Non-persisted — leaves no trace.
    public var transientCustomEndpoints: [Int: URL] = [:]

    public func hasKey(_ seat: Seat) -> Bool {
        if let k = transientKeys[seat.id], !k.isEmpty { return true }   // facade-supplied key
        guard let provider = seat.provider else { return false }   // no model picked yet
        return keyExists(provider)
    }

    /// Save a key to the Keychain. Returns false when the WRITE failed — callers must surface it.
    /// (This used to `try?`-swallow the error: a failed save looked exactly like success, the seat
    /// showed as connected, and the next call failed with "API key not found".)
    @discardableResult
    public func setKey(_ key: String, for provider: LLMProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do { try KeychainStore.save(trimmed, account: provider.keychainAccount) }
        catch KeychainStore.KeychainError.staleItem {
            // A previous build's orphaned item owns this name (post-update state) — adopt the next
            // generation (carrying every still-readable key with it) and retry once.
            _ = KeychainStore.migrateToNextGeneration(accounts:
                LLMProvider.allCases.filter(\.requiresAPIKey).map(\.keychainAccount))
            guard (try? KeychainStore.save(trimmed, account: provider.keychainAccount)) != nil else { return false }
        }
        catch { return false }
        keyRevision += 1
        return true
    }

    public func clearKey(for provider: LLMProvider) {
        KeychainStore.delete(account: provider.keychainAccount)
        keyRevision += 1
    }

    /// Launch-time staleness check for the app. Ad-hoc signing means every shipped build is a
    /// different code identity to macOS, so after a Sparkle update the old build's keychain items
    /// answer only to password prompts — and can be neither read, deleted, nor re-created under
    /// the same name. This probes silently (NO dialogs) and returns the providers whose keys this
    /// build can't use, so the app shows ONE calm re-enter sheet instead of a prompt storm.
    ///
    /// DETECTION ONLY — deliberately no generation bump here. The bump happens lazily inside
    /// setKey (KeychainError.staleItem → migrate + retry) the moment the user actually re-enters a
    /// key. A launch-time bump would let any side-by-side build (a dev ⌘R next to the installed
    /// release) silently shift the SHARED generation and orphan the other build's readable keys.
    public func staleKeychainProviders() -> [LLMProvider] {
        let keyed = LLMProvider.allCases.filter(\.requiresAPIKey)
        let stale = KeychainStore.staleAccounts(keyed.map(\.keychainAccount))
        guard !stale.isEmpty else { return [] }
        return keyed.filter { stale.contains($0.keychainAccount) }
    }

    public func validateAndSaveKey(_ key: String, for seat: Seat) async -> String? {
        guard let provider = seat.provider else { return "No model selected." }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty key." }
        let client = LLMClientFactory.make(for: provider, model: seat.model)
        do { try await client.validate(apiKey: trimmed) } catch { return error.localizedDescription }
        guard setKey(trimmed, for: provider) else {
            return "Key verified, but saving it to the macOS Keychain failed. Quit any other running Council copies and try again."
        }
        return nil
    }

    public func setModel(_ model: String, seatID: Int) {
        guard let idx = seats.firstIndex(where: { $0.id == seatID }) else { return }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        seats[idx].model = trimmed.isEmpty ? (seats[idx].provider?.defaultModel ?? "") : trimmed
        saveSeats()
    }

    /// Assign (or change) a seat's provider, resetting the model to that provider's default.
    public func setProvider(_ provider: LLMProvider, seatID: Int) {
        guard let idx = seats.firstIndex(where: { $0.id == seatID }) else { return }
        seats[idx].provider = provider
        seats[idx].model = provider.defaultModel
        saveSeats()
        keyRevision += 1
    }

    /// Reset a seat back to unassigned ("PICK YOUR MODEL").
    public func clearProvider(seatID: Int) {
        guard let idx = seats.firstIndex(where: { $0.id == seatID }) else { return }
        seats[idx].provider = nil
        seats[idx].model = ""
        saveSeats()
        keyRevision += 1
    }

    /// True if another seat already uses this provider — drives the duplicate-token warning.
    public func providerInUse(_ provider: LLMProvider, excluding seatID: Int) -> Bool {
        seats.contains { $0.id != seatID && $0.provider == provider }
    }

    // MARK: - Neutral chair

    /// Configure (or clear, with nil) the neutral chair. The chair reuses the normal provider/key
    /// machinery via a reserved out-of-band Seat, so keys come from the same Keychain accounts.
    public func setChair(_ provider: LLMProvider?, model: String? = nil) {
        guard let provider else { chairSeat = nil; keyRevision += 1; return }
        chairSeat = Seat(id: Seat.chairID, archetype: .sage, provider: provider, model: model)
        keyRevision += 1
    }

    public func setChairModel(_ model: String) {
        guard var c = chairSeat else { return }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        c.model = trimmed.isEmpty ? (c.provider?.defaultModel ?? "") : trimmed
        chairSeat = c
    }

    /// True when a chair is configured and looks runnable (its provider is connected). "Connected"
    /// is all the app can know up front for key-free backends (Ollama, a custom endpoint): the call
    /// itself is the only real proof, so `chairFallbackNote` reports after the fact when a chair
    /// turned out not to work and an advisor stood in.
    public var isChairActive: Bool { chairSeat.map(hasKey) ?? false }
    public var chairName: String? { chairSeat?.provider?.panelName }
    /// Set when a configured chair failed and an advisor authored the stage instead — the UI shows
    /// the actual author, never the intended one.
    public var chairFallbackNote: String?

    /// The advisor that authors deliberation when there is no usable chair.
    private var advisorSynthesizerSeat: Seat? {
        if let chosen = seats.first(where: { $0.id == synthesizerSeatID }), hasKey(chosen) { return chosen }
        return seats.first { hasKey($0) }
    }

    /// Per-seat sampling override. Passing nil clears it (falls back to provider default).
    public func setTemperature(_ value: Double?, seatID: Int) {
        guard let idx = seats.firstIndex(where: { $0.id == seatID }) else { return }
        seats[idx].temperature = value.map { min(max($0, 0), 2) }   // clamp to a sane range
        saveSeats()
    }

    public func setMaxTokens(_ value: Int?, seatID: Int) {
        guard let idx = seats.firstIndex(where: { $0.id == seatID }) else { return }
        // Treat 0/negative as "no override"; cap very large values to avoid runaway costs.
        if let v = value, v > 0 { seats[idx].maxTokens = min(v, 64_000) }
        else { seats[idx].maxTokens = nil }
        saveSeats()
    }

    // MARK: - Round navigation + viewed accessors

    public var roundCount: Int { rounds.count }
    public var isViewingLatest: Bool { !rounds.isEmpty && viewingRound == rounds.count - 1 }
    public var canGoPrevRound: Bool { viewingRound > 0 }
    public var canGoNextRound: Bool { viewingRound < rounds.count - 1 }
    public func prevRound() { if canGoPrevRound { viewingRound -= 1; clearDeliberationErrors() } }
    public func nextRound() { if canGoNextRound { viewingRound += 1; clearDeliberationErrors() } }

    /// Drop the transient deliberation errors (they belong to one attempt on one round).
    public func clearDeliberationErrors() {
        divergenceError = nil; synthesisError = nil; chairError = nil
        peerReviewError = nil; rebuttalError = nil
    }

    private var viewedRound: Round? { rounds.indices.contains(viewingRound) ? rounds[viewingRound] : nil }
    public var viewedQuestion: String { viewedRound?.question ?? "" }
    /// True if the viewed round carried an attachment — the UI uses it to disable per-seat Regenerate
    /// (which can't reproduce an answer built from an image/document Council doesn't persist).
    /// True only when the viewed round's attachment can't be reproduced — the case that still has
    /// to disable Regenerate. A round whose document we kept is regenerable like any other.
    public var viewedRoundHadAttachment: Bool {
        guard let r = viewedRound else { return false }
        return r.hadAttachment && r.attachedDocument == nil
    }
    public func viewedAnswer(_ seatID: Int) -> String? {
        // While this seat is streaming into the viewed (generating) round, read the live buffer.
        if generatingRound == viewingRound, let live = liveAnswers[seatID] { return live }
        return viewedRound?.answers[seatID]
    }
    public func viewedPeerReview(_ seatID: Int) -> String? {
        // Streaming reads come from the live buffer; committed text takes over on finish.
        if generatingRound == viewingRound, let live = livePeerReviews[seatID] { return live }
        return viewedRound?.peerReviews[seatID]
    }
    /// Provider name recorded for this seat's answer in the viewed round (for the panel title when
    /// the seat itself is currently unassigned, e.g. a reopened session).
    public func viewedAnswerProvider(_ seatID: Int) -> String? { viewedRound?.answerProviders[seatID] }
    /// How this seat's answer in the viewed round ended, as recorded. nil while it is still
    /// streaming (a status is recorded only when the answer finishes; regenerate clears the old
    /// one), and for a round saved before 1.3.2, which counts as complete.
    public func viewedAnswerStatus(_ seatID: Int) -> AnswerStatus? { viewedRound?.answerStatuses[seatID] }
    /// Read-only views of the current round's cross-model artifacts (used by the UI).
    public var divergenceText: String? { liveDivergence ?? viewedRound?.divergence }
    public var synthesisText: String? { liveSynthesis ?? viewedRound?.synthesis }
    /// Gated on the generating round (unlike the older divergence/synthesis readers): the chair
    /// summary streams AFTER the debate, by which time the user may well have navigated away —
    /// its partial text must not appear under a different round's debate.
    public var chairSummaryText: String? {
        if generatingRound == viewingRound, let live = liveChairSummary { return live }
        return viewedRound?.chairSummary
    }
    /// Who chaired the VIEWED round — the recorded author, not whatever Settings says today.
    public var viewedChairName: String? { viewedRound?.chairProvider ?? chairName }
    /// The viewed round's pasted guest answer, if any — the UI reads these instead of touching the
    /// reserved sentinel id.
    public var viewedGuestAnswer: String? { viewedRound?.guestAnswer }
    public var viewedGuestName: String { viewedRound?.guestName ?? "Guest" }
    /// Ids that actually deliberate in a round — the single source of truth the UI must ask, so a
    /// seat the engine drops (missing key) is reported exactly like one the user excluded, instead
    /// of being shown as participating.
    public func participantIDs(in idx: Int) -> Set<Int> { Set(participants(in: idx).map(\.id)) }
    /// Same, for the round on screen.
    public var viewedParticipantIDs: Set<Int> { participantIDs(in: viewingRound) }

    /// Whether this seat's answer participates in the viewed round's deliberation (false = SAT OUT).
    public func isSeatDeliberating(_ seatID: Int) -> Bool { viewedParticipantIDs.contains(seatID) }
    /// The verdict's AGREEMENT score (0–100). Named honestly — the UI shows 100 − this as divergence.
    public var agreementScore: Int? { viewedRound?.divergenceScore }
    public var divergenceCamps: Int? { viewedRound?.divergenceCamps }
    public var outlierName: String? { viewedRound?.outlier }
    /// The seat whose answer Dissent spotlights in the viewed round, so a surface can also say how
    /// that answer ended. Prefers the seat id resolved at verdict time; falls back to panel-name
    /// matching for sessions saved before that. nil when the outlier has no answer here.
    public var dissentSeatID: Int? {
        guard let round = viewedRound else { return nil }
        if let sid = round.outlierSeatID, round.answers[sid]?.isEmpty == false { return sid }
        guard let name = round.outlier,
              let sid = round.answerProviders.first(where: { $0.value == name })?.key,
              round.answers[sid]?.isEmpty == false else { return nil }
        return sid
    }
    /// The outlier advisor's own answer for the viewed round — for Dissent.
    public var outlierAnswer: String? { dissentSeatID.flatMap { viewedRound?.answers[$0] } }
    public var hasDissent: Bool { outlierAnswer != nil }

    /// Session token + cost totals (sum across rounds) — an estimate.
    public var sessionInputTokens: Int { rounds.reduce(0) { $0 + $1.inputTokens } }
    public var sessionOutputTokens: Int { rounds.reduce(0) { $0 + $1.outputTokens } }
    public var sessionCostUSD: Double { rounds.reduce(0) { $0 + $1.costUSD } }

    // MARK: Dashboard aggregates (all saved sessions; the current session joins after its first save).
    // Cached — recomputed only when `sessions` actually changes (its didSet), not on every render.
    public private(set) var allTimeCostUSD: Double = 0
    public private(set) var thisMonthCostUSD: Double = 0
    /// Most-used model (panel name) across all rounds, for the dashboard's "top model".
    public private(set) var topModelName: String?
    private func recomputeDashboardAggregates() {
        var all = 0.0, month = 0.0, counts: [String: Int] = [:]
        let cal = Calendar.current, now = Date()
        for s in sessions {
            all += s.totalCostUSD
            if cal.isDate(s.updatedAt, equalTo: now, toGranularity: .month) { month += s.totalCostUSD }
            // Skip the guest sentinel: a pasted answer's label ("Guest", "ChatGPT"…) isn't a model
            // the user runs, and must never surface as the dashboard's "top model".
            for r in s.rounds {
                for (sid, name) in r.answerProviders where sid != Round.guestSeatID {
                    counts[name, default: 0] += 1
                }
            }
        }
        allTimeCostUSD = all; thisMonthCostUSD = month
        topModelName = counts.max { $0.value < $1.value }?.key
    }
    /// Whether a key exists for this provider — reads the cache, never the Keychain (so it's safe
    /// to call from a view body). Key-free providers (Ollama) are always "ready".
    public func keyExists(_ p: LLMProvider) -> Bool {
        if !p.requiresAPIKey || keyCache.contains(p) { return true }
        // CLI (no bundle): the cache is never warmed — check the Keychain directly, but only
        // when actually asked about this provider (one prompt max, for a seat in use).
        if Bundle.main.bundleIdentifier == nil,
           let k = (try? KeychainStore.read(account: p.keychainAccount)) ?? nil, !k.isEmpty {
            keyCache.insert(p)
            return true
        }
        return false
    }

    // MARK: Spend alert (opt-in local notification when total spend crosses a threshold)
    public static let spendAlertOnKey = "council.spendAlertOn"
    public static let spendAlertAmtKey = "council.spendAlertAmt"
    private static let spendAlertFiredKey = "council.spendAlertFiredAt"

    /// Re-arm the spend alert (called when the user re-enables it or changes the threshold) so a
    /// freshly-configured alert can fire again even if it fired for an earlier threshold.
    public static func rearmSpendAlert() {
        UserDefaults.standard.removeObject(forKey: spendAlertFiredKey)
    }

    /// Fire a one-time local notification when all-time spend first crosses the user's threshold.
    /// Cheap; called from saveConversation so every spend path is covered. No-op unless opted in.
    public func checkSpendAlert() {
        // UNUserNotificationCenter requires a real app bundle — a bare CLI process has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.spendAlertOnKey) else { return }
        let threshold = d.double(forKey: Self.spendAlertAmtKey)
        guard threshold > 0, allTimeCostUSD >= threshold,
              d.double(forKey: Self.spendAlertFiredKey) < threshold else { return }
        let spent = allTimeCostUSD
        let firedKey = Self.spendAlertFiredKey   // capture plain Sendable values only (no `self`/`center`)
        // Claim the one-shot SYNCHRONOUSLY (we're on the MainActor) so two near-simultaneous saves
        // can't both pass the guard above and double-post. Roll back only if we can't actually notify.
        d.set(threshold, forKey: firedKey)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                UserDefaults.standard.removeObject(forKey: firedKey)   // denied → re-arm so it retries once granted
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Council — spend alert"
            content.body = String(format: "You've spent about $%.2f, past your $%.2f alert.", spent, threshold)
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "council.spendAlert", content: content, trigger: nil))
        }
    }

    /// One entry in a round's blind deliberation set: a real seat's answer, or the pasted guest
    /// answer. `seat == nil` = the guest — reviewed and analyzed like any advisor, but it never
    /// calls a model (no reviews BY it, no rebuttal FROM it).
    private struct Participant {
        let id: Int
        let name: String
        let answer: String
        let seat: Seat?
    }

    /// The full blind set for a round's deliberation: answered keyed seats plus the guest answer,
    /// filtered by the round's `includedSeatIDs` selection (nil = everyone deliberates). A read-only
    /// session is a recording: its seats took part when it was made, whatever keys THIS viewer has,
    /// so the key check is skipped there (nothing can run against it anyway).
    private func participants(in idx: Int) -> [Participant] {
        guard rounds.indices.contains(idx) else { return [] }
        let round = rounds[idx]
        let included = round.includedSeatIDs.map(Set.init)
        var out: [Participant] = []
        for seat in seats {
            guard isReadOnlySession || hasKey(seat), let a = round.answers[seat.id], !a.isEmpty else { continue }
            if let inc = included, !inc.contains(seat.id) { continue }
            out.append(Participant(id: seat.id, name: seat.provider?.panelName ?? "Advisor",
                                   answer: a, seat: seat))
        }
        if let g = round.guestAnswer, included?.contains(Round.guestSeatID) ?? true {
            out.append(Participant(id: Round.guestSeatID, name: round.guestName, answer: g, seat: nil))
        }
        return out
    }

    /// The real seats that both deliberate AND can call a model — the reviewers/rebutters.
    private func deliberatingSeats(in idx: Int) -> [Seat] { participants(in: idx).compactMap(\.seat) }

    private var anyLoading: Bool { status.values.contains { $0 == .loading } || deliberationBusy }
    /// True while any advisor or a deliberation round is generating. The UI uses this to lock
    /// session switching so an in-flight write can't land in a session swapped out underneath it.
    public var isWorking: Bool { anyLoading }
    /// Who authors divergence/verdict/synthesis: a connected neutral chair wins; else the chosen
    /// synthesizer seat if keyed; else the first connected seat.
    private var synthesizerSeat: Seat? {
        if let chair = chairSeat, hasKey(chair) { return chair }
        return advisorSynthesizerSeat
    }
    /// Deliberation needs ≥2 positions on the table and ≥1 real seat to do the reviewing —
    /// "1 real advisor + the guest" is the minimum council (pressure-test a pasted answer).
    private func canDeliberate(_ idx: Int) -> Bool {
        guard !isReadOnlySession else { return false }
        let all = participants(in: idx)
        return all.count >= 2 && all.contains { $0.seat != nil } && !anyLoading
    }

    /// Peer review / divergence / synthesis operate on the round you're viewing.
    public var canPeerReview: Bool { canDeliberate(viewingRound) }
    public var canSynthesize: Bool { canDeliberate(viewingRound) }
    /// Whether the viewed round already has peer reviews (so clicking PEER REVIEW just shows them).
    public var hasPeerReviewForViewedRound: Bool {
        viewedRound?.peerReviews.values.contains { !$0.isEmpty } ?? false
    }
    /// One-round bounded debate: available once peer review exists, and only until it has run once
    /// (hard cap — a single rebuttal round per round, so cost stays bounded). Never on a read-only
    /// session: this doesn't go through canDeliberate, so it needs its own gate, or the DEBATE
    /// offer would appear on an example that has peer review but no debate.
    public var canRebut: Bool {
        !isReadOnlySession && hasPeerReviewForViewedRound && !hasRebuttalForViewedRound
    }
    public var hasRebuttalForViewedRound: Bool {
        viewedRound?.rebuttals.values.contains { !$0.isEmpty } ?? false
    }
    /// The revised (or held) answer a seat gave in the rebuttal round, if any.
    public func viewedRebuttal(_ seatID: Int) -> String? {
        if generatingRound == viewingRound, let live = liveRebuttals[seatID], !live.isEmpty { return live }
        guard let r = viewedRound?.rebuttals[seatID], !r.isEmpty else { return nil }
        return r
    }
    public var synthesizerName: String? { synthesizerSeat?.provider?.panelName }
    /// A session exists once a REAL advisor has answered — a guest-only round (every seat failed)
    /// is not a council and must not persist as one.
    public var hasSession: Bool {
        rounds.contains { !$0.answeredSeatIDs.subtracting([Round.guestSeatID]).isEmpty }
    }

    // MARK: - One answer isn't a council

    /// The viewed round holds exactly ONE real advisor's answer and no guest, so it can't be
    /// deliberated; the UI explains why and offers a second view. Counted from the STORED answers,
    /// never from today's keys: participants drop keyless seats, so a reopened three-answer session
    /// would otherwise read as a one-answer round right after the user re-enters a single key.
    /// False on a read-only session and while anything is generating.
    public var viewedRoundNeedsSecondView: Bool {
        guard !isReadOnlySession, !anyLoading, let r = viewedRound, r.guestAnswer == nil else { return false }
        return r.answeredSeatIDs.subtracting([Round.guestSeatID]).count == 1
    }

    /// Whether the latest round already has any deliberation (peer review, debate, divergence,
    /// synthesis or a chair summary): what adding, replacing or removing an outside answer clears.
    public var latestRoundHasAnalysis: Bool { roundHasDeliberation(rounds.count - 1) }

    /// Whether this seat has a committed, non-empty answer in the latest round. False for a seat
    /// that had no answer there, which `regenerate(seatID:)` fills in place, in the same round.
    public func latestRoundAnswered(_ seatID: Int) -> Bool {
        guard let a = rounds.last?.answers[seatID] else { return false }
        return !a.isEmpty
    }

    // MARK: - Selective deliberation

    /// Choose which answers (by seat id, `Round.guestSeatID` included) enter this round's
    /// deliberation. nil = everyone (the default). Rejects selections smaller than 2 or naming
    /// seats that didn't answer — except one that only adds to a smaller selection: when every
    /// answer ended early, the default selection is empty, and the way back is one answer at a time.
    /// If the round already deliberated, its artifacts are cleared — same "nothing stale survives"
    /// rule as regenerate.
    public func setDeliberationSelection(_ ids: Set<Int>?, forRound idx: Int) {
        guard !isReadOnlySession else { return }
        guard rounds.indices.contains(idx), !anyLoading else { return }
        let current = rounds[idx].includedSeatIDs.map(Set.init)
        if let ids {
            let growsSmallSelection = current.map { $0.count < 2 && $0.isStrictSubset(of: ids) } ?? false
            guard ids.count >= 2 || growsSmallSelection, ids.isSubset(of: rounds[idx].answeredSeatIDs) else { return }
        }
        guard current != ids else { return }
        if roundHasDeliberation(idx) { invalidateDeliberation(idx) }
        rounds[idx].includedSeatIDs = ids.map { Array($0).sorted() }
        saveConversation()
    }

    private func roundHasDeliberation(_ idx: Int) -> Bool {
        guard rounds.indices.contains(idx) else { return false }
        let r = rounds[idx]
        return r.peerReviews.values.contains(where: { !$0.isEmpty })
            || r.divergence != nil || r.synthesis != nil
            || r.rebuttals.values.contains(where: { !$0.isEmpty })
            || r.chairSummary != nil
    }

    /// Clear every deliberation artifact on a round — peer reviews, the rebuttal round, divergence +
    /// verdict, synthesis, and the chair's summary. Used when an input to deliberation changes
    /// (regenerate, a new guest, a changed selection) so nothing stale survives next to new inputs.
    private func invalidateDeliberation(_ idx: Int) {
        guard rounds.indices.contains(idx) else { return }
        rounds[idx].peerReviews.removeAll()
        rounds[idx].rebuttals.removeAll()
        rounds[idx].divergence = nil
        rounds[idx].divergenceScore = nil; rounds[idx].divergenceCamps = nil
        rounds[idx].outlier = nil; rounds[idx].outlierSeatID = nil
        rounds[idx].synthesis = nil
        rounds[idx].chairSummary = nil
        rounds[idx].chairProvider = nil
        clearDeliberationErrors()
    }

    // MARK: - Guest seat

    /// Paste an external answer into the LATEST round after the fact. Deliberation artifacts (if
    /// any) are invalidated — the blind set changed — and any selection resets to the default:
    /// everyone, less any answer that ended early.
    public func addGuestAnswer(_ text: String, name: String? = nil) {
        guard !isReadOnlySession else { return }
        let idx = rounds.count - 1
        guard rounds.indices.contains(idx), !anyLoading else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, CouncilLimits.guestError(trimmed) == nil else { return }
        if roundHasDeliberation(idx) { invalidateDeliberation(idx) }
        rounds[idx].includedSeatIDs = nil
        rounds[idx].answers[Round.guestSeatID] = trimmed
        rounds[idx].answerProviders[Round.guestSeatID] = Self.guestDisplayName(name)
        excludeIncompleteAnswersByDefault(idx)
        saveConversation()
    }

    /// Remove the latest round's guest answer (and, since the blind set changed, its deliberation).
    public func removeGuestAnswer() {
        guard !isReadOnlySession else { return }
        let idx = rounds.count - 1
        guard rounds.indices.contains(idx), !anyLoading, rounds[idx].guestAnswer != nil else { return }
        if roundHasDeliberation(idx) { invalidateDeliberation(idx) }
        rounds[idx].includedSeatIDs = nil
        rounds[idx].answers[Round.guestSeatID] = nil
        rounds[idx].answerProviders[Round.guestSeatID] = nil
        excludeIncompleteAnswersByDefault(idx)
        saveConversation()
    }

    private static func guestDisplayName(_ raw: String?) -> String {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !t.isEmpty else { return "Guest" }
        // A guest literally named "Advisor C" would collide with the blind labels themselves.
        if t.range(of: "^Advisor\\s+[A-Z]$", options: [.regularExpression, .caseInsensitive]) != nil {
            return "Guest"
        }
        return String(t.prefix(24))
    }

    // MARK: - Rounds

    /// Round 1: a NEW round; every connected seat answers in parallel, streaming token-by-token,
    /// each with its own prior context. An optional image rides on the question.
    /// Round 1. An optional `document` is analyzed by EVERY seat alongside the question — the core
    /// "pressure-test this AI output with other models" use case. Like an image, the document rides
    /// on the request only: history + the saved round keep just the typed question, so a big doc
    /// never bloats the sidebar or follow-up context.
    public func ask(_ query: String, image: ImageAttachment? = nil, document: String? = nil,
                    guest: GuestAnswer? = nil) async {
        // A recording can't take a new question: a caller that wants one calls newSession() first.
        guard !isReadOnlySession else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defend the public API: a whitespace-only document is no document, regardless of caller hygiene.
        let trimmedDoc = document?.trimmingCharacters(in: .whitespacesAndNewlines)
        let doc = (trimmedDoc?.isEmpty == false) ? trimmedDoc : nil
        guard !trimmed.isEmpty || image != nil || doc != nil else { return }
        let question = trimmed.isEmpty
            ? (doc != nil ? Self.documentOnlyQuestion : Self.imageOnlyQuestion)
            : trimmed
        // The document is folded into the prompt every seat receives, but NOT saved as the question.
        let effectivePrompt = doc.map { Self.documentPrompt(question, document: $0) } ?? question

        let keyed = seats.filter { hasKey($0) }
        guard !keyed.isEmpty else { return }
        // Only a NEW round gets a time and a prompt version: a round decoded from an older file
        // keeps nil for both instead of a made-up one.
        var round = Round(question: question, createdAt: Date(), promptVersion: CouncilKit.promptVersion)
        round.hadAttachment = (image != nil || doc != nil)   // see Round.hadAttachment — gates Regenerate
        // Keep a modest document so Regenerate can re-ask the SAME question later. An image is
        // never kept (size), so an image round still can't be regenerated.
        if image == nil, let doc, doc.count <= CouncilLimits.maxStoredAttachmentCharacters {
            round.attachedDocument = doc
        }
        // A staged guest answer joins the round as one more (static) position. The advisors never
        // see it in THEIR answer prompts — it enters only the blind deliberation set.
        if let g = guest {
            let gTrim = g.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gTrim.isEmpty, CouncilLimits.guestError(gTrim) == nil {
                round.answers[Round.guestSeatID] = gTrim
                round.answerProviders[Round.guestSeatID] = Self.guestDisplayName(g.name)
            }
        }
        for seat in keyed { round.answers[seat.id] = "" }   // in-progress slots
        rounds.append(round)
        let idx = rounds.count - 1
        viewingRound = idx
        clearDeliberationErrors()
        generatingRound = idx
        for seat in keyed { status[seat.id] = .loading }

        await withTaskGroup(of: Void.self) { group in
            for seat in keyed {
                let sys = systemPrompt(for: seat)
                // Only hand the image to models that accept it; a text-only model would 400.
                let seatImage = (seat.provider?.supportsVision(model: seat.model) ?? false) ? image : nil
                let messages = [ChatMessage.system(sys)] + (history[seat.id] ?? []) + [.user(effectivePrompt, image: seatImage)]
                group.addTask { @MainActor in
                    let r = await self.streamCall(seat: seat, messages: messages) { partial in
                        self.setAnswer(idx, seat.id, partial)
                    }
                    self.finishAnswer(roundIndex: idx, seat: seat, question: question, result: r)
                }
            }
        }
        excludeIncompleteAnswersByDefault(idx)
        generatingRound = nil
        saveConversation()
    }

    /// Round 2: each advisor reviews the other POSITIONS (anonymized) for the VIEWED round, in its
    /// own persona, with the question and the round's kept document. The blind set may include a
    /// pasted guest answer — it gets an Advisor label like everyone else, so reviewers can't tell
    /// it's pasted; the guest itself never reviews (it can't call a model).
    public func peerReview() async {
        guard !isReadOnlySession else { return }
        let idx = viewingRound
        let all = participants(in: idx)
        let reviewers = all.compactMap(\.seat)
        guard all.count >= 2, !reviewers.isEmpty, rounds.indices.contains(idx) else { return }
        let names = uniqueNames(for: all.map { (id: $0.id, base: $0.name) })
        let question = rounds[idx].question
        let attachment = reviewAttachment(idx)
        deliberationBusy = true
        generatingRound = idx
        pipelineStage = "Peer review"
        peerReviewError = nil
        for s in reviewers { status[s.id] = .loading; rounds[idx].peerReviews[s.id] = "" }
        // Re-running peer review invalidates the rebuttal round (and any chair summary of it) that
        // followed the OLD reviews — clear them so DEBATE unlocks again instead of showing stale takes.
        rounds[idx].rebuttals.removeAll()
        rounds[idx].chairSummary = nil

        let unfinished = await withTaskGroup(of: (Int, StreamResult)?.self) { group -> [Int: StreamResult] in
            for seat in reviewers {
                let myAnswer = rounds[idx].answers[seat.id] ?? ""
                // Blind the reviewer with anonymous labels (no brand bias), but keep a map back
                // to real names so the READER sees "I disagree with Gemini", not "Advisor B".
                // Shuffled per reviewer so no position (e.g. the guest) sits at a fixed letter.
                let others = blindPositions(all, excluding: seat.id, heading: " said:")
                let reviewText = Self.peerReviewRequest(question: question, attachment: attachment,
                                                        ownAnswer: myAnswer, others: others.text)
                // The seat reviews in its own persona (as set now: a round doesn't record the one
                // it answered with). The devil's advocate gets an adversarial brief instead of the
                // standard reviewer one.
                let brief = (seat.id == devilsAdvocateSeatID) ? Self.adversaryReviewPrompt : Self.peerReviewPrompt
                let reviewSystem = Self.reviewerSystemPrompt(persona: systemPrompt(for: seat), brief: brief)
                let messages = [ChatMessage.system(reviewSystem), .user(reviewText)]
                group.addTask { @MainActor in
                    let r = await self.streamCall(seat: seat, messages: messages) { partial in
                        self.livePeerReviews[seat.id] = partial   // raw buffer — no rounds churn per tick
                    }
                    self.livePeerReviews[seat.id] = nil
                    guard self.rounds.indices.contains(idx) else { return nil }
                    // The seat's ANSWER is untouched whatever happens here: .failed would turn its
                    // answer panel to ERROR, and that panel's retry re-asks the answer.
                    self.status[seat.id] = .idle
                    self.addRoundUsage(idx, seat, r)
                    guard r.status == .complete, let text = r.text else {
                        self.rounds[idx].peerReviews[seat.id] = nil   // only a finished review is kept
                        return (seat.id, r)
                    }
                    self.rounds[idx].peerReviews[seat.id] = self.deAnonymize(text, others.remap)
                    return nil
                }
            }
            var out: [Int: StreamResult] = [:]
            for await item in group { if let (id, r) = item { out[id] = r } }
            return out
        }
        peerReviewError = Self.stageErrors(reviewers.compactMap { seat in
            unfinished[seat.id].map { (name: names[seat.id] ?? "Advisor", result: $0) }
        })
        deliberationBusy = false
        generatingRound = nil
        pipelineStage = nil
        saveConversation()
    }

    /// Bounded debate — one optional rebuttal round. Each advisor sees its own answer plus where the
    /// whole council landed (anonymized, so no brand bias creeps back in) and either revises or holds,
    /// briefly saying why. Hard-capped at a single round per round so cost can't run away.
    public func runRebuttal() async {
        guard !isReadOnlySession else { return }
        let idx = viewingRound
        let all = participants(in: idx)
        let rebutters = all.compactMap(\.seat)
        guard all.count >= 2, !rebutters.isEmpty, rounds.indices.contains(idx),
              !hasRebuttalForViewedRound else { return }
        deliberationBusy = true
        generatingRound = idx
        pipelineStage = "Debate"
        rebuttalError = nil
        for s in rebutters { status[s.id] = .loading; rounds[idx].rebuttals[s.id] = "" }
        let names = uniqueNames(for: all.map { (id: $0.id, base: $0.name) })

        let unfinished = await withTaskGroup(of: (Int, StreamResult)?.self) { group -> [Int: StreamResult] in
            for seat in rebutters {
                let myAnswer = rounds[idx].answers[seat.id] ?? ""
                // Anonymize only the OTHER positions (like peer review) — the guest's answer is in
                // the blind set too, but the guest itself never rebuts (it's a static paste, and a
                // fabricated "I hold my position" line would be dishonest). Including the seat's own
                // answer in the blind set makes it read its own position as a stranger's — and after
                // de-anonymization it ends up "agreeing with itself" by name on screen.
                let others = blindPositions(all, excluding: seat.id)
                let prompt = Self.rebuttalRequest(question: rounds[idx].question, ownAnswer: myAnswer, others: others.text)
                let messages = [ChatMessage.system(systemPrompt(for: seat)), .user(prompt)]
                group.addTask { @MainActor in
                    let r = await self.streamCall(seat: seat, messages: messages) { partial in
                        self.liveRebuttals[seat.id] = partial   // raw buffer — no rounds churn per tick
                    }
                    self.liveRebuttals[seat.id] = nil
                    guard self.rounds.indices.contains(idx) else { return nil }
                    self.status[seat.id] = .idle   // as in peer review: the answer is not what failed
                    self.addRoundUsage(idx, seat, r)
                    guard r.status == .complete, let text = r.text else {
                        self.rounds[idx].rebuttals[seat.id] = nil   // only a finished take is kept
                        return (seat.id, r)
                    }
                    self.rounds[idx].rebuttals[seat.id] = self.deAnonymize(text, others.remap)
                    return nil
                }
            }
            var out: [Int: StreamResult] = [:]
            for await item in group { if let (id, r) = item { out[id] = r } }
            return out
        }
        rebuttalError = Self.stageErrors(rebutters.compactMap { seat in
            unfinished[seat.id].map { (name: names[seat.id] ?? "Advisor", result: $0) }
        })
        deliberationBusy = false
        generatingRound = nil
        pipelineStage = nil
        saveConversation()
        // A configured chair closes the debate with its neutral summary — one extra call, disclosed
        // in the UI's cost note. Runs only when the rebuttal actually produced final takes. Pass the
        // round explicitly: round navigation isn't locked during a run, so re-reading viewingRound
        // here could attach this summary to a round that never had the debate.
        if !Task.isCancelled, isChairActive,
           rounds[idx].rebuttals.values.contains(where: { !$0.isEmpty }) {
            await runChairSummary(round: idx)
        }
    }

    /// The chair's post-debate wrap-up: a short, neutral map of who moved and who held. Chair-only
    /// (never an advisor — an advisor summarizing a debate it argued in isn't neutral). Reads the
    /// de-anonymized transcript: rebuttals are stored with real names restored, and re-blinding
    /// them by string surgery would garble content, so the chair sees names — acceptable for a
    /// SUMMARY of an already-public transcript, unlike divergence/synthesis which stay blind.
    /// `round` defaults to the viewed round (a manual re-run); the debate pipeline passes its own
    /// index so a mid-run round change can't misfile the summary.
    public func runChairSummary(round idx: Int? = nil) async {
        guard !isReadOnlySession else { return }
        let idx = idx ?? viewingRound
        guard let chair = chairSeat, hasKey(chair), rounds.indices.contains(idx),
              rounds[idx].rebuttals.values.contains(where: { !$0.isEmpty }) else { return }
        deliberationBusy = true
        generatingRound = idx   // the live buffer belongs to THIS round (see chairSummaryText)
        pipelineStage = "Chair summary"
        chairError = nil
        let round = rounds[idx]
        func displayName(_ id: Int) -> String {
            round.answerProviders[id] ?? seats.first { $0.id == id }?.provider?.panelName ?? "Advisor"
        }
        var blocks: [String] = []
        for p in participants(in: idx) {
            let reb = round.rebuttals[p.id]
            blocks.append(Self.chairDebateBlock(name: displayName(p.id), firstSaid: p.answer,
                                                finalTake: (reb?.isEmpty == false) ? reb : nil))
        }
        let user = Self.chairSummaryRequest(question: round.question, blocks: blocks)
        let r = await streamCall(seat: chair, messages: [.system(Self.chairSummaryPrompt), .user(user)]) { partial in
            self.liveChairSummary = partial   // raw buffer — no rounds churn per tick
        }
        liveChairSummary = nil
        if rounds.indices.contains(idx) {
            addRoundUsage(idx, chair, r)
            if r.status == .complete, let t = r.text {
                rounds[idx].chairSummary = t
                // Record WHO chaired: the Settings chair can change later, and a summary must keep
                // naming the model that actually wrote it.
                rounds[idx].chairProvider = chair.provider?.panelName
            } else {
                // Transient, never persisted as content — and an unfinished summary isn't kept.
                chairError = Self.stageErrors([(name: chair.provider?.panelName ?? "The chair", result: r)])
                    ?? "The chair couldn't write its summary."
            }
        }
        deliberationBusy = false
        generatingRound = nil
        pipelineStage = nil
        saveConversation()
    }

    /// The single-page flow: once a round's answers are in, the deliberation stages run
    /// automatically in pipeline order. Each stage skips itself if it already exists, so this is
    /// safe to call after a regenerate too. Cancellation (Stop) exits between stages.
    public func runAutoPipeline() async {
        guard !isReadOnlySession else { return }
        let idx = viewingRound
        guard rounds.indices.contains(idx), canDeliberate(idx) else { return }
        if !hasPeerReviewForViewedRound, !Task.isCancelled {
            pipelineStage = "Peer review"
            await peerReview()
        }
        if rounds.indices.contains(idx), rounds[idx].divergence == nil, !Task.isCancelled {
            pipelineStage = "Divergence"
            await runDivergence()
        }
        if rounds.indices.contains(idx), rounds[idx].synthesis == nil, !Task.isCancelled {
            pipelineStage = "Synthesis"
            await runSynthesis()
        }
        pipelineStage = nil
    }

    /// Run a deliberation call, and if a configured CHAIR is the one that failed, stand an advisor
    /// up instead rather than leaving the round with nothing. Whether a key-free chair (Ollama, a
    /// custom endpoint, a model that isn't pulled) can actually answer is only knowable by calling
    /// it — so the honest design is to try, then fall back and SAY SO (`chairFallbackNote`).
    private func runAuthored(
        round idx: Int, _ messages: [ChatMessage],
        onDelta: @MainActor @escaping (String) -> Void
    ) async -> (seat: Seat, result: StreamResult)? {
        guard let first = synthesizerSeat else { return nil }
        let r = await streamCall(seat: first, messages: messages, onDelta: onDelta)
        // Unfinished output is never kept, so a chair that was cut off or went quiet leaves the
        // round with nothing, just like one that failed: an advisor stands in. A Stop doesn't.
        let chairFailed = (first.id == Seat.chairID) && r.status != .complete && r.status != .cancelled
        guard chairFailed, let advisor = advisorSynthesizerSeat else {
            if first.id != Seat.chairID { chairFallbackNote = nil }
            return (first, r)
        }
        addRoundUsage(idx, first, r)   // the chair's attempt was billed, even though it isn't used
        let retry = await streamCall(seat: advisor, messages: messages, onDelta: onDelta)
        let why = r.status == .failed ? "couldn't run" : "didn't finish"
        chairFallbackNote = retry.status == .complete
            ? "\(first.provider?.panelName ?? "The chair") \(why) — \(advisor.provider?.panelName ?? "an advisor") wrote this."
            : nil
        return (advisor, retry)
    }

    public func runDivergence() async {
        guard !isReadOnlySession else { return }
        let idx = viewingRound
        guard canDeliberate(idx), rounds.indices.contains(idx) else { return }
        deliberationBusy = true
        pipelineStage = "Divergence"
        divergenceError = nil
        // Don't wipe an existing divergence up front: on a failed REGEN the prior good text stays,
        // and the stream replaces it from the first token on success.
        let (ctx, remap, seatByLabel) = anonymizedContext(idx)
        let user = Self.analysisRequest(question: rounds[idx].question, answers: ctx)
        // Capable backends return the map AND its verdict together, halving this stage's calls.
        let merged = synthesizerSeat?.provider?.supportsMergedVerdict ?? false
        let prompt = merged ? Self.divergenceWithVerdictPrompt : Self.divergencePrompt
        let authored = await runAuthored(round: idx, [.system(prompt), .user(user)]) { partial in
            // Never let the machine-readable tail flash on screen mid-stream.
            self.liveDivergence = Self.narrativePart(partial)
        }
        liveDivergence = nil   // a failed/cancelled regen falls back to the prior committed text
        if let (seat, r) = authored, rounds.indices.contains(idx) {
            addRoundUsage(idx, seat, r)
            if r.status == .complete, let t = r.text {
                rounds[idx].divergence = deAnonymize(Self.narrativePart(t), remap)
                // Use the merged verdict when it parsed; otherwise fall back to the separate judge
                // call, so a backend that ignored the tail costs exactly what it costs today.
                if !(merged && applyVerdict(Self.parseVerdictJSON(Self.verdictPart(t) ?? ""),
                                            idx: idx, remap: remap, seatByLabel: seatByLabel)) {
                    await computeVerdict(seat: seat, idx: idx, user: user, remap: remap, seatByLabel: seatByLabel)
                }
            }
            // Transient, never persisted as content — and a cut-off map isn't kept either.
            else { divergenceError = Self.stageErrors([(name: seat.provider?.panelName ?? "The analyst", result: r)]) }
        }
        deliberationBusy = false
        pipelineStage = nil
        saveConversation()
    }

    public func runSynthesis() async {
        guard !isReadOnlySession else { return }
        let idx = viewingRound
        guard canDeliberate(idx), rounds.indices.contains(idx) else { return }
        deliberationBusy = true
        pipelineStage = "Synthesis"
        synthesisError = nil
        let (ctx, remap, _) = anonymizedContext(idx)
        let context = Self.analysisRequest(question: rounds[idx].question, answers: ctx)
        let authored = await runAuthored(round: idx, [.system(Self.synthesisPrompt), .user(context)]) { partial in
            self.liveSynthesis = partial   // raw buffer — no rounds churn per tick
        }
        liveSynthesis = nil   // a failed/cancelled regen falls back to the prior committed text
        if let (seat, r) = authored, rounds.indices.contains(idx) {
            addRoundUsage(idx, seat, r)
            if r.status == .complete, let t = r.text { rounds[idx].synthesis = deAnonymize(t, remap) }
            // Transient, never persisted as content — and a cut-off synthesis isn't kept either.
            else { synthesisError = Self.stageErrors([(name: seat.provider?.panelName ?? "The synthesizer", result: r)]) }
        }
        deliberationBusy = false
        pipelineStage = nil
        saveConversation()
    }

    /// Re-run a single advisor's answer in the latest round (only when viewing it).
    public func regenerate(seatID: Int) async {
        guard !isReadOnlySession else { return }
        let idx = rounds.count - 1
        guard idx == viewingRound, rounds.indices.contains(idx), !anyLoading,
              let seat = seats.first(where: { $0.id == seatID }), hasKey(seat) else { return }
        // A round whose attachment we kept can be re-asked exactly as it was asked. One we didn't
        // (an image, or a document too large to store) still can't: re-asking without it would get
        // a confident answer about nothing, so refuse instead of faking it.
        let storedDoc = rounds[idx].attachedDocument
        if rounds[idx].hadAttachment, storedDoc == nil {
            status[seatID] = .failed("Can't regenerate — this answer used an image or an oversized document, which Council doesn't keep. Start a new directive to re-attach it.")
            return
        }
        let q = rounds[idx].question
        // Same fold as ask(): the document rides on the request, never into the saved question.
        let effectiveQ = storedDoc.map { Self.documentPrompt(q, document: $0) } ?? q
        // Only drop this seat's last exchange from history if this round's answer is in it: one
        // that completed (or an older round's, which records no status). A failed, cut-off or
        // stopped answer never went into history, so dropping "its" pair would delete a PREVIOUS
        // round's exchange instead.
        let hadAnswer = !((rounds[idx].answers[seatID] ?? "").isEmpty)
        let inHistory = (rounds[idx].answerStatuses[seatID] ?? .complete) == .complete
        if hadAnswer, inHistory, var h = history[seatID], h.count >= 2 { h.removeLast(2); history[seatID] = h }
        // Changing one answer invalidates every peer review (they all read the old set), the rebuttal
        // round, and both cross-model artifacts — clear them all so nothing stale survives next to
        // the new answer (a surviving rebuttal would also lock DEBATE for this round forever). The
        // deliberation selection resets too: the participant set's content changed under it.
        invalidateDeliberation(idx)
        rounds[idx].includedSeatIDs = nil
        rounds[idx].answers[seatID] = ""
        rounds[idx].answerStatuses[seatID] = nil   // the new answer records its own; no stale marker
        rounds[idx].answerModels[seatID] = nil
        // Nor a stale author: a seat moved to another provider whose regenerate fails would still
        // be named after the one that wrote the answer it replaced (in exports, the memo, the CLI).
        rounds[idx].answerProviders[seatID] = nil
        status[seatID] = .loading
        generatingRound = idx
        let messages = [ChatMessage.system(systemPrompt(for: seat))] + (history[seatID] ?? []) + [.user(effectiveQ)]
        let r = await streamCall(seat: seat, messages: messages) { partial in
            self.setAnswer(idx, seatID, partial)
        }
        finishAnswer(roundIndex: idx, seat: seat, question: q, result: r)
        excludeIncompleteAnswersByDefault(idx)   // the selection was reset above
        generatingRound = nil
        saveConversation()
    }

    public func cancelAll() {
        for id in status.keys where status[id] == .loading { status[id] = .idle }
        deliberationBusy = false
        generatingRound = nil
        pipelineStage = nil
        livePeerReviews = [:]; liveRebuttals = [:]
        liveDivergence = nil; liveSynthesis = nil
        liveChairSummary = nil
    }

    // MARK: - Round helpers

    private func systemPrompt(for seat: Seat) -> String {
        (seat.systemPrompt?.isEmpty == false) ? seat.systemPrompt! : sharedSystemPrompt
    }

    /// What peer review can show of the attachment behind a round's answers. Only the round's own
    /// kept document is sent (so at most `CouncilLimits.maxStoredAttachmentCharacters`); a later
    /// round doesn't carry an earlier one. Whatever the reviewer can't see is said plainly instead
    /// of silently left out.
    private func reviewAttachment(_ idx: Int) -> ReviewAttachment {
        let round = rounds[idx]
        if let document = round.attachedDocument { return .document(document) }
        if round.hadAttachment { return .notKept }
        return rounds[..<idx].contains(where: \.hadAttachment) ? .notInThisRound : .none
    }

    private func setAnswer(_ idx: Int, _ seatID: Int, _ text: String) {
        // The status guard drops any straggler flush that lands after finishAnswer settled the seat.
        guard rounds.indices.contains(idx), status[seatID] == .loading else { return }
        liveAnswers[seatID] = text   // #15: stream into the live buffer; committed to rounds in finishAnswer
    }

    /// The model id a call on this seat runs: its own, or the provider's default when it names
    /// none (as the client factory does). nil for a seat with no provider.
    private func calledModel(_ seat: Seat) -> String? {
        seat.provider.map { seat.model.isEmpty ? $0.defaultModel : seat.model }
    }

    private func finishAnswer(roundIndex idx: Int, seat: Seat, question: String, result r: StreamResult) {
        guard rounds.indices.contains(idx) else { return }
        let id = seat.id
        var ended = r.status
        // An empty "complete" answer is no answer: committing it would put an empty assistant turn
        // into this seat's history, which the next follow-up's request would carry.
        if ended == .complete, r.text?.isEmpty ?? true { ended = .failed }
        // Recorded however it ended, so a reopened session, an export or the CLI can tell a cut-off
        // answer from a whole one, and name the model that actually ran.
        rounds[idx].answerStatuses[id] = ended
        if let model = calledModel(seat) { rounds[idx].answerModels[id] = model }
        switch ended {
        case .complete:
            // Completed normally → commit the answer and extend this seat's conversation history.
            let text = r.text ?? ""
            rounds[idx].answers[id] = text
            rounds[idx].answerProviders[id] = seat.provider?.panelName
            history[id, default: []].append(.user(question))
            history[id, default: []].append(.assistant(text))
            status[id] = .idle
        case .truncated, .stalled, .cancelled:
            // Ended early: keep whatever streamed for the user to read, but do NOT append it to
            // history — feeding a cut-off answer into later rounds as if complete corrupts context.
            // The recorded status, not a transient error, is what marks it.
            rounds[idx].answers[id] = r.text   // partial text, or nil if nothing arrived yet
            rounds[idx].answerProviders[id] = r.text == nil ? nil : seat.provider?.panelName
            status[id] = .idle
        case .failed:
            rounds[idx].answers[id] = nil   // hard failure → drop the empty in-progress slot
            status[id] = .failed(r.error ?? (r.status == .complete
                ? "\(seat.provider?.panelName ?? "This advisor") returned an empty answer." : "Unknown error"))
        }
        addRoundUsage(idx, seat, r)   // whatever was billed, a cut-off answer included
        liveAnswers[id] = nil   // streaming finished → viewedAnswer falls back to the committed rounds value
    }

    /// An answer that ended early sits out of deliberation by default: a half-answer reviewed,
    /// scored and named the outlier as if it were a whole position would mislead the council. The
    /// default is written as the round's selection, so the user can still bring it back in (and
    /// every surface already shows it as sat out). Runs once the round's answers are in.
    private func excludeIncompleteAnswersByDefault(_ idx: Int) {
        guard rounds.indices.contains(idx), rounds[idx].includedSeatIDs == nil else { return }
        let incomplete = rounds[idx].incompleteSeatIDs
        guard !incomplete.isEmpty else { return }
        rounds[idx].includedSeatIDs = rounds[idx].answeredSeatIDs.subtracting(incomplete).sorted()
    }

    /// Optional price override (the CouncilKit facade) so a stale built-in price can't silently
    /// mislead. Keyed on (provider, model) because models within one provider price differently.
    /// Returns ($/1M input, $/1M output); nil → the provider's built-in price. Non-persisted.
    public var priceOverride: (@Sendable (LLMProvider, String?) -> (inputPer1M: Double, outputPer1M: Double)?)?

    private func addRoundUsage(_ idx: Int, _ seat: Seat, _ r: StreamResult) {
        guard rounds.indices.contains(idx), let provider = seat.provider,
              r.input > 0 || r.output > 0 else { return }
        rounds[idx].inputTokens += r.input
        rounds[idx].outputTokens += r.output
        let rates = priceOverride?(provider, seat.model.isEmpty ? nil : seat.model)
            ?? (inputPer1M: provider.pricePer1MInput, outputPer1M: provider.pricePer1MOutput)
        rounds[idx].costUSD += Double(r.input) / 1_000_000 * rates.inputPer1M
                             + Double(r.output) / 1_000_000 * rates.outputPer1M
    }

    /// Test seam: when true, the blind stages keep the participant order instead of shuffling it,
    /// so a test can pin the exact text a scripted round sends. Internal, and never set outside the
    /// test target: in production every blind stage shuffles.
    static var fixedBlindOrderForTesting = false

    /// The order a blind stage labels its positions in: shuffled, so no position (the guest, say)
    /// always sits at the same letter. Fixed only under the test seam above.
    private static func blindOrder<T>(_ items: [T]) -> [T] {
        fixedBlindOrderForTesting ? items : items.shuffled()
    }

    /// The positions a blind stage reads, each under an anonymous label (Advisor A, B, C…), plus the
    /// maps back from each label to the real display name (to restore attribution in the output)
    /// and to the participant (to resolve a verdict's outlier).
    private struct BlindPositions {
        let text: String
        let remap: [String: String]
        let seatByLabel: [String: Int]   // lowercased label → participant id
    }

    /// The one place blind labels are assigned, for every blind stage. Names come from the FULL,
    /// UNSHUFFLED participant list, before anyone is left out or the order is shuffled: deriving them
    /// after either step moved a collision suffix ("Claude (1)"/"Claude (2)") to a different seat
    /// per stage, so peer review and synthesis disagreed about who was who. `excluding` leaves out
    /// the reading seat's own answer (peer review and the debate); `heading` follows each label.
    private func blindPositions(_ all: [Participant], excluding seatID: Int? = nil,
                                heading: String = ":") -> BlindPositions {
        let names = uniqueNames(for: all.map { (id: $0.id, base: $0.name) })
        let parts = Self.blindOrder(all.filter { $0.id != seatID })
        var blocks: [String] = []
        var remap: [String: String] = [:]
        var seatByLabel: [String: Int] = [:]
        for (i, p) in parts.enumerated() {
            let label = "Advisor \(String(UnicodeScalar(65 + i)!))"   // Advisor A, B, C…
            remap[label] = names[p.id] ?? "Advisor"
            seatByLabel[label.lowercased()] = p.id
            blocks.append("\(label)\(heading)\n\(p.answer)")
        }
        return BlindPositions(text: blocks.joined(separator: "\n\n"), remap: remap, seatByLabel: seatByLabel)
    }

    /// Every position for the synthesizer (and divergence and the verdict) with ANONYMOUS, shuffled
    /// labels, so it can't tell which answer is its own and favor it. The guest answer is one more
    /// shuffled block — indistinguishable from a real advisor.
    private func anonymizedContext(_ idx: Int) -> (context: String, remap: [String: String], seatByLabel: [String: Int]) {
        let blind = blindPositions(participants(in: idx))
        return (blind.text, blind.remap, blind.seatByLabel)
    }

    /// Put the real provider names back into a generated artifact, for display.
    ///
    /// ONE pass over the text, longest labels first, never re-scanning what was already written —
    /// a sequential replace could substitute into its own output (a guest the user literally named
    /// "Advisor B" made the pass rewrite an earlier "Advisor A" result a second time).
    ///
    /// Matching is deliberately tolerant, because models echo the label back in their own spelling:
    /// a live llama3.2 run wrote "Adviser A"/"Adviser B" and the strict pass left those raw labels
    /// on screen next to real names — meaningless to the reader. Case, inner whitespace, and that
    /// one-letter misspelling are all accepted. A label is a whole word, though: prose such as
    /// "every advisor agrees" or "the second advisor brings" must never read as "Advisor A"/"B" and
    /// come out as "every Claudegrees" — which would also pin a council-wide point on one model.
    private func deAnonymize(_ text: String, _ remap: [String: String]) -> String {
        guard !remap.isEmpty else { return text }
        var aliases: [(needle: String, replacement: String)] = []
        for (label, name) in remap {
            aliases.append((label, name))
            if let letter = label.split(separator: " ").last {
                aliases.append(("Adviser \(letter)", name))
            }
        }
        aliases.sort { $0.needle.count > $1.needle.count }

        var out = ""
        var i = text.startIndex
        outer: while i < text.endIndex {
            // Only where a word starts: "Advisor A" inside a longer word is ordinary prose.
            let startsWord = i == text.startIndex || !Self.isWordCharacter(text[text.index(before: i)])
            for a in aliases where startsWord {
                if let end = Self.matchLabel(a.needle, in: text, at: i) {
                    out += a.replacement
                    i = end
                    continue outer
                }
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }

    /// Test seam for the de-anonymization pass (it's the one piece of display logic that has
    /// silently regressed in a live run before).
    func deAnonymizeForTesting(_ text: String, _ remap: [String: String]) -> String {
        deAnonymize(text, remap)
    }

    /// The human-readable half of a merged divergence answer — everything before the verdict
    /// sentinel. Applied to partial text too, so the JSON tail never flashes on screen. A model
    /// that emitted no sentinel simply keeps its whole answer.
    nonisolated static func narrativePart(_ text: String) -> String {
        guard let r = text.range(of: verdictSentinel) else { return text }
        return String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The machine-readable half, or nil when the model never emitted the sentinel.
    nonisolated static func verdictPart(_ text: String) -> String? {
        guard let r = text.range(of: verdictSentinel) else { return nil }
        return String(text[r.upperBound...])
    }

    /// Commit a parsed verdict onto a round. Returns false when there was nothing usable to
    /// commit, which is the caller's signal to fall back to the separate judge call.
    @discardableResult
    private func applyVerdict(_ v: (agreement: Int, camps: Int?, outlier: String?)?,
                              idx: Int, remap: [String: String], seatByLabel: [String: Int]) -> Bool {
        guard let v, rounds.indices.contains(idx) else { return false }
        rounds[idx].divergenceScore = v.agreement
        rounds[idx].divergenceCamps = v.camps
        // With exactly two positions "the outlier" is undefined — either side of a symmetric
        // disagreement would do, so a pick is fake precision. Score + camps still stand.
        if let label = v.outlier, participants(in: idx).count > 2 {
            let k = label.lowercased().trimmingCharacters(in: .whitespaces)
            rounds[idx].outlierSeatID = seatByLabel[k]
            rounds[idx].outlier = remap[label]
                ?? remap.first { $0.key.lowercased() == k }?.value
                ?? label
        } else {
            rounds[idx].outlierSeatID = nil
            rounds[idx].outlier = nil
        }
        return true
    }

    /// Whether `c` continues a word next to a label. Only Latin letters and digits do: the label is
    /// Latin, and so is the prose it can be mistaken for ("advisor agrees", "advisor décide").
    /// Space, punctuation and an apostrophe end a word, and so does a script that writes without
    /// spaces or attaches particles ("Advisor A认为", "Advisor Aは", "Advisor A는" still map).
    private static func isWordCharacter(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, scalar.value < 0x0250 else { return false }
        return c.isLetter || c.isNumber
    }

    /// Case-insensitive match of `needle` at `start`, where a space in the needle matches any run
    /// of whitespace, and the match must end a word ("Advisor A." or "Advisor A's", never the
    /// "advisor a" of "advisor agrees"). Returns the index just past the match, or nil if it
    /// doesn't match here.
    private static func matchLabel(_ needle: String, in text: String, at start: String.Index) -> String.Index? {
        var t = start
        var n = needle.startIndex
        while n < needle.endIndex {
            guard t < text.endIndex else { return nil }
            if needle[n] == " " {
                guard text[t].isWhitespace else { return nil }
                while t < text.endIndex, text[t].isWhitespace { t = text.index(after: t) }
                n = needle.index(after: n)
                continue
            }
            guard text[t].lowercased() == needle[n].lowercased() else { return nil }
            t = text.index(after: t)
            n = needle.index(after: n)
        }
        guard t == text.endIndex || !isWordCharacter(text[t]) else { return nil }
        return t
    }

    /// Map each participant to a UNIQUE display name. Two seats on the same provider — or a guest
    /// the user named after a real seat's provider — would otherwise de-anonymize to the same name
    /// and become indistinguishable to the reader; append "(1)"/"(2)" only on an actual collision.
    private func uniqueNames(for entries: [(id: Int, base: String)]) -> [Int: String] {
        let counts = Dictionary(grouping: entries, by: \.base).mapValues(\.count)
        var seen: [String: Int] = [:]; var out: [Int: String] = [:]
        for e in entries {
            if (counts[e.base] ?? 0) > 1 { let n = (seen[e.base] ?? 0) + 1; seen[e.base] = n; out[e.id] = "\(e.base) (\(n))" }
            else { out[e.id] = e.base }
        }
        return out
    }

    /// Separate, json-mode "verdict" call on the synthesizer: a reliable agreement score, camp count,
    /// and outlier — instead of a free-form line a small model might drop. Free for local synthesizers.
    private func computeVerdict(seat: Seat, idx: Int, user: String,
                                remap: [String: String], seatByLabel: [String: Int]) async {
        guard let provider = seat.provider else { return }
        var key = ""
        if let k = transientKeys[seat.id], !k.isEmpty {
            key = k                                          // facade-supplied key (also auths custom endpoints)
        } else if provider.requiresAPIKey {
            guard let k = storedKey(for: provider) else { return }
            key = k
        }
        let client = Self.clientOverrideForTesting?(provider)
            ?? LLMClientFactory.make(for: provider, model: seat.model,
                                     endpoint: transientCustomEndpoints[seat.id])
        // Parse the RAW output — the outlier is still an anonymous label ("Advisor B"), which we
        // resolve to a seat id HERE (case-insensitively). Matching by display name later is fragile:
        // duplicate providers share a panel name, and judges drift on label casing.
        guard let raw = try? await client.judge(messages: [.system(Self.verdictPrompt), .user(user)], apiKey: key)
        else { return }
        applyVerdict(Self.parseVerdictJSON(raw), idx: idx, remap: remap, seatByLabel: seatByLabel)
    }

    /// Robust parse of the judge's JSON — tolerant of the schema drift small models produce (camps as
    /// an array → use its count, agreement as a string, "none"/null outliers).
    nonisolated static func parseVerdictJSON(_ text: String) -> (agreement: Int, camps: Int?, outlier: String?)? {
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e,
              let data = String(text[s...e]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func intify(_ v: Any?) -> Int? {
            if let i = v as? Int { return i }
            if let d = v as? Double { return Int(d) }
            if let str = v as? String { return Int(str.filter(\.isNumber)) }
            if let arr = v as? [Any] { return arr.count }
            return nil
        }
        guard let a = intify(obj["agreement"]) else { return nil }
        let camps = intify(obj["camps"])
        var outlier: String? = nil
        if let o = obj["outlier"] as? String, !o.isEmpty,
           o.lowercased() != "none", o.lowercased() != "null" { outlier = o }
        return (min(100, max(0, a)), camps, outlier)
    }

    /// What one model call produced. `status` says how it ended: `text` is the whole response when
    /// complete, what arrived when truncated, stalled or cancelled (nil if nothing did), and nil
    /// when failed. `error` explains every ending but complete and cancelled. `cancelled` is
    /// `status == .cancelled`, kept for older readers.
    public typealias StreamResult = (text: String?, input: Int, output: Int, cancelled: Bool, error: String?,
                                     status: AnswerStatus)

    /// The one place a `StreamResult` is built, so `cancelled` and `status` can never disagree.
    private static func streamResult(_ text: String?, _ input: Int, _ output: Int,
                                     _ status: AnswerStatus, _ error: String? = nil) -> StreamResult {
        (text, input, output, status == .cancelled, error, status)
    }

    /// The line a call cut off at the length limit leaves, naming the one fix that works.
    private static func cutOffMessage(_ name: String, nothingArrived: Bool = false) -> String {
        nothingArrived
            ? "\(name) hit the length limit before writing anything — raise this seat's max tokens."
            : "\(name) was cut off at the length limit — raise this seat's max tokens."
    }

    /// The error line a deliberation stage leaves for its calls that didn't finish (nil when there
    /// are none): one line per author, and one for everyone the user stopped. Unfinished stage
    /// output is never kept, so each line says so — a half-written review or synthesis would read
    /// as the whole thing on screen, in every export, and on disk.
    private static func stageErrors(_ unfinished: [(name: String, result: StreamResult)]) -> String? {
        var lines: [String] = []
        var stopped: [String] = []
        for (name, r) in unfinished {
            switch r.status {
            case .complete: continue
            case .cancelled: stopped.append(name)
            case .truncated: lines.append(cutOffMessage(name) + " Nothing was saved.")
            case .stalled: lines.append((r.error ?? "\(name) didn't finish.") + " Nothing was saved.")
            case .failed:
                // Name the author: one stage card can hold several seats' lines.
                let m = r.error ?? "it failed."
                lines.append(m.contains(name) ? m : "\(name): \(m)")
            }
        }
        if !stopped.isEmpty {
            lines.append("Stopped before \(stopped.joined(separator: ", ")) finished — nothing unfinished was saved.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Test seam: when set, every model call (answers, reviews, debate, divergence, synthesis and
    /// the verdict) goes to this client instead of the real backend, so a test can prove what ran,
    /// and what didn't, without the network. Internal, and never set outside the test target.
    static var clientOverrideForTesting: ((LLMProvider) -> any LLMClient)?

    /// Stream one model call, feeding the growing text to `onDelta`. Returns the text, token usage
    /// and how the call ended (see `StreamResult`): partial text is kept when it was cut off, went
    /// quiet or was stopped, and dropped only when the call failed outright.
    private func streamCall(seat: Seat, messages: [ChatMessage],
                            onDelta: @MainActor @escaping (String) -> Void) async -> StreamResult {
        guard let provider = seat.provider else { return Self.streamResult(nil, 0, 0, .failed, "No model selected.") }
        var apiKey = ""
        if let k = transientKeys[seat.id], !k.isEmpty {
            apiKey = k                                       // facade-supplied key (also auths custom endpoints)
        } else if provider.requiresAPIKey {
            guard let key = (try? KeychainStore.read(account: provider.keychainAccount)) ?? nil,
                  !key.isEmpty else { return Self.streamResult(nil, 0, 0, .failed, "API key not found.") }
            apiKey = key
        }
        let client = Self.clientOverrideForTesting?(provider)
            ?? LLMClientFactory.make(for: provider, model: seat.model,
                                     temperature: seat.temperature, maxTokens: seat.maxTokens,
                                     endpoint: transientCustomEndpoints[seat.id])
        // One automatic retry on a transient connection drop (flaky Wi-Fi, an SSH-tunnelled remote
        // Ollama, a brief blip). The long streaming connection is what tends to fail, so we re-run
        // from scratch once before surfacing the error — the seat stays in its loading state throughout.
        let gate = FlushGate()
        var lastMessage = "Failed"
        for attempt in 0..<2 {
            let r = await Self.pump(client: client, messages: messages, apiKey: apiKey,
                                    provider: provider, gate: gate, onDelta: onDelta)
            await gate.waitUntilIdle()             // the final flush below must be ordered LAST
            if !r.text.isEmpty { onDelta(r.text) } // authoritative full/partial text, on the MainActor
            switch r.failure {
            case .none where r.stop == .lengthLimit:
                // Cut off, not failed: the text is kept and was billed. With nothing written at all
                // (a reasoning model that spent the cap thinking) there is no answer to keep.
                return r.text.isEmpty
                    ? Self.streamResult(nil, r.input, r.output, .failed,
                                        Self.cutOffMessage(provider.panelName, nothingArrived: true))
                    : Self.streamResult(r.text, r.input, r.output, .truncated, Self.cutOffMessage(provider.panelName))
            case .none:
                return Self.streamResult(r.text, r.input, r.output, .complete)
            case .cancelled:
                return Self.streamResult(r.text.isEmpty ? nil : r.text, r.input, r.output, .cancelled)
            case .stalled(let m):
                // Deliberately NOT retried: a backend that went quiet once will almost always go
                // quiet again, and a second 90s wait is 90s the whole council spends blocked.
                return r.text.isEmpty
                    ? Self.streamResult(nil, r.input, r.output, .failed, m)
                    : Self.streamResult(r.text, r.input, r.output, .stalled, m)
            case .transient where Task.isCancelled:
                // The connection dropped as the user pressed Stop: that is a stop, not an error.
                return Self.streamResult(r.text.isEmpty ? nil : r.text, r.input, r.output, .cancelled)
            case .transient(let m):
                lastMessage = m
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000)   // brief backoff, then re-run once
                    continue
                }
                return Self.streamResult(nil, r.input, r.output, .failed, m)
            case .permanent(let m):
                return Self.streamResult(nil, r.input, r.output, .failed, m)
            }
        }
        return Self.streamResult(nil, 0, 0, .failed, lastMessage)
    }

    /// The network pump — deliberately `nonisolated`, so it runs on the GLOBAL executor, never the
    /// MainActor. A main-thread stall (a held text-selection mouse-tracking loop, a menu, a heavy
    /// commit) must not stall the model streams — it used to: every SSE chunk hopped through the
    /// MainActor, so holding the mouse down over text froze all three answers mid-flight.
    /// UI flushes are throttled (10Hz/seat), FIRE-AND-FORGET (never block the network), and
    /// serialized through `gate` so at most one is in flight and the caller's final flush wins.
    /// Runs the stream and races it against a stall watchdog, so one wedged backend can't hold the
    /// round. Cancellation from above (Stop) is forwarded to the inner task explicitly — an
    /// unstructured `Task` does not inherit it.
    /// Test seam for the stall watchdog — the one behaviour that needs a fake backend to prove.
    nonisolated static func pumpForTesting(
        client: any LLMClient, provider: LLMProvider = .ollama
    ) async -> PumpOutcome {
        await pump(client: client, messages: [.user("hi")], apiKey: "",
                   provider: provider, gate: FlushGate(), onDelta: { _ in })
    }

    private nonisolated static func pump(
        client: any LLMClient, messages: [ChatMessage], apiKey: String,
        provider: LLMProvider, gate: FlushGate, onDelta: @escaping @MainActor (String) -> Void
    ) async -> PumpOutcome {
        let liveness = StreamLiveness()
        let streaming = Task {
            await rawPump(client: client, messages: messages, apiKey: apiKey,
                          provider: provider, gate: gate, liveness: liveness, onDelta: onDelta)
        }
        let watchdog = Task {
            let limit = UInt64(max(1, CouncilLimits.stallTimeoutSeconds) * 1_000_000_000)
            let thinkingLimit = UInt64(max(1, CouncilLimits.thinkingTimeoutSeconds) * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if await liveness.idleNanos() >= limit {
                    await liveness.markTimedOut()
                    streaming.cancel()
                    return
                }
                // Signs of life alone don't keep a call open for ever (see `thinkingTimeoutSeconds`).
                if await liveness.stuckNanos() >= thinkingLimit {
                    await liveness.markTimedOut(stillWorking: true)
                    streaming.cancel()
                    return
                }
            }
        }
        var outcome = await withTaskCancellationHandler {
            await streaming.value
        } onCancel: {
            streaming.cancel()
        }
        watchdog.cancel()
        // The watchdog cancels the same way Stop does, so the classification is corrected here —
        // this is the only place that can tell the two apart. A stream that had already said how
        // it ended keeps that verdict, even if it then hung instead of closing.
        if await liveness.timedOut, outcome.stop == nil {
            if await liveness.stillWorking {
                let minutes = max(1, Int((CouncilLimits.thinkingTimeoutSeconds / 60).rounded()))
                outcome.failure = .stalled(outcome.text.isEmpty
                    ? "\(provider.panelName) was still working after \(minutes) min with no answer — the council finished without it."
                    : "\(provider.panelName) stopped writing for \(minutes) min before it finished.")
            } else {
                let secs = Int(CouncilLimits.stallTimeoutSeconds)
                outcome.failure = .stalled(outcome.text.isEmpty
                    ? "\(provider.panelName) stopped responding (nothing for \(secs)s) — the council finished without it."
                    : "\(provider.panelName) stopped responding before it finished (nothing for \(secs)s).")
            }
        }
        return outcome
    }

    /// The network pump — deliberately `nonisolated`, so it runs on the GLOBAL executor, never the
    /// MainActor. A main-thread stall (a held text-selection mouse-tracking loop, a menu, a heavy
    /// commit) must not stall the model streams — it used to: every SSE chunk hopped through the
    /// MainActor, so holding the mouse down over text froze all three answers mid-flight.
    /// UI flushes are throttled (10Hz/seat), FIRE-AND-FORGET (never block the network), and
    /// serialized through `gate` so at most one is in flight and the caller's final flush wins.
    private nonisolated static func rawPump(
        client: any LLMClient, messages: [ChatMessage], apiKey: String,
        provider: LLMProvider, gate: FlushGate, liveness: StreamLiveness,
        onDelta: @escaping @MainActor (String) -> Void
    ) async -> PumpOutcome {
        let minInterval: UInt64 = 100_000_000   // 100ms — 10Hz per seat; 3 seats ≈ 30 UI flushes/sec
        var full = "", input = 0, output = 0
        var stop: StreamChunk.StopReason?
        var lastEmit: UInt64 = 0
        do {
            for try await chunk in client.stream(messages: messages, apiKey: apiKey) {
                // Proof of life for the stall watchdog. A heartbeat proves the call is alive, not
                // that the answer is getting anywhere: only the other chunks count as progress.
                let progress: Bool
                if case .heartbeat = chunk { progress = false } else { progress = true }
                await liveness.touch(progress: progress)
                switch chunk {
                case .text(let t):
                    full += t
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now &- lastEmit >= minInterval, await gate.tryEnter() {
                        lastEmit = now
                        let snapshot = full
                        Task { @MainActor in onDelta(snapshot); await gate.leave() }
                    }
                case .usage(let i, let o): input = i; output = o
                case .stop(let reason): if stop == nil { stop = reason }
                case .heartbeat: break         // nothing to keep; the touch above is the point
                }
                // Checked after the chunk, not before: an end signal that reached us counts even
                // when Stop lands at the same moment.
                try Task.checkCancellation()   // Stop → exit → stream terminates → network cancels
            }
            // A Stop usually lands here, not in the catch: cancelling a task that is waiting for the
            // next chunk ends the stream WITHOUT throwing. Only asking the task tells it from a finish.
            return PumpOutcome(text: full, input: input, output: output,
                               failure: endFailure(stop, cancelled: Task.isCancelled, text: full, provider: provider),
                               stop: stop)
        } catch {
            // Partial text survives cancel/failure; classify here so the outcome stays Sendable.
            // A provider that already said how it ended keeps that verdict: the answer was over.
            if let stop {
                return PumpOutcome(text: full, input: input, output: output,
                                   failure: endFailure(stop, cancelled: false, text: full, provider: provider), stop: stop)
            }
            let failure: PumpFailure
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                failure = .cancelled
            } else if isTransient(error) {
                failure = .transient(friendlyError(error, provider: provider))
            } else {
                failure = .permanent(friendlyError(error, provider: provider))
            }
            return PumpOutcome(text: full, input: input, output: output, failure: failure)
        }
    }

    /// How a stream that ran to its end (or was stopped) is classified. The provider's own end
    /// signal wins, so a Stop that lands as an answer finishes keeps it complete; with no signal, a
    /// cancelled task means the user stopped it. A cut-off answer is no failure (`stop` says it).
    private nonisolated static func endFailure(_ stop: StreamChunk.StopReason?, cancelled: Bool,
                                               text: String, provider: LLMProvider) -> PumpFailure? {
        switch stop {
        case .endedEarly?:
            return .stalled(text.isEmpty
                ? "\(provider.panelName)'s connection ended before it answered."
                : "\(provider.panelName)'s connection ended before it finished.")
        case .finished?, .lengthLimit?, .unknown?:
            return nil
        case nil:
            return cancelled ? .cancelled : nil
        }
    }

    /// A transient connection failure worth one automatic retry (vs a permanent auth/model error,
    /// which a retry wouldn't fix).
    private nonisolated static func isTransient(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
             .notConnectedToInternet, .cannotLoadFromNetwork, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default: return false
        }
    }

    /// Turn a raw networking error into a clear, provider-aware message. The common confusing case
    /// is a local Ollama that simply isn't running — say so plainly instead of "Could not connect…".
    private nonisolated static func friendlyError(_ error: Error, provider: LLMProvider) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .timedOut, .cannotLoadFromNetwork, .dnsLookupFailed:
                if provider == .ollama {
                    return "Can't reach Ollama at \(LLMProvider.ollamaHost) — is it running? Start it with 'ollama serve', or set a different address in Settings → Models."
                }
                if let slot = provider.customSlot {
                    return "Can't reach \(provider.panelName) at \(LLMProvider.customHost(slot)) — is the server running and reachable from this Mac?"
                }
                return "Couldn't reach \(provider.panelName). Check your connection and try again."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    // MARK: - Export

    public func exportMarkdown() -> String {
        // Attribute by what's RECORDED on the round, not the current seat assignment — a reopened
        // session may have different (or no) providers on its seats today.
        func name(_ round: Round, _ seatID: Int) -> String {
            round.answerProviders[seatID] ?? seats.first { $0.id == seatID }?.provider?.panelName ?? "Advisor"
        }
        // A seat that answered but was excluded from deliberation gets an honest "(sat out)" tag —
        // only on rounds that actually deliberated, or every answer in an un-analyzed round would
        // read as having been left out of something that never happened.
        func satOut(_ round: Round, _ seatID: Int) -> String {
            guard round.peerReviews.values.contains(where: { !$0.isEmpty }) || round.divergence != nil,
                  let inc = round.includedSeatIDs, !inc.contains(seatID) else { return "" }
            return " *(sat out of deliberation)*"
        }
        // An answer that ended early says why, and a seat that was asked but kept nothing says it
        // did not answer. Rounds saved before 1.3.2 record no status, so they export as before.
        func ended(_ round: Round, _ seatID: Int) -> String {
            round.statusLabel(seatID).map { " *(\($0))*" } ?? ""
        }
        var out = "# Council\n\n"
        for (i, round) in rounds.enumerated() where !round.answeredSeatIDs.isEmpty {
            out += "## Round \(i + 1) — \(round.question)\n\n"
            for seat in seats {
                let model = exportModelTag(seat, round)
                if let answer = round.answers[seat.id], !answer.isEmpty {
                    out += "### \(name(round, seat.id))\(model)\(ended(round, seat.id))\(satOut(round, seat.id))\n\n\(answer)\n\n"
                } else if didNotAnswer(seat, in: round) {
                    out += "### \(name(round, seat.id))\(model)\(ended(round, seat.id))\n\n"
                }
            }
            if let g = round.guestAnswer {
                out += "### \(round.guestName) — guest (pasted answer)\(satOut(round, Round.guestSeatID))\n\n\(g)\n\n"
            }
            let reviews = seats.filter { !((round.peerReviews[$0.id] ?? "").isEmpty) }
            if !reviews.isEmpty {
                out += "#### Peer Review\n\n"
                for seat in reviews { out += "**\(name(round, seat.id)):** \(round.peerReviews[seat.id] ?? "")\n\n" }
            }
            let rebuts = seats.filter { !((round.rebuttals[$0.id] ?? "").isEmpty) }
            if !rebuts.isEmpty {
                out += "#### Debate — final takes\n\n"
                for seat in rebuts { out += "**\(name(round, seat.id)):** \(round.rebuttals[seat.id] ?? "")\n\n" }
            }
            if let d = round.divergence { out += "#### Divergence\n\n\(d)\n\n" }
            if let s = round.synthesis { out += "#### Synthesis\n\n\(s)\n\n" }
            if let c = round.chairSummary { out += "#### Chair's summary\n\n\(c)\n\n" }
        }
        if let cur = sessions.first(where: { $0.id == currentSessionID }),
           let d = cur.decision, !d.isEmpty {
            out += "## Decision\n\n\(d)\n\n"
            if let o = cur.outcome, !o.isEmpty { out += "**How it turned out:** \(o)\n\n" }
        }
        return out
    }

    /// A decision-ready Markdown memo for the VIEWED round — readable enough to paste into a
    /// design doc or ADR as-is. Excerpts (not full transcripts) for answers; full synthesis.
    /// No keys, no internal ids.
    /// First markdown paragraph of a text, capped — a deterministic, zero-cost "summary".
    /// Shared by the decision memo and the Engram memory composer.
    private static func excerpt(_ text: String, cap: Int = 500) -> String {
        let para = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? text
        let flat = para.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= cap ? flat : String(flat.prefix(cap)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The " — `model`" tag an export puts after a seat's name. The model recorded with the answer
    /// wins: it is what actually ran, whatever the seat runs today. A round saved before 1.3.2
    /// records none: a read-only recording then uses the model ids recorded with it (none recorded
    /// → no tag), never this viewer's seats, and any other session attaches the seat's current id
    /// only when its current provider is the one that answered.
    private func exportModelTag(_ seat: Seat, _ round: Round) -> String {
        if let m = round.answerModels[seat.id], !m.isEmpty { return " — `\(m)`" }
        if isReadOnlySession {
            guard let m = readOnlyModels[seat.id], !m.isEmpty else { return "" }
            return " — `\(m)`"
        }
        return (seat.provider?.panelName == round.answerProviders[seat.id]) ? " — `\(seat.model)`" : ""
    }

    /// True when this seat was asked in the round but kept no answer, and it still runs the model
    /// it was asked with. A seat that failed records no provider, so after a lineup change (or in a
    /// recording, whose seats aren't this viewer's) the miss can't be pinned on the right advisor:
    /// the export then leaves it out rather than name the wrong one.
    private func didNotAnswer(_ seat: Seat, in round: Round) -> Bool {
        guard !isReadOnlySession, round.answers[seat.id]?.isEmpty ?? true,
              round.answerStatuses[seat.id] != nil, let model = calledModel(seat) else { return false }
        return round.answerModels[seat.id] == model
    }

    public func exportDecisionMemo() -> String {
        guard rounds.indices.contains(viewingRound) else { return "" }
        let round = rounds[viewingRound]

        func excerpt(_ text: String, cap: Int = 500) -> String { Self.excerpt(text, cap: cap) }
        func name(_ seatID: Int) -> String {
            round.answerProviders[seatID] ?? seats.first { $0.id == seatID }?.provider?.panelName ?? "Advisor"
        }

        let df = ISO8601DateFormatter(); df.formatOptions = [.withFullDate]
        var out = "# Council decision memo\n\n"
        out += "*\(df.string(from: Date()))*\n\n"
        out += "## Question\n\n\(round.question)\n\n"

        func satOut(_ seatID: Int) -> String {
            guard round.peerReviews.values.contains(where: { !$0.isEmpty }) || round.divergence != nil,
                  let inc = round.includedSeatIDs, !inc.contains(seatID) else { return "" }
            return " (sat out)"
        }
        // The same short label as the full export: why an answer is incomplete, or "did not answer".
        func ended(_ seatID: Int) -> String { round.statusLabel(seatID).map { " (\($0))" } ?? "" }
        out += "## Council\n\n"
        for seat in seats {
            let model = exportModelTag(seat, round)
            if round.answers[seat.id]?.isEmpty == false {
                out += "- \(name(seat.id))\(model)\(ended(seat.id))\(satOut(seat.id))\n"
            } else if didNotAnswer(seat, in: round) {
                out += "- \(name(seat.id))\(model)\(ended(seat.id))\n"
            }
        }
        if round.guestAnswer != nil {
            out += "- \(round.guestName) — guest (pasted answer)\(satOut(Round.guestSeatID))\n"
        }
        out += "\n## Answers (excerpts)\n\n"
        for seat in seats {
            if let a = round.answers[seat.id], !a.isEmpty {
                out += "**\(name(seat.id))\(ended(seat.id)):** \(excerpt(a))\n\n"
            }
        }
        if let g = round.guestAnswer {
            out += "**\(round.guestName) (guest):** \(excerpt(g))\n\n"
        }

        if let agreement = round.divergenceScore {
            out += "## Divergence\n\n"
            out += "- **Divergence: \(100 - agreement)/100** (how far apart the council landed)\n"
            if let c = round.divergenceCamps { out += "- Camps: \(c)\n" }
            if let o = round.outlier { out += "- Outlier: \(o)\n" }
            out += "\n*Measures agreement, not correctness — models can share the same blind spot.*\n\n"
        }
        // The memo's round is the viewed one, so this is the same answer the Dissent card shows.
        if let outlier = round.outlier, let sid = dissentSeatID, let d = round.answers[sid], !d.isEmpty {
            out += "## Minority view — \(outlier)\(ended(sid))\n\n\(excerpt(d, cap: 700))\n\n"
        }
        if let s = round.synthesis, !s.isEmpty {
            out += "## Synthesis\n\n\(s)\n\n"
        }
        if let c = round.chairSummary, !c.isEmpty {
            out += "## Chair's summary\n\n\(c)\n\n"
        }
        if let cur = sessions.first(where: { $0.id == currentSessionID }),
           let d = cur.decision, !d.isEmpty {
            out += "## Decision\n\n\(d)\n\n"
            if let o = cur.outcome, !o.isEmpty { out += "**Outcome:** \(o)\n\n" }
        }
        return out
    }

    // MARK: - Sessions (local multi-session history — one JSON file each, no server)

    public var sessions: [Session] = [] { didSet { recomputeDashboardAggregates() } }
    private var currentSessionID = UUID()
    private var currentTitle = ""
    private var currentCreatedAt = Date()
    public var currentSession: UUID { currentSessionID }

    public static var sessionsFolderURL: URL? {
        let fm = FileManager.default
        // Explicit override — used by the unit tests (which must never touch the real container:
        // enumerating another app's container from an unsigned test binary blocks the whole suite
        // on a TCC prompt) and available to power users who want history elsewhere.
        if let override = ProcessInfo.processInfo.environment["COUNCIL_SESSIONS_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        // Inside the sandboxed app, application-support already resolves into the app container.
        // A NON-sandboxed process (the `council` CLI) must target that container explicitly, so
        // CLI runs land in the same history the app shows.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
            let container = fm.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Containers/com.joseph.Council/Data/Library/Application Support/Council/Sessions")
            if fm.fileExists(atPath: container.path) { return container }
        }
        guard let base = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("Council/Sessions", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var conversationFolderDisplayPath: String {
        guard let dir = Self.sessionsFolderURL else { return "—" }
        return dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
    public var conversationFileDisplayPath: String { conversationFolderDisplayPath }

    private func sessionURL(_ id: UUID) -> URL? {
        Self.sessionsFolderURL?.appendingPathComponent("\(id.uuidString).json")
    }
    /// How session files are written and read. Internal so the tests round-trip through it.
    static var sessionCoder: (enc: JSONEncoder, dec: JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    /// Reads every saved session (newest first) and opens the newest one as the current session.
    /// The app's history read: `init` calls it only for the Council app (see `init(loadHistory:)`).
    public func loadSessions() {
        guard let dir = Self.sessionsFolderURL,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let dec = Self.sessionCoder.dec
        var loaded: [Session] = []
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let s = try? dec.decode(Session.self, from: data) { loaded.append(s) }
        }
        sessions = loaded.sorted { $0.updatedAt > $1.updatedAt }
        if let recent = sessions.first { apply(recent) }
    }

    private var derivedTitle: String {
        let q = (rounds.first?.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? "Untitled" : String(q.prefix(48))
    }

    public func saveConversation() {
        // A read-only session (the example council) must never enter history, the journal or disk.
        guard persistenceEnabled, hasSession, !isReadOnlySession else { return }
        if currentTitle.isEmpty { currentTitle = derivedTitle }
        let prior = sessions.first { $0.id == currentSessionID }
        var s = Session(id: currentSessionID, title: currentTitle,
                        createdAt: currentCreatedAt, updatedAt: Date(),
                        rounds: rounds, history: [:])   // history is reconstructed from rounds on load — not persisted
        // Carry the decision-journal fields forward — they live out-of-band from the live round state,
        // so a plain rebuild would silently wipe them on the next save.
        s.decision = prior?.decision; s.decisionAt = prior?.decisionAt
        s.outcome = prior?.outcome; s.outcomeAt = prior?.outcomeAt
        s.remindAt = prior?.remindAt
        s.engramMemoryID = prior?.engramMemoryID; s.engramRememberedAt = prior?.engramRememberedAt
        // In-memory state updates immediately (the UI reads `sessions`); the DISK write is
        // coalesced. Encoding a whole session — every round, every review, every synthesis — is the
        // expensive half, and rapid callers (a deliberation-chip tap, several stages finishing
        // together) used to pay it in full each time.
        sessions.removeAll { $0.id == s.id }
        sessions.insert(s, at: 0)
        haystackCache[s.id] = nil   // its transcript changed → rebuild on next search
        scheduleSessionWrite(s.id)
        checkSpendAlert()
    }

    /// Pending coalesced disk write, if one is queued.
    private var pendingWrite: (id: UUID, task: Task<Void, Never>)?

    /// Queue a debounced write of one session. A newer call replaces an older pending one for the
    /// same session, so a burst of mutations costs a single encode + a single atomic write.
    private func scheduleSessionWrite(_ id: UUID, delay: Duration = .milliseconds(400)) {
        guard persistenceEnabled else { return }
        if let p = pendingWrite, p.id == id { p.task.cancel() }
        else if pendingWrite != nil { flushPendingWrite() }   // different session → don't lose it
        pendingWrite = (id, Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingWrite = nil
            self.writeSessionNow(id)
        })
    }

    /// Write any queued session NOW, synchronously, and wait for any write already in flight. When
    /// this returns, every session edit made so far is on disk. Call it before anything that must
    /// not lose the last edit: quitting the app, a CLI exit, switching or deleting sessions.
    /// (The queued write used to go to a detached task, so a process that exited right after this
    /// call could still lose it: the CLI's last stages, or the app's final write on quit.)
    public func flushPendingWrite() {
        if let p = pendingWrite {
            p.task.cancel()
            pendingWrite = nil
            writeSessionNow(p.id)
        }
        Self.sessionWriteQueue.sync {}   // returns once every write handed to the queue has landed
    }

    /// Every session file write goes through this one serial queue. Writes land in the order they
    /// were made (two detached writes could finish out of order and leave the older copy on disk),
    /// and `flushPendingWrite` can wait for whatever is still in flight.
    private nonisolated static let sessionWriteQueue = DispatchQueue(label: "council.session-writes", qos: .utility)

    private func writeSessionNow(_ id: UUID) {
        guard persistenceEnabled, let s = sessions.first(where: { $0.id == id }),
              let url = sessionURL(id), let data = try? Self.sessionCoder.enc.encode(s) else { return }
        // Atomic disk write off the MainActor (Data is Sendable) so the I/O doesn't hitch the UI.
        Self.sessionWriteQueue.async { _ = try? data.write(to: url, options: .atomic) }
    }

    // MARK: - Decision journal (local only)

    /// Sessions that have a recorded decision, newest decision first — the journal feed.
    public var journal: [Session] {
        sessions.filter { ($0.decision?.isEmpty == false) }
                .sorted { ($0.decisionAt ?? .distantPast) > ($1.decisionAt ?? .distantPast) }
    }
    /// Journal entries matching a free-text query over the decision, the outcome and the session
    /// title — the journal is where the value accumulates, so it has to be findable years later.
    public func searchedJournal(_ query: String) -> [Session] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return journal }
        return journal.filter {
            $0.title.lowercased().contains(q)
                || ($0.decision ?? "").lowercased().contains(q)
                || ($0.outcome ?? "").lowercased().contains(q)
        }
    }

    /// Decisions with no outcome recorded yet — the open loops, whether or not a reminder was set.
    public var awaitingOutcome: [Session] {
        journal.filter { ($0.outcome ?? "").isEmpty }
    }

    /// The whole decision journal as one Markdown document: what you decided, when, how it turned
    /// out, and the question that prompted it. Deliberately NOT the transcripts — this is the log
    /// of judgements, which is the part worth keeping.
    public func exportJournal() -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        var out = "# Decision journal\n\n"
        let entries = journal
        guard !entries.isEmpty else { return out + "_No decisions recorded yet._\n" }
        let closed = entries.filter { !($0.outcome ?? "").isEmpty }.count
        out += "_\(entries.count) decision\(entries.count == 1 ? "" : "s") · \(closed) with an outcome recorded._\n\n"
        for s in entries {
            out += "## \(s.title.isEmpty ? "Untitled" : s.title)\n\n"
            if let at = s.decisionAt { out += "*\(df.string(from: at))*\n\n" }
            if let q = s.rounds.last?.question, !q.isEmpty {
                out += "**Question:** \(Self.excerpt(q, cap: 300))\n\n"
            }
            out += "**Decided:** \(s.decision ?? "")\n\n"
            if let o = s.outcome, !o.isEmpty {
                out += "**How it turned out:** \(o)"
                if let oa = s.outcomeAt { out += " *(\(df.string(from: oa)))*" }
                out += "\n\n"
            } else {
                out += "*Outcome not recorded yet.*\n\n"
            }
            out += "---\n\n"
        }
        return out
    }

    /// Record (or update) what the user actually decided after this council.
    public func recordDecision(_ text: String, for id: UUID) {
        guard !isReadOnly(id) else { return }
        if id == currentSessionID && !sessions.contains(where: { $0.id == id }) { saveConversation() }
        updateSession(id) { $0.decision = text; $0.decisionAt = Date() }
        syncReminderNotifications()
    }
    /// Record how a past decision turned out — closing the loop on whether the council's read held up.
    /// Logging the outcome also clears any pending reminder: the loop is closed.
    public func recordOutcome(_ text: String, for id: UUID) {
        guard !isReadOnly(id) else { return }
        updateSession(id) { $0.outcome = text; $0.outcomeAt = Date(); $0.remindAt = nil }
        syncReminderNotifications()   // the loop is closed → its notification goes away
    }

    /// Set (or clear, with nil) the outcome reminder on a journal entry.
    public func setReminder(_ date: Date?, for id: UUID) {
        guard !isReadOnly(id) else { return }   // and never ask notification permission for it
        // Whole minutes: the notification trigger has minute resolution, so the card must count the
        // reminder as due the moment the banner fires — not 47 seconds later.
        let date = date.map { Calendar.current.date(bySetting: .second, value: 0, of: $0) ?? $0 }
        updateSession(id) { $0.remindAt = date }
        if date != nil {
            // First reminder ever → macOS asks once. Later ones just re-sync.
            Task { @MainActor in _ = await requestReminderNotificationPermission(); syncReminderNotifications() }
        } else {
            syncReminderNotifications()
        }
    }

    /// Journal entries whose reminder has come due — decision logged, outcome still open, remindAt
    /// passed. Computed against Date() on read: dueness refreshes on launch and on interaction,
    /// which is the right granularity for week-scale reminders (deliberately NO timer — @Observable
    /// can't track wall-clock time, and a ticking clock for a calm weekly nudge is noise).
    public var dueReminders: [Session] {
        let now = Date()
        return sessions.filter {
            ($0.decision?.isEmpty == false) && (($0.outcome ?? "").isEmpty)
                && ($0.remindAt.map { $0 <= now } ?? false)
        }
        .sorted { ($0.remindAt ?? .distantPast) < ($1.remindAt ?? .distantPast) }
    }

    // MARK: - Engram bridge (engine side: pure text + markers; the app does the writing)

    /// A short, self-contained memory of a journal decision, for the user's Engram store. Contains
    /// ONLY journal fields + the round's public verdict — never keys, transcripts, or attachments.
    public func engramMemoryText(for session: Session) -> String {
        let df = ISO8601DateFormatter(); df.formatOptions = [.withFullDate]
        var out = "Council decision"
        if let at = session.decisionAt { out += " (\(df.string(from: at)))" }
        out += ": \(session.decision ?? "")"
        if let q = session.rounds.last?.question, !q.isEmpty {
            out += "\nQuestion: \(Self.excerpt(q, cap: 200))"
        }
        if let r = session.rounds.last, let agreement = r.divergenceScore {
            out += "\nCouncil divergence: \(100 - agreement)/100"
            if let o = r.outlier { out += " — dissent from \(o)" }
        }
        if let o = session.outcome, !o.isEmpty {
            out += "\nOutcome: \(o)"
        }
        return out
    }

    /// Mark a journal entry as remembered in Engram (persists the marker with the session).
    public func markRememberedInEngram(_ id: UUID, memoryID: UUID) {
        guard !isReadOnly(id) else { return }
        updateSession(id) { $0.engramMemoryID = memoryID; $0.engramRememberedAt = Date() }
    }
    private func updateSession(_ id: UUID, _ mutate: (inout Session) -> Void) {
        guard !isReadOnly(id), let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[i])
        haystackCache[id] = nil   // the journal text is searchable → rebuild on next search
        // Same no-trace gate as every other write path: a non-persisting store (facade, --no-save,
        // tests) mutates only its in-memory copy.
        guard persistenceEnabled else { return }
        // Journal edits are deliberate, low-frequency and easy to lose track of (typing an outcome,
        // setting a reminder), so they go straight to disk rather than through the debounce.
        writeSessionNow(id)
    }

    /// Rebuild each seat's replay history from saved rounds. `history` is no longer persisted in the
    /// session file (it duplicated every answer's full text); we reconstruct it on load, mirroring how
    /// finishAnswer builds it incrementally — one user(question)+assistant(answer) pair per round the
    /// seat answered, in round order. Sessions saved before this still carry `history`, used as-is.
    /// Like finishAnswer, it leaves out an answer that ended early; one with no recorded status
    /// (saved before 1.3.2) counts as complete.
    static func reconstructHistory(from rounds: [Round]) -> [Int: [ChatMessage]] {
        var h: [Int: [ChatMessage]] = [:]
        for r in rounds {
            // The guest sentinel never calls a model, so it has no replay history.
            for (seatID, answer) in r.answers where !answer.isEmpty && seatID != Round.guestSeatID
                && (r.answerStatuses[seatID] ?? .complete) == .complete {
                h[seatID, default: []].append(.user(r.question))
                h[seatID, default: []].append(.assistant(answer))
            }
        }
        return h
    }

    private func apply(_ s: Session) {
        isReadOnlySession = false   // only openReadOnly opens a session for reading
        readOnlyModels = [:]
        currentSessionID = s.id
        currentTitle = s.title
        currentCreatedAt = s.createdAt
        rounds = s.rounds
        // Reconstruct replay history from rounds (no longer persisted); fall back to an older
        // session's stored history if present.
        history = s.history.isEmpty ? Self.reconstructHistory(from: s.rounds) : s.history
        viewingRound = max(0, rounds.count - 1)
        status = [:]
        clearDeliberationErrors()
    }

    public func openSession(_ s: Session) {
        guard !anyLoading else { return }   // don't swap rounds out from under a running task
        flushPendingWrite()                 // never carry a queued write across a session switch
        apply(s)
    }

    // MARK: - Read-only session (the bundled example council)

    /// True while the current session is open for READING only: the bundled example council,
    /// recorded with someone else's keys. Nothing may run against it, change it, or persist it.
    /// Every mutator refuses, deliberation reports itself unavailable, and its recorded seats count
    /// as participants whatever keys this viewer has (so nothing shows SAT OUT). Opening any other
    /// session, or starting a new one, clears it.
    public private(set) var isReadOnlySession = false
    /// Model ids recorded with the read-only session, by seat id (see `openReadOnly`).
    private var readOnlyModels: [Int: String] = [:]

    /// Show a recorded session without adopting it. It never joins `sessions`, the journal or the
    /// sessions folder, and nothing can run against it (see `isReadOnlySession`). The session being
    /// left is flushed to disk first, like any switch. Returns false, and changes nothing, while
    /// something is generating. `models` (seat id → model id) is what the recording was made with;
    /// exports use it instead of this viewer's seat models (session files don't record model ids).
    @discardableResult
    public func openReadOnly(_ s: Session, models: [Int: String] = [:]) -> Bool {
        guard !anyLoading else { return false }
        flushPendingWrite()
        apply(s)
        isReadOnlySession = true
        readOnlyModels = models
        chairFallbackNote = nil   // a note about today's chair doesn't belong on a recording
        return true
    }

    /// True for the read-only session's own id. Journal edits for OTHER sessions still work while
    /// the example is on screen (the Journal screen stays usable); only the example itself refuses.
    private func isReadOnly(_ id: UUID) -> Bool { isReadOnlySession && id == currentSessionID }

    public func newSession() {
        guard !anyLoading else { return }
        flushPendingWrite()   // the session being left must land on disk complete
        isReadOnlySession = false
        currentSessionID = UUID()
        currentTitle = ""
        currentCreatedAt = Date()
        rounds = []
        viewingRound = 0
        status = [:]
        liveAnswers = [:]
        livePeerReviews = [:]; liveRebuttals = [:]
        liveDivergence = nil; liveSynthesis = nil
        liveChairSummary = nil
        history = [:]
        clearDeliberationErrors()
    }

    public func renameSession(_ id: UUID, to title: String) {
        guard !isReadOnly(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if id == currentSessionID { currentTitle = t }
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].title = t
        guard persistenceEnabled else { return }
        writeSessionNow(id)
    }

    public func deleteSession(_ id: UUID) {
        // Deleting the active session resets rounds → must not happen mid-generation.
        if id == currentSessionID && anyLoading { return }
        // Drop any queued write for this session, or it would recreate the file after deletion.
        if let p = pendingWrite, p.id == id { p.task.cancel(); pendingWrite = nil }
        // Remove on the write queue, so a write already handed to it (a rename, a journal edit, a
        // flush) lands first and can't recreate the file after it's gone.
        if let url = sessionURL(id) {
            Self.sessionWriteQueue.sync { try? FileManager.default.removeItem(at: url) }
        }
        sessions.removeAll { $0.id == id }
        if id == currentSessionID { newSession() }
        syncReminderNotifications()   // a deleted decision must not ping a week later
    }

    /// Lowercased search text per session, built once and reused so typing in the history search
    /// doesn't rebuild every transcript on every keystroke. Invalidated when a session is saved.
    private var haystackCache: [UUID: String] = [:]
    private func haystack(_ s: Session) -> String {
        if let cached = haystackCache[s.id] { return cached }
        let h = s.searchHaystack
        haystackCache[s.id] = h
        return h
    }

    public func searchedSessions(_ query: String) -> [Session] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.isEmpty ? sessions : sessions.filter { haystack($0).contains(q) }
    }

    public func revealConversationFolder() {
        guard let dir = Self.sessionsFolderURL else { return }
        NSWorkspace.shared.open(dir)
    }
}
