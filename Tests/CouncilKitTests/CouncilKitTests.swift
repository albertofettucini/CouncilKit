import XCTest
import Foundation
import CryptoKit
@testable import CouncilKit
@testable import council

/// Fast, deterministic unit tests for the CouncilKit facade — no network, and no writes to the
/// real Keychain or to the app's saved state. They lock in the public API shape, the error
/// contract, and the persistence isolation that the live run + adversarial review hardened.
///
/// Keys are supplied via `COUNCIL_KEY_*` env overrides (set in `setUp`) so the tests never prompt
/// for Keychain access; the values are dummies. No test reaches the network, and that is enforced:
/// `setUp` arms a client that fails any model call a test didn't give a canned reply, and every
/// HTTP request through `URLSession.shared` fails the test (see `NoNetworkProtocol`).
final class CouncilKitTests: XCTestCase {

    /// The blind-order seam as the engine ships it, read before any test can touch it.
    private static var blindOrderFixedAtLaunch = false
    /// The history gate's bundle-id seam as the engine ships it, read the same way.
    private static var hostBundleIDAtLaunch: String?

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(NoNetworkProtocol.self)
        blindOrderFixedAtLaunch = MainActor.assumeIsolated { CouncilStore.fixedBlindOrderForTesting }
        hostBundleIDAtLaunch = MainActor.assumeIsolated { CouncilStore.hostBundleIDForTesting }
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(NoNetworkProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        // Re-armed before every test: a test that wants replies installs its own client.
        // (XCTest runs setUp and tearDown on the main thread.)
        MainActor.assumeIsolated {
            CouncilStore.clientOverrideForTesting = { NetworkForbiddenClient(provider: $0) }
        }
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
        MainActor.assumeIsolated {
            CouncilStore.clientOverrideForTesting = nil
            CouncilStore.fixedBlindOrderForTesting = false
            CouncilStore.hostBundleIDForTesting = nil
        }
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "council-unit-tests")
        super.tearDown()
    }

    // MARK: - Hermetic: no test reaches a real model

    /// The default client for every test: a model call that reaches the store's seam without a
    /// canned client fails the test by name, and ends at once instead of going to a real backend.
    private struct NetworkForbiddenClient: LLMClient {
        let provider: LLMProvider
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            XCTFail("a test made a real \(provider.panelName) model call — give it a CannedClient")
            return AsyncThrowingStream { $0.finish(throwing: LLMError.message("model calls are forbidden in tests")) }
        }
        func validate(apiKey: String) async throws {
            XCTFail("a test validated a real \(provider.panelName) key")
            throw LLMError.message("model calls are forbidden in tests")
        }
    }

    /// For the calls that never pass the seam (key checks, model lists, a client built outside
    /// it): any HTTP request through `URLSession.shared` fails the test instead of leaving the machine.
    private final class NoNetworkProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            XCTFail("a test made a real network request to \(request.url?.host ?? "an unknown host")")
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
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
            ("Advisor A.",                   "Ollama."),                 // punctuation ends the label
            ("Advisor A's case holds.",      "Ollama's case holds."),
            ("(Advisor B)",                  "(ChatGPT)"),
            ("**Advisor A**: yes",           "**Ollama**: yes"),
            ("Advisor B",                    "ChatGPT"),                 // at the very end
        ]
        for (input, expected) in cases {
            XCTAssertEqual(store.deAnonymizeForTesting(input, remap), expected, "failed on: \(input)")
        }
    }

    /// A label is a whole word. Prose that merely starts with one ("every advisor agrees", "the
    /// second advisor brings") stays as written: matching it cut the word and pinned a council-wide
    /// statement on one named model ("Every Claudegrees on the core point.").
    @MainActor func testDeAnonymizeLeavesOrdinaryProseAlone() {
        let store = CouncilStore()
        store.persistenceEnabled = false
        let remap = ["Advisor A": "Claude", "Advisor B": "GPT", "Advisor C": "Gemini", "Advisor D": "Guest"]
        let prose = [
            "Every advisor agrees on the core point.",
            "Another advisor argues the opposite.",
            "No advisor addresses cost.",
            "The second advisor brings up risk.",
            "One advisor correctly notes the deadline.",
            "Each advisor does the maths differently and one advisor disagrees.",
            "An ADVISOR ADDRESSES it; the adviser adds detail.",
            "Their financial advisor asked; a co-advisor a2 replied.",
            "Subadvisor A and Advisorb never count.",
            "The advisor décide.",
        ]
        for text in prose {
            XCTAssertEqual(store.deAnonymizeForTesting(text, remap), text, "prose changed: \(text)")
        }
        XCTAssertEqual(store.deAnonymizeForTesting("Every advisor agrees with Advisor C, not Advisor D.", remap),
                       "Every advisor agrees with Gemini, not Guest.", "the real labels around it still map")
        XCTAssertEqual(store.deAnonymizeForTesting("advisor c's point, ADVISOR B holds.", remap),
                       "Gemini's point, GPT holds.")
        // Scripts that write without spaces, or attach a particle to the name, still map.
        XCTAssertEqual(store.deAnonymizeForTesting("Advisor A认为可行，Advisor Bは反対、Advisor C는 동의", remap),
                       "Claude认为可行，GPTは反対、Gemini는 동의")
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
        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { _ in CannedClient(log: log, reply: "a review") }
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        let sid = store.seats[0].id
        store.setProvider(.claude, seatID: sid)
        await store.ask("Review this", document: "the design doc body")
        XCTAssertTrue(log.last?.last?.text.contains("the design doc body") ?? false, "the model saw the document")
        XCTAssertEqual(store.rounds.first?.attachedDocument, "the design doc body")
        XCTAssertTrue(store.rounds.first?.hadAttachment ?? false)
        XCTAssertFalse(store.viewedRoundHadAttachment, "a kept document must not disable Regenerate")
    }

    @MainActor func testOversizedDocumentIsNotStoredAndStillBlocksRegenerate() async {
        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { _ in CannedClient(log: log, reply: "a review") }
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        let sid = store.seats[0].id
        store.setProvider(.claude, seatID: sid)
        let huge = String(repeating: "x", count: CouncilLimits.maxStoredAttachmentCharacters + 1)
        await store.ask("Review this", document: huge)
        XCTAssertTrue(log.last?.last?.text.contains(huge) ?? false, "too big to keep, yet still analyzed this round")
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
    /// Reading counts too (1.3.2): the facade never loads the app's saved history, even when it is
    /// called inside the app's own process, and never creates the sessions folder.
    @MainActor func testFacadeLeavesNoTrace() throws {
        let d = UserDefaults.standard
        let keys = ["council.seats.v7", "council.synthesizerSeat", "council.devilsAdvocate", "council.systemPrompt",
                    "council.chairSeat", "council.custom1.host", "council.custom1.name"]
        let before = keys.map { d.object(forKey: $0) as? NSObject }

        func facadeStore() throws -> CouncilStore {
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
            return store
        }

        // No history yet: a facade call must not even create the sessions folder.
        try? FileManager.default.removeItem(at: hermeticSessionsDir)
        _ = try facadeStore()
        XCTAssertNil(sessionsFolderContents(), "facade created the sessions folder")

        // Saved history, and the facade run inside the app (where a default store reads history):
        // a store that read it would hold the session and open it.
        let saved = try seedSession("A question from the app's history", updatedAt: Date())
        let sessionsBefore = sessionsFolderContents()
        CouncilStore.hostBundleIDForTesting = CouncilStore.appBundleID
        let store = try facadeStore()
        CouncilStore.hostBundleIDForTesting = nil
        XCTAssertTrue(store.sessions.isEmpty, "facade read the app's saved history")
        XCTAssertTrue(store.rounds.isEmpty)
        XCTAssertNotEqual(store.currentSession, saved.id)

        // The in-code key and custom endpoint must be held in memory, never persisted.
        XCTAssertFalse(store.transientKeys.isEmpty, "an in-code key must live in memory, not the Keychain")
        XCTAssertFalse(store.transientCustomEndpoints.isEmpty, "a custom endpoint must live in memory, not UserDefaults")

        for (i, k) in keys.enumerated() {
            XCTAssertEqual(d.object(forKey: k) as? NSObject, before[i], "facade mutated UserDefaults key \(k)")
        }
        XCTAssertEqual(sessionsFolderContents(), sessionsBefore, "facade wrote to the sessions directory")
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

    /// One model call as the seam saw it: the messages, and the provider the client was made for
    /// (the seam hands a client only its provider, so seats on different providers tell calls apart).
    private struct LoggedCall {
        let provider: LLMProvider?
        let messages: [ChatMessage]
        /// Every message's text, for "is this anywhere in the call" checks.
        var text: String { messages.map(\.text).joined(separator: "\n") }
    }

    /// Every model call made through the store's test seam, so a test can prove what ran (and
    /// what didn't) with no network.
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [LoggedCall] = []
        func record(_ messages: [ChatMessage], provider: LLMProvider? = nil) {
            lock.lock(); calls.append(LoggedCall(provider: provider, messages: messages)); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
        var last: [ChatMessage]? { lock.lock(); defer { lock.unlock() }; return calls.last?.messages }
        /// The calls from index `start` on, in the order they were made.
        func since(_ start: Int) -> [LoggedCall] { lock.lock(); defer { lock.unlock() }; return Array(calls[start...]) }
    }

    /// Answers every call at once with fixed text, and logs it.
    private struct CannedClient: LLMClient {
        let log: CallLog
        let reply: String
        var provider: LLMProvider? = nil
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            log.record(messages, provider: provider)
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

        let store = CouncilStore(loadHistory: true)   // the app's read of the sessions folder
        store.persistenceEnabled = false
        XCTAssertEqual(Set(store.sessions.map(\.id)), [legacyID, recordedID], "both old files must decode")
        // Neither file has the 1.3.2 round record: nothing is made up, and no answer is marked incomplete.
        for r in store.sessions.flatMap(\.rounds) {
            XCTAssertTrue(r.answerStatuses.isEmpty)
            XCTAssertTrue(r.answerModels.isEmpty)
            XCTAssertNil(r.promptVersion)
            XCTAssertNil(r.createdAt)
            XCTAssertTrue(r.incompleteSeatIDs.isEmpty, "an old answer counts as complete")
        }
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

    // MARK: - Only the app reads history (1.3.2)

    /// The hermetic sessions folder, from the env override itself. `CouncilStore.sessionsFolderURL`
    /// creates the folder it returns, so a check made through it could never see a folder appear.
    private var hermeticSessionsDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["COUNCIL_SESSIONS_DIR"]!, isDirectory: true)
    }

    private struct FileState: Equatable {
        let bytes: Data
        let modified: Date?
    }

    /// Every file in the hermetic folder, by name, with its bytes and modification date (so an
    /// identical rewrite still shows). Nil when the folder doesn't exist.
    private func sessionsFolderContents() -> [String: FileState]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hermeticSessionsDir.path) else { return nil }
        let files = (try? fm.contentsOfDirectory(at: hermeticSessionsDir,
                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var m: [String: FileState] = [:]
        for f in files {
            m[f.lastPathComponent] = FileState(
                bytes: (try? Data(contentsOf: f)) ?? Data(),
                modified: (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        return m
    }

    /// Writes one saved session with a single answered round, the way the app saves it.
    @MainActor @discardableResult
    private func seedSession(_ question: String, updatedAt: Date) throws -> (id: UUID, url: URL) {
        try FileManager.default.createDirectory(at: hermeticSessionsDir, withIntermediateDirectories: true)
        var r = Round(question: question); r.answers[0] = "a saved answer"; r.answerProviders[0] = "Claude"
        let s = Session(id: UUID(), title: question, createdAt: updatedAt, updatedAt: updatedAt,
                        rounds: [r], history: [:])
        let url = hermeticSessionsDir.appendingPathComponent("\(s.id.uuidString).json")
        try CouncilStore.sessionCoder.enc.encode(s).write(to: url)
        return (s.id, url)
    }

    /// A store reads the saved history at construction only in the Council app (its exact bundle id)
    /// or when told to. The CLI, the facade, the test runner and any other app get an empty
    /// `sessions` list and a fresh session, and don't even create the folder.
    @MainActor func testOnlyTheAppReadsHistoryWhenItBuildsAStore() throws {
        XCTAssertNil(Self.hostBundleIDAtLaunch, "the gate's test seam must ship unset")
        // The rule: the app's exact id and nothing else. The runner has an id of its own, so an
        // "is there a bundle id" check would let it (and every other host) through.
        XCTAssertTrue(CouncilStore.loadsHistoryAutomatically(bundleID: "com.joseph.Council"))
        XCTAssertNotNil(Bundle.main.bundleIdentifier, "precondition: the test runner has a bundle id")
        let others: [String?] = [nil, "", Bundle.main.bundleIdentifier, "com.apple.dt.xctest.tool",
                                 "com.example.CouncilFork", "com.joseph.Council.debug", "com.joseph.council"]
        for id in others {
            XCTAssertFalse(CouncilStore.loadsHistoryAutomatically(bundleID: id), "\(id ?? "no bundle id") read history")
        }

        // With no history yet, a default store here doesn't create the folder as a side effect.
        try? FileManager.default.removeItem(at: hermeticSessionsDir)
        XCTAssertTrue(CouncilStore().sessions.isEmpty)
        XCTAssertNil(sessionsFolderContents(), "building a store created the sessions folder")

        let older = try seedSession("An older question", updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let newest = try seedSession("The newest question", updatedAt: Date(timeIntervalSince1970: 1_790_100_000))
        let onDisk = sessionsFolderContents()

        /// Builds a store as `host` would (nil: this test runner, as it really is).
        func store(as host: String?, loadHistory: Bool? = nil) -> CouncilStore {
            CouncilStore.hostBundleIDForTesting = host
            defer { CouncilStore.hostBundleIDForTesting = nil }
            return CouncilStore(loadHistory: loadHistory)
        }
        let readsNothing: [(String, CouncilStore)] = [
            ("the test runner", store(as: nil)),
            ("another app embedding CouncilKit", store(as: "com.example.Host")),
            ("the app, opted out", store(as: CouncilStore.appBundleID, loadHistory: false)),
        ]
        for (who, s) in readsNothing {
            XCTAssertTrue(s.sessions.isEmpty, "\(who) read the saved history")
            XCTAssertTrue(s.rounds.isEmpty, "\(who) opened a saved session")
            XCTAssertFalse([older.id, newest.id].contains(s.currentSession), "\(who) took over a saved session")
        }
        let reads: [(String, CouncilStore)] = [
            ("the app", store(as: CouncilStore.appBundleID)),
            ("a fork that opts in", store(as: "com.example.CouncilFork", loadHistory: true)),
            ("the test runner, opted in", store(as: nil, loadHistory: true)),
        ]
        for (who, s) in reads {
            XCTAssertEqual(s.sessions.map(\.id), [newest.id, older.id], "\(who) must read every session, newest first")
            XCTAssertEqual(s.currentSession, newest.id, "\(who) opens the newest session")
            XCTAssertEqual(s.rounds.map(\.question), ["The newest question"])
        }
        XCTAssertEqual(sessionsFolderContents(), onDisk, "reading history never rewrites it")
    }

    /// A CLI run that saves puts its own new session into the app's history and touches nothing else
    /// there. That is what made it safe to drop the CLI's old "every file must decode first" check
    /// (which needed the whole history read): even a file this build can't decode stays as it was.
    @MainActor func testCLIRunSavesOnlyItsOwnSessionFile() async throws {
        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { _ in CannedClient(log: log, reply: "an answer") }
        defer { CouncilStore.clientOverrideForTesting = nil }
        let saved = try seedSession("A question from the app's history", updatedAt: Date())
        try Data(#"{"id":"written by some future build","rounds":7}"#.utf8)
            .write(to: hermeticSessionsDir.appendingPathComponent("\(UUID().uuidString).json"))
        let before = try XCTUnwrap(sessionsFolderContents())

        /// The CLI's own store, built as if inside the app (so the opt-out has to be explicit), on a
        /// lineup set without touching the runner's saved defaults.
        func runStore(saving: Bool) -> CouncilStore {
            CouncilStore.hostBundleIDForTesting = CouncilStore.appBundleID
            let store = cliStore(saving: saving)
            CouncilStore.hostBundleIDForTesting = nil
            XCTAssertTrue(store.sessions.isEmpty, "the CLI read the app's saved history")
            XCTAssertTrue(store.rounds.isEmpty)
            XCTAssertNotEqual(store.currentSession, saved.id)
            XCTAssertEqual(store.persistenceEnabled, saving)
            store.seats = [Seat(id: 0, archetype: .sage, provider: .claude),
                           Seat(id: 1, archetype: .scientist, provider: .openAI),
                           Seat(id: 2, archetype: .strategist, provider: .gemini)]
            return store
        }

        let run = runStore(saving: true)
        await run.ask("A CLI question")
        run.flushPendingWrite()
        let after = try XCTUnwrap(sessionsFolderContents())
        for (name, state) in before {
            XCTAssertEqual(after[name], state, "the run touched \(name)")
        }
        let own = "\(run.currentSession.uuidString).json"
        XCTAssertEqual(Set(after.keys).subtracting(before.keys), [own], "exactly one new file: the run's own session")
        XCTAssertEqual(try decodeSession(hermeticSessionsDir.appendingPathComponent(own)).rounds.map(\.question),
                       ["A CLI question"])
        XCTAssertEqual(run.sessions.map(\.id), [run.currentSession], "only the run's own session is in memory")

        // --no-save writes nothing at all.
        let quiet = runStore(saving: false)
        await quiet.ask("Another CLI question")
        quiet.flushPendingWrite()
        XCTAssertEqual(sessionsFolderContents(), after, "--no-save wrote to the history folder")
        XCTAssertEqual(log.count, 6, "both runs really answered")
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

    // MARK: - The round record: how each answer ended, its model, the prompts, the time (1.3.2)

    private static let recordTime = Date(timeIntervalSince1970: 1_790_000_000)   // a whole second

    /// A round with every status: a kept answer for each way an answer can end, a failed seat with
    /// no answer, and a seat stopped before any text arrived.
    private func recordedStatusRound() -> Round {
        var r = Round(question: "Q", createdAt: Self.recordTime, promptVersion: 7)
        r.answers = [0: "a0", 1: "a1", 2: "a2", 3: "a3", 4: "", 5: ""]
        r.answerStatuses = [0: .complete, 1: .truncated, 2: .stalled, 3: .cancelled, 4: .failed, 5: .cancelled]
        r.answerModels = [0: "model-0", 1: "model-1", 2: "model-2", 3: "model-3", 4: "model-4", 5: "model-5"]
        return r
    }

    /// Every status, the model map, the prompt version and the time survive a plain JSONEncoder and
    /// the coder session files are written with. That one writes ISO 8601 dates, which keep whole
    /// seconds only, so the fixture time is a whole second.
    @MainActor func testRoundRecordRoundTripsThroughBothCoders() throws {
        XCTAssertEqual(AnswerStatus.allCases.map(\.rawValue), ["complete", "truncated", "stalled", "cancelled", "failed"],
                       "the raw values are the file format: renaming one would orphan every saved status")
        let r = recordedStatusRound()
        XCTAssertEqual(Set(r.answerStatuses.values), Set(AnswerStatus.allCases), "precondition: the fixture has every status")
        let plain = try JSONDecoder().decode(Round.self, from: JSONEncoder().encode(r))
        let coder = CouncilStore.sessionCoder
        let session = Session(id: UUID(), title: "T", createdAt: Self.recordTime, updatedAt: Self.recordTime,
                              rounds: [r], history: [:])
        let filed = try XCTUnwrap(coder.dec.decode(Session.self, from: coder.enc.encode(session)).rounds.first)
        for back in [plain, filed] {
            XCTAssertEqual(back.answerStatuses, r.answerStatuses)
            XCTAssertEqual(back.answerModels, r.answerModels)
            XCTAssertEqual(back.promptVersion, 7)
            XCTAssertEqual(back.createdAt, Self.recordTime)
            XCTAssertEqual(back.incompleteSeatIDs, [1, 2, 3])
        }
    }

    /// Only a kept answer that ended early is incomplete. A failed seat and one stopped before any
    /// text have no answer to mark, and a seat with no recorded status counts as complete.
    func testOnlyAKeptAnswerThatEndedEarlyIsIncomplete() {
        XCTAssertEqual(AnswerStatus.allCases.filter(\.isIncomplete), [.truncated, .stalled, .cancelled])
        var r = recordedStatusRound()
        XCTAssertEqual(r.incompleteSeatIDs, [1, 2, 3])
        r.answerStatuses = [:]
        XCTAssertTrue(r.incompleteSeatIDs.isEmpty, "no recorded status counts as complete")
    }

    /// A round from an older file decodes with an empty record, and a round built in code is never
    /// handed a time or a prompt version. A status written by a newer build drops only its own
    /// entry, never the rest of the map or the round.
    func testOldRoundsHaveAnEmptyRecordAndAnUnknownStatusDropsAlone() throws {
        let built = Round(question: "Q")
        XCTAssertNil(built.createdAt, "the default is no time, never now")
        XCTAssertNil(built.promptVersion, "the default is no version, never the current one")

        let legacy = try JSONDecoder().decode(Round.self, from: Data(#"{"question":"Q","answers":{"0":"a","1":"b"}}"#.utf8))
        XCTAssertTrue(legacy.answerStatuses.isEmpty)
        XCTAssertTrue(legacy.answerModels.isEmpty)
        XCTAssertNil(legacy.promptVersion)
        XCTAssertNil(legacy.createdAt)
        XCTAssertEqual(legacy.answeredSeatIDs, [0, 1])
        XCTAssertTrue(legacy.incompleteSeatIDs.isEmpty, "an old answer counts as complete")

        let newer = try JSONDecoder().decode(Round.self, from: Data("""
        {"question":"Q","answers":{"0":"a","1":"b","2":"c"},"answerModels":{"1":"m1"},"promptVersion":9,
         "answerStatuses":{"0":"paused","1":"truncated","2":"complete"}}
        """.utf8))
        XCTAssertEqual(newer.answerStatuses, [1: .truncated, 2: .complete], "only the unknown entry is dropped")
        XCTAssertEqual(newer.answers, [0: "a", 1: "b", 2: "c"])
        XCTAssertEqual(newer.answerModels, [1: "m1"])
        XCTAssertEqual(newer.promptVersion, 9)
        XCTAssertEqual(newer.incompleteSeatIDs, [1])

        let malformed = try JSONDecoder().decode(Round.self, from: Data(#"{"question":"Q","answers":{"0":"a"},"answerStatuses":["truncated"]}"#.utf8))
        XCTAssertTrue(malformed.answerStatuses.isEmpty, "a map it can't read is dropped, the round still loads")
        XCTAssertEqual(malformed.answers, [0: "a"])
    }

    /// Through the real save and load path: asking stamps the new round with the time and the
    /// prompt version, and all four fields reach the file and come back. A field left out of
    /// CodingKeys would quietly be left out of the file; this is the test that notices.
    @MainActor func testRoundRecordSurvivesTheRealSaveAndLoad() async throws {
        CouncilStore.clientOverrideForTesting = { _ in CannedClient(log: CallLog(), reply: "an answer") }
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = connectedStore(persisting: true)
        store.newSession()
        let id = store.currentSession
        let before = Date()
        await store.ask("Should we?")
        let after = Date()
        let asked = try XCTUnwrap(store.rounds.first)
        let stamped = try XCTUnwrap(asked.createdAt, "a new round is stamped when it is asked")
        XCTAssertTrue(before <= stamped && stamped <= after)
        XCTAssertEqual(asked.promptVersion, CouncilKit.promptVersion)
        // Set by hand, so an incomplete status and the model map reach the file too.
        store.rounds[0].answerStatuses = [0: .complete, 1: .truncated, 2: .cancelled]
        store.rounds[0].answerModels = [0: "model-0", 1: "model-1", 2: "model-2"]
        store.saveConversation()
        store.flushPendingWrite()

        let url = try XCTUnwrap(CouncilStore.sessionsFolderURL).appendingPathComponent("\(id.uuidString).json")
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let fileRound = try XCTUnwrap((file["rounds"] as? [[String: Any]])?.first)
        for key in ["answerStatuses", "answerModels", "promptVersion", "createdAt"] {
            XCTAssertNotNil(fileRound[key], "\(key) must be written to the session file")
        }

        let reloaded = CouncilStore(loadHistory: true)   // the app's read: opens the newest session
        reloaded.persistenceEnabled = false
        let back = try XCTUnwrap(reloaded.sessions.first { $0.id == id }?.rounds.first)
        XCTAssertEqual(back.answerStatuses, [0: .complete, 1: .truncated, 2: .cancelled])
        XCTAssertEqual(back.answerModels, [0: "model-0", 1: "model-1", 2: "model-2"])
        XCTAssertEqual(back.promptVersion, CouncilKit.promptVersion)
        let backTime = try XCTUnwrap(back.createdAt)
        XCTAssertEqual(backTime.timeIntervalSince1970, stamped.timeIntervalSince1970, accuracy: 1,
                       "the file keeps whole seconds only")
        XCTAssertEqual(reloaded.rounds.first?.incompleteSeatIDs, [1, 2])
    }

    // MARK: - Stage wiring and the prompt fingerprint (1.3.2)

    /// What the scripted round plants, so a test can tell exactly which input reached which call.
    /// None of it contains a provider name, a model id the seam would see, or an "Advisor X" label.
    private enum Marker {
        static let question = "QUESTION-MARKER"
        static let document = "DOCUMENT-MARKER"
        static let followUp = "FOLLOW-UP-MARKER"
        static let guestName = "GUESTNAME-MARKER"
        static let guestAnswer = "guest-answer-marker"
        static func persona(_ seat: Int) -> String { "PERSONA-MARKER-\(seat)" }
        static func model(_ seat: Int) -> String { "model-marker-\(seat)" }
        static let chairModel = "model-marker-chair"
        /// One canned reply per provider: every seat's answer is distinct, and so is the chair's.
        static let replies: [LLMProvider: String] = [.claude: "reply-alpha", .openAI: "reply-beta",
                                                     .gemini: "reply-gamma", .ollama: "reply-delta"]
    }

    /// One stage of the scripted round and the model calls it made.
    private struct StageCalls {
        let stage: String
        let calls: [LoggedCall]
    }

    /// The fixed round the wiring and fingerprint tests share: three seats on three providers, a
    /// named guest, a question and a small document, then every stage in pipeline order: peer
    /// review (seat 2 as devil's advocate), the debate, divergence and its verdict, synthesis, the
    /// chair's summary, a regenerate, a follow-up question and its peer review (where round 1's
    /// document is not in the round). Blind order is fixed, so the text each call receives is
    /// exact. Calls inside a parallel stage are sorted by provider, so the order never depends on
    /// which task finished first.
    @MainActor private func runScriptedRound() async -> [StageCalls] {
        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { p in
            CannedClient(log: log, reply: Marker.replies[p] ?? "reply-other", provider: p)
        }
        CouncilStore.fixedBlindOrderForTesting = true
        defer {
            CouncilStore.clientOverrideForTesting = nil
            CouncilStore.fixedBlindOrderForTesting = false
        }
        let store = CouncilStore()
        store.persistenceEnabled = false   // the role and chair didSets must not write the runner's defaults
        store.newSession()
        // init reads whatever the runner's defaults hold: pin every input that can reach a prompt.
        store.seats = [LLMProvider.claude, .openAI, .gemini].enumerated().map { i, p in
            Seat(id: i, archetype: .sage, provider: p, model: Marker.model(i), systemPrompt: Marker.persona(i))
        }
        store.sharedSystemPrompt = CouncilStore.defaultSystemPrompt
        store.synthesizerSeatID = 0
        store.devilsAdvocateSeatID = 2
        store.chairSeat = nil

        var stages: [StageCalls] = []
        var seen = 0
        func take(_ stage: String, parallel: Bool = false) {
            var calls = log.since(seen)
            seen = log.count
            if parallel { calls.sort { ($0.provider?.rawValue ?? "") < ($1.provider?.rawValue ?? "") } }
            stages.append(StageCalls(stage: stage, calls: calls))
        }
        await store.ask(Marker.question, document: Marker.document,
                        guest: GuestAnswer(name: Marker.guestName, text: Marker.guestAnswer))
        take("answers", parallel: true)
        await store.peerReview()
        take("peerReview", parallel: true)
        await store.runRebuttal()
        take("rebuttal", parallel: true)
        await store.runDivergence()
        // One sequential stage, two calls: the map (the merged prompt, since Claude authors it) and,
        // because the canned reply has no verdict tail, the separate verdict call after it.
        let divergence = log.since(seen)
        seen = log.count
        stages.append(StageCalls(stage: "divergence", calls: Array(divergence.prefix(1))))
        stages.append(StageCalls(stage: "verdict", calls: Array(divergence.dropFirst())))
        await store.runSynthesis()
        take("synthesis")
        store.chairSeat = Seat(id: Seat.chairID, archetype: .sage, provider: .ollama, model: Marker.chairModel)
        await store.runChairSummary(round: 0)
        take("chair")
        await store.regenerate(seatID: 0)
        take("regenerate")
        await store.ask(Marker.followUp)
        take("followUp", parallel: true)
        await store.peerReview()
        take("followUpPeerReview", parallel: true)
        return stages
    }

    /// A stage's calls as one string: each call's provider, then every message's role and text.
    private func transcript(_ calls: [LoggedCall]) -> String {
        calls.map { call in
            "=== \(call.provider?.rawValue ?? "none")\n" + call.messages.map {
                "[\($0.role.rawValue)\($0.image == nil ? "" : " +image")]\n\($0.text)"
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Prompt fingerprints by `CouncilKit.promptVersion`, one table per layer. APPEND-ONLY: when
    /// prompt text changes on purpose, bump the version and add a new entry to both tables with the
    /// digests the failing tests print; never edit an old entry, it records what that version sent.
    /// One exception: a change to the scripted round itself (its markers, replies or steps) changes
    /// no prompt, so it re-pins the current `scriptedTranscriptDigests` entry without a bump.
    private static let promptDigests: [Int: [String: String]] = [
        1: [
            "adversaryReviewPrompt": "1aafed266b847b8e39d19e02b89e14b80227dcba8b8d45824ad9f1d035078cd3",
            "analysisRequest": "7611606c34b99c94258419987d99f86dc575a29ab2d8d763fb5b9cb02c9ee745",
            "chairDebateBlock": "cf2133de17fdfecf0a7742c306e21fc74507343a83a680b03ad89144d851822d",
            "chairDebateBlockWithoutFinalTake": "26a3d7f9a6e28d5b8960941ee65a1c05f7cb6925b0463449544ab6c43814b17c",
            "chairSummaryPrompt": "c704ef29997246b4bb7fbca0953d793dc664b1cbafe20e64e0e9de6cc41ff08f",
            "chairSummaryRequest": "b8de5f0f35ba8b051d2b90d6c585a7f777e1df915f9951002399eae35fe21de6",
            "defaultSystemPrompt": "7dc75d976ac297969a58577810d711754ea6fea61705db19821d6e9738439a76",
            "divergencePrompt": "75513714a159793ebd85597eca1be52c0a45df01669f1980770b4b0fa3d4d741",
            "divergenceWithVerdictPrompt": "451b5870e2771e7aae263ab62849e7e8b0495ecb05db6b4c96378d23d53d3ae8",
            "documentOnlyQuestion": "28f063430796d65808212b31bf47276883c11cc761f27e40681ace310bd708f6",
            "documentPrompt": "eae479b0ad4f975ea18b1e9358e5ed7c56ba6f4a75011c932b63287affbd5e8a",
            "facadeDevilsAdvocatePersona": "826d073bc4570b0771e7e6e460524c251e512f3f0eff00b7d98e952aacbbc93d",
            "imageOnlyQuestion": "894b1bf999a5ae3a25812834eb8dd0db99fb848d839ec047172909dba7cb8939",
            "peerReviewPrompt": "1ac2b9829e30ec835bbeec62ce05eb2bcb890eba68be479055b4139df2ebe61c",
            "peerReviewRequest": "df6bd2493a1de624e877ff1c409b3ac21fef2639d9d8100d68420916728f52c6",
            "personaAnalyst": "353d51f9f4c64f5694ecdc6919c4149dfc5a86793ee467eafa38f6ed4c7426ad",
            "personaPractitioner": "4549d2856f5657a7843e4e56085ff60cc761e356c81437e4ef013d99fa3aca58",
            "personaSkeptic": "2d5111f9e3d1a5c452bfab85c0d2b8021b3b2c49ddbed49c5e29f37a323c2854",
            "rebuttalRequest": "7041ddfe0e414791758f47686c294de326fe7e4548b92bb069fd45e056cd8945",
            "synthesisPrompt": "eb64fd6386020429ea98fec776e977ae1208ad882662de9661972ed9197a620a",
            "verdictPrompt": "92be6fa926acb2f8df357c1577b3132e9fd5803ae42f80c1152ef18067a7033f",
            "verdictSentinel": "754d21c5e09eb73d52c9d0d5d2fd4186e7e5725c1f133cf4e64143de5e7f367c",
        ],
        // 2: peer review reads the question, the seat's persona and the round's kept document.
        2: [
            "adversaryReviewPrompt": "1aafed266b847b8e39d19e02b89e14b80227dcba8b8d45824ad9f1d035078cd3",
            "analysisRequest": "7611606c34b99c94258419987d99f86dc575a29ab2d8d763fb5b9cb02c9ee745",
            "chairDebateBlock": "cf2133de17fdfecf0a7742c306e21fc74507343a83a680b03ad89144d851822d",
            "chairDebateBlockWithoutFinalTake": "26a3d7f9a6e28d5b8960941ee65a1c05f7cb6925b0463449544ab6c43814b17c",
            "chairSummaryPrompt": "c704ef29997246b4bb7fbca0953d793dc664b1cbafe20e64e0e9de6cc41ff08f",
            "chairSummaryRequest": "b8de5f0f35ba8b051d2b90d6c585a7f777e1df915f9951002399eae35fe21de6",
            "defaultSystemPrompt": "7dc75d976ac297969a58577810d711754ea6fea61705db19821d6e9738439a76",
            "divergencePrompt": "75513714a159793ebd85597eca1be52c0a45df01669f1980770b4b0fa3d4d741",
            "divergenceWithVerdictPrompt": "451b5870e2771e7aae263ab62849e7e8b0495ecb05db6b4c96378d23d53d3ae8",
            "documentOnlyQuestion": "28f063430796d65808212b31bf47276883c11cc761f27e40681ace310bd708f6",
            "documentPrompt": "eae479b0ad4f975ea18b1e9358e5ed7c56ba6f4a75011c932b63287affbd5e8a",
            "facadeDevilsAdvocatePersona": "826d073bc4570b0771e7e6e460524c251e512f3f0eff00b7d98e952aacbbc93d",
            "imageOnlyQuestion": "894b1bf999a5ae3a25812834eb8dd0db99fb848d839ec047172909dba7cb8939",
            "peerReviewPrompt": "1ac2b9829e30ec835bbeec62ce05eb2bcb890eba68be479055b4139df2ebe61c",
            "peerReviewRequest": "c7c8373838c5e16af6c598155d873ccc6408f95ed044e9205bab7fd343251553",
            "peerReviewRequestAttachmentNotInThisRound": "c0fc68eaaac5024e13ec425dcd5944d881f7a9677442af9c1543667bf1ccc342",
            "peerReviewRequestAttachmentNotKept": "8f92bfeba1e53bcee9ff08ccb7c9f1dfd5e73b37ff4aaaf9dc0dec42177c0663",
            "peerReviewRequestWithDocument": "94655be69e9e238bd1bcbf874581518c9e930873e259adca6578878f4890d527",
            "personaAnalyst": "353d51f9f4c64f5694ecdc6919c4149dfc5a86793ee467eafa38f6ed4c7426ad",
            "personaPractitioner": "4549d2856f5657a7843e4e56085ff60cc761e356c81437e4ef013d99fa3aca58",
            "personaSkeptic": "2d5111f9e3d1a5c452bfab85c0d2b8021b3b2c49ddbed49c5e29f37a323c2854",
            "rebuttalRequest": "7041ddfe0e414791758f47686c294de326fe7e4548b92bb069fd45e056cd8945",
            "reviewerSystemPrompt": "68af7bad1bb6b747561e8d71b527d00bdb7e7901312c319d6c6bad52b45c9c39",
            "synthesisPrompt": "eb64fd6386020429ea98fec776e977ae1208ad882662de9661972ed9197a620a",
            "verdictPrompt": "92be6fa926acb2f8df357c1577b3132e9fd5803ae42f80c1152ef18067a7033f",
            "verdictSentinel": "754d21c5e09eb73d52c9d0d5d2fd4186e7e5725c1f133cf4e64143de5e7f367c",
        ],
        // 3: the synthesis maps what settled and what is left to decide, and recommends nothing.
        3: [
            "adversaryReviewPrompt": "1aafed266b847b8e39d19e02b89e14b80227dcba8b8d45824ad9f1d035078cd3",
            "analysisRequest": "7611606c34b99c94258419987d99f86dc575a29ab2d8d763fb5b9cb02c9ee745",
            "chairDebateBlock": "cf2133de17fdfecf0a7742c306e21fc74507343a83a680b03ad89144d851822d",
            "chairDebateBlockWithoutFinalTake": "26a3d7f9a6e28d5b8960941ee65a1c05f7cb6925b0463449544ab6c43814b17c",
            "chairSummaryPrompt": "c704ef29997246b4bb7fbca0953d793dc664b1cbafe20e64e0e9de6cc41ff08f",
            "chairSummaryRequest": "b8de5f0f35ba8b051d2b90d6c585a7f777e1df915f9951002399eae35fe21de6",
            "defaultSystemPrompt": "7dc75d976ac297969a58577810d711754ea6fea61705db19821d6e9738439a76",
            "divergencePrompt": "75513714a159793ebd85597eca1be52c0a45df01669f1980770b4b0fa3d4d741",
            "divergenceWithVerdictPrompt": "451b5870e2771e7aae263ab62849e7e8b0495ecb05db6b4c96378d23d53d3ae8",
            "documentOnlyQuestion": "28f063430796d65808212b31bf47276883c11cc761f27e40681ace310bd708f6",
            "documentPrompt": "eae479b0ad4f975ea18b1e9358e5ed7c56ba6f4a75011c932b63287affbd5e8a",
            "facadeDevilsAdvocatePersona": "826d073bc4570b0771e7e6e460524c251e512f3f0eff00b7d98e952aacbbc93d",
            "imageOnlyQuestion": "894b1bf999a5ae3a25812834eb8dd0db99fb848d839ec047172909dba7cb8939",
            "peerReviewPrompt": "1ac2b9829e30ec835bbeec62ce05eb2bcb890eba68be479055b4139df2ebe61c",
            "peerReviewRequest": "c7c8373838c5e16af6c598155d873ccc6408f95ed044e9205bab7fd343251553",
            "peerReviewRequestAttachmentNotInThisRound": "c0fc68eaaac5024e13ec425dcd5944d881f7a9677442af9c1543667bf1ccc342",
            "peerReviewRequestAttachmentNotKept": "8f92bfeba1e53bcee9ff08ccb7c9f1dfd5e73b37ff4aaaf9dc0dec42177c0663",
            "peerReviewRequestWithDocument": "94655be69e9e238bd1bcbf874581518c9e930873e259adca6578878f4890d527",
            "personaAnalyst": "353d51f9f4c64f5694ecdc6919c4149dfc5a86793ee467eafa38f6ed4c7426ad",
            "personaPractitioner": "4549d2856f5657a7843e4e56085ff60cc761e356c81437e4ef013d99fa3aca58",
            "personaSkeptic": "2d5111f9e3d1a5c452bfab85c0d2b8021b3b2c49ddbed49c5e29f37a323c2854",
            "rebuttalRequest": "7041ddfe0e414791758f47686c294de326fe7e4548b92bb069fd45e056cd8945",
            "reviewerSystemPrompt": "68af7bad1bb6b747561e8d71b527d00bdb7e7901312c319d6c6bad52b45c9c39",
            "synthesisPrompt": "805acfc2d5f3260a81c9317a2b451c01a19963fdb9ed03c2e6f1bb7a9015f216",
            "verdictPrompt": "92be6fa926acb2f8df357c1577b3132e9fd5803ae42f80c1152ef18067a7033f",
            "verdictSentinel": "754d21c5e09eb73d52c9d0d5d2fd4186e7e5725c1f133cf4e64143de5e7f367c",
        ],
    ]

    private static let scriptedTranscriptDigests: [Int: [String: String]] = [
        1: [
            "answers": "0902a1cc8bf934e4f5454afd6b7dee246ea1eab0be4c9fb806ea79eda7ca0d02",
            "chair": "1bcd72e9b2530c58cac52656c04dba353fa97099ab0b207764c8e6eee85dcd9a",
            "divergence": "291b0589ca0ae3da53cf1d4a7e00772879591aafc1a960efb2aaeb8d69675bbd",
            "followUp": "104d725be52e0c9fa49fcec357135d38993109359a281d1de0f339bd29496030",
            "peerReview": "27c8b40d7d823fab353dc5596e1435631e17eb384500b6407f88cc1ff8eba4fe",
            "rebuttal": "cd4cdb3f9a8bc17a58705b0d6e722191eb38aefc2a49fa582d98f44de1883af6",
            "regenerate": "bb009d951fe2557bbc48ff55226864040bce18c01d524a4fa7ea57240a95708f",
            "synthesis": "dfba97a0ed3a397ca950e0e4ab959f7b351e87269e60532631e66e538861014e",
            "verdict": "37994b9792f3315457041a196e915e0c0d58b3b169a6ee9ea095cb23b5a621c5",
        ],
        // 2: peer review changed; the round gained the follow-up's peer review.
        2: [
            "answers": "0902a1cc8bf934e4f5454afd6b7dee246ea1eab0be4c9fb806ea79eda7ca0d02",
            "chair": "1bcd72e9b2530c58cac52656c04dba353fa97099ab0b207764c8e6eee85dcd9a",
            "divergence": "291b0589ca0ae3da53cf1d4a7e00772879591aafc1a960efb2aaeb8d69675bbd",
            "followUp": "104d725be52e0c9fa49fcec357135d38993109359a281d1de0f339bd29496030",
            "followUpPeerReview": "b537a3eca01a6e0cffeddaa246c75aeb6dc69f1a09c5bf5b90dbf174d98b44ce",
            "peerReview": "85dd031bc8cfdd1853be19d62de24deafabd53094542f5138a9a97e0c6ced5f8",
            "rebuttal": "cd4cdb3f9a8bc17a58705b0d6e722191eb38aefc2a49fa582d98f44de1883af6",
            "regenerate": "bb009d951fe2557bbc48ff55226864040bce18c01d524a4fa7ea57240a95708f",
            "synthesis": "dfba97a0ed3a397ca950e0e4ab959f7b351e87269e60532631e66e538861014e",
            "verdict": "37994b9792f3315457041a196e915e0c0d58b3b169a6ee9ea095cb23b5a621c5",
        ],
        // 3: only the synthesis brief changed.
        3: [
            "answers": "0902a1cc8bf934e4f5454afd6b7dee246ea1eab0be4c9fb806ea79eda7ca0d02",
            "chair": "1bcd72e9b2530c58cac52656c04dba353fa97099ab0b207764c8e6eee85dcd9a",
            "divergence": "291b0589ca0ae3da53cf1d4a7e00772879591aafc1a960efb2aaeb8d69675bbd",
            "followUp": "104d725be52e0c9fa49fcec357135d38993109359a281d1de0f339bd29496030",
            "followUpPeerReview": "b537a3eca01a6e0cffeddaa246c75aeb6dc69f1a09c5bf5b90dbf174d98b44ce",
            "peerReview": "85dd031bc8cfdd1853be19d62de24deafabd53094542f5138a9a97e0c6ced5f8",
            "rebuttal": "cd4cdb3f9a8bc17a58705b0d6e722191eb38aefc2a49fa582d98f44de1883af6",
            "regenerate": "bb009d951fe2557bbc48ff55226864040bce18c01d524a4fa7ea57240a95708f",
            "synthesis": "e7b43d7ea2b5711cdf8c8b301f1cbb7c82877de1d25ca0cd7f93b93727866c2f",
            "verdict": "37994b9792f3315457041a196e915e0c0d58b3b169a6ee9ea095cb23b5a621c5",
        ],
    ]

    /// A table entry ready to paste, for when a fingerprint has to be pinned.
    private static func pinnable(_ digests: [String: String]) -> String {
        digests.keys.sorted().map { "            \"\($0)\": \"\(digests[$0]!)\"," }.joined(separator: "\n")
    }

    /// Compares one layer against its pinned entry: a failure names each prompt or stage that
    /// changed, then gives the whole entry to paste under the next version.
    private static func checkFingerprint(_ actual: [String: String], _ table: [Int: [String: String]],
                                         _ tableName: String) {
        let version = CouncilKit.promptVersion
        let pinned = table[version] ?? [:]
        guard actual != pinned else { return }
        for name in Set(actual.keys).union(pinned.keys).sorted() where actual[name] != pinned[name] {
            XCTFail("\(tableName): \"\(name)\" no longer matches prompt version \(version) "
                    + "(pinned \(pinned[name] ?? "nothing"), now \(actual[name] ?? "gone")).")
        }
        let next = table[version] == nil ? version : version + 1
        XCTFail("""
            The text sent to models changed without a prompt version bump. If that is intended, bump \
            CouncilKit.promptVersion to \(next) and add this entry to \(tableName) as version \(next) \
            (never edit an old one):
            \(pinnable(actual))
            """)
    }

    /// The tables only grow: versions run from 1 to the current one with no gaps (a bump without a
    /// new entry fails), and every version changes something in at least one layer.
    func testPromptFingerprintTablesGrowOneVersionAtATime() {
        let version = CouncilKit.promptVersion
        for (name, table) in [("promptDigests", Self.promptDigests),
                              ("scriptedTranscriptDigests", Self.scriptedTranscriptDigests)] {
            XCTAssertEqual(table.keys.max(), version, "\(name): the newest entry must be prompt version \(version)")
            XCTAssertEqual(Set(table.keys), Set(1...max(version, 1)), "\(name): versions run from 1 with no gaps")
        }
        for v in Self.promptDigests.keys.sorted() where v > 1 {
            XCTAssertTrue(Self.promptDigests[v] != Self.promptDigests[v - 1]
                          || Self.scriptedTranscriptDigests[v] != Self.scriptedTranscriptDigests[v - 1],
                          "prompt version \(v) pins exactly what \(v - 1) did: a bump with no text change")
        }
    }

    /// Fingerprint layer 1: every named prompt in the catalog hashes to its pinned digest.
    @MainActor func testPromptCatalogMatchesItsFingerprint() {
        let catalog = CouncilStore.promptCatalog
        XCTAssertEqual(Set(catalog.map(\.name)).count, catalog.count, "catalog names must be unique")
        for entry in catalog { XCTAssertFalse(entry.text.isEmpty, "\(entry.name) is empty") }
        Self.checkFingerprint(Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, Self.sha256($0.text)) }),
                              Self.promptDigests, "promptDigests")
    }

    /// Fingerprint layer 2: the full text each stage of the scripted round sent. This catches what
    /// the catalog can't: the blind-label blocks and how each stage assembles its messages.
    @MainActor func testScriptedRoundTranscriptMatchesItsFingerprint() async {
        let stages = await runScriptedRound()
        Self.checkFingerprint(Dictionary(uniqueKeysWithValues: stages.map { ($0.stage, Self.sha256(transcript($0.calls))) }),
                              Self.scriptedTranscriptDigests, "scriptedTranscriptDigests")
    }

    /// Every stage gets the inputs its role needs, and the blind stages nothing that would unblind
    /// them: no provider, model or guest name, and one label per position they read. The chair
    /// reads real names on purpose. Checks look anywhere in a call, never at a message position, so
    /// how a stage composes its messages is free to change.
    @MainActor func testEveryStageGetsItsInputsAndBlindStagesNameNoOne() async {
        XCTAssertFalse(Self.blindOrderFixedAtLaunch, "production shuffles; only a test may fix the order")
        let stages = await runScriptedRound()
        func calls(_ stage: String) -> [LoggedCall] { stages.first { $0.stage == stage }?.calls ?? [] }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: stages.map { ($0.stage, $0.calls.count) }),
                       ["answers": 3, "peerReview": 3, "rebuttal": 3, "divergence": 1, "verdict": 1,
                        "synthesis": 1, "chair": 1, "regenerate": 1, "followUp": 3, "followUpPeerReview": 3])

        let seatOf: [LLMProvider: Int] = [.claude: 0, .openAI: 1, .gemini: 2]
        func seat(_ call: LoggedCall) -> Int { call.provider.flatMap { seatOf[$0] } ?? -1 }
        let personas = (0...2).map(Marker.persona)
        let names = [LLMProvider.claude, .openAI, .gemini, .ollama].flatMap { [$0.panelName, $0.displayName, $0.rawValue] }
            + [Marker.guestName]
        let labels = (0..<6).map { "Advisor \(String(UnicodeScalar(65 + $0)!))" }   // Advisor A…F

        // No prompt ever carries a model id.
        for stage in stages {
            for call in stage.calls {
                for model in (0...2).map(Marker.model) + [Marker.chairModel] {
                    XCTAssertFalse(call.text.contains(model), "\(stage.stage) sent the model id \(model)")
                }
            }
        }

        // Blind stages: nobody is named, and each reads one label per position (reviewers and
        // rebutters see the three others, the analyst all four, the guest included; the follow-up
        // has no guest).
        for (stage, positions) in [("peerReview", 3), ("rebuttal", 3), ("divergence", 4), ("verdict", 4), ("synthesis", 4),
                                   ("followUpPeerReview", 2)] {
            for call in calls(stage) {
                for name in names {
                    XCTAssertFalse(call.text.contains(name), "\(stage) (seat \(seat(call))) names \"\(name)\"")
                }
                XCTAssertEqual(labels.filter(call.text.contains), Array(labels.prefix(positions)),
                               "\(stage) (seat \(seat(call))): one label per position")
            }
        }

        // The question reaches every stage that weighs it.
        for stage in ["answers", "peerReview", "rebuttal", "divergence", "verdict", "synthesis", "chair", "regenerate"] {
            for call in calls(stage) { XCTAssertTrue(call.text.contains(Marker.question), "\(stage) lacks the question") }
        }
        for stage in ["followUp", "followUpPeerReview"] {
            for call in calls(stage) { XCTAssertTrue(call.text.contains(Marker.followUp), "\(stage) lacks its own question") }
        }

        // A seat answers, reviews and debates in its own persona, never another seat's; the neutral
        // roles (divergence, verdict, synthesis, chair) carry none.
        for stage in ["answers", "peerReview", "rebuttal", "regenerate", "followUp", "followUpPeerReview"] {
            for call in calls(stage) {
                XCTAssertEqual(personas.filter(call.text.contains), [Marker.persona(seat(call))], "\(stage) persona")
            }
        }
        for stage in ["divergence", "verdict", "synthesis", "chair"] {
            for call in calls(stage) { XCTAssertTrue(personas.filter(call.text.contains).isEmpty, "\(stage) carries a persona") }
        }

        // The document reaches the answers, a regenerate of them and the round's peer review. The
        // debate, the analysts and the chair don't get it, and a follow-up doesn't carry it (that is
        // 1.3.3 work): asserted, so that changing any of this is a deliberate act. The follow-up's
        // review says plainly that it isn't there; nothing else does.
        for stage in ["answers", "regenerate", "peerReview"] {
            for call in calls(stage) { XCTAssertTrue(call.text.contains(Marker.document), "\(stage) lacks the document") }
        }
        for stage in ["rebuttal", "divergence", "verdict", "synthesis", "chair", "followUp", "followUpPeerReview"] {
            for call in calls(stage) { XCTAssertFalse(call.text.contains(Marker.document), "\(stage) carries the document") }
        }
        for stage in stages {
            for call in stage.calls {
                XCTAssertEqual(call.text.contains("not in this round"), stage.stage == "followUpPeerReview",
                               "\(stage.stage) and the note that the document is not in this round")
            }
        }

        // Peer review: each reviewer reads every other position, the guest's included, under the
        // brief its role calls for (seat 2 is the devil's advocate), placed after its persona so
        // the brief has the last word.
        for call in calls("peerReview") {
            let s = seat(call)
            for (provider, other) in seatOf where other != s {
                XCTAssertTrue(call.text.contains(Marker.replies[provider]!), "seat \(s) can't see seat \(other)'s answer")
            }
            XCTAssertTrue(call.text.contains(Marker.guestAnswer), "seat \(s) can't see the guest's answer")
        }
        for call in calls("peerReview") + calls("followUpPeerReview") {
            let s = seat(call)
            XCTAssertEqual(call.text.contains(CouncilStore.adversaryReviewPrompt), s == 2, "seat \(s) review brief")
            XCTAssertEqual(call.text.contains(CouncilStore.peerReviewPrompt), s != 2, "seat \(s) review brief")
            let brief = s == 2 ? CouncilStore.adversaryReviewPrompt : CouncilStore.peerReviewPrompt
            if let persona = call.text.range(of: Marker.persona(s)), let briefAt = call.text.range(of: brief) {
                XCTAssertLessThan(persona.lowerBound, briefAt.lowerBound, "seat \(s): the brief comes after the persona")
            }
        }

        // The chair reads the debate under real names, by design (see runChairSummary), and no labels.
        for call in calls("chair") {
            for name in ["Claude", "GPT", "Gemini", Marker.guestName] {
                XCTAssertTrue(call.text.contains(name), "the chair should read \"\(name)\"")
            }
            XCTAssertTrue(labels.filter(call.text.contains).isEmpty, "the chair reads names, not labels")
        }
    }

    /// Answers with its seat's own token ("position-N", taken from the persona marker). In every
    /// later stage it reports which label held which token, one "Advisor X holds position-N" line
    /// per position, so the de-anonymized text shows which name the store gave each position.
    private struct EchoClient: LLMClient {
        let log: CallLog
        let provider: LLMProvider
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            log.record(messages, provider: provider)
            let reply = Self.reply(to: messages)
            return AsyncThrowingStream { continuation in
                continuation.yield(.text(reply))
                continuation.finish()
            }
        }
        func validate(apiKey: String) async throws {}

        static func reply(to messages: [ChatMessage]) -> String {
            // A label line ("Advisor B:", "Advisor B said:") is followed by the position it labels.
            let lines = (messages.last { $0.role == .user }?.text ?? "").components(separatedBy: "\n")
            var held: [String] = []
            for (i, line) in lines.enumerated() where line.hasPrefix("Advisor ") && line.hasSuffix(":") && i + 1 < lines.count {
                let label = line.split(separator: " ").prefix(2).joined(separator: " ").replacingOccurrences(of: ":", with: "")
                held.append("\(label) holds \(lines[i + 1])")
            }
            if !held.isEmpty { return held.joined(separator: "\n") }
            let persona = messages.first { $0.role == .system }?.text ?? ""
            return persona.replacingOccurrences(of: "PERSONA-MARKER-", with: "position-")
        }
    }

    /// Two seats on one provider are "Claude (1)" and "Claude (2)", and each keeps its own name in
    /// peer review, the debate, divergence and synthesis. Names never enter a prompt, so the
    /// fingerprint can't see this. Blind order stays shuffled, as in production, over several
    /// rounds, so labels land on different seats from call to call.
    @MainActor func testTwoSeatsOnOneProviderKeepTheirNamesAcrossStages() async {
        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { p in EchoClient(log: log, provider: p) }
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.newSession()
        store.seats = [LLMProvider.claude, .claude, .openAI].enumerated().map { i, p in
            Seat(id: i, archetype: .sage, provider: p, systemPrompt: Marker.persona(i))
        }
        store.synthesizerSeatID = 0
        store.devilsAdvocateSeatID = -1
        store.chairSeat = nil
        let nameOf = ["position-0": "Claude (1)", "position-1": "Claude (2)", "position-2": "GPT"]

        /// "Name holds position-N" lines → position → name.
        func names(in text: String) -> [String: String] {
            var out: [String: String] = [:]
            for line in text.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: " holds ")
                if parts.count == 2 { out[parts[1]] = parts[0] }
            }
            return out
        }
        func check(_ text: String?, _ what: String, seeing positions: Set<String>) {
            let found = names(in: text ?? "")
            XCTAssertEqual(Set(found.keys), positions, "\(what) reads the wrong positions")
            for (position, name) in found { XCTAssertEqual(name, nameOf[position], "\(what): \(position) is \(name)") }
        }

        for n in 0..<4 {
            await store.ask("\(Marker.question) \(n)")
            await store.peerReview()
            await store.runRebuttal()
            await store.runDivergence()
            await store.runSynthesis()
            let r = store.rounds[n]
            XCTAssertEqual(r.answers, [0: "position-0", 1: "position-1", 2: "position-2"])
            for s in 0...2 {
                let others = Set(nameOf.keys).subtracting(["position-\(s)"])   // a seat never reads itself
                check(r.peerReviews[s], "round \(n) peer review by seat \(s)", seeing: others)
                check(r.rebuttals[s], "round \(n) rebuttal by seat \(s)", seeing: others)
            }
            check(r.divergence, "round \(n) divergence", seeing: Set(nameOf.keys))
            check(r.synthesis, "round \(n) synthesis", seeing: Set(nameOf.keys))
        }
    }

    /// Peer review reads its round's own kept document in full, and says plainly when the answers
    /// had an attachment it can't see: one Council didn't keep (an image, or a document over the
    /// limit), or one from an earlier round. A session with no attachment so far gets no note.
    @MainActor func testPeerReviewReadsItsRoundsDocumentAndSaysWhenItCant() async {
        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { p in CannedClient(log: log, reply: "an answer", provider: p) }
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = connectedStore(persisting: false)
        store.newSession()
        store.chairSeat = nil
        let limit = CouncilLimits.maxStoredAttachmentCharacters
        let notKept = "the advisors answered with an attachment"
        let notHere = "is not in this round"

        /// Asks, then runs peer review on that round and returns the review calls.
        func reviews(_ question: String, image: ImageAttachment? = nil, document: String? = nil) async -> [LoggedCall] {
            await store.ask(question, image: image, document: document)
            let seen = log.count
            await store.peerReview()
            let calls = log.since(seen)
            XCTAssertEqual(calls.count, 3, "\(question): every seat reviews")
            for call in calls {
                XCTAssertTrue(call.text.contains(question), "\(question): the review has the question")
                XCTAssertTrue(call.messages.allSatisfy { $0.image == nil }, "\(question): a review sends no image")
            }
            return calls
        }

        for call in await reviews("Q1 nothing attached") {
            XCTAssertFalse(call.text.contains("--- ATTACHED DOCUMENT ---"))
            XCTAssertFalse(call.text.contains(notKept) || call.text.contains(notHere), "nothing to say yet")
        }
        // A document right at the limit is kept, so every reviewer reads all of it.
        let atLimit = String(repeating: "k", count: limit - 4) + "TAIL"
        for call in await reviews("Q2 at the limit", document: atLimit) {
            XCTAssertTrue(call.text.contains(atLimit), "the whole kept document")
            XCTAssertFalse(call.text.contains(notKept) || call.text.contains(notHere))
        }
        // One character over: not kept, so not sent, and the review says so.
        for call in await reviews("Q3 over the limit", document: String(repeating: "o", count: limit + 1)) {
            XCTAssertFalse(call.text.contains("--- ATTACHED DOCUMENT ---"), "a document Council didn't keep isn't sent")
            XCTAssertTrue(call.text.contains(notKept))
            XCTAssertFalse(call.text.contains(notHere))
        }
        // An image is never kept either.
        for call in await reviews("Q4 an image", image: ImageAttachment(data: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png")) {
            XCTAssertTrue(call.text.contains(notKept))
        }
        // A later round with nothing attached: the earlier attachment is not in this round.
        for call in await reviews("Q5 a follow-up") {
            XCTAssertFalse(call.text.contains("--- ATTACHED DOCUMENT ---"), "an earlier round's document isn't carried")
            XCTAssertTrue(call.text.contains(notHere))
            XCTAssertFalse(call.text.contains(notKept))
        }
        // Attaching again on a later round sends that round's own document, with no note.
        for call in await reviews("Q6 attached again", document: "DOCUMENT-SIX") {
            XCTAssertTrue(call.text.contains("DOCUMENT-SIX"))
            XCTAssertFalse(call.text.contains(atLimit), "only this round's document")
            XCTAssertFalse(call.text.contains(notKept) || call.text.contains(notHere))
        }
    }

    // MARK: - Answers that end early: detected, recorded, kept out of history and deliberation (1.3.2)

    /// A backend that sends a fixed list of chunks, then ends the way a test needs: it finishes,
    /// drops the connection, or goes quiet until the caller stops listening.
    private struct ScriptedClient: LLMClient {
        enum End: Sendable { case finish, hang, drop(URLError.Code) }
        var chunks: [StreamChunk]
        var end: End = .finish
        var log: CallLog? = nil
        var provider: LLMProvider? = nil
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            log?.record(messages, provider: provider)
            let chunks = self.chunks, end = self.end
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for chunk in chunks { continuation.yield(chunk) }
                    switch end {
                    case .finish: continuation.finish()
                    case .drop(let code): continuation.finish(throwing: URLError(code))
                    case .hang:
                        try? await Task.sleep(nanoseconds: 60_000_000_000)   // never ends in test time
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        func validate(apiKey: String) async throws {}
    }

    /// One scripted backend per provider for the model calls that follow. A provider the test
    /// didn't script fails the test if it is called.
    @MainActor private func script(_ clients: [LLMProvider: ScriptedClient]) {
        CouncilStore.clientOverrideForTesting = { p in
            if let client = clients[p] { return client }
            return NetworkForbiddenClient(provider: p)
        }
    }

    @MainActor private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The context each seat replays on its next question: the turns its call carries before the
    /// new question. History is private, and this is the only place it reaches a model anyway.
    @MainActor private func contextOnNextAsk(_ store: CouncilStore) async -> [LLMProvider: [String]] {
        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { p in CannedClient(log: log, reply: "next", provider: p) }
        await store.ask("NEXT-QUESTION")
        var out: [LLMProvider: [String]] = [:]
        for call in log.since(0) {
            guard let p = call.provider else { continue }
            out[p] = Array(call.messages.filter { $0.role != .system }.map(\.text).dropLast())
        }
        return out
    }

    private func stops(_ chunks: [StreamChunk]) -> [StreamChunk.StopReason] {
        chunks.compactMap { if case .stop(let r) = $0 { return r } else { return nil } }
    }

    private func text(_ chunks: [StreamChunk]) -> String {
        chunks.map { if case .text(let t) = $0 { return t } else { return "" } }.joined()
    }

    /// Stop used to commit a half-written answer as a WHOLE one: cancelling the task that waits for
    /// the next chunk ends the stream without an error, and the pump took that for a finish. An end
    /// signal that arrived first still wins, so a Stop landing as an answer finishes changes nothing.
    func testStopIsCancelledNotFinishedAndAnEndSignalWins() async {
        func stopped(after chunks: [StreamChunk]) async -> PumpOutcome {
            let pumping = Task { await CouncilStore.pumpForTesting(client: ScriptedClient(chunks: chunks, end: .hang)) }
            try? await Task.sleep(nanoseconds: 300_000_000)   // the chunks are in; the stream is waiting
            pumping.cancel()
            return await pumping.value
        }
        let half = await stopped(after: [.text("half an answer")])
        guard case .cancelled? = half.failure else {
            return XCTFail("a Stop must be classified as cancelled, got \(String(describing: half.failure))")
        }
        XCTAssertEqual(half.text, "half an answer", "what streamed before the Stop is kept")

        let finished = await stopped(after: [.text("a whole answer"), .stop(.finished)])
        XCTAssertNil(finished.failure, "the provider said it finished before the Stop landed")
        XCTAssertEqual(finished.stop, .finished)
        let cut = await stopped(after: [.text("a cut answer"), .stop(.lengthLimit)])
        XCTAssertNil(cut.failure, "cut off is not a failure: the text is kept")
        XCTAssertEqual(cut.stop, .lengthLimit)

        let early = await CouncilStore.pumpForTesting(client: ScriptedClient(chunks: [.text("part"), .stop(.endedEarly)]))
        guard case .stalled(let message)? = early.failure else {
            return XCTFail("a stream that ended early is stalled, got \(String(describing: early.failure))")
        }
        XCTAssertTrue(message.contains("connection ended before it finished"), message)
        XCTAssertEqual(early.text, "part")

        let dropped = await CouncilStore.pumpForTesting(
            client: ScriptedClient(chunks: [.text("a whole answer"), .stop(.finished)], end: .drop(.networkConnectionLost)))
        XCTAssertNil(dropped.failure, "the answer was over before the connection dropped: nothing to retry")
        XCTAssertEqual(dropped.text, "a whole answer")
    }

    /// A backend that sent its end signal and then never closed is finished, not stalled.
    func testWatchdogLeavesAnAnswerThatAlreadyEndedAlone() async {
        let previous = CouncilLimits.stallTimeoutSeconds
        CouncilLimits.stallTimeoutSeconds = 1
        defer { CouncilLimits.stallTimeoutSeconds = previous }
        let outcome = await CouncilStore.pumpForTesting(
            client: ScriptedClient(chunks: [.text("a whole answer"), .stop(.finished)], end: .hang))
        XCTAssertNil(outcome.failure, "it had finished; going quiet afterwards changes nothing")
        XCTAssertEqual(outcome.text, "a whole answer")
    }

    /// Each provider's own end signal becomes exactly one stop chunk, read from recorded lines.
    func testStreamReadersTurnEachProvidersEndSignalIntoOneStopChunk() throws {
        let start = #"data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":1}}}"#
        func delta(_ t: String) -> String { #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(t)"}}"# }
        func ended(_ reason: String) -> String {
            #"data: {"type":"message_delta","delta":{"stop_reason":"\#(reason)","stop_sequence":null},"usage":{"output_tokens":40}}"#
        }
        let messageStop = #"data: {"type":"message_stop"}"#
        func anthropic(_ lines: [String]) throws -> [StreamChunk] {
            var reader = AnthropicClient.EventReader()
            var out: [StreamChunk] = []
            for line in lines { out += try reader.read(line) }
            return out + reader.finish()
        }
        let whole = try anthropic([start, "event: content_block_delta", delta("Hel"), delta("lo"), ended("end_turn"), messageStop])
        XCTAssertEqual(text(whole), "Hello")
        XCTAssertEqual(stops(whole), [.finished])
        guard case .usage(let i, let o)? = whole.last else { return XCTFail("usage comes last") }
        XCTAssertEqual([i, o], [12, 40])
        XCTAssertEqual(stops(try anthropic([start, delta("x"), ended("stop_sequence"), messageStop])), [.finished])
        XCTAssertEqual(stops(try anthropic([start, delta("x"), ended("max_tokens"), messageStop])), [.lengthLimit])
        XCTAssertEqual(stops(try anthropic([start, delta("x"), ended("model_context_window_exceeded"), messageStop])),
                       [.lengthLimit], "a full context window cuts the answer off too")
        XCTAssertEqual(stops(try anthropic([start, delta("x"), ended("refusal"), messageStop])), [.unknown])
        XCTAssertEqual(stops(try anthropic([start, delta("x"), messageStop])), [.finished], "message_stop alone closes a good stream")
        XCTAssertEqual(stops(try anthropic([start, delta("Half an")])), [.endedEarly],
                       "no stop reason and no message_stop: the connection ended partway")
        XCTAssertEqual(stops(try anthropic([start, delta("x"), ended("max_tokens")])), [.lengthLimit],
                       "the reason already arrived; a lost message_stop changes nothing")
        XCTAssertThrowsError(try anthropic([start, #"data: {"type":"error","error":{"message":"Overloaded"}}"#]))

        func chunk(_ t: String) -> String { #"data: {"choices":[{"index":0,"delta":{"content":"\#(t)"},"finish_reason":null}]}"# }
        func finish(_ reason: String) -> String { #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"\#(reason)"}]}"# }
        let usage = #"data: {"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":3}}"#
        func openAI(_ lines: [String], knownHost: Bool) -> [StreamChunk] {
            var reader = OpenAICompatibleClient.EventReader(marksItsEnd: knownHost)
            var out: [StreamChunk] = []
            for line in lines {
                out += reader.read(line)
                if reader.done { break }
            }
            return out + reader.finish()
        }
        let done = "data: [DONE]"
        let good = openAI([chunk("Hi"), chunk(" there"), finish("stop"), usage, done], knownHost: true)
        XCTAssertEqual(text(good), "Hi there")
        XCTAssertEqual(stops(good), [.finished])
        for host in [true, false] {
            XCTAssertEqual(stops(openAI([chunk("x"), finish("length"), done], knownHost: host)), [.lengthLimit])
            XCTAssertEqual(stops(openAI([chunk("x"), finish("max_tokens"), done], knownHost: host)), [.lengthLimit])
            XCTAssertEqual(stops(openAI([chunk("x"), finish("model_length"), done], knownHost: host)), [.lengthLimit],
                           "Mistral's context-length cut is a cut-off answer too")
            XCTAssertEqual(stops(openAI([chunk("x"), finish("error"), done], knownHost: host)), [.endedEarly],
                           "an error finish (OpenRouter) means the answer stopped partway")
            XCTAssertEqual(stops(openAI([chunk("x"), finish("content_filter"), done], knownHost: host)), [.unknown])
            XCTAssertEqual(stops(openAI([chunk("x"), done], knownHost: host)), [.unknown], "[DONE] with no reason is no marker")
        }
        XCTAssertEqual(stops(openAI([chunk("Half")], knownHost: true)), [.endedEarly],
                       "a hosted API that just stopped, with no reason and no [DONE], ended early")
        XCTAssertEqual(stops(openAI([chunk("Half")], knownHost: false)), [.unknown],
                       "a custom server that sends no reason must never look cut off")
    }

    // MARK: - Models that think before they answer (1.3.2)

    /// A model that thinks before it answers sends events with no answer text in them. Each one is
    /// a sign of life and never text: the thinking itself must not reach the answer.
    func testReadersReportLifeWhileAModelThinks() throws {
        var claude = AnthropicClient.EventReader()
        let thinking = [
            #"data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":1}}}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Weighing the options"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCg"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
        ]
        for line in thinking {
            let chunks = try claude.read(line)
            XCTAssertEqual(chunks.count, 1, line)
            guard case .heartbeat? = chunks.first else { return XCTFail("a thinking event is a sign of life: \(line)") }
        }
        XCTAssertTrue(try claude.read("event: ping").isEmpty, "only data lines are events")
        let answer = try claude.read(#"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"No."}}"#)
        XCTAssertEqual(text(answer), "No.")
        XCTAssertEqual(answer.count, 1, "a line with text carries just the text")

        var openAI = OpenAICompatibleClient.EventReader(marksItsEnd: true)
        let reasoning = [
            #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"reasoning_content":"Weighing the options"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"reasoning":"Weighing the options"},"finish_reason":null}]}"#,
            ": keep-alive",
            ": OPENROUTER PROCESSING",
        ]
        for line in reasoning {
            let chunks = openAI.read(line)
            XCTAssertEqual(chunks.count, 1, line)
            guard case .heartbeat? = chunks.first else { return XCTFail("a reasoning event is a sign of life: \(line)") }
        }
        XCTAssertTrue(openAI.read("").isEmpty)
        XCTAssertTrue(openAI.read("event: message").isEmpty)
        let said = openAI.read(#"data: {"choices":[{"index":0,"delta":{"content":"No."},"finish_reason":null}]}"#)
        XCTAssertEqual(text(said), "No.")
        XCTAssertEqual(said.count, 1, "a line with text carries just the text")
        XCTAssertTrue(openAI.read("data: [DONE]").isEmpty, "[DONE] ends the stream; it is not a sign of life")
    }

    /// Sends signs of life for longer than the stall limit, then answers.
    private struct ThinksThenAnswersClient: LLMClient {
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    for _ in 0..<12 {
                        try? await Task.sleep(nanoseconds: 150_000_000)   // 1.8s in all: past the limit below
                        continuation.yield(.heartbeat)
                    }
                    continuation.yield(.text("a considered answer"))
                    continuation.yield(.stop(.finished))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        func validate(apiKey: String) async throws {}
    }

    /// The models that think before they answer used to be cut off as stalled once the thinking
    /// ran past the limit, because only answer text counted as a sign of life.
    func testAModelThatThinksPastTheStallLimitIsNotCutOff() async {
        let previous = CouncilLimits.stallTimeoutSeconds
        CouncilLimits.stallTimeoutSeconds = 1
        defer { CouncilLimits.stallTimeoutSeconds = previous }
        let outcome = await CouncilStore.pumpForTesting(client: ThinksThenAnswersClient())
        XCTAssertNil(outcome.failure, "thinking is not a stall: \(String(describing: outcome.failure))")
        XCTAssertEqual(outcome.text, "a considered answer")
        XCTAssertEqual(outcome.stop, .finished)
    }

    /// Sends signs of life and nothing else, for ever: a queue that only says keep-alive.
    private struct OnlyHeartbeatsClient: LLMClient {
        var preamble: String? = nil
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            let preamble = self.preamble
            return AsyncThrowingStream { continuation in
                let task = Task {
                    if let preamble { continuation.yield(.text(preamble)) }
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        continuation.yield(.heartbeat)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        func validate(apiKey: String) async throws {}
    }

    /// Signs of life keep a thinking model from being cut off, but they are not an answer. A call
    /// that sends nothing else is still bounded, or it would hold the round (and the CLI, which
    /// has no Stop) for ever.
    func testSignsOfLifeAloneDoNotKeepACallOpenForEver() async {
        let stall = CouncilLimits.stallTimeoutSeconds, thinking = CouncilLimits.thinkingTimeoutSeconds
        CouncilLimits.stallTimeoutSeconds = 30       // never reached: a heartbeat arrives every 100ms
        CouncilLimits.thinkingTimeoutSeconds = 1
        defer { CouncilLimits.stallTimeoutSeconds = stall; CouncilLimits.thinkingTimeoutSeconds = thinking }

        let silent = await CouncilStore.pumpForTesting(client: OnlyHeartbeatsClient())
        guard case .stalled(let message)? = silent.failure else {
            return XCTFail("a call with no answer must end as stalled, got \(String(describing: silent.failure))")
        }
        XCTAssertTrue(message.contains("still working"), message)
        XCTAssertEqual(silent.text, "")

        let half = await CouncilStore.pumpForTesting(client: OnlyHeartbeatsClient(preamble: "half an answer"))
        guard case .stalled(let partial)? = half.failure else {
            return XCTFail("an answer that stopped moving must end as stalled, got \(String(describing: half.failure))")
        }
        XCTAssertTrue(partial.contains("stopped writing"), partial)
        XCTAssertEqual(half.text, "half an answer", "what was written is kept")
    }

    /// Two things servers do that ended in a half answer saved as a whole one: an empty finish
    /// reason on every chunk, and a failure reported inside a stream that began with HTTP 200.
    func testReaderIgnoresAnEmptyReasonAndReportsAFailureInsideTheStream() {
        var reader = OpenAICompatibleClient.EventReader(marksItsEnd: false)
        let first = reader.read(#"data: {"choices":[{"index":0,"delta":{"content":"Half"},"finish_reason":""}]}"#)
        XCTAssertEqual(text(first), "Half")
        XCTAssertTrue(stops(first).isEmpty, "an empty reason is no reason yet")
        XCTAssertEqual(stops(reader.read(#"data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#)),
                       [.lengthLimit], "the real reason still arrives")

        var failing = OpenAICompatibleClient.EventReader(marksItsEnd: false)
        XCTAssertEqual(text(failing.read(#"data: {"choices":[{"index":0,"delta":{"content":"Half"},"finish_reason":null}]}"#)), "Half")
        XCTAssertNil(failing.failure)
        XCTAssertTrue(failing.read(#"data: {"error":{"message":"model runner has stopped","code":500}}"#).isEmpty)
        XCTAssertEqual(failing.failure, "model runner has stopped", "the provider's own words reach the user")

        var bare = OpenAICompatibleClient.EventReader(marksItsEnd: false)
        _ = bare.read(#"data: {"error":"overloaded"}"#)
        XCTAssertEqual(bare.failure, "overloaded")

        // OpenRouter sends its error beside an "error" finish reason: still an early end, text kept.
        var router = OpenAICompatibleClient.EventReader(marksItsEnd: true)
        let ended = router.read(#"data: {"error":{"message":"provider failed"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#)
        XCTAssertEqual(stops(ended), [.endedEarly])
        XCTAssertNil(router.failure)

        // A chunk that merely carries a null error is an ordinary chunk.
        var plain = OpenAICompatibleClient.EventReader(marksItsEnd: true)
        XCTAssertEqual(text(plain.read(#"data: {"error":null,"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#)), "Hi")
        XCTAssertNil(plain.failure)
    }

    /// Claude from Opus 4.7 on answers a request that sets a temperature with HTTP 400. The seat's
    /// setting is left out for those models and still sent to the families that take it.
    func testClaudeLeavesTemperatureOutWhereTheModelRefusesIt() throws {
        func body(_ model: String, temperature: Double? = 0.2, maxTokens: Int? = nil) throws -> [String: Any] {
            let data = try AnthropicClient(model: model, temperature: temperature, maxTokens: maxTokens)
                .streamBody(for: [.system("be brief"), .user("hi")])
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        for model in ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5", "claude-haiku-4-5-20251001"] {
            XCTAssertEqual(try body(model)["temperature"] as? Double, 0.2, "\(model) takes a temperature")
        }
        for model in ["claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-5",
                      "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5", "claude-fable-5-2", "claude-next-9"] {
            XCTAssertNil(try body(model)["temperature"], "\(model) must not be sent a temperature")
        }
        XCTAssertNil(try body("claude-sonnet-4-6", temperature: nil)["temperature"], "no setting, nothing sent")
        // The cap covers a thinking model's thinking as well as its answer, so the default leaves room.
        XCTAssertEqual(try body("claude-sonnet-5-5")["max_tokens"] as? Int, AnthropicClient.defaultMaxTokens)
        XCTAssertGreaterThanOrEqual(AnthropicClient.defaultMaxTokens, 16_000)
        XCTAssertEqual(try body("claude-sonnet-5-5", maxTokens: 900)["max_tokens"] as? Int, 900, "the seat's own cap wins")
        XCTAssertEqual(try body("claude-sonnet-5-5")["stream"] as? Bool, true)
        XCTAssertEqual(try body("claude-sonnet-5-5")["system"] as? String, "be brief")
    }

    /// Mistral's reasoning models send `content` as a list of parts while they think, and once
    /// more as the answer starts. The thinking stays out of the answer; the answer's first words
    /// stay in. (Read as a string only, both whole lines were dropped.)
    func testReaderKeepsAnswerTextThatArrivesAsParts() {
        var reader = OpenAICompatibleClient.EventReader(marksItsEnd: false)
        let thinking = reader.read(#"data: {"choices":[{"index":0,"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"Weighing it"}]}]},"finish_reason":null}]}"#)
        XCTAssertEqual(text(thinking), "", "thinking is not answer text")
        guard case .heartbeat? = thinking.first else { return XCTFail("a thinking part is a sign of life") }
        let turn = reader.read(#"data: {"choices":[{"index":0,"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"Done."}]},{"type":"text","text":"No,"}]},"finish_reason":null}]}"#)
        XCTAssertEqual(text(turn), "No,", "the answer's first words arrive in the same list as the last thought")
        XCTAssertEqual(text(reader.read(#"data: {"choices":[{"index":0,"delta":{"content":" not yet."},"finish_reason":null}]}"#)), " not yet.")
        guard case .heartbeat? = reader.read(#"data: {"choices":[{"index":0,"delta":{"content":null},"finish_reason":null}]}"#).first
        else { return XCTFail("a null content is no text, and still a sign of life") }
        guard case .heartbeat? = reader.read(#"data: {"choices":[{"index":0,"delta":{"content":{"odd":true}},"finish_reason":null}]}"#).first
        else { return XCTFail("a shape nobody documented must not fail the line") }

        // The one-shot verdict reads the same two shapes.
        let plain = Data(#"{"choices":[{"message":{"role":"assistant","content":"{\"agreement\":80}"}}]}"#.utf8)
        XCTAssertEqual(OpenAICompatibleClient.verdictText(in: plain), #"{"agreement":80}"#)
        let parts = Data(#"{"choices":[{"message":{"role":"assistant","content":[{"type":"thinking","thinking":[{"type":"text","text":"hm"}]},{"type":"text","text":"{\"agreement\":80}"}]}}]}"#.utf8)
        XCTAssertEqual(OpenAICompatibleClient.verdictText(in: parts), #"{"agreement":80}"#)
        XCTAssertEqual(OpenAICompatibleClient.verdictText(in: Data("{}".utf8)), "")
    }

    /// OpenAI's own API takes the cap as `max_completion_tokens` and its GPT-6 models take no
    /// temperature; every other host keeps `max_tokens`, the name they all understand.
    func testEachHostGetsTheCapAndTemperatureItAccepts() throws {
        func sent(_ host: String, _ model: String, cap: Int? = 900, temperature: Double? = 0.2) throws -> [String: Any] {
            let client = OpenAICompatibleClient(endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
                                                model: model, temperature: temperature, maxTokens: cap)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: client.streamBody(for: [.user("hi")])) as? [String: Any])
        }
        let openAI = try sent("api.openai.com", "gpt-5.4-mini")
        XCTAssertEqual(openAI["max_completion_tokens"] as? Int, 900)
        XCTAssertNil(openAI["max_tokens"], "OpenAI has deprecated max_tokens and its reasoning models refuse it")
        XCTAssertEqual(openAI["temperature"] as? Double, 0.2)
        XCTAssertEqual(openAI["stream"] as? Bool, true)
        XCTAssertEqual(try sent("eu.api.openai.com", "gpt-5.4-mini")["max_completion_tokens"] as? Int, 900)
        for host in ["api.mistral.ai", "api.deepseek.com", "api.x.ai", "openrouter.ai", "localhost", "notopenai.com"] {
            let other = try sent(host, "some-model")
            XCTAssertEqual(other["max_tokens"] as? Int, 900, host)
            XCTAssertNil(other["max_completion_tokens"], host)
        }
        let uncapped = try sent("api.openai.com", "gpt-5.4-mini", cap: nil)
        XCTAssertNil(uncapped["max_completion_tokens"]); XCTAssertNil(uncapped["max_tokens"])

        for model in ["gpt-6.2-astra", "gpt-6.2-sol", "gpt-6-luna", "o3", "o4-mini", "sonar-reasoning-pro"] {
            XCTAssertNil(try sent("api.openai.com", model)["temperature"], "\(model) must not be sent a temperature")
        }
        XCTAssertNil(try sent("openrouter.ai", "openai/gpt-6.2-sol")["temperature"], "the same model behind OpenRouter")
        for model in ["gpt-5.4-mini", "deepseek-flash", "grok-4.3", "mistral-large-latest", "gemini-3.6-flash", "llama3.2"] {
            XCTAssertEqual(try sent("example.com", model)["temperature"] as? Double, 0.2, "\(model) takes a temperature")
        }

        // The verdict: the same naming rule, and room for a model that reasons before it answers.
        func verdict(_ host: String, json: Bool) throws -> [String: Any] {
            let client = OpenAICompatibleClient(endpoint: URL(string: "https://\(host)/v1/chat/completions")!, model: "m")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: client.verdictBody(for: [.user("score it")], jsonMode: json)) as? [String: Any])
        }
        XCTAssertEqual(try verdict("api.openai.com", json: true)["max_completion_tokens"] as? Int, OpenAICompatibleClient.verdictMaxTokens)
        XCTAssertEqual(try verdict("api.mistral.ai", json: true)["max_tokens"] as? Int, OpenAICompatibleClient.verdictMaxTokens)
        XCTAssertGreaterThanOrEqual(OpenAICompatibleClient.verdictMaxTokens, 1500)
        XCTAssertNotNil(try verdict("api.mistral.ai", json: true)["response_format"])
        XCTAssertNil(try verdict("api.mistral.ai", json: false)["response_format"])
        XCTAssertNil(try verdict("api.mistral.ai", json: true)["stream"], "the verdict is one shot")
    }

    // MARK: - Model lists (1.3.2)

    /// Every provider's default is one of its own suggestions, nothing offered is a model the
    /// provider has switched off, and no replacement is itself a retired id.
    func testModelListsOfferOnlyModelsThatStillExist() {
        for p in LLMProvider.allCases {
            XCTAssertTrue(p.modelOptions.contains(p.defaultModel), "\(p.panelName): the default must be in its own list")
            XCTAssertEqual(Set(p.modelOptions).count, p.modelOptions.count, "\(p.panelName): no duplicates")
            for id in p.modelOptions {
                XCTAssertEqual(p.current(id), id, "\(p.panelName) still offers \(id), which it has retired")
            }
        }
        XCTAssertFalse(LLMProvider.retiredModels.isEmpty)
        for (p, replacements) in LLMProvider.retiredModels {
            for (old, new) in replacements {
                XCTAssertEqual(old, old.lowercased(), "retired ids are matched in lower case")
                XCTAssertEqual(p.current(new), new, "\(old) must not move to another retired id")
                XCTAssertEqual(p.current(old.uppercased()), new, "however the saved id is cased")
            }
        }
    }

    /// A seat saved while `deepseek-chat` existed fails on every question now. It moves to the
    /// replacement when it loads, and so does an imported lineup. A current id stays, and so does
    /// the same name on someone's own server.
    @MainActor func testASavedSeatWithARetiredModelMovesToItsReplacement() throws {
        func seat(_ provider: String, _ model: String) throws -> Seat {
            let json = #"{"id":0,"archetype":"sage","provider":"\#(provider)","model":"\#(model)"}"#
            return try JSONDecoder().decode(Seat.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try seat("deepSeek", "deepseek-chat").model, "deepseek-flash")
        XCTAssertEqual(try seat("deepSeek", "DeepSeek-Reasoner").model, "deepseek-flash")
        XCTAssertEqual(try seat("deepSeek", "deepseek-v4-pro").model, "deepseek-v4-pro", "a current id stays")
        XCTAssertEqual(try seat("custom1", "deepseek-chat").model, "deepseek-chat", "your own server names its own models")
        XCTAssertEqual(try seat("claude", "claude-sonnet-4-6").model, "claude-sonnet-4-6")
        XCTAssertEqual(try seat("deepSeek", "").model, LLMProvider.deepSeek.defaultModel, "no saved model: the default")

        let lineup = #"""
        {"name":"an old lineup","sharedSystemPrompt":"",
         "seats":[{"provider":"deepSeek","model":"deepseek-chat"},{"provider":"claude","model":"claude-sonnet-4-6"}],
         "chair":{"provider":"deepSeek","model":"deepseek-reasoner"}}
        """#
        let store = CouncilStore()
        store.persistenceEnabled = false
        store.applyConfig(try JSONDecoder().decode(CouncilConfig.self, from: Data(lineup.utf8)))
        XCTAssertEqual(store.seats[0].model, "deepseek-flash")
        XCTAssertEqual(store.seats[1].model, "claude-sonnet-4-6")
        XCTAssertEqual(store.chairSeat?.model, "deepseek-flash")

        store.setModel("deepseek-chat", seatID: store.seats[0].id)
        XCTAssertEqual(store.seats[0].model, "deepseek-chat", "an id the user types is kept as typed for now")
    }

    /// Drops the connection partway through its first stream, then answers in full.
    private struct DropsOnceClient: LLMClient {
        let log: CallLog
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            log.record(messages)
            let client = log.count == 1
                ? ScriptedClient(chunks: [.text("the first try, ")], end: .drop(.networkConnectionLost))
                : ScriptedClient(chunks: [.text("the retry's whole answer"), .stop(.finished)])
            return client.stream(messages: messages, apiKey: apiKey)
        }
        func validate(apiKey: String) async throws {}
    }

    /// Serves canned server-sent events for chosen hosts, in process, so the real clients run end
    /// to end with no network. Registered after NoNetworkProtocol, so it is asked first.
    private final class SSEStubProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var bodies: [String: String] = [:]
        static func serve(_ bodies: [String: String]) { lock.lock(); self.bodies = bodies; lock.unlock() }
        private static func body(for host: String?) -> String? {
            lock.lock(); defer { lock.unlock() }
            return host.flatMap { bodies[$0] }
        }
        override class func canInit(with request: URLRequest) -> Bool { body(for: request.url?.host) != nil }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let body = Self.body(for: request.url?.host) ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Through the real clients: a Claude stream whose connection closed before message_stop and
    /// a GPT stream that reported an "error" finish both keep their text as stalled, never as a
    /// whole answer; a finished one stays complete. A thrown drop is retried once from scratch.
    @MainActor func testConnectionThatEndsEarlyOrAnErrorFinishIsStalled() async throws {
        SSEStubProtocol.serve([
            "api.anthropic.com": """
                event: message_start
                data: {"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":1}}}

                data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half an "}}

                data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"answer"}}

                """,
            "api.openai.com": """
                data: {"choices":[{"index":0,"delta":{"content":"Partial"},"finish_reason":null}]}

                data: {"choices":[{"index":0,"delta":{},"finish_reason":"error"}]}

                data: [DONE]

                """,
            "generativelanguage.googleapis.com": """
                data: {"choices":[{"index":0,"delta":{"content":"A whole answer"},"finish_reason":null}]}

                data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

                data: [DONE]

                """,
            "llm.example.test": """
                data: {"choices":[{"index":0,"delta":{"content":"From a custom server"}}]}

                """,
        ])
        URLProtocol.registerClass(SSEStubProtocol.self)
        defer { URLProtocol.unregisterClass(SSEStubProtocol.self); SSEStubProtocol.serve([:]) }
        CouncilStore.clientOverrideForTesting = { p in LLMClientFactory.make(for: p, model: p.defaultModel) }
        defer { CouncilStore.clientOverrideForTesting = nil }

        let store = connectedStore(persisting: false)
        store.newSession()
        await store.ask("Should we?")
        let r = store.rounds[0]
        XCTAssertEqual(r.answers, [0: "Half an answer", 1: "Partial", 2: "A whole answer"])
        XCTAssertEqual(r.answerStatuses, [0: .stalled, 1: .stalled, 2: .complete])
        XCTAssertTrue(store.status.values.allSatisfy { $0 == .idle }, "kept text is marked, not an error: \(store.status)")
        XCTAssertEqual(r.includedSeatIDs, [2])

        // A custom server that sends no reason at all reads as a finished answer: no marker.
        var custom: [StreamChunk] = []
        let client = OpenAICompatibleClient(endpoint: URL(string: "https://llm.example.test/v1/chat/completions")!, model: "m")
        for try await c in client.stream(messages: [.user("hi")], apiKey: "") { custom.append(c) }
        XCTAssertEqual(text(custom), "From a custom server")
        XCTAssertEqual(stops(custom), [.unknown])

        // A thrown drop is retried once, from scratch: the answer is the retry's alone.
        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { p in
            if p == .claude { return DropsOnceClient(log: log) }
            return CannedClient(log: CallLog(), reply: "fine")
        }
        await store.ask("Again?")
        XCTAssertEqual(log.count, 2, "one retry")
        XCTAssertEqual(store.rounds[1].answers[0], "the retry's whole answer")
        XCTAssertEqual(store.rounds[1].answerStatuses[0], .complete)
    }

    /// Stop keeps what streamed, marked as stopped, and keeps it out of the seat's context and out
    /// of deliberation. The seats that had finished are untouched.
    @MainActor func testStoppedAnswerIsKeptButNotAsAWholeAnswer() async {
        script([.claude: ScriptedClient(chunks: [.text("half an answer")], end: .hang),
                .openAI: ScriptedClient(chunks: [.text("a whole answer"), .stop(.finished)]),
                .gemini: ScriptedClient(chunks: [.text("another whole answer")])])
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = connectedStore(persisting: false)
        store.newSession()
        let asking = Task { await store.ask("Should we?") }
        await waitUntil("two seats finish and the third is mid-answer") {
            store.liveAnswers[0] == "half an answer" && store.status[1] == .idle && store.status[2] == .idle
        }
        store.cancelAll(); asking.cancel()   // what the app's Stop does
        await asking.value

        let r = store.rounds[0]
        XCTAssertEqual(r.answers, [0: "half an answer", 1: "a whole answer", 2: "another whole answer"])
        XCTAssertEqual(r.answerStatuses, [0: .cancelled, 1: .complete, 2: .complete])
        XCTAssertEqual(store.viewedAnswerStatus(0), .cancelled)
        XCTAssertEqual(r.answerModels, [0: LLMProvider.claude.defaultModel, 1: LLMProvider.openAI.defaultModel,
                                        2: LLMProvider.gemini.defaultModel], "the model that ran is recorded")
        XCTAssertEqual(store.status[0], .idle, "a Stop is not an error")
        XCTAssertEqual(r.incompleteSeatIDs, [0])
        XCTAssertEqual(store.participantIDs(in: 0), [1, 2], "it sits out of deliberation by default")
        let context = await contextOnNextAsk(store)
        XCTAssertEqual(context[.claude], [], "a stopped answer never becomes the seat's context")
        XCTAssertEqual(context[.openAI], ["Should we?", "a whole answer"])
    }

    /// Stopped before a single token: no empty answer, and no empty turn in the seat's history
    /// (the next request would carry it).
    @MainActor func testStopBeforeAnyTokenLeavesNoEmptyAnswer() async {
        let log = CallLog()
        script([.claude: ScriptedClient(chunks: [], end: .hang, log: log, provider: .claude),
                .openAI: ScriptedClient(chunks: [.text("a whole answer")]),
                .gemini: ScriptedClient(chunks: [.text("another whole answer")])])
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = connectedStore(persisting: false)
        store.newSession()
        let asking = Task { await store.ask("Should we?") }
        await waitUntil("the silent seat is called and the others finish") {
            log.count == 1 && store.status[1] == .idle && store.status[2] == .idle
        }
        try? await Task.sleep(nanoseconds: 100_000_000)   // the silent stream is being waited on
        store.cancelAll(); asking.cancel()
        await asking.value

        let r = store.rounds[0]
        XCTAssertNil(r.answers[0], "no empty answer is committed")
        XCTAssertEqual(r.answerStatuses[0], .cancelled)
        XCTAssertEqual(store.status[0], .idle)
        XCTAssertEqual(r.answeredSeatIDs, [1, 2])
        XCTAssertTrue(r.incompleteSeatIDs.isEmpty, "nothing was kept, so there is nothing to mark")
        XCTAssertNil(r.includedSeatIDs, "and nothing to sit out")
        let context = await contextOnNextAsk(store)
        XCTAssertEqual(context[.claude], [], "no empty assistant turn")
    }

    /// A model that "finishes" without writing anything gave no answer: nothing is committed, the
    /// seat says why, and no empty turn joins its history.
    @MainActor func testEmptyAnswerIsNotCommittedAsAWholeOne() async {
        script([.claude: ScriptedClient(chunks: [.stop(.finished)]),
                .openAI: ScriptedClient(chunks: [.text("a whole answer")]),
                .gemini: ScriptedClient(chunks: [.text("another whole answer")])])
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = connectedStore(persisting: false)
        store.newSession()
        await store.ask("Should we?")
        XCTAssertNil(store.rounds[0].answers[0])
        XCTAssertEqual(store.rounds[0].answerStatuses[0], .failed)
        XCTAssertEqual(store.status[0], .failed("Claude returned an empty answer."))
        let context = await contextOnNextAsk(store)
        XCTAssertEqual(context[.claude], [], "no empty assistant turn")
    }

    /// The stall watchdog: kept text is marked stalled and stays out of history; a seat that went
    /// quiet before any text has no answer and says why.
    @MainActor func testStalledAnswerIsMarkedAndKeptOutOfContext() async {
        let previous = CouncilLimits.stallTimeoutSeconds
        CouncilLimits.stallTimeoutSeconds = 1
        defer { CouncilLimits.stallTimeoutSeconds = previous }
        script([.claude: ScriptedClient(chunks: [.text("half an answer")], end: .hang),
                .openAI: ScriptedClient(chunks: [.text("a whole answer")]),
                .gemini: ScriptedClient(chunks: [], end: .hang)])
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = connectedStore(persisting: false)
        store.newSession()
        await store.ask("Should we?")

        let r = store.rounds[0]
        XCTAssertEqual(r.answers, [0: "half an answer", 1: "a whole answer"])
        XCTAssertEqual(r.answerStatuses, [0: .stalled, 1: .complete, 2: .failed])
        XCTAssertEqual(store.viewedAnswerStatus(0), .stalled)
        XCTAssertEqual(store.status[0], .idle, "the kept text is marked by its status, not an error")
        guard case .failed(let m)? = store.status[2] else { return XCTFail("a silent seat says why it has no answer") }
        XCTAssertTrue(m.contains("stopped responding") && m.contains("the council finished without it"), m)
        XCTAssertEqual(r.includedSeatIDs, [1])
        XCTAssertFalse(store.canPeerReview, "one finished answer is not a council")
        let context = await contextOnNextAsk(store)
        XCTAssertEqual(context[.claude], [])
        XCTAssertEqual(context[.openAI], ["Should we?", "a whole answer"])
        XCTAssertEqual(context[.gemini], [])
    }

    /// Cut off at the length limit: the text is kept and marked, what it cost is counted, and it
    /// stays out of history. With nothing written at all, there is no answer, and the fix is named.
    @MainActor func testTruncatedAnswerIsMarkedBilledAndKeptOutOfContext() async {
        script([.claude: ScriptedClient(chunks: [.text("a cut answer"), .usage(input: 100, output: 50), .stop(.lengthLimit)]),
                .openAI: ScriptedClient(chunks: [.usage(input: 10, output: 40), .stop(.lengthLimit)]),
                .gemini: ScriptedClient(chunks: [.text("a whole answer"), .usage(input: 1, output: 2), .stop(.finished)])])
        defer { CouncilStore.clientOverrideForTesting = nil }
        let store = connectedStore(persisting: false)
        store.newSession()
        await store.ask("Should we?")

        let r = store.rounds[0]
        XCTAssertEqual(r.answers, [0: "a cut answer", 2: "a whole answer"])
        XCTAssertEqual(r.answerStatuses, [0: .truncated, 1: .failed, 2: .complete])
        XCTAssertEqual(store.status[0], .idle)
        guard case .failed(let m)? = store.status[1] else { return XCTFail("a seat that wrote nothing says why") }
        XCTAssertTrue(m.contains("raise this seat's max tokens"), m)
        XCTAssertEqual(r.inputTokens, 111, "every call that was billed is counted")
        XCTAssertEqual(r.outputTokens, 92)
        XCTAssertEqual(r.includedSeatIDs, [2])
        // Pasting or removing a guest resets the selection to the same default, never to everyone.
        store.addGuestAnswer("a pasted answer")
        XCTAssertEqual(store.rounds[0].includedSeatIDs, [2, Round.guestSeatID])
        store.removeGuestAnswer()
        XCTAssertEqual(store.rounds[0].includedSeatIDs, [2])
        // Sitting out is a default, not a verdict: the user can bring the answer back in.
        store.setDeliberationSelection([0, 2], forRound: 0)
        XCTAssertEqual(store.participantIDs(in: 0), [0, 2])
        XCTAssertTrue(store.canPeerReview)
        let context = await contextOnNextAsk(store)
        XCTAssertEqual(context[.claude], [])
        XCTAssertEqual(context[.gemini], ["Should we?", "a whole answer"])
    }

    /// A cut-off answer never reaches review or analysis by default: it can't be reviewed, scored
    /// or named the outlier, and exports already say it sat out. Including everyone brings it back;
    /// when every answer ended early, it comes back one answer at a time.
    @MainActor func testAnswersThatEndedEarlySitOutUntilBroughtBack() async {
        let store = connectedStore(persisting: false)
        store.newSession()
        store.chairSeat = nil
        store.synthesizerSeatID = 1
        store.devilsAdvocateSeatID = -1
        script([.claude: ScriptedClient(chunks: [.text("CUT-ANSWER"), .stop(.lengthLimit)]),
                .openAI: ScriptedClient(chunks: [.text("answer B")]),
                .gemini: ScriptedClient(chunks: [.text("answer C")])])
        defer { CouncilStore.clientOverrideForTesting = nil }
        await store.ask("Should we?", guest: GuestAnswer(name: "Web", text: "a pasted answer"))
        XCTAssertEqual(store.rounds[0].includedSeatIDs, [1, 2, Round.guestSeatID])
        XCTAssertFalse(store.isSeatDeliberating(0))

        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { p in
            CannedClient(log: log, reply: #"{"agreement":40,"camps":2,"outlier":"Advisor A"}"#, provider: p)
        }
        await store.runAutoPipeline()
        let r = store.rounds[0]
        XCTAssertEqual(Set(r.peerReviews.keys), [1, 2], "the cut-off seat doesn't review either")
        XCTAssertNotNil(r.divergence); XCTAssertNotNil(r.synthesis)
        for call in log.since(0) {
            XCTAssertFalse(call.text.contains("CUT-ANSWER"), "a cut-off answer reached \(call.provider?.rawValue ?? "a call")")
        }
        XCTAssertNotNil(r.outlierSeatID, "precondition: the verdict named an outlier")
        XCTAssertNotEqual(r.outlierSeatID, 0, "the cut-off answer can't be the outlier")
        XCTAssertNotEqual(store.outlierAnswer, "CUT-ANSWER")
        XCTAssertTrue(store.exportMarkdown().contains("*(sat out of deliberation)*"))

        store.setDeliberationSelection(nil, forRound: 0)   // what the app sends when every chip is on
        XCTAssertEqual(store.participantIDs(in: 0), [0, 1, 2, Round.guestSeatID])
        XCTAssertFalse(store.latestRoundHasAnalysis, "a changed blind set clears the old analysis")

        script([.claude: ScriptedClient(chunks: [.text("cut 0"), .stop(.lengthLimit)]),
                .openAI: ScriptedClient(chunks: [.text("cut 1"), .stop(.lengthLimit)]),
                .gemini: ScriptedClient(chunks: [.text("cut 2"), .stop(.lengthLimit)])])
        await store.ask("And when every answer is cut off?")
        XCTAssertEqual(store.rounds[1].includedSeatIDs, [])
        XCTAssertFalse(store.canPeerReview)
        store.setDeliberationSelection([0], forRound: 1)
        XCTAssertEqual(store.rounds[1].includedSeatIDs, [0], "an empty selection grows one answer at a time")
        store.setDeliberationSelection([0, 1], forRound: 1)
        XCTAssertEqual(store.participantIDs(in: 1), [0, 1])
        XCTAssertTrue(store.canPeerReview)
        store.setDeliberationSelection([0], forRound: 1)
        XCTAssertEqual(store.rounds[1].includedSeatIDs, [0, 1], "shrinking below two is still refused")
    }

    /// A reopened session rebuilds each seat's context from what finished only. A round saved
    /// before 1.3.2 records no status and counts as complete.
    @MainActor func testReopenedSessionRebuildsContextFromFinishedAnswersOnly() async {
        var legacy = Round(question: "Q0"); legacy.answers = [0: "old", 1: "old too"]
        var r = Round(question: "Q1")
        r.answers = [0: "whole", 1: "cut", 2: "stopped"]
        r.answerStatuses = [0: .complete, 1: .truncated, 2: .cancelled]
        let h = CouncilStore.reconstructHistory(from: [legacy, r])
        XCTAssertEqual(h[0]?.map(\.text), ["Q0", "old", "Q1", "whole"])
        XCTAssertEqual(h[1]?.map(\.text), ["Q0", "old too"], "the cut-off answer is left out")
        XCTAssertNil(h[2], "so is the stopped one")

        let store = connectedStore(persisting: false)
        store.openSession(Session(id: UUID(), title: "T", createdAt: Date(), updatedAt: Date(),
                                  rounds: [legacy, r], history: [:]))
        defer { CouncilStore.clientOverrideForTesting = nil }
        let context = await contextOnNextAsk(store)
        XCTAssertEqual(context[.claude], ["Q0", "old", "Q1", "whole"])
        XCTAssertEqual(context[.openAI], ["Q0", "old too"])
        XCTAssertEqual(context[.gemini], [])
    }

    /// Regenerating a cut-off answer used to drop the seat's last history pair, which belonged to
    /// the PREVIOUS round (the cut-off answer was never added). It also clears the stale marker.
    @MainActor func testRegenerateAfterAnIncompleteAnswerKeepsTheEarlierExchange() async {
        let store = connectedStore(persisting: false)
        store.newSession()
        defer { CouncilStore.clientOverrideForTesting = nil }
        script([.claude: ScriptedClient(chunks: [.text("first")]), .openAI: ScriptedClient(chunks: [.text("b1")]),
                .gemini: ScriptedClient(chunks: [.text("c1")])])
        await store.ask("Q1")
        script([.claude: ScriptedClient(chunks: [.text("cut"), .stop(.lengthLimit)]),
                .openAI: ScriptedClient(chunks: [.text("b2")]), .gemini: ScriptedClient(chunks: [.text("c2")])])
        await store.ask("Q2")
        XCTAssertEqual(store.rounds[1].answerStatuses[0], .truncated)
        XCTAssertEqual(store.rounds[1].includedSeatIDs, [1, 2])

        let log = CallLog()
        script([.claude: ScriptedClient(chunks: [.text("second")], log: log, provider: .claude)])
        await store.regenerate(seatID: 0)
        let regen = log.since(0).first?.messages.filter { $0.role != .system }.map(\.text)
        XCTAssertEqual(regen, ["Q1", "first", "Q2"], "round 1's exchange is still the seat's context")
        XCTAssertEqual(store.rounds[1].answers[0], "second")
        XCTAssertEqual(store.rounds[1].answerStatuses[0], .complete, "no stale marker survives")
        XCTAssertNil(store.rounds[1].includedSeatIDs, "a whole answer deliberates again")

        script([.claude: ScriptedClient(chunks: [.text("cut again"), .stop(.lengthLimit)])])
        await store.regenerate(seatID: 0)
        XCTAssertEqual(store.rounds[1].answerStatuses[0], .truncated)
        XCTAssertEqual(store.rounds[1].includedSeatIDs, [1, 2], "cut off again: it sits out again")

        // While the new answer streams, the old one's marker is gone; Stop marks the new one.
        script([.claude: ScriptedClient(chunks: [.text("a third try")], end: .hang)])
        let regenerating = Task { await store.regenerate(seatID: 0) }
        await waitUntil("the regenerated answer is streaming") { store.liveAnswers[0] == "a third try" }
        XCTAssertNil(store.viewedAnswerStatus(0), "no stale marker under an answer that is still being written")
        XCTAssertNil(store.rounds[1].answerModels[0])
        store.cancelAll(); regenerating.cancel()
        await regenerating.value
        XCTAssertEqual(store.rounds[1].answers[0], "a third try")
        XCTAssertEqual(store.viewedAnswerStatus(0), .cancelled)
        let context = await contextOnNextAsk(store)
        XCTAssertEqual(context[.claude], ["Q1", "first"], "neither a cut-off answer nor its question is replayed")
    }

    /// A review or final take that didn't finish is not saved, the stage says why, and the seat's
    /// ANSWER keeps its status: an ERROR there would offer a retry that re-asks the answer.
    @MainActor func testUnfinishedReviewsAndTakesAreNotSavedAndLeaveTheAnswerAlone() async {
        let store = connectedStore(persisting: false)
        store.newSession()
        store.chairSeat = nil
        store.devilsAdvocateSeatID = -1
        defer { CouncilStore.clientOverrideForTesting = nil }
        script([.claude: ScriptedClient(chunks: [.text("answer A")]), .openAI: ScriptedClient(chunks: [.text("answer B")]),
                .gemini: ScriptedClient(chunks: [.text("answer C")])])
        await store.ask("Should we?")
        let answered = store.rounds[0]
        XCTAssertEqual(answered.answerStatuses, [0: .complete, 1: .complete, 2: .complete])

        script([.claude: ScriptedClient(chunks: [.text("half a review"), .stop(.lengthLimit)]),
                .openAI: ScriptedClient(chunks: [.text("a review that"), .stop(.endedEarly)]),
                .gemini: ScriptedClient(chunks: [], end: .drop(.badServerResponse))])
        await store.peerReview()
        XCTAssertTrue(store.rounds[0].peerReviews.isEmpty, "no unfinished review is kept: \(store.rounds[0].peerReviews)")
        XCTAssertEqual(store.rounds[0].answers, answered.answers)
        XCTAssertEqual(store.rounds[0].answerStatuses, answered.answerStatuses)
        XCTAssertTrue(store.status.values.allSatisfy { $0 == .idle }, "no answer panel turns to ERROR: \(store.status)")
        let reviewError = store.peerReviewError ?? ""
        XCTAssertTrue(reviewError.contains("Claude was cut off at the length limit — raise this seat's max tokens. Nothing was saved."),
                      reviewError)
        XCTAssertTrue(reviewError.contains("GPT's connection ended before it finished. Nothing was saved."), reviewError)
        XCTAssertTrue(reviewError.contains("Gemini: "), "a failed review names its seat: \(reviewError)")

        script([.claude: ScriptedClient(chunks: [.text("a final take")]),
                .openAI: ScriptedClient(chunks: [.text("half a take"), .stop(.lengthLimit)]),
                .gemini: ScriptedClient(chunks: [.text("a take")], end: .hang)])
        let debating = Task { await store.runRebuttal() }
        await waitUntil("two takes are in and the third is mid-way") {
            store.liveRebuttals[2] == "a take" && store.status[0] == .idle && store.status[1] == .idle
        }
        store.cancelAll(); debating.cancel()
        await debating.value
        XCTAssertEqual(store.rounds[0].rebuttals, [0: "a final take"], "only the finished take is kept")
        let takeError = store.rebuttalError ?? ""
        XCTAssertTrue(takeError.contains("GPT was cut off at the length limit"), takeError)
        XCTAssertTrue(takeError.contains("Stopped before Gemini finished — nothing unfinished was saved."), takeError)
        XCTAssertEqual(store.rounds[0].answerStatuses, answered.answerStatuses)
        XCTAssertTrue(store.status.values.allSatisfy { $0 == .idle })

        store.clearDeliberationErrors()   // what round navigation does: the lines belong to one attempt
        XCTAssertNil(store.peerReviewError); XCTAssertNil(store.rebuttalError)
    }

    /// A divergence, synthesis or chair summary that didn't finish is not saved, and its stage
    /// says why. A chair cut off partway hands over to an advisor, like a chair that failed.
    @MainActor func testUnfinishedAnalysesAreNotSavedAndACutOffChairHandsOver() async {
        let store = connectedStore(persisting: false)
        store.newSession()
        store.chairSeat = nil
        store.synthesizerSeatID = 0
        defer { CouncilStore.clientOverrideForTesting = nil }
        script([.claude: ScriptedClient(chunks: [.text("answer A")]), .openAI: ScriptedClient(chunks: [.text("answer B")]),
                .gemini: ScriptedClient(chunks: [.text("answer C")])])
        await store.ask("Should we?")
        let answered = store.rounds[0]

        script([.claude: ScriptedClient(chunks: [.text("half a map"), .usage(input: 7, output: 9), .stop(.lengthLimit)])])
        await store.runDivergence()
        XCTAssertNil(store.rounds[0].divergence, "a cut-off map isn't kept")
        XCTAssertNil(store.rounds[0].divergenceScore)
        XCTAssertEqual(store.divergenceError,
                       "Claude was cut off at the length limit — raise this seat's max tokens. Nothing was saved.")
        XCTAssertEqual(store.rounds[0].outputTokens, 9, "the cut-off call was still billed")

        script([.claude: ScriptedClient(chunks: [.text("half a synthesis"), .stop(.endedEarly)])])
        await store.runSynthesis()
        XCTAssertNil(store.rounds[0].synthesis)
        XCTAssertEqual(store.synthesisError, "Claude's connection ended before it finished. Nothing was saved.")

        store.chairSeat = Seat(id: Seat.chairID, archetype: .sage, provider: .ollama)
        script([.ollama: ScriptedClient(chunks: [.text("half a chair synthesis"), .stop(.lengthLimit)]),
                .claude: ScriptedClient(chunks: [.text("the advisor's synthesis")])])
        await store.runSynthesis()
        XCTAssertEqual(store.rounds[0].synthesis, "the advisor's synthesis", "an advisor stands in for the cut-off chair")
        XCTAssertNil(store.synthesisError)
        XCTAssertEqual(store.chairFallbackNote, "Ollama didn't finish — Claude wrote this.")

        store.rounds[0].rebuttals = [0: "take A", 1: "take B"]
        script([.ollama: ScriptedClient(chunks: [.text("half a summary"), .stop(.lengthLimit)])])
        await store.runChairSummary(round: 0)
        XCTAssertNil(store.rounds[0].chairSummary)
        XCTAssertEqual(store.chairError,
                       "Ollama was cut off at the length limit — raise this seat's max tokens. Nothing was saved.")
        XCTAssertEqual(store.rounds[0].answerStatuses, answered.answerStatuses, "no stage touches an answer's status")
        XCTAssertTrue(store.status.values.allSatisfy { $0 == .idle })
    }

    // MARK: - Exports, the memo and the facade say how each answer ended (1.3.2)

    /// The part of a full export that belongs to round `n` (1-based, as the export numbers them).
    private func roundSection(_ md: String, _ n: Int) -> String {
        guard let start = md.range(of: "## Round \(n) — ") else { return "" }
        let rest = md[start.lowerBound...]
        let end = rest.dropFirst().range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// An answer that ended early says why in its export heading, its memo line, its excerpt and
    /// the minority view; a seat that was asked and kept nothing says it did not answer. The model
    /// named is the one that ran, whatever the seat runs now. A round saved before 1.3.2 records no
    /// status and exports exactly as before.
    @MainActor func testExportsAndTheMemoSayHowEachAnswerEnded() async {
        let store = connectedStore(persisting: false)
        store.newSession()
        store.chairSeat = nil
        store.setModel("claude-then", seatID: 0)
        defer { CouncilStore.clientOverrideForTesting = nil }
        // Cut off, a connection that ended early, and a seat that wrote nothing at all.
        script([.claude: ScriptedClient(chunks: [.text("a cut answer"), .stop(.lengthLimit)]),
                .openAI: ScriptedClient(chunks: [.text("a half answer"), .stop(.endedEarly)]),
                .gemini: ScriptedClient(chunks: [.stop(.lengthLimit)])])
        await store.ask("First?")
        // Stopped mid-answer while the other two finish.
        script([.claude: ScriptedClient(chunks: [.text("a stopped answer")], end: .hang),
                .openAI: ScriptedClient(chunks: [.text("a whole answer"), .stop(.finished)]),
                .gemini: ScriptedClient(chunks: [.text("another whole answer")])])
        let asking = Task { await store.ask("Second?") }
        await waitUntil("two seats finish and the third is mid-answer") {
            store.liveAnswers[0] == "a stopped answer" && store.status[1] == .idle && store.status[2] == .idle
        }
        store.cancelAll(); asking.cancel()
        await asking.value
        XCTAssertEqual(store.rounds.map(\.answerStatuses),
                       [[0: .truncated, 1: .stalled, 2: .failed], [0: .cancelled, 1: .complete, 2: .complete]],
                       "precondition: every status, recorded by the real answer path")
        store.rounds[1].peerReviews = [1: "a review", 2: "another review"]   // it deliberated without seat 0
        // A session begun before 1.3.2: its first round records no status and no model.
        var old = Round(question: "Older?")
        old.answers = [0: "an old answer", 1: "another old answer"]
        old.answerProviders = [0: "Claude", 1: "GPT"]
        store.rounds.insert(old, at: 0)
        store.setModel("claude-now", seatID: 0)
        let gpt = LLMProvider.openAI.defaultModel, gemini = LLMProvider.gemini.defaultModel

        let md = store.exportMarkdown()
        let older = roundSection(md, 1), first = roundSection(md, 2), second = roundSection(md, 3)
        XCTAssertTrue(first.contains("### Claude — `claude-then` *(incomplete: cut off at the length limit)*\n\na cut answer\n"), first)
        XCTAssertTrue(first.contains("### GPT — `\(gpt)` *(incomplete: stopped responding)*\n\na half answer\n"), first)
        XCTAssertTrue(first.hasSuffix("### Gemini — `\(gemini)` *(did not answer)*\n"), "a heading with no body: \(first)")
        XCTAssertTrue(second.contains("### Claude — `claude-then` *(incomplete: stopped)* *(sat out of deliberation)*\n\na stopped answer\n"), second)
        XCTAssertTrue(second.contains("### GPT — `\(gpt)`\n\na whole answer\n"), "a whole answer has no label")
        XCTAssertFalse(md.contains("`claude-now` *("), "the model that ran, not the one the seat runs today")
        XCTAssertTrue(older.contains("### Claude — `claude-now`\n\nan old answer\n"), "no model recorded: today's rule")
        XCTAssertTrue(older.contains("### GPT — `\(gpt)`\n\nanother old answer\n"), older)
        for text in [older, second] { XCTAssertFalse(text.contains("did not answer"), text) }
        XCTAssertFalse(older.contains("incomplete") || older.contains("Gemini"), older)

        store.viewingRound = 1
        // Brought back into the deliberation, an incomplete answer can be the outlier.
        store.rounds[1].outlier = "GPT"; store.rounds[1].outlierSeatID = 1
        let memo = store.exportDecisionMemo()
        XCTAssertTrue(memo.contains("- Claude — `claude-then` (incomplete: cut off at the length limit)\n"), memo)
        XCTAssertTrue(memo.contains("- GPT — `\(gpt)` (incomplete: stopped responding)\n"), memo)
        XCTAssertTrue(memo.contains("- Gemini — `\(gemini)` (did not answer)\n"), memo)
        XCTAssertTrue(memo.contains("**Claude (incomplete: cut off at the length limit):** a cut answer\n"), memo)
        XCTAssertTrue(memo.contains("**GPT (incomplete: stopped responding):** a half answer\n"), memo)
        XCTAssertFalse(memo.contains("**Gemini"), "no excerpt without an answer")
        XCTAssertTrue(memo.contains("## Minority view — GPT (incomplete: stopped responding)\n\na half answer\n"), memo)

        store.viewingRound = 2
        let memo2 = store.exportDecisionMemo()
        XCTAssertTrue(memo2.contains("- Claude — `claude-then` (incomplete: stopped) (sat out)\n"), memo2)
        XCTAssertTrue(memo2.contains("- GPT — `\(gpt)`\n"), memo2)
        XCTAssertTrue(memo2.contains("**Claude (incomplete: stopped):** a stopped answer\n"), memo2)
        XCTAssertFalse(memo2.contains("did not answer"), memo2)

        store.viewingRound = 0
        let oldMemo = store.exportDecisionMemo()
        XCTAssertFalse(oldMemo.contains("incomplete") || oldMemo.contains("did not answer"), oldMemo)
        XCTAssertTrue(oldMemo.contains("- Claude — `claude-now`\n"), oldMemo)

        // Once the seat runs something else, the miss can't be pinned on the right advisor: left out.
        store.setProvider(.ollama, seatID: 2)
        store.viewingRound = 1
        for text in [store.exportMarkdown(), store.exportDecisionMemo()] {
            XCTAssertFalse(text.contains("did not answer") || text.contains("Ollama"), text)
            XCTAssertTrue(text.contains("incomplete: cut off at the length limit"), "the kept answers keep their labels")
        }
    }

    /// A regenerate that fails after the seat moved to another provider names the provider that
    /// was asked, never the one that wrote the answer it replaced: a miss pinned on the wrong
    /// advisor in a shareable export is worse than no line at all.
    @MainActor func testAFailedRegenerateForgetsWhoWroteTheAnswerItReplaced() async {
        let store = connectedStore(persisting: false)
        store.newSession()
        store.chairSeat = nil
        defer { CouncilStore.clientOverrideForTesting = nil }
        script([.claude: ScriptedClient(chunks: [.text("a whole answer"), .stop(.finished)]),
                .openAI: ScriptedClient(chunks: [.text("b1")]), .gemini: ScriptedClient(chunks: [.text("c1")])])
        await store.ask("Q?")
        XCTAssertEqual(store.rounds[0].answerProviders[0], "Claude", "precondition")

        store.setProvider(.ollama, seatID: 0)
        script([.ollama: ScriptedClient(chunks: [.stop(.lengthLimit)])])   // nothing kept: failed
        await store.regenerate(seatID: 0)
        XCTAssertEqual(store.rounds[0].answerStatuses[0], .failed, "precondition: the regenerate failed")
        XCTAssertNil(store.rounds[0].answers[0])
        XCTAssertNil(store.rounds[0].answerProviders[0], "no stale author survives a regenerate")
        XCTAssertNil(store.viewedAnswerProvider(0))

        let ollama = LLMProvider.ollama.defaultModel
        let md = store.exportMarkdown(), memo = store.exportDecisionMemo()
        XCTAssertTrue(md.contains("### Ollama — `\(ollama)` *(did not answer)*\n"), md)
        XCTAssertTrue(memo.contains("- Ollama — `\(ollama)` (did not answer)\n"), memo)
        for text in [md, memo] { XCTAssertFalse(text.contains("Claude"), text) }
    }

    /// A recording shows only what its rounds record: nothing for one saved before 1.3.2; for a
    /// newer one, the label of an answer recorded as incomplete and the model recorded with the
    /// answer over the one passed in. A seat recorded as failed can't be named from this viewer's
    /// seats, so it is left out.
    @MainActor func testRecordingsShowOnlyWhatTheirRoundsRecord() {
        let store = connectedStore(persisting: false)
        XCTAssertTrue(store.openReadOnly(recordedSession(debated: true), models: [0: "claude-sonnet-4-6"]))
        for text in [store.exportMarkdown(), store.exportDecisionMemo()] {
            XCTAssertFalse(text.contains("incomplete") || text.contains("did not answer"), text)
        }

        var recording = recordedSession(debated: true)
        recording.rounds[0].answerStatuses = [0: .truncated, 1: .failed, 2: .complete]
        // The failed seat's recorded model matches this viewer's seat: only being a recording keeps it out.
        recording.rounds[0].answerModels = [0: "claude-recorded", 1: LLMProvider.openAI.defaultModel, 2: "llama-recorded"]
        recording.rounds[0].answers[1] = nil; recording.rounds[0].answerProviders[1] = nil
        recording.rounds[0].peerReviews[1] = nil; recording.rounds[0].rebuttals[1] = nil
        XCTAssertTrue(store.openReadOnly(recording, models: [0: "claude-passed-in"]))
        let md = store.exportMarkdown(), memo = store.exportDecisionMemo()
        XCTAssertTrue(md.contains("### Claude — `claude-recorded` *(incomplete: cut off at the length limit)*"), md)
        XCTAssertTrue(memo.contains("- Claude — `claude-recorded` (incomplete: cut off at the length limit)"), memo)
        for text in [md, memo] {
            XCTAssertTrue(text.contains("Ollama — `llama-recorded`"), text)
            XCTAssertFalse(text.contains("claude-passed-in") || text.contains("did not answer"), text)
        }
    }

    /// The facade says how each answer ended: a cut-off answer comes back with its status and the
    /// part that arrived, isn't a failed advisor, and never reaches the deliberation. An answer
    /// built without a status, and a round that records none, read as complete.
    @MainActor func testFacadeAnswerSaysHowItEnded() async throws {
        XCTAssertEqual(DeliberationResult.Answer(backend: "Claude", text: "t", peerReview: nil).status, .complete)

        let log = CallLog()
        CouncilStore.clientOverrideForTesting = { p in
            if p == .gemini { return ScriptedClient(chunks: [.text("CUT-ANSWER"), .stop(.lengthLimit)], log: log, provider: p) }
            return CannedClient(log: log, reply: "a whole answer from \(p.panelName)", provider: p)
        }
        defer { CouncilStore.clientOverrideForTesting = nil }
        let result = try await Council(advisors: [Advisor(backend: .claude, apiKey: "test-key"),
                                                  Advisor(backend: .gpt, apiKey: "test-key"),
                                                  Advisor(backend: .gemini, apiKey: "test-key")]).deliberate("Should we?")
        XCTAssertEqual(result.answers.map(\.backend), ["Claude", "GPT", "Gemini"])
        XCTAssertEqual(result.answers.map(\.status), [.complete, .complete, .truncated])
        XCTAssertEqual(result.answers.last?.text, "CUT-ANSWER", "the part that arrived is kept")
        XCTAssertTrue(result.failedAdvisors.isEmpty, "a cut-off answer is not a failed advisor")
        XCTAssertNotNil(result.synthesis, "the two whole answers still deliberate")
        XCTAssertGreaterThan(log.count, 3, "precondition: the deliberation ran")
        for call in log.since(0) {
            XCTAssertFalse(call.text.contains("CUT-ANSWER"), "the cut-off answer reached \(call.provider?.rawValue ?? "a call")")
        }

        let store = connectedStore(persisting: false)
        store.newSession()
        var r = Round(question: "Q")
        r.answers = [0: "an old answer"]; r.answerProviders = [0: "Claude"]
        store.rounds = [r]; store.viewingRound = 0
        XCTAssertEqual(Council.result(store).answers.map(\.status), [.complete], "a round that records no status")
    }

    // MARK: - The CLI says how each answer and each stage ended (1.3.2)

    /// Answers each call by the stage brief it carries (its system message ends with it: peer
    /// review puts the seat's persona first), so a test can cut off one stage and let the rest
    /// finish. A brief with no route gets `otherwise`.
    private struct BriefRoutedClient: LLMClient {
        var routes: [String: [StreamChunk]] = [:]
        let otherwise: [StreamChunk]
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            let system = messages.first?.text ?? ""
            let chunks = routes.first { system.hasSuffix($0.key) }?.value ?? otherwise
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        }
        func validate(apiKey: String) async throws {}
    }

    private func verdict(outlier: String) -> [StreamChunk] {
        [.text(#"{"agreement":40,"camps":2,"outlier":"\#(outlier)"}"#)]
    }

    /// The text `council --json` prints for the viewed round, read back the way a script reads it.
    @MainActor private func cliJSON(_ store: CouncilStore) throws -> [String: Any] {
        let r = store.rounds[store.viewingRound]
        let stages = stageOutcomes(store, r, skipped: deliberationSkipReason(store, r))
        let text = jsonText(resultJSON(store, r, stages: stages, started: "START", finished: "END"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// The --json payload exactly as the 1.3.1 CLI built it (its code, verbatim), kept to prove
    /// that the current payload only adds to it.
    @MainActor private func cliJSON131(_ store: CouncilStore) throws -> [String: Any] {
        let r = store.rounds[store.viewingRound]
        let started = "START", finished = "END"
        func name(_ seatID: Int) -> String {
            r.answerProviders[seatID] ?? store.seats.first { $0.id == seatID }?.provider?.panelName ?? "Advisor"
        }
        var seatsArr: [[String: Any]] = []
        var answers: [String: String] = [:], reviews: [String: String] = [:], rebuttals: [String: String] = [:]
        for seat in store.seats {
            if let a = r.answers[seat.id], !a.isEmpty {
                seatsArr.append(["name": name(seat.id), "provider": seat.provider?.rawValue ?? "", "model": seat.model])
                answers[name(seat.id)] = a
            }
            if let rv = r.peerReviews[seat.id], !rv.isEmpty { reviews[name(seat.id)] = rv }
            if let rb = r.rebuttals[seat.id], !rb.isEmpty { rebuttals[name(seat.id)] = rb }
        }
        if let g = r.guestAnswer {
            let gname = answers[r.guestName] == nil ? r.guestName : "\(r.guestName) (guest)"
            seatsArr.append(["name": gname, "provider": "guest", "model": ""])
            answers[gname] = g
        }
        var obj: [String: Any] = [
            "schemaVersion": "council.cli.v1",
            "question": r.question,
            "startedAt": started, "finishedAt": finished,
            "seats": seatsArr, "answers": answers,
            "peerReviews": reviews, "rebuttals": rebuttals,
        ]
        if let agreement = r.divergenceScore {
            var d: [String: Any] = ["agreement": agreement, "displayedDivergence": 100 - agreement]
            if let c = r.divergenceCamps { d["camps"] = c }
            if let o = r.outlier { d["outlier"] = o }
            if let n = r.divergence { d["narrative"] = n }
            obj["divergence"] = d
        }
        if let s = r.synthesis { obj["synthesis"] = s }
        if let o = r.outlier, let a = store.outlierAnswer { obj["dissent"] = ["name": o, "answer": a] }
        if let inc = r.includedSeatIDs {
            obj["deliberatedSeats"] = inc.sorted().map { $0 == Round.guestSeatID ? r.guestName : name($0) }
        }
        if store.chairFallbackNote == nil, store.isChairActive, let cn = store.chairName { obj["chair"] = cn }
        if let note = store.chairFallbackNote { obj["chairFallback"] = note }
        if let c = r.chairSummary { obj["chairSummary"] = c }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every key of `old` is still in `new` with the same value: objects may only gain keys, and
    /// arrays keep their length and order.
    private func assertOnlyAdds(_ old: Any, _ new: Any, at path: String = "$",
                                file: StaticString = #filePath, line: UInt = #line) {
        switch (old, new) {
        case let (o as [String: Any], n as [String: Any]):
            for (key, value) in o {
                guard let now = n[key] else { XCTFail("\(path).\(key) was removed", file: file, line: line); continue }
                assertOnlyAdds(value, now, at: "\(path).\(key)", file: file, line: line)
            }
        case let (o as [Any], n as [Any]):
            guard o.count == n.count else {
                return XCTFail("\(path) has \(n.count) entries, had \(o.count)", file: file, line: line)
            }
            for (i, (was, now)) in zip(o, n).enumerated() { assertOnlyAdds(was, now, at: "\(path)[\(i)]", file: file, line: line) }
        default:
            XCTAssertEqual(old as? NSObject, new as? NSObject, "\(path) changed", file: file, line: line)
        }
    }

    private func stageStatuses(_ json: [String: Any]) -> [String: String]? {
        (json["stages"] as? [String: [String: Any]])?.mapValues { $0["status"] as? String ?? "" }
    }

    /// --json keeps schema council.cli.v1 and only adds: how each answer ended, the model recorded
    /// with it, how each stage ended, and the dissent's status; every 1.3.1 key keeps its value. A
    /// cut-off answer sits out by default; the notes say so, and how --fail-above counted it.
    @MainActor func testCLIJSONOnlyAddsHowEachAnswerAndStageEnded() async throws {
        let store = connectedStore(persisting: false)
        store.newSession()
        store.chairSeat = nil
        store.synthesizerSeatID = 0
        store.devilsAdvocateSeatID = -1
        store.setModel("claude-test", seatID: 0)
        CouncilStore.fixedBlindOrderForTesting = true   // the verdict's "Advisor A" is the first position
        defer { CouncilStore.clientOverrideForTesting = nil }
        script([.claude: ScriptedClient(chunks: [.text("a whole answer"), .stop(.finished)]),
                .openAI: ScriptedClient(chunks: [.text("CUT-ANSWER"), .stop(.lengthLimit)]),
                .gemini: ScriptedClient(chunks: [.text("another whole answer")])])
        await store.ask("Should we?")
        XCTAssertNil(deliberationSkipReason(store, store.rounds[0]), "two answers finished")
        XCTAssertEqual(incompleteAnswerNotes(store, store.rounds[0]), [
            "GPT's answer is incomplete: cut off at the length limit — raise this seat's max tokens;"
            + " it sits out of peer review, divergence and synthesis (--deliberate brings it back)"])

        CouncilStore.clientOverrideForTesting = { _ in BriefRoutedClient(otherwise: self.verdict(outlier: "Advisor A")) }
        await store.peerReview(); await store.runDivergence(); await store.runSynthesis()
        store.setModel("claude-now", seatID: 0)   // `model` stays the seat's, as in 1.3.1
        let json = try cliJSON(store)
        assertOnlyAdds(try cliJSON131(store), json)
        XCTAssertEqual(json["schemaVersion"] as? String, "council.cli.v1")
        let seats = try XCTUnwrap(json["seats"] as? [[String: Any]])
        XCTAssertEqual(seats.map { $0["name"] as? String }, ["Claude", "GPT", "Gemini"], "the cut-off answer is still listed")
        XCTAssertEqual(seats.map { $0["status"] as? String }, ["complete", "truncated", "complete"])
        XCTAssertEqual(seats.map { $0["recordedModel"] as? String },
                       ["claude-test", LLMProvider.openAI.defaultModel, LLMProvider.gemini.defaultModel])
        XCTAssertEqual(seats.first?["model"] as? String, "claude-now")
        XCTAssertEqual(json["answerStatus"] as? [String: String], ["Claude": "complete", "GPT": "truncated", "Gemini": "complete"])
        XCTAssertEqual((json["answers"] as? [String: String])?["GPT"], "CUT-ANSWER", "the part that arrived is kept")
        XCTAssertEqual(json["deliberatedSeats"] as? [String], ["Claude", "Gemini"], "it sat out by default")
        XCTAssertEqual(stageStatuses(json), ["peerReview": "complete", "rebuttal": "skipped", "divergence": "complete",
                                             "verdict": "complete", "synthesis": "complete", "chair": "skipped"])
        XCTAssertNil(json["dissent"], "two positions name no outlier")
        XCTAssertEqual(stageNotes(stageOutcomes(store, store.rounds[0], skipped: nil)), [])
        XCTAssertEqual(failAboveNote(store, store.rounds[0]),
                       "--fail-above gates on a divergence that leaves out the incomplete answer from GPT")

        // `--deliberate claude,gpt,gemini` brings it back; one review and the synthesis are cut off.
        store.setDeliberationSelection([0, 1, 2], forRound: 0)
        let cut: [StreamChunk] = [.text("half of it"), .stop(.lengthLimit)]
        CouncilStore.clientOverrideForTesting = { p in
            BriefRoutedClient(routes: p == .gemini ? [CouncilStore.peerReviewPrompt: cut]
                                    : p == .claude ? [CouncilStore.synthesisPrompt: cut] : [:],
                              otherwise: self.verdict(outlier: "Advisor B"))
        }
        await store.peerReview(); await store.runDivergence(); await store.runSynthesis()
        let r = store.rounds[0]
        let again = try cliJSON(store)
        assertOnlyAdds(try cliJSON131(store), again)
        XCTAssertEqual(stageStatuses(again), ["peerReview": "partial", "rebuttal": "skipped", "divergence": "complete",
                                              "verdict": "complete", "synthesis": "failed", "chair": "skipped"])
        XCTAssertEqual(stageNotes(stageOutcomes(store, r, skipped: nil)), [
            "peer review: Gemini was cut off at the length limit — raise this seat's max tokens. Nothing was saved.",
            "synthesis: Claude was cut off at the length limit — raise this seat's max tokens. Nothing was saved."])
        XCTAssertEqual((again["stages"] as? [String: [String: Any]])?["synthesis"]?["notes"] as? [String],
                       ["Claude was cut off at the length limit — raise this seat's max tokens. Nothing was saved."])
        XCTAssertNil(again["synthesis"], "a cut-off synthesis isn't kept")
        XCTAssertEqual(again["deliberatedSeats"] as? [String], ["Claude", "GPT", "Gemini"])
        let outlier = again["dissent"] as? [String: Any]
        XCTAssertEqual(outlier?["name"] as? String, "GPT"); XCTAssertEqual(outlier?["status"] as? String, "truncated")
        XCTAssertEqual(statusTag(store.dissentSeatID.flatMap(r.statusLabel), color: false),
                       " (incomplete: cut off at the length limit)", "the DISSENT block's tag")
        XCTAssertEqual(incompleteAnswerNotes(store, r), [
            "GPT's answer is incomplete: cut off at the length limit — raise this seat's max tokens;"
            + " --deliberate kept it in peer review, divergence and synthesis"])
        XCTAssertEqual(failAboveNote(store, r),
                       "--fail-above gates on a divergence that counts the incomplete answer from GPT (--deliberate)")
    }

    /// --deliberate with one name is never applied, as in 1.3.1, even when the answers that ended
    /// early left a smaller default selection the engine would let it grow: one position can't
    /// deliberate, so "deliberating over: claude" would contradict the skip note that follows.
    @MainActor func testCLIDeliberateNeedsTwoNamesWhateverTheDefaultLeft() async {
        let store = connectedStore(persisting: false)
        store.newSession()
        store.chairSeat = nil
        defer { CouncilStore.clientOverrideForTesting = nil }
        // Every answer cut off: the default selection is empty.
        script([.claude: ScriptedClient(chunks: [.text("a1"), .stop(.lengthLimit)]),
                .openAI: ScriptedClient(chunks: [.text("b1"), .stop(.lengthLimit)]),
                .gemini: ScriptedClient(chunks: [.text("c1"), .stop(.lengthLimit)])])
        await store.ask("Q1?")
        XCTAssertEqual(store.rounds[0].includedSeatIDs, [], "precondition")
        XCTAssertFalse(applyDeliberateSelection(store, [0]), "--deliberate claude")
        XCTAssertEqual(store.rounds[0].includedSeatIDs, [], "the one name was not applied")
        XCTAssertTrue(applyDeliberateSelection(store, [0, 1]), "--deliberate claude,gpt")
        XCTAssertEqual(store.rounds[0].includedSeatIDs, [0, 1])
        XCTAssertNil(deliberationSkipReason(store, store.rounds[0]))

        // Only one answer finished: the default already equals a one-name request.
        script([.claude: ScriptedClient(chunks: [.text("a2"), .stop(.finished)]),
                .openAI: ScriptedClient(chunks: [.text("b2"), .stop(.lengthLimit)]),
                .gemini: ScriptedClient(chunks: [.text("c2"), .stop(.lengthLimit)])])
        await store.ask("Q2?")
        XCTAssertEqual(store.rounds[1].includedSeatIDs, [0], "precondition")
        XCTAssertFalse(applyDeliberateSelection(store, [0]), "matching the default is not applying it")
        XCTAssertNotNil(deliberationSkipReason(store, store.rounds[1]))
        XCTAssertFalse(applyDeliberateSelection(store, [0, 5]), "a seat that didn't answer: refused by the engine")
        XCTAssertEqual(store.rounds[1].includedSeatIDs, [0])
        XCTAssertTrue(applyDeliberateSelection(store, [0, 2]))
        XCTAssertEqual(store.rounds[1].includedSeatIDs, [0, 2])
    }

    /// When too few answers finished, nothing deliberates and the CLI says why: the cut-off answer
    /// sat out, and --deliberate can bring it back. A seat that kept nothing is still reported.
    /// With nothing to bring back, the 1.3.1 note stands.
    /// Answers by the seat's own system prompt, so two seats on one provider can end differently.
    private struct PromptRoutedClient: LLMClient {
        let marker: String, marked: [StreamChunk], otherwise: [StreamChunk]
        func stream(messages: [ChatMessage], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
            let chunks = (messages.first?.text ?? "").contains(marker) ? marked : otherwise
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        }
        func validate(apiKey: String) async throws {}
    }

    /// Found in a live run: two seats on one provider were both keyed "Ollama", so the second
    /// overwrote the first in `answers` and `answerStatus` and a cut-off answer read "complete".
    @MainActor func testCLINamesTwoSeatsOnOneProviderApart() async throws {
        let store = connectedStore(persisting: false)
        store.setProvider(.claude, seatID: 1)
        store.clearProvider(seatID: 2)
        store.setSeatPrompt("SEAT-ZERO", seatID: 0)
        store.newSession()
        defer { CouncilStore.clientOverrideForTesting = nil }
        CouncilStore.clientOverrideForTesting = { _ in
            PromptRoutedClient(marker: "SEAT-ZERO", marked: [.text("HALF"), .stop(.lengthLimit)],
                               otherwise: [.text("a whole answer")])
        }
        await store.ask("Should we?")
        let r = store.rounds[0]
        XCTAssertEqual(advisorName(store, r, 0), "Claude (1)")
        XCTAssertEqual(advisorName(store, r, 1), "Claude (2)")
        let json = try cliJSON(store)
        XCTAssertEqual(json["answers"] as? [String: String], ["Claude (1)": "HALF", "Claude (2)": "a whole answer"])
        XCTAssertEqual(json["answerStatus"] as? [String: String], ["Claude (1)": "truncated", "Claude (2)": "complete"])
        XCTAssertEqual((json["seats"] as? [[String: Any]])?.map { $0["name"] as? String }, ["Claude (1)", "Claude (2)"])
        XCTAssertEqual(incompleteAnswerNotes(store, r).count, 1)
        XCTAssertTrue(incompleteAnswerNotes(store, r).first?.hasPrefix("Claude (1)'s answer is incomplete") == true)
    }

    /// --deliberate could only ever name a provider's first seat, so a cut-off second seat had no
    /// way back in. The name the run prints picks a seat, and a repeated provider name takes that
    /// provider's seats in order.
    @MainActor func testCLIDeliberateCanNameEachSeatOfOneProvider() {
        let store = connectedStore(persisting: false)
        store.setProvider(.claude, seatID: 1)        // seats 0 and 1 are both Claude; seat 2 is Gemini
        XCTAssertEqual(deliberateSeat(store, nil, named: "claude", taken: [])?.id, 0)
        XCTAssertEqual(deliberateSeat(store, nil, named: "claude", taken: [0])?.id, 1, "the second claude is the second Claude seat")
        XCTAssertEqual(deliberateSeat(store, nil, named: "claude (2)", taken: [])?.id, 1, "the name the run prints")
        XCTAssertEqual(deliberateSeat(store, nil, named: " Claude (1) ", taken: [1])?.id, 0)
        XCTAssertEqual(deliberateSeat(store, nil, named: "gemini", taken: [])?.id, 2)
        XCTAssertNil(deliberateSeat(store, nil, named: "grok", taken: []), "not in the lineup")
        XCTAssertNil(deliberateSeat(store, nil, named: "nonsense", taken: []))
    }

    /// The engine names only the answers that deliberated, so with two seats on one provider and
    /// one sitting out it calls the other plain "Claude". The JSON names the outlier, the dissent
    /// and the deliberated seats by the keys their answers sit under, or a script could not join them.
    @MainActor func testCLINamesTheOutlierByItsAnswersKey() throws {
        var r = Round(question: "Should we?")
        for (id, name) in [(0, "Claude"), (1, "Claude"), (2, "Gemini")] {
            r.answers[id] = "answer from seat \(id)"
            r.answerProviders[id] = name
        }
        r.answerStatuses = [0: .truncated, 1: .complete, 2: .complete]
        r.includedSeatIDs = [1, 2]
        r.divergence = "## Divergence\nClaude differs"
        r.divergenceScore = 60; r.divergenceCamps = 2
        r.outlier = "Claude"; r.outlierSeatID = 1          // the engine's name for seat 1
        r.synthesis = "What settled: little."
        let session = Session(id: UUID(), title: "Two Claudes", createdAt: Date(), updatedAt: Date(),
                              rounds: [r], history: [:])
        let store = connectedStore(persisting: false)
        XCTAssertTrue(store.openReadOnly(session, models: [:]))
        let json = try cliJSON(store)
        XCTAssertEqual(Set((json["answers"] as? [String: String] ?? [:]).keys), ["Claude (1)", "Claude (2)", "Gemini"])
        XCTAssertEqual((json["divergence"] as? [String: Any])?["outlier"] as? String, "Claude (2)")
        XCTAssertEqual((json["dissent"] as? [String: Any])?["name"] as? String, "Claude (2)")
        XCTAssertEqual((json["dissent"] as? [String: Any])?["answer"] as? String, "answer from seat 1")
        XCTAssertEqual(json["deliberatedSeats"] as? [String], ["Claude (2)", "Gemini"])
    }

    /// A guest named after a seat that kept no answer must not take over that seat's status.
    @MainActor func testCLIGuestNamedAfterAFailedSeatKeepsBothStatuses() async throws {
        let store = connectedStore(persisting: false)
        store.clearProvider(seatID: 2)
        store.newSession()
        defer { CouncilStore.clientOverrideForTesting = nil }
        script([.claude: ScriptedClient(chunks: [.text("a whole answer"), .stop(.finished)]),
                .openAI: ScriptedClient(chunks: [.stop(.lengthLimit)])])   // nothing kept: failed
        await store.ask("Should we?")
        store.addGuestAnswer("an outside answer", name: "GPT")
        let json = try cliJSON(store)
        let status = try XCTUnwrap(json["answerStatus"] as? [String: String])
        XCTAssertEqual(status["GPT"], "failed", "the seat that kept nothing keeps its own entry")
        XCTAssertEqual(status["GPT (guest)"], "complete")
        XCTAssertEqual((json["answers"] as? [String: String])?["GPT (guest)"], "an outside answer")
    }

    @MainActor func testCLISaysWhyTooFewFinishedAnswersDeliberateNothing() async throws {
        let store = connectedStore(persisting: false)
        store.newSession()
        defer { CouncilStore.clientOverrideForTesting = nil }
        script([.claude: ScriptedClient(chunks: [.text("a whole answer")]),
                .openAI: ScriptedClient(chunks: [.text("HALF-ANSWER"), .stop(.endedEarly)]),
                .gemini: ScriptedClient(chunks: [.stop(.lengthLimit)])])
        await store.ask("Should we?")
        let r = store.rounds[0]
        let why = "fewer than 2 finished answers — peer review / divergence / synthesis need ≥2"
            + " (the incomplete one sat out; --deliberate brings it back)"
        XCTAssertEqual(deliberationSkipReason(store, r), why)
        let json = try cliJSON(store)
        assertOnlyAdds(try cliJSON131(store), json)
        XCTAssertEqual(json["answerStatus"] as? [String: String], ["Claude": "complete", "GPT": "stalled", "Gemini": "failed"],
                       "a seat that kept no answer is reported too")
        XCTAssertEqual((json["seats"] as? [[String: Any]])?.map { $0["status"] as? String }, ["complete", "stalled"])
        XCTAssertNil(json["divergence"])
        let stages = json["stages"] as? [String: [String: Any]]
        for key in ["peerReview", "divergence", "verdict", "synthesis"] {
            XCTAssertEqual(stages?[key]?["status"] as? String, "skipped", key)
            XCTAssertEqual(stages?[key]?["notes"] as? [String], [why], key)
        }
        XCTAssertEqual(stages?["chair"]?["status"] as? String, "skipped", "the chair had nothing to moderate")
        XCTAssertEqual(stageNotes(stageOutcomes(store, r, skipped: why)), [], "stderr gives the reason once, not per stage")
        XCTAssertEqual(incompleteAnswerNotes(store, r), [
            "GPT's answer is incomplete: stopped responding;"
            + " it sits out of peer review, divergence and synthesis (--deliberate brings it back)"])
        XCTAssertEqual(failAboveNote(store, r),
                       "--fail-above gates on a divergence that leaves out the incomplete answer from GPT")

        store.setDeliberationSelection([0, 1], forRound: 0)   // --deliberate claude,gpt
        XCTAssertNil(deliberationSkipReason(store, store.rounds[0]), "brought back, it can deliberate")
        // The chair maps the divergence, but its verdict can't be read.
        CouncilStore.clientOverrideForTesting = { _ in
            BriefRoutedClient(routes: [CouncilStore.verdictPrompt: [.text("no verdict here")]], otherwise: [.text("a map")])
        }
        await store.peerReview(); await store.runDivergence(); await store.runSynthesis()
        let judged = try cliJSON(store)
        assertOnlyAdds(try cliJSON131(store), judged)
        XCTAssertEqual(stageStatuses(judged), ["peerReview": "complete", "rebuttal": "skipped", "divergence": "complete",
                                               "verdict": "failed", "synthesis": "complete", "chair": "complete"])
        XCTAssertEqual(stageNotes(stageOutcomes(store, store.rounds[0], skipped: nil)),
                       ["divergence verdict: no verdict came back, or it couldn't be read"])

        script([.claude: ScriptedClient(chunks: [.text("the only answer")]),
                .openAI: ScriptedClient(chunks: [.stop(.lengthLimit)]),
                .gemini: ScriptedClient(chunks: [.stop(.endedEarly)])])
        await store.ask("And now?")
        XCTAssertEqual(deliberationSkipReason(store, store.rounds[1]),
                       "only one advisor answered — peer review / divergence / synthesis need ≥2")
        XCTAssertNil(failAboveNote(store, store.rounds[1]))
        XCTAssertEqual(incompleteAnswerNotes(store, store.rounds[1]), [])
    }

    /// The chair stage says whether the chair wrote divergence and synthesis, and names who stood
    /// in when it didn't finish.
    @MainActor func testCLIChairStageSaysWhoStoodIn() async throws {
        let store = connectedStore(persisting: false)   // Claude chairs
        store.newSession()
        store.synthesizerSeatID = 2
        defer { CouncilStore.clientOverrideForTesting = nil }
        script([.claude: ScriptedClient(chunks: [.text("answer A")]),
                .openAI: ScriptedClient(chunks: [.text("answer B")]),
                .gemini: ScriptedClient(chunks: [.text("answer C")])])
        await store.ask("Should we?")
        CouncilStore.clientOverrideForTesting = { _ in BriefRoutedClient(otherwise: self.verdict(outlier: "Advisor A")) }
        await store.peerReview(); await store.runDivergence(); await store.runSynthesis()
        var json = try cliJSON(store)
        XCTAssertEqual(stageStatuses(json)?["chair"], "complete")
        XCTAssertEqual(json["chair"] as? String, "Claude")

        script([.claude: ScriptedClient(chunks: [.text("answer A")]),
                .openAI: ScriptedClient(chunks: [.text("answer B")]),
                .gemini: ScriptedClient(chunks: [.text("answer C")])])
        await store.ask("And now?")
        CouncilStore.clientOverrideForTesting = { p in
            BriefRoutedClient(routes: p == .claude ? [CouncilStore.divergenceWithVerdictPrompt: [.text("half a map"), .stop(.lengthLimit)]] : [:],
                              otherwise: self.verdict(outlier: "Advisor A"))
        }
        await store.peerReview(); await store.runDivergence(); await store.runSynthesis()
        json = try cliJSON(store)
        assertOnlyAdds(try cliJSON131(store), json)
        XCTAssertEqual(stageStatuses(json), ["peerReview": "complete", "rebuttal": "skipped", "divergence": "complete",
                                             "verdict": "complete", "synthesis": "complete", "chair": "failed"])
        XCTAssertEqual(stageNotes(stageOutcomes(store, store.rounds[1], skipped: nil)),
                       ["chair: Claude didn't finish — Gemini wrote this."])
        XCTAssertEqual(json["chairFallback"] as? String, "Claude didn't finish — Gemini wrote this.")
    }

    /// The dim tag is plain text under NO_COLOR or off a terminal, and absent for a whole answer.
    func testCLIStatusTagRespectsNoColor() {
        XCTAssertTrue(Style.enabled(environment: [:], stdoutIsTTY: true))
        XCTAssertFalse(Style.enabled(environment: ["NO_COLOR": "1"], stdoutIsTTY: true))
        XCTAssertFalse(Style.enabled(environment: [:], stdoutIsTTY: false))
        XCTAssertEqual(statusTag("incomplete: stopped responding", color: false), " (incomplete: stopped responding)")
        XCTAssertEqual(statusTag("incomplete: stopped responding", color: true),
                       " \u{1B}[2m(incomplete: stopped responding)\u{1B}[0m")
        XCTAssertEqual(statusTag(nil, color: true), "")
    }

    // MARK: - The synthesis maps the decision and leaves it to the user (1.3.2)

    /// The synthesis brief asks for what settled and what is left to decide, never a recommended
    /// answer. Nothing downstream reads the synthesis's headings: the round, the screen's text, both
    /// exports and the CLI's JSON carry it exactly as written, each full "Advisor X" label put back
    /// to its advisor's name. (`--quiet` prints `synthesisText` and the facade returns it unchanged.)
    @MainActor func testSynthesisReachesEveryReaderAsWritten() async throws {
        let brief = CouncilStore.synthesisPrompt
        XCTAssertFalse(brief.lowercased().contains("recommended answer"), "the synthesis doesn't decide for the user")
        for heading in ["## What the council settled", "## What you still have to decide", "## Where they diverged"] {
            XCTAssertTrue(brief.contains(heading), "the brief asks for \(heading)")
        }

        let store = connectedStore(persisting: false)
        store.newSession()
        store.chairSeat = nil
        store.synthesizerSeatID = 0
        store.devilsAdvocateSeatID = -1
        CouncilStore.fixedBlindOrderForTesting = true   // Advisor A, B and C are seats 0, 1 and 2
        defer { CouncilStore.clientOverrideForTesting = nil }
        let written = """
            ## What the council settled

            Advisor A and Advisor B agree: start small.

            ## What you still have to decide

            How much risk to take on now. Advisor C makes the strongest case for waiting.

            ## Where they diverged

            Advisor C would wait a year; Advisor A would not.
            """
        CouncilStore.clientOverrideForTesting = { _ in
            BriefRoutedClient(routes: [CouncilStore.synthesisPrompt: [.text(written)]], otherwise: [.text("an answer")])
        }
        await store.ask("Should we?")
        await store.runSynthesis()

        let shown = written.replacingOccurrences(of: "Advisor A", with: "Claude")
            .replacingOccurrences(of: "Advisor B", with: "GPT")
            .replacingOccurrences(of: "Advisor C", with: "Gemini")
        XCTAssertEqual(store.rounds[0].synthesis, shown)
        XCTAssertEqual(store.synthesisText, shown)
        XCTAssertNil(store.synthesisError)
        XCTAssertTrue(store.exportMarkdown().contains("#### Synthesis\n\n\(shown)\n\n"), "the full export")
        XCTAssertTrue(store.exportDecisionMemo().contains("## Synthesis\n\n\(shown)\n\n"), "the memo")
        XCTAssertEqual(try cliJSON(store)["synthesis"] as? String, shown, "the CLI's JSON")
    }
}
