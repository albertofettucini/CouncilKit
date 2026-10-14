import XCTest
import Foundation
@testable import CouncilKit

/// Fast, deterministic unit tests for the CouncilKit facade — no network, and no writes to the
/// real Keychain or to the app's saved state. They lock in the public API shape, the error
/// contract, and the persistence isolation that the live run + adversarial review hardened.
///
/// Keys are supplied via `COUNCIL_KEY_*` env overrides (set in `setUp`) so the tests never prompt
/// for Keychain access; the values are dummies and no test makes a network call.
final class CouncilKitTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeychainStore.allowEnvOverride = true
        setenv("COUNCIL_KEY_CLAUDE", "test-key", 1)
        setenv("COUNCIL_KEY_OPENAI", "test-key", 1)
        setenv("COUNCIL_KEY_GEMINI", "test-key", 1)
        // Hermetic sessions dir: enumerating the real app container from an unsigned xctest binary
        // blocks the whole suite on a TCC prompt (and would read the dev's real history).
        setenv("COUNCIL_SESSIONS_DIR", NSTemporaryDirectory() + "council-unit-tests/Sessions", 1)
    }

    override func tearDown() {
        unsetenv("COUNCIL_KEY_CLAUDE")
        unsetenv("COUNCIL_KEY_OPENAI")
        unsetenv("COUNCIL_KEY_GEMINI")
        unsetenv("COUNCIL_SESSIONS_DIR")
        KeychainStore.allowEnvOverride = false
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "council-unit-tests")
        super.tearDown()
    }

    // MARK: - History reconstruction (#12: history is no longer persisted; rebuilt from rounds on load)

    @MainActor
    func testReconstructHistoryFromRounds() {
        var r1 = Round(question: "Q1"); r1.answers = [0: "A1-0", 1: "A1-1"]
        var r2 = Round(question: "Q2"); r2.answers = [0: "A2-0"]   // seat 1 didn't answer round 2
        let h = CouncilStore.reconstructHistory(from: [r1, r2])
        XCTAssertEqual(h[0]?.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(h[0]?.map(\.text), ["Q1", "A1-0", "Q2", "A2-0"])   // round order preserved
        XCTAssertEqual(h[1]?.map(\.text), ["Q1", "A1-1"])                 // only the round it answered
    }

    @MainActor
    func testReconstructHistorySkipsEmptyAnswers() {
        var r = Round(question: "Q"); r.answers = [0: "", 1: "real"]   // seat 0 has no answer yet
        let h = CouncilStore.reconstructHistory(from: [r])
        XCTAssertNil(h[0])                                              // empty answer → no history entry
        XCTAssertEqual(h[1]?.map(\.text), ["Q", "real"])
    }

    // MARK: - Public API shape

    func testGptAliasMapsToOpenAI() {
        XCTAssertEqual(Backend.gpt, .openAI)
    }

    func testAdvisorDefaults() {
        let a = Advisor(backend: .claude)
        XCTAssertEqual(a.backend, .claude)
        guard case .analyst = a.persona else { return XCTFail("default persona should be .analyst") }
        XCTAssertNil(a.model)
    }

    @MainActor func testCustomPersonaPassesThrough() {
        XCTAssertEqual(Persona.custom("be terse").systemPrompt, "be terse")
    }

    @MainActor func testBuiltinPersonasAreDistinctAndNonEmpty() {
        let prompts = [Persona.analyst, .practitioner, .skeptic, .devilsAdvocate].map(\.systemPrompt)
        XCTAssertFalse(prompts.contains(where: \.isEmpty), "no built-in persona prompt should be empty")
        XCTAssertEqual(Set(prompts).count, prompts.count, "built-in personas should be distinct")
    }

    // MARK: - Error contract (guards fire before any store / network / Keychain access)

    @MainActor func testEmptyAdvisorsThrowsNoAdvisors() async {
        do {
            _ = try await Council(advisors: []).deliberate("anything")
            XCTFail("expected .noAdvisors")
        } catch CouncilError.noAdvisors {
            // expected
        } catch {
            XCTFail("expected .noAdvisors, got \(error)")
        }
    }

    @MainActor func testTooManyAdvisorsThrows() {
        let many = Array(repeating: Advisor(backend: .claude), count: 99)
        XCTAssertThrowsError(try Council.configuredStore(many)) { error in
            guard case CouncilError.tooManyAdvisors = error else {
                return XCTFail("expected .tooManyAdvisors, got \(error)")
            }
        }
    }

    // MARK: - Persistence isolation (regression guards for the P1 data-corruption fixes)

    @MainActor func testNonPersistingStoreDoesNotOverwriteSavedSeats() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        let key = "council.seats.v7"                                   // CouncilStore.seatsKey (private)
        let before = UserDefaults.standard.data(forKey: key)
        if let sid = store.seats.first?.id { store.setProvider(.claude, seatID: sid) }  // → saveSeats()
        store.saveSeats()
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), before,
                       "a non-persisting store must not overwrite the app's saved seat lineup")
    }

    @MainActor func testNonPersistingStoreDoesNotOverwriteRoleSeats() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        let devilBefore = UserDefaults.standard.object(forKey: "council.devilsAdvocate") as? Int
        let synthBefore = UserDefaults.standard.object(forKey: "council.synthesizerSeat") as? Int
        store.devilsAdvocateSeatID = 99
        store.synthesizerSeatID = 99
        XCTAssertEqual(UserDefaults.standard.object(forKey: "council.devilsAdvocate") as? Int, devilBefore,
                       "a non-persisting store must not overwrite the saved devil's-advocate seat")
        XCTAssertEqual(UserDefaults.standard.object(forKey: "council.synthesizerSeat") as? Int, synthBefore,
                       "a non-persisting store must not overwrite the saved synthesizer seat")
    }

    // MARK: - Facade isolates itself from any leaked app state

    @MainActor func testConfiguredStoreNeutralizesLeakedRoleStateAndStaysNonPersisting() throws {
        let store = try Council.configuredStore([
            Advisor(backend: .claude, persona: .analyst),
            Advisor(backend: .claude, persona: .skeptic),
        ])
        XCTAssertEqual(store.devilsAdvocateSeatID, -1, "facade must neutralize any leaked devil's-advocate seat")
        XCTAssertEqual(store.synthesizerSeatID, -1, "facade must reset the synthesizer seat to auto")
        XCTAssertNil(store.chairSeat, "facade must never inherit the app user's persisted chair (their spend)")
        XCTAssertFalse(store.persistenceEnabled, "a facade store must never persist")
    }

    // MARK: - Round / Session / Config codable back-compat (new v1.2 fields)

    func testRoundCodableRoundTripsNewFieldsAndDecodesLegacy() throws {
        var r = Round(question: "Q")
        r.answers[Round.guestSeatID] = "guest text"
        r.answerProviders[Round.guestSeatID] = "ChatGPT"
        r.includedSeatIDs = [0, Round.guestSeatID]
        r.chairSummary = "who moved, who held"
        let back = try JSONDecoder().decode(Round.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.guestAnswer, "guest text")
        XCTAssertEqual(back.guestName, "ChatGPT")
        XCTAssertEqual(back.includedSeatIDs, [0, Round.guestSeatID])
        XCTAssertEqual(back.chairSummary, "who moved, who held")

        let legacy = try JSONDecoder().decode(Round.self, from: Data(#"{"question":"Q"}"#.utf8))
        XCTAssertNil(legacy.includedSeatIDs)
        XCTAssertNil(legacy.chairSummary)
        XCTAssertNil(legacy.guestAnswer)
        XCTAssertEqual(legacy.guestName, "Guest")
    }

    func testSessionCodableRoundTripsReminderAndEngramFieldsAndDecodesLegacy() throws {
        var s = Session(id: UUID(), title: "T", createdAt: Date(), updatedAt: Date(), rounds: [], history: [:])
        s.decision = "d"
        s.remindAt = Date(timeIntervalSince1970: 1_000_000)
        s.engramMemoryID = UUID()
        s.engramRememberedAt = Date(timeIntervalSince1970: 2_000_000)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Session.self, from: enc.encode(s))
        XCTAssertEqual(back.remindAt, s.remindAt)
        XCTAssertEqual(back.engramMemoryID, s.engramMemoryID)
        XCTAssertEqual(back.engramRememberedAt, s.engramRememberedAt)

        // A pre-1.2 session file (no reminder/engram keys).
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","title":"T","createdAt":"2026-01-01T00:00:00Z",
         "updatedAt":"2026-01-01T00:00:00Z","rounds":[],"history":{}}
        """
        let legacy = try dec.decode(Session.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.remindAt)
        XCTAssertNil(legacy.engramMemoryID)
    }

    @MainActor func testConfigCarriesChairAndLegacyConfigsDecodeWithout() throws {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.setChair(.gemini)
        let cfg = store.currentConfig(name: "with chair")
        let back = try JSONDecoder().decode(CouncilConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertNotNil(back.chair, "exported config must carry the chair")

        let store2 = CouncilStore()
        store2.persistenceEnabled = false
        store2.applyConfig(back)
        XCTAssertEqual(store2.chairSeat?.provider, .gemini, "importing a chaired config must set the chair")
        XCTAssertEqual(store2.chairSeat?.id, Seat.chairID)

        let legacy = try JSONDecoder().decode(
            CouncilConfig.self, from: Data(#"{"name":"x","seats":[],"sharedSystemPrompt":""}"#.utf8))
        XCTAssertNil(legacy.chair, "pre-chair configs must decode with no chair")
    }

    // MARK: - Guest seat

    @MainActor func testGuestUnlocksDeliberationWithOneRealSeat() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        let sid = store.seats[0].id
        store.setProvider(.claude, seatID: sid)
        for s in store.seats.dropFirst() { store.clearProvider(seatID: s.id) }
        var r = Round(question: "Q")
        r.answers[sid] = "real answer"
        store.rounds = [r]
        store.viewingRound = 0
        XCTAssertFalse(store.canPeerReview, "a single real answer can't deliberate alone")

        store.addGuestAnswer("pasted external answer", name: "ChatGPT")
        XCTAssertTrue(store.canPeerReview, "1 real advisor + a guest is a council of two")
        XCTAssertEqual(store.viewedGuestAnswer, "pasted external answer")
        XCTAssertEqual(store.viewedGuestName, "ChatGPT")

        store.removeGuestAnswer()
        XCTAssertNil(store.viewedGuestAnswer)
        XCTAssertFalse(store.canPeerReview)
    }

    @MainActor func testGuestOnlyRoundIsNotASession() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        var r = Round(question: "Q")
        r.answers[Round.guestSeatID] = "only a pasted answer"   // every real seat failed
        store.rounds = [r]
        XCTAssertFalse(store.hasSession, "a guest-only round must not persist as a council session")
    }

    @MainActor func testAddingGuestInvalidatesStaleDeliberation() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        let s0 = store.seats[0].id, s1 = store.seats[1].id
        store.setProvider(.claude, seatID: s0)
        store.setProvider(.openAI, seatID: s1)
        var r = Round(question: "Q")
        r.answers[s0] = "a"; r.answers[s1] = "b"
        r.divergence = "stale"; r.synthesis = "stale"; r.divergenceScore = 10
        r.chairSummary = "stale"
        store.rounds = [r]
        store.viewingRound = 0
        store.addGuestAnswer("new position")
        XCTAssertNil(store.rounds[0].divergence, "a new participant invalidates old analysis")
        XCTAssertNil(store.rounds[0].synthesis)
        XCTAssertNil(store.rounds[0].divergenceScore)
        XCTAssertNil(store.rounds[0].chairSummary)
        XCTAssertEqual(store.rounds[0].guestAnswer, "new position")
    }

    // MARK: - Selective deliberation

    @MainActor func testDeliberationSelectionValidatesAndInvalidates() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        let s0 = store.seats[0].id, s1 = store.seats[1].id, s2 = store.seats[2].id
        store.setProvider(.claude, seatID: s0)
        store.setProvider(.openAI, seatID: s1)
        store.clearProvider(seatID: s2)
        var r = Round(question: "Q")
        r.answers[s0] = "a"; r.answers[s1] = "b"
        r.answers[Round.guestSeatID] = "g"; r.answerProviders[Round.guestSeatID] = "Guest"
        r.divergence = "stale"
        store.rounds = [r]
        store.viewingRound = 0

        store.setDeliberationSelection([s0], forRound: 0)               // < 2 → rejected
        XCTAssertNil(store.rounds[0].includedSeatIDs)
        store.setDeliberationSelection([s0, 12345], forRound: 0)        // unknown id → rejected
        XCTAssertNil(store.rounds[0].includedSeatIDs)

        store.setDeliberationSelection([s0, Round.guestSeatID], forRound: 0)
        XCTAssertEqual(store.rounds[0].includedSeatIDs?.sorted(), [s0, Round.guestSeatID].sorted())
        XCTAssertNil(store.rounds[0].divergence, "changing the selection clears stale analysis")
        XCTAssertTrue(store.isSeatDeliberating(s0))
        XCTAssertFalse(store.isSeatDeliberating(s1), "excluded seat sits out")
        XCTAssertTrue(store.canPeerReview, "guest + one real seat still deliberates")

        store.setDeliberationSelection(nil, forRound: 0)                // back to everyone
        XCTAssertNil(store.rounds[0].includedSeatIDs)
        XCTAssertTrue(store.isSeatDeliberating(s1))
    }

    // MARK: - Exports carry the guest + honest sat-out tags

    @MainActor func testExportsIncludeGuestAndSatOut() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        let s0 = store.seats[0].id, s1 = store.seats[1].id
        store.setProvider(.claude, seatID: s0)
        store.setProvider(.openAI, seatID: s1)
        var r = Round(question: "Q")
        r.answers[s0] = "answer zero"; r.answerProviders[s0] = "Claude"
        r.answers[s1] = "answer one";  r.answerProviders[s1] = "GPT"
        r.answers[Round.guestSeatID] = "the pasted guest text"
        r.answerProviders[Round.guestSeatID] = "ChatGPT"
        r.includedSeatIDs = [s0, Round.guestSeatID]   // GPT sat out
        r.peerReviews[s0] = "a critique"              // the round actually deliberated
        store.rounds = [r]
        store.viewingRound = 0

        let md = store.exportMarkdown()
        XCTAssertTrue(md.contains("the pasted guest text"), "markdown export must include the guest answer")
        XCTAssertTrue(md.contains("ChatGPT — guest"), "markdown export must label the guest honestly")
        XCTAssertTrue(md.contains("sat out"), "markdown export must tag excluded seats")

        let memo = store.exportDecisionMemo()
        XCTAssertTrue(memo.contains("ChatGPT (guest):"), "memo must excerpt the guest answer")
        XCTAssertTrue(memo.contains("(sat out)"), "memo must tag excluded seats")
    }

    /// A round that was never deliberated must NOT tag anyone as having "sat out" — there was
    /// nothing to sit out of.
    @MainActor func testExportsDoNotClaimSatOutBeforeDeliberation() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        let s0 = store.seats[0].id, s1 = store.seats[1].id
        store.setProvider(.claude, seatID: s0)
        store.setProvider(.openAI, seatID: s1)
        var r = Round(question: "Q")
        r.answers[s0] = "a"; r.answerProviders[s0] = "Claude"
        r.answers[s1] = "b"; r.answerProviders[s1] = "GPT"
        r.includedSeatIDs = [s0, s1]
        store.rounds = [r]
        store.viewingRound = 0
        XCTAssertFalse(store.exportMarkdown().contains("sat out"))
        XCTAssertFalse(store.exportDecisionMemo().contains("(sat out)"))
    }

    // MARK: - Merged divergence + verdict (one call instead of two, when the backend can take it)

    func testMergedVerdictIsSplitOffAndNeverShown() {
        let s = CouncilStore.verdictSentinel
        let full = """
        ## Agreement
        They both want to ship.

        ## Divergence
        Advisor A wants tests first.

        \(s)
        {"agreement": 40, "camps": 2, "outlier": "Advisor A"}
        """
        let narrative = CouncilStore.narrativePart(full)
        XCTAssertTrue(narrative.hasSuffix("Advisor A wants tests first."))
        XCTAssertFalse(narrative.contains(s), "the sentinel must never reach the reader")
        XCTAssertFalse(narrative.contains("agreement"), "the JSON tail must never reach the reader")

        let verdict = CouncilStore.parseVerdictJSON(CouncilStore.verdictPart(full) ?? "")
        XCTAssertEqual(verdict?.agreement, 40)
        XCTAssertEqual(verdict?.camps, 2)
        XCTAssertEqual(verdict?.outlier, "Advisor A")
    }

    /// Partial text mid-stream: the sentinel can arrive before its JSON, and the UI must already
    /// be showing only the narrative.
    func testNarrativePartHandlesPartialAndAbsentSentinel() {
        let s = CouncilStore.verdictSentinel
        XCTAssertEqual(CouncilStore.narrativePart("## Agreement\nthey agree"), "## Agreement\nthey agree")
        XCTAssertNil(CouncilStore.verdictPart("## Agreement\nthey agree"))
        XCTAssertEqual(CouncilStore.narrativePart("done\n\(s)"), "done")
        XCTAssertEqual(CouncilStore.narrativePart("done\n\(s)\n{\"agree"), "done")
    }

    /// A backend that ignored the tail must degrade to the old two-call path, not to a missing score.
    func testMissingMergedVerdictParsesAsNil() {
        XCTAssertNil(CouncilStore.parseVerdictJSON(CouncilStore.verdictPart("no sentinel here") ?? ""))
    }

    func testOnlyFrontierBackendsTakeTheMergedPath() {
        for p in [LLMProvider.claude, .openAI, .gemini, .deepSeek, .grok, .mistral] {
            XCTAssertTrue(p.supportsMergedVerdict, "\(p.panelName) should merge")
        }
        // Anything that can be pointed at a small model keeps the reliable split.
        for p in [LLMProvider.ollama, .foundationModels, .custom1, .custom2, .openRouter, .perplexity] {
            XCTAssertFalse(p.supportsMergedVerdict, "\(p.panelName) must keep the separate verdict call")
        }
    }

    // MARK: - Stall watchdog (a wedged backend must not hold the round)

    /// A backend that accepts the connection, emits some text, then goes quiet forever — the exact
    /// shape of the failure that used to block every other advisor's finished answer.
    private struct StallingClient: LLMClient {
        var preamble: String?
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            let preamble = self.preamble
            return AsyncThrowingStream { continuation in
                Task {
                    if let preamble { continuation.yield(.text(preamble)) }
                    try? await Task.sleep(nanoseconds: 60_000_000_000)   // never finishes in test time
                    continuation.finish()
                }
            }
        }
        func validate(apiKey: String) async throws {}
    }

    /// A backend that streams steadily but slowly — it must NEVER be cut off, however long it runs.
    private struct SlowButAliveClient: LLMClient {
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    for i in 0..<8 {
                        try? await Task.sleep(nanoseconds: 120_000_000)   // slower than the stall limit below
                        continuation.yield(.text("chunk\(i) "))
                    }
                    continuation.finish()
                }
            }
        }
        func validate(apiKey: String) async throws {}
    }

    func testStalledBackendIsCutOffAndKeepsItsPartialText() async {
        let previous = CouncilLimits.stallTimeoutSeconds
        CouncilLimits.stallTimeoutSeconds = 1
        defer { CouncilLimits.stallTimeoutSeconds = previous }

        let outcome = await CouncilStore.pumpForTesting(client: StallingClient(preamble: "half an answer"))
        guard case .stalled(let message)? = outcome.failure else {
            return XCTFail("a silent backend must be classified as stalled, got \(String(describing: outcome.failure))")
        }
        XCTAssertTrue(message.contains("stopped responding"), "the message must say what happened: \(message)")
        XCTAssertEqual(outcome.text, "half an answer", "whatever did stream must survive the cut-off")
    }

    func testSlowBackendIsNeverCutOff() async {
        let previous = CouncilLimits.stallTimeoutSeconds
        CouncilLimits.stallTimeoutSeconds = 1   // shorter than the total run, longer than each gap
        defer { CouncilLimits.stallTimeoutSeconds = previous }

        let outcome = await CouncilStore.pumpForTesting(client: SlowButAliveClient())
        XCTAssertNil(outcome.failure, "a model that keeps producing must never be timed out")
        XCTAssertTrue(outcome.text.contains("chunk7"), "it must be allowed to finish: \(outcome.text)")
    }

    /// Models echo the anonymous labels back in their own spelling. Every variant a real run has
    /// produced must still resolve to the advisor's name — a leftover "Adviser A" means nothing
    /// to the reader. (The misspelling here is verbatim from a live llama3.2 divergence.)
    @MainActor func testDeAnonymizeToleratesLabelSpellingDrift() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        let remap = ["Advisor A": "Ollama", "Advisor B": "ChatGPT"]
        let cases: [(String, String)] = [
            ("Advisor A agrees.",            "Ollama agrees."),          // exact
            ("Adviser B disagrees.",         "ChatGPT disagrees."),      // the common misspelling
            ("advisor a is vague.",          "Ollama is vague."),        // lowercase
            ("ADVISOR B holds.",             "ChatGPT holds."),          // uppercase
            ("Advisor  A hedges.",           "Ollama hedges."),          // doubled space
            ("Adviser A and Advisor B split.", "Ollama and ChatGPT split."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(store.deAnonymizeForTesting(input, remap), expected, "failed on: \(input)")
        }
    }

    /// The single-pass guarantee: a replacement must never be re-scanned and replaced again.
    @MainActor func testDeAnonymizeNeverSubstitutesIntoItsOwnOutput() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        // A guest whose display name is itself label-shaped (defence in depth — guestDisplayName
        // already rejects these, but the facade and configs can set names too).
        let remap = ["Advisor A": "Advisor B", "Advisor B": "Gemini"]
        XCTAssertEqual(store.deAnonymizeForTesting("Advisor A", remap), "Advisor B",
                       "the first replacement must not be re-replaced by the second rule")
    }

    // MARK: - Attachments survive so Regenerate can re-ask the same question

    @MainActor func testStoredDocumentMakesTheRoundRegenerable() async {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        let sid = store.seats[0].id
        store.setProvider(.claude, seatID: sid)
        await store.ask("Review this", document: "the design doc body")
        XCTAssertEqual(store.rounds.first?.attachedDocument, "the design doc body")
        XCTAssertTrue(store.rounds.first?.hadAttachment ?? false)
        XCTAssertFalse(store.viewedRoundHadAttachment, "a kept document must not disable Regenerate")
    }

    @MainActor func testOversizedDocumentIsNotStoredAndStillBlocksRegenerate() async {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        let sid = store.seats[0].id
        store.setProvider(.claude, seatID: sid)
        let huge = String(repeating: "x", count: CouncilLimits.maxStoredAttachmentCharacters + 1)
        await store.ask("Review this", document: huge)
        XCTAssertNil(store.rounds.first?.attachedDocument, "an oversized document must not bloat history")
        XCTAssertTrue(store.viewedRoundHadAttachment, "…and Regenerate stays disabled for it")
    }

    func testRoundCodableRoundTripsStoredAttachment() throws {
        var r = Round(question: "Q")
        r.hadAttachment = true
        r.attachedDocument = "doc body"
        let back = try JSONDecoder().decode(Round.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.attachedDocument, "doc body")
        let legacy = try JSONDecoder().decode(Round.self, from: Data(#"{"question":"Q","hadAttachment":true}"#.utf8))
        XCTAssertNil(legacy.attachedDocument, "pre-1.2 rounds decode with no stored document")
    }

    /// A guest named after the blind labels themselves must not be able to corrupt de-anonymization.
    @MainActor func testGuestNamedLikeALabelIsNeutralized() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        let s0 = store.seats[0].id
        store.setProvider(.claude, seatID: s0)
        var r = Round(question: "Q")
        r.answers[s0] = "a"
        store.rounds = [r]
        store.viewingRound = 0
        store.addGuestAnswer("pasted", name: "Advisor B")
        XCTAssertEqual(store.viewedGuestName, "Guest", "a label-shaped guest name must be rejected")
    }

    // MARK: - Outcome reminders

    @MainActor func testDueRemindersFilterAndOutcomeClearsReminder() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        func session(_ title: String) -> Session {
            Session(id: UUID(), title: title, createdAt: Date(), updatedAt: Date(), rounds: [], history: [:])
        }
        var due = session("due")
        due.decision = "ship"; due.remindAt = Date(timeIntervalSinceNow: -3600)
        var future = session("future")
        future.decision = "wait"; future.remindAt = Date(timeIntervalSinceNow: 3600)
        var closed = session("closed")
        closed.decision = "done"; closed.outcome = "went well"; closed.remindAt = Date(timeIntervalSinceNow: -3600)
        var noReminder = session("none")
        noReminder.decision = "meh"
        store.sessions = [noReminder, closed, future, due]

        XCTAssertEqual(store.dueReminders.map(\.title), ["due"], "only decided+open+past-due entries are due")

        store.recordOutcome("turned out fine", for: due.id)
        XCTAssertTrue(store.dueReminders.isEmpty, "logging the outcome closes the loop and clears the reminder")
        XCTAssertNil(store.sessions.first { $0.title == "due" }?.remindAt)

        store.setReminder(Date(timeIntervalSinceNow: -60), for: future.id)
        XCTAssertEqual(store.dueReminders.map(\.title), ["future"], "setReminder reschedules")
        store.setReminder(nil, for: future.id)
        XCTAssertTrue(store.dueReminders.isEmpty, "clearing the reminder dismisses the nudge")
    }

    // MARK: - Journal search / filter / export

    @MainActor func testJournalSearchFilterAndExport() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        func entry(_ title: String, decision: String, outcome: String?) -> Session {
            var r = Round(question: "Should we \(title)?")
            r.answers[0] = "an answer nobody exports"
            var s = Session(id: UUID(), title: title, createdAt: Date(), updatedAt: Date(),
                            rounds: [r], history: [:])
            s.decision = decision; s.decisionAt = Date()
            s.outcome = outcome; s.outcomeAt = outcome == nil ? nil : Date()
            return s
        }
        store.sessions = [
            entry("microservices", decision: "Stayed on the monolith", outcome: "Right call, shipped faster"),
            entry("hiring", decision: "Hired the generalist", outcome: nil),
        ]

        XCTAssertEqual(store.journal.count, 2)
        XCTAssertEqual(store.searchedJournal("monolith").map(\.title), ["microservices"], "search covers the decision")
        XCTAssertEqual(store.searchedJournal("shipped faster").map(\.title), ["microservices"], "…and the outcome")
        XCTAssertEqual(store.searchedJournal("hiring").map(\.title), ["hiring"], "…and the title")
        XCTAssertTrue(store.searchedJournal("nothing here").isEmpty)
        XCTAssertEqual(store.searchedJournal("  ").count, 2, "a blank query is not a filter")
        XCTAssertEqual(store.awaitingOutcome.map(\.title), ["hiring"], "open loops are the ones with no outcome")

        let md = store.exportJournal()
        XCTAssertTrue(md.contains("Stayed on the monolith"))
        XCTAssertTrue(md.contains("Right call, shipped faster"))
        XCTAssertTrue(md.contains("Outcome not recorded yet"), "an open loop must read as open")
        XCTAssertTrue(md.contains("2 decisions · 1 with an outcome recorded"))
        XCTAssertFalse(md.contains("an answer nobody exports"),
                       "the journal export is judgements, not transcripts")
    }

    @MainActor func testJournalExportIsHonestWhenEmpty() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.sessions = []
        XCTAssertTrue(store.exportJournal().contains("No decisions recorded yet"))
    }

    // MARK: - Engram memory composer (pure text, journal fields only)

    @MainActor func testEngramMemoryTextComposesJournalAndVerdictOnly() {
        let store = CouncilStore()
        var r = Round(question: "Should we ship now or wait?")
        r.divergenceScore = 40   // agreement 40 → divergence 60
        r.outlier = "Gemini"
        r.answers[0] = "a full transcript that must NOT be included"
        var s = Session(id: UUID(), title: "T", createdAt: Date(), updatedAt: Date(), rounds: [r], history: [:])
        s.decision = "Ship it now"
        s.decisionAt = Date()
        s.outcome = "Went fine"
        let text = store.engramMemoryText(for: s)
        XCTAssertTrue(text.contains("Ship it now"))
        XCTAssertTrue(text.contains("Should we ship now or wait?"))
        XCTAssertTrue(text.contains("60/100"))
        XCTAssertTrue(text.contains("Gemini"))
        XCTAssertTrue(text.contains("Went fine"))
        XCTAssertFalse(text.contains("full transcript"), "answers never leak into the memory")
    }

    // MARK: - "Library leaves no trace" invariant (regression net for the P1 data-corruption bug)

    /// Exercises every persistence entry point a facade call can reach (seat lineup, role ids, session
    /// disk write) and asserts ZERO mutation of shared UserDefaults config and ZERO writes to the
    /// sessions directory. Fails if any future change reintroduces a write from a library path.
    @MainActor func testFacadeLeavesNoTrace() throws {
        let d = UserDefaults.standard
        let keys = ["council.seats.v7", "council.synthesizerSeat", "council.devilsAdvocate", "council.systemPrompt",
                    "council.chairSeat", "council.custom1.host", "council.custom1.name"]
        let before = keys.map { d.object(forKey: $0) as? NSObject }

        func sessionSnapshot() -> [String: Date] {
            guard let dir = CouncilStore.sessionsFolderURL,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [:] }
            var m: [String: Date] = [:]
            for f in files {
                m[f.lastPathComponent] = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            }
            return m
        }
        let sessionsBefore = sessionSnapshot()

        // Include an in-code key AND a custom OpenAI-compatible endpoint — the paths that must stay
        // off disk / out of the Keychain.
        let store = try Council.configuredStore([
            Advisor(backend: .claude, persona: .analyst),
            Advisor(backend: .custom1, persona: .skeptic, model: "local-model",
                    apiKey: "transient-key", endpoint: URL(string: "http://localhost:9999")!),
        ])
        store.saveSeats()         // seat-lineup write — must be gated by persistenceEnabled
        store.saveConversation()  // session disk write — must be gated
        // (the role-id didSets already fired inside configuredStore — also gated)

        // The in-code key and custom endpoint must be held in memory, never persisted.
        XCTAssertFalse(store.transientKeys.isEmpty, "an in-code key must live in memory, not the Keychain")
        XCTAssertFalse(store.transientCustomEndpoints.isEmpty, "a custom endpoint must live in memory, not UserDefaults")

        for (i, k) in keys.enumerated() {
            XCTAssertEqual(d.object(forKey: k) as? NSObject, before[i], "facade mutated UserDefaults key \(k)")
        }
        XCTAssertEqual(sessionSnapshot(), sessionsBefore, "facade wrote to the sessions directory")
    }

    // MARK: - Reminder notifications (1.3)

    func testScheduledRemindersOnlyForOpenLoopsInTheFuture() {
        let now = Date()
        func session(_ title: String, decision: String?, outcome: String?, remindAt: Date?) -> Session {
            var s = Session(id: UUID(), title: title, createdAt: now, updatedAt: now, rounds: [], history: [:])
            s.decision = decision; s.outcome = outcome; s.remindAt = remindAt
            return s
        }
        let inAWeek = now.addingTimeInterval(7 * 86_400)
        let yesterday = now.addingTimeInterval(-86_400)
        let sessions = [
            session("Berlin offer", decision: "Take it", outcome: nil, remindAt: inAWeek),        // ✓ scheduled
            session("Already closed", decision: "Ship", outcome: "Shipped, fine", remindAt: inAWeek), // outcome logged
            session("Came due", decision: "Wait", outcome: nil, remindAt: yesterday),           // in-app list, not a notification
            session("No decision yet", decision: nil, outcome: nil, remindAt: inAWeek),         // nothing to remind about
            session("No reminder", decision: "Hire", outcome: nil, remindAt: nil),
            session("Later one", decision: "Move", outcome: "", remindAt: inAWeek.addingTimeInterval(3_600)),
        ]
        let scheduled = CouncilStore.scheduledReminders(in: sessions, now: now)
        XCTAssertEqual(scheduled.map(\.line), ["Berlin offer — Take it", "Later one — Move"])   // sorted by date
        XCTAssertEqual(scheduled.first?.at, inAWeek)
    }

    func testScheduledReminderLineIsOneShortLine() {
        let now = Date()
        var s = Session(id: UUID(), title: "", createdAt: now, updatedAt: now, rounds: [], history: [:])
        s.decision = String(repeating: "decide\n", count: 40)
        s.remindAt = now.addingTimeInterval(3_600)
        let line = CouncilStore.scheduledReminders(in: [s], now: now).first?.line ?? ""
        XCTAssertFalse(line.contains("\n"))
        XCTAssertLessThanOrEqual(line.count, 120)
        XCTAssertTrue(line.hasSuffix("…"))
    }

    // MARK: - Read-only session: the bundled example council (0.3.1)

    /// Every model call made through the store's test seam, so a test can prove what ran (and
    /// what didn't) with no network.
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[ChatMessage]] = []
        func record(_ messages: [ChatMessage]) { lock.lock(); calls.append(messages); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
        var last: [ChatMessage]? { lock.lock(); defer { lock.unlock() }; return calls.last }
    }

    /// Answers every call at once with fixed text, and logs it.
    private struct CannedClient: LLMClient {
        let log: CallLog
        let reply: String
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            log.record(messages)
            let reply = self.reply
            return AsyncThrowingStream { continuation in
                continuation.yield(.text(reply))
                continuation.finish()
            }
        }
        func validate(apiKey: String) async throws {}
    }

    /// A recorded session shaped like the bundled example: three answers and their peer reviews;
    /// `debated` adds the debate, the verdict (outlier = seat 2) and the synthesis.
    private func recordedSession(debated: Bool, guest: Bool = false) -> Session {
        var r = Round(question: "Should a two-person startup adopt microservices on day one?")
        for (id, name) in [(0, "Claude"), (1, "GPT"), (2, "Ollama")] {
            r.answers[id] = "answer from seat \(id)"
            r.answerProviders[id] = name
            r.peerReviews[id] = "review by seat \(id)"
        }
        if debated {
            for id in 0...2 { r.rebuttals[id] = "final take from seat \(id)" }
            r.divergence = "## Agreement\nmostly\n\n## Divergence\nOllama differs"
            r.divergenceScore = 92; r.divergenceCamps = 2
            r.outlier = "Ollama"; r.outlierSeatID = 2
            r.synthesis = "Start with a monolith."
        }
        if guest {
            r.answers[Round.guestSeatID] = "a pasted outside answer"
            r.answerProviders[Round.guestSeatID] = "ChatGPT"
        }
        return Session(id: UUID(), title: "Example", createdAt: Date(), updatedAt: Date(),
                       rounds: [r], history: [:])
    }

    /// A viewer with all three seats connected (env keys) and a chair, so any mutator that slipped
    /// past the read-only guard would really run, and be caught.
    @MainActor private func connectedStore(persisting: Bool) -> CouncilStore {
        let store = CouncilStore()
        store.persistenceEnabled = false   // the chair's didSet must not write the runner's defaults
        store.seats = [Seat(id: 0, archetype: .sage, provider: .claude),
                       Seat(id: 1, archetype: .scientist, provider: .openAI),
                       Seat(id: 2, archetype: .strategist, provider: .gemini)]
        store.chairSeat = Seat(id: Seat.chairID, archetype: .sage, provider: .claude)
        store.persistenceEnabled = persisting
        return store
    }

    @MainActor private func sessionFilesOnDisk() -> [URL] {
        guard let dir = CouncilStore.sessionsFolderURL,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }
    }

    private func snapshot(_ rounds: [Round]) -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(rounds)) ?? Data()
    }

    /// The example must never run, change, or land in history, whatever the app calls. Both
    /// recordings matter: without the guards the undebated one would offer and run the debate,
    /// divergence and synthesis, and the complete one the chair summary and guest removal.
    @MainActor func testReadOnlyRefusesEveryMutation() async {
        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { _ in CannedClient(log: log, reply: "a model ran") }
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = connectedStore(persisting: true)   // a leak would reach the (hermetic) sessions dir

        for recording in [recordedSession(debated: false), recordedSession(debated: true, guest: true)] {
            XCTAssertTrue(store.openReadOnly(recording))
            let id = recording.id
            let before = snapshot(store.rounds)
            let mutators: [(String, () async -> Void)] = [
                ("ask", { await store.ask("A follow-up question") }),
                ("peerReview", { await store.peerReview() }),
                ("runRebuttal", { await store.runRebuttal() }),
                ("runChairSummary", { await store.runChairSummary() }),
                ("runAutoPipeline", { await store.runAutoPipeline() }),
                ("runDivergence", { await store.runDivergence() }),
                ("runSynthesis", { await store.runSynthesis() }),
                ("regenerate", { for s in store.seats { await store.regenerate(seatID: s.id) } }),
                ("setDeliberationSelection", { store.setDeliberationSelection([0, 1], forRound: 0) }),
                ("addGuestAnswer", { store.addGuestAnswer("pasted from elsewhere", name: "Gemini web") }),
                ("removeGuestAnswer", { store.removeGuestAnswer() }),
                ("saveConversation", { store.saveConversation() }),
                ("recordDecision", { store.recordDecision("Stay on the monolith", for: id) }),
                ("recordOutcome", { store.recordOutcome("It held up", for: id) }),
                ("setReminder", { store.setReminder(Date(timeIntervalSinceNow: 86_400), for: id) }),
                ("markRememberedInEngram", { store.markRememberedInEngram(id, memoryID: UUID()) }),
                ("renameSession", { store.renameSession(id, to: "Renamed") }),
            ]
            for (name, mutate) in mutators {
                await mutate()
                store.flushPendingWrite()   // anything queued would be on disk now
                XCTAssertEqual(snapshot(store.rounds), before, "\(name) changed the recording")
                XCTAssertEqual(log.count, 0, "\(name) called a model")
                XCTAssertTrue(store.sessions.isEmpty, "\(name) put the recording into history")
                XCTAssertTrue(sessionFilesOnDisk().isEmpty, "\(name) wrote a session file")
                XCTAssertTrue(store.status.values.allSatisfy { $0 == .idle }, "\(name) touched a seat")
                XCTAssertNil(store.divergenceError, name); XCTAssertNil(store.synthesisError, name)
                XCTAssertNil(store.chairError, name)
                XCTAssertTrue(store.isReadOnlySession, "\(name) left read-only mode")
                XCTAssertEqual(store.currentSession, id, name)
                XCTAssertFalse(store.canPeerReview, "\(name): deliberation must stay unavailable")
                XCTAssertFalse(store.canSynthesize, "\(name): deliberation must stay unavailable")
                XCTAssertFalse(store.canRebut, "\(name): no DEBATE offer on a recording")
            }
        }
    }

    /// A first-run viewer has no keys, yet the recording's seats must read as having taken part.
    @MainActor func testReadOnlyParticipantsIgnoreViewerKeys() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.seats = [Seat(id: 0, archetype: .sage), Seat(id: 1, archetype: .scientist),
                       Seat(id: 2, archetype: .strategist)]   // nothing picked, nothing keyed
        let recording = recordedSession(debated: true)

        store.openSession(recording)
        XCTAssertTrue(store.viewedParticipantIDs.isEmpty, "precondition: a normal session drops keyless seats")

        XCTAssertTrue(store.openReadOnly(recording))
        XCTAssertEqual(store.viewedParticipantIDs, [0, 1, 2], "a recording's seats took part, whatever keys you have")
        for id in 0...2 { XCTAssertTrue(store.isSeatDeliberating(id), "seat \(id) must not show SAT OUT") }
        XCTAssertFalse(store.canPeerReview, "…and still nothing can run")
        XCTAssertEqual(store.outlierAnswer, "answer from seat 2", "the dissent card reads the recorded outlier")

        // A recorded selection is still honoured: a seat that was excluded really did sit out.
        var partial = recordedSession(debated: false)
        partial.rounds[0].includedSeatIDs = [0, 1]
        XCTAssertTrue(store.openReadOnly(partial))
        XCTAssertTrue(store.isSeatDeliberating(0))
        XCTAssertFalse(store.isSeatDeliberating(2))
    }

    @MainActor func testOpenSessionAndNewSessionLeaveReadOnly() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        XCTAssertFalse(store.isReadOnlySession, "a store starts writable (the CLI and the facade never change it)")
        let recording = recordedSession(debated: true)
        let mine = recordedSession(debated: false)   // stands in for one of the user's own sessions

        store.chairFallbackNote = "Gemini couldn't run — Claude wrote this."
        XCTAssertTrue(store.openReadOnly(recording))
        XCTAssertTrue(store.isReadOnlySession)
        XCTAssertEqual(store.currentSession, recording.id)
        XCTAssertNil(store.chairFallbackNote, "a note about today's chair doesn't belong on a recording")

        store.openSession(mine)
        XCTAssertFalse(store.isReadOnlySession, "opening a real session leaves read-only")
        XCTAssertEqual(store.currentSession, mine.id)

        XCTAssertTrue(store.openReadOnly(recording))
        store.newSession()
        XCTAssertFalse(store.isReadOnlySession, "a new session is writable")
        XCTAssertTrue(store.rounds.isEmpty)

        // While something runs: refuse, and change nothing.
        store.openSession(mine)
        store.deliberationBusy = true
        XCTAssertFalse(store.openReadOnly(recording))
        XCTAssertFalse(store.isReadOnlySession)
        XCTAssertEqual(store.currentSession, mine.id)
        store.deliberationBusy = false
    }

    // MARK: - One answer isn't a council (0.3.1)

    @MainActor func testSecondViewCountsStoredAnswers() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        // One connected seat and two that lost their key: the state right after an update.
        store.seats = [Seat(id: 0, archetype: .sage, provider: .claude),
                       Seat(id: 1, archetype: .scientist), Seat(id: 2, archetype: .strategist)]
        func needsSecondView(_ answers: [Int: String]) -> Bool {
            var r = Round(question: "Q"); r.answers = answers
            store.rounds = [r]; store.viewingRound = 0
            return store.viewedRoundNeedsSecondView
        }
        XCTAssertFalse(needsSecondView([0: "a", 1: "b", 2: "c"]),
                       "three stored answers are a council, whatever is connected today")
        XCTAssertEqual(store.viewedParticipantIDs, [0], "precondition: counting participants would have said 'one'")
        XCTAssertTrue(needsSecondView([0: "a"]), "one real answer can't be compared with anything")
        XCTAssertTrue(needsSecondView([1: "b"]), "…also when that seat has no key today")
        XCTAssertTrue(needsSecondView([0: "a", 1: "", 2: ""]), "empty in-progress slots are not answers")
        XCTAssertFalse(needsSecondView([0: "a", Round.guestSeatID: "pasted"]), "one real answer plus a guest is a council of two")
        XCTAssertFalse(needsSecondView([Round.guestSeatID: "pasted"]), "a guest alone is not a one-answer round")
        XCTAssertFalse(needsSecondView([:]))

        // An older round on screen is judged on its own answers.
        var one = Round(question: "Q1"); one.answers = [0: "a"]
        var three = Round(question: "Q2"); three.answers = [0: "a", 1: "b", 2: "c"]
        store.rounds = [one, three]
        store.viewingRound = 0; XCTAssertTrue(store.viewedRoundNeedsSecondView)
        store.viewingRound = 1; XCTAssertFalse(store.viewedRoundNeedsSecondView)

        store.rounds = [one]; store.viewingRound = 0
        store.deliberationBusy = true
        XCTAssertFalse(store.viewedRoundNeedsSecondView, "never while something is running")
        store.deliberationBusy = false

        var recording = recordedSession(debated: false)
        recording.rounds[0].answers = [0: "the only answer"]
        recording.rounds[0].peerReviews = [:]
        XCTAssertTrue(store.openReadOnly(recording))
        XCTAssertFalse(store.viewedRoundNeedsSecondView, "never on a read-only recording")
    }

    /// ASK {PROVIDER} TOO relies on this: regenerate fills a seat that had no answer, inside the
    /// SAME round, without asking the first seat again.
    @MainActor func testRegenerateFillsEmptySeatInLatestRound() async {
        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { _ in CannedClient(log: log, reply: "a second view") }
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = connectedStore(persisting: false)
        store.newSession()
        var r = Round(question: "Should we?")
        r.answers[0] = "the first view"; r.answerProviders[0] = "Claude"
        store.rounds = [r]; store.viewingRound = 0
        XCTAssertTrue(store.viewedRoundNeedsSecondView)
        XCTAssertTrue(store.latestRoundAnswered(0))
        XCTAssertFalse(store.latestRoundAnswered(1))

        await store.regenerate(seatID: 1)

        XCTAssertEqual(store.rounds.count, 1, "filled in the same round, not a round 2")
        XCTAssertEqual(store.rounds[0].answers[1], "a second view")
        XCTAssertEqual(store.rounds[0].answerProviders[1], LLMProvider.openAI.panelName)
        XCTAssertEqual(store.rounds[0].answers[0], "the first view", "the first seat is not asked again")
        XCTAssertEqual(log.count, 1, "exactly one model call, for the new seat")
        XCTAssertEqual(log.last?.last?.text, "Should we?", "it is asked the round's own question")
        XCTAssertTrue(store.latestRoundAnswered(1))
        XCTAssertFalse(store.viewedRoundNeedsSecondView)
        XCTAssertTrue(store.canPeerReview, "two answers: the round can now be compared")
        XCTAssertEqual(store.status[1], .idle)
    }

    @MainActor func testLatestRoundHasAnalysis() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        XCTAssertFalse(store.latestRoundHasAnalysis, "no rounds, no analysis")
        var plain = Round(question: "Q"); plain.answers = [0: "a", 1: "b"]
        store.rounds = [plain]
        XCTAssertFalse(store.latestRoundHasAnalysis, "answers alone are not analysis")
        var reviewed = plain; reviewed.peerReviews[0] = "a critique"
        store.rounds = [reviewed]
        XCTAssertTrue(store.latestRoundHasAnalysis)
        var synthesized = plain; synthesized.synthesis = "the synthesis"
        store.rounds = [synthesized]
        XCTAssertTrue(store.latestRoundHasAnalysis)
        // About the LATEST round, whichever one is on screen.
        store.rounds = [reviewed, plain]; store.viewingRound = 0
        XCTAssertFalse(store.latestRoundHasAnalysis)
        XCTAssertTrue(store.latestRoundAnswered(1))
        XCTAssertFalse(store.latestRoundAnswered(2))
    }

    // MARK: - Old session files still decode (0.3.1 changed no persisted struct)

    /// Session files written by earlier versions must still load, and open read-only unchanged:
    /// a pre-1.2 file (stored history, none of the later round keys) and a 1.3.0 file in the exact
    /// shape the bundled example was recorded in.
    @MainActor func testOldSessionFilesStillDecodeAndOpenReadOnly() throws {
        let dir = try XCTUnwrap(CouncilStore.sessionsFolderURL)
        let legacyID = UUID(), recordedID = UUID()
        let legacy = """
        {"id":"\(legacyID.uuidString)","title":"Old","createdAt":"2026-03-01T09:00:00Z",
         "updatedAt":"2026-03-01T09:05:00Z",
         "rounds":[{"id":"\(UUID().uuidString)","question":"Old question","answers":{"0":"old a","1":"old b"},
                    "peerReviews":{},"divergence":"old map","synthesis":"old synthesis",
                    "inputTokens":10,"outputTokens":20,"costUSD":0.01,
                    "answerProviders":{"0":"Claude","1":"GPT"}}],
         "history":{"0":[{"role":"user","text":"Old question"},{"role":"assistant","text":"old a"}]}}
        """
        let recorded = """
        {"id":"\(recordedID.uuidString)","title":"Should a two-person startup adopt microservices",
         "createdAt":"2026-10-14T10:00:00Z","updatedAt":"2026-10-14T10:04:00Z","history":{},
         "rounds":[{"id":"\(UUID().uuidString)","question":"Should a two-person startup adopt microservices on day one?",
                    "answers":{"0":"a0","1":"a1","2":"a2"},"answerProviders":{"0":"Claude","1":"GPT","2":"Ollama"},
                    "peerReviews":{"0":"p0","1":"p1","2":"p2"},"rebuttals":{"0":"r0","1":"r1","2":"r2"},
                    "divergence":"map","divergenceScore":92,"divergenceCamps":2,"outlier":"Ollama","outlierSeatID":2,
                    "synthesis":"synthesis","hadAttachment":false,"inputTokens":1,"outputTokens":2,"costUSD":0.02}]}
        """
        let legacyURL = dir.appendingPathComponent("\(legacyID.uuidString).json")
        let recordedURL = dir.appendingPathComponent("\(recordedID.uuidString).json")
        try Data(legacy.utf8).write(to: legacyURL)
        try Data(recorded.utf8).write(to: recordedURL)

        let store = CouncilStore()   // loads the sessions folder
        store.persistenceEnabled = false
        XCTAssertEqual(Set(store.sessions.map(\.id)), [legacyID, recordedID], "both old files must decode")
        let old = try XCTUnwrap(store.sessions.first { $0.id == legacyID })
        XCTAssertEqual(old.rounds.first?.answers[1], "old b")
        XCTAssertTrue(old.rounds.first?.rebuttals.isEmpty ?? false)
        XCTAssertNil(old.rounds.first?.includedSeatIDs)

        store.seats = [Seat(id: 0, archetype: .sage), Seat(id: 1, archetype: .scientist),
                       Seat(id: 2, archetype: .strategist)]
        let example = try XCTUnwrap(store.sessions.first { $0.id == recordedID })
        XCTAssertTrue(store.openReadOnly(example))
        XCTAssertEqual(store.agreementScore, 92)
        XCTAssertEqual(store.divergenceCamps, 2)
        XCTAssertEqual(store.outlierName, "Ollama")
        XCTAssertEqual(store.outlierAnswer, "a2")
        XCTAssertEqual(store.viewedAnswerProvider(2), "Ollama")
        XCTAssertTrue(store.hasRebuttalForViewedRound)
        XCTAssertEqual(store.viewedParticipantIDs, [0, 1, 2])
        store.flushPendingWrite()
        XCTAssertEqual(try Data(contentsOf: recordedURL), Data(recorded.utf8), "opening it never rewrites it")
    }

    // MARK: - Session writes land before exit (0.3.1)

    private func decodeSession(_ url: URL) throws -> Session {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(Session.self, from: Data(contentsOf: url))
    }

    /// The CLI exits and the app quits right after flushPendingWrite, so it must not return until
    /// the file is on disk: the queued write AND any write already handed off.
    @MainActor func testFlushPendingWriteLandsSynchronously() throws {
        let store = connectedStore(persisting: true)
        store.newSession()
        let id = store.currentSession
        let url = try XCTUnwrap(CouncilStore.sessionsFolderURL).appendingPathComponent("\(id.uuidString).json")
        var r = Round(question: "Q"); r.answers[0] = "first"; r.answerProviders[0] = "Claude"
        store.rounds = [r]

        store.saveConversation()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "precondition: the write is debounced")
        store.flushPendingWrite()
        // No await between the flush and the read: the file must already be there, complete.
        XCTAssertEqual(try decodeSession(url).rounds.first?.answers[0], "first")

        // A journal edit writes straight away, off the main thread. Flush waits for that too.
        store.recordDecision("Ship it", for: id)
        store.flushPendingWrite()
        XCTAssertEqual(try decodeSession(url).decision, "Ship it")

        // The newest edit wins.
        store.rounds[0].answers[1] = "second"; store.rounds[0].answerProviders[1] = "GPT"
        store.saveConversation()
        store.flushPendingWrite()
        let back = try decodeSession(url)
        XCTAssertEqual(back.rounds.first?.answers[1], "second")
        XCTAssertEqual(back.decision, "Ship it", "the journal fields are carried forward")
    }

    /// Exports of a recording name the models it was recorded with, never this viewer's seats.
    @MainActor func testReadOnlyExportsUseRecordedModels() {
        let store = connectedStore(persisting: false)
        store.seats[0].model = "viewer-claude-model"
        store.seats[1].model = "viewer-gpt-model"
        let recording = recordedSession(debated: true)

        // Recorded models given: exports use them.
        XCTAssertTrue(store.openReadOnly(recording, models: [0: "claude-sonnet-4-6", 1: "gpt-5.4-mini", 2: "llama3.2"]))
        for text in [store.exportMarkdown(), store.exportDecisionMemo()] {
            XCTAssertTrue(text.contains("`claude-sonnet-4-6`"))
            XCTAssertTrue(text.contains("`gpt-5.4-mini`"))
            XCTAssertTrue(text.contains("`llama3.2`"))
            XCTAssertFalse(text.contains("viewer-"), "the viewer's model ids must not leak into a recording's export")
        }

        // No recorded models: no model tags at all, still no viewer ids.
        XCTAssertTrue(store.openReadOnly(recording))
        for text in [store.exportMarkdown(), store.exportDecisionMemo()] {
            XCTAssertFalse(text.contains("viewer-"))
            XCTAssertFalse(text.contains("`claude-sonnet-4-6`"), "models from the previous recording are cleared")
        }

        // A normal session keeps today's rule: the id shows when the seat's provider answered.
        store.openSession(recording)
        XCTAssertTrue(store.exportMarkdown().contains("`viewer-claude-model`"))
        XCTAssertFalse(store.exportMarkdown().contains("`llama3.2`"))
    }

    /// A write already handed to the write queue (a journal edit here) must not recreate a session
    /// file after the session was deleted.
    @MainActor func testDeletedSessionStaysDeleted() throws {
        let store = connectedStore(persisting: true)
        store.newSession()
        let id = store.currentSession
        let url = try XCTUnwrap(CouncilStore.sessionsFolderURL).appendingPathComponent("\(id.uuidString).json")
        var r = Round(question: "Q"); r.answers[0] = "first"; r.answerProviders[0] = "Claude"
        store.rounds = [r]
        store.saveConversation()
        store.flushPendingWrite()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "precondition: the session is on disk")

        store.recordDecision("Ship it", for: id)   // an immediate write, queued off the main thread
        store.deleteSession(id)
        store.flushPendingWrite()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a queued write must land before the delete, not after")
        XCTAssertFalse(store.sessions.contains { $0.id == id })
    }

    /// Switching to the example is a session switch: the session being left must be on disk
    /// before it goes, and the example must never be.
    @MainActor func testOpenReadOnlyFlushesTheSessionBeingLeft() {
        let store = connectedStore(persisting: true)
        store.newSession()
        let mine = store.currentSession
        var r = Round(question: "Q"); r.answers[0] = "a real answer"; r.answerProviders[0] = "Claude"
        store.rounds = [r]
        store.saveConversation()   // queued (debounced), not yet written
        XCTAssertTrue(store.openReadOnly(recordedSession(debated: true)))
        XCTAssertEqual(sessionFilesOnDisk().map(\.lastPathComponent), ["\(mine.uuidString).json"],
                       "the session being left lands on disk at once; the recording never does")
    }
}
