import Foundation
import CouncilKit

// ─────────────────────────────────────────────────────────────────────────────
// council — the Council engine as a text-only power tool. Zero pixels.
// Exit codes: 0 ok · 1 --fail-above tripped · 2 runtime error · 64 usage error.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Output helpers (respect NO_COLOR + non-TTY)

enum Style {
    /// Color only on a terminal, and never when NO_COLOR is set.
    static func enabled(environment: [String: String], stdoutIsTTY: Bool) -> Bool {
        environment["NO_COLOR"] == nil && stdoutIsTTY
    }
    static let on = enabled(environment: ProcessInfo.processInfo.environment, stdoutIsTTY: isatty(1) != 0)
    static func bold(_ s: String) -> String { on ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
    static func dim(_ s: String, color: Bool = Style.on) -> String { color ? "\u{1B}[2m\(s)\u{1B}[0m" : s }
}

func errPrint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func die(_ msg: String, code: Int32 = 2) -> Never { errPrint("error: \(msg)"); exit(code) }

// MARK: - Options

struct Options {
    var question = ""
    var configPath: String?
    var seatNames: [String] = []
    var json = false
    var md = false
    var mdOut: String?
    var quiet = false
    var verbose = false
    var failAbove: Int?
    var noSave = false
    var allowEnvKeys = false
    var filePath: String?
    var guestPath: String?
    var guestName: String?
    var deliberateNames: [String]?
    var chairName: String?
}

let usage = """
council — multi-LLM roundtable in your terminal (the Council app's engine)

USAGE
  council "question" [flags]            run the full pipeline
  council keys set <provider>           store an API key in the Keychain (hidden prompt)
  council "review this" --file doc.md   attach a document for every seat
  cat doc.md | council "review this"    same, from stdin

FLAGS
  --config <path.council>   use a saved lineup (schema council.v1)
  --file <path>             attach a text/markdown document (analyzed by every seat)
  --seats a,b,c             ad-hoc lineup with default personas
                            (claude gpt gemini deepseek grok mistral perplexity
                             openrouter ollama apple custom1 custom2)
  --guest <path>            paste an external AI's answer (from a file) into the round —
                            it joins blind peer review as one more anonymous advisor
  --guest-name <name>       guest label, revealed only AFTER deliberation (default "Guest")
  --deliberate a,b[,guest]  only these answers enter peer review / divergence / synthesis
  --chair <provider>        neutral chair for THIS run: it moderates (divergence + synthesis)
                            but never answers the question itself. If it can't run, an advisor
                            writes them instead and the run says so
  --json                    full structured result on stdout (schema council.cli.v1)
  --md [-o file.md]         decision memo (markdown) on stdout or to a file
  --quiet                   synthesis only (bare text, no headers)
  -v                        include the full peer reviews (the CLI doesn't run the debate round)
  --fail-above <N>          exit 1 if displayed divergence > N (CI gating). An answer that was cut
                            off or stalled sits out of it unless --deliberate names it
  --no-save                 don't write the session into the app's history
  --allow-env-keys          CI only: COUNCIL_KEY_<PROVIDER> env vars may supply keys. The suffix is
                            the provider id, not the seat name: CLAUDE OPENAI (not GPT) GEMINI
                            DEEPSEEK GROK MISTRAL PERPLEXITY OPENROUTER

EXIT CODES   0 ok · 1 divergence gate tripped · 2 runtime error · 64 usage error

Keys are read from the macOS Keychain (shared with the Council app — macOS asks once
per key, and again after a Council update rotates its Keychain items). Sessions land
in the app's history unless --no-save.

\(CouncilKit.attribution)
"""

func parseArgs(_ argv: [String]) -> Options {
    var o = Options()
    var args = argv
    var positionals: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--help", "-h": print(usage); exit(0)
        case "--version", "-V": print("council \(CouncilKit.version)\n\(CouncilKit.signature)"); exit(0)
        case "--config":     o.configPath = args.isEmpty ? nil : args.removeFirst()
        case "--file":       guard !args.isEmpty else { die("--file needs a path (see --help)", code: 64) }
                             o.filePath = args.removeFirst()
        case "--seats":      o.seatNames = (args.isEmpty ? "" : args.removeFirst())
                                 .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        case "--guest":      guard !args.isEmpty else { die("--guest needs a path (see --help)", code: 64) }
                             o.guestPath = args.removeFirst()
        case "--guest-name": guard !args.isEmpty else { die("--guest-name needs a name", code: 64) }
                             o.guestName = args.removeFirst()
        case "--deliberate": o.deliberateNames = (args.isEmpty ? "" : args.removeFirst())
                                 .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        case "--chair":      guard !args.isEmpty else { die("--chair needs a provider (see --help)", code: 64) }
                             o.chairName = args.removeFirst().lowercased()
        case "--json":       o.json = true
        case "--md":         o.md = true
        case "-o":           o.mdOut = args.isEmpty ? nil : args.removeFirst()
        case "--quiet":      o.quiet = true
        case "-v", "--verbose": o.verbose = true
        case "--fail-above":
            guard !args.isEmpty, let n = Int(args.removeFirst()), (0...100).contains(n)
            else { die("--fail-above needs a number 0–100", code: 64) }
            o.failAbove = n
        case "--no-save":    o.noSave = true
        case "--allow-env-keys": o.allowEnvKeys = true
        default:
            if a.hasPrefix("-") { die("unknown flag \(a) (see --help)", code: 64) }
            positionals.append(a)
        }
    }
    o.question = positionals.joined(separator: " ")
    return o
}

// MARK: - Provider names

func provider(named raw: String) -> LLMProvider? {
    switch raw.lowercased() {
    case "claude":                 return .claude
    case "gpt", "openai":          return .openAI
    case "gemini":                 return .gemini
    case "deepseek":               return .deepSeek
    case "grok":                   return .grok
    case "mistral":                return .mistral
    case "perplexity", "sonar":    return .perplexity
    case "openrouter":             return .openRouter
    case "ollama":                 return .ollama
    case "apple", "foundationmodels", "on-device": return .foundationModels
    case "custom1":                return .custom1
    case "custom2":                return .custom2
    default:                       return nil
    }
}

// MARK: - How each answer and stage ended
// `r` is always the round this run asked (the store's viewed round).

/// The name the CLI prints a seat under and keys its JSON by: the provider recorded with the
/// answer, else the seat's current one. Two seats on one provider would share that name and
/// overwrite each other as JSON keys, so a collision among the round's seats gets "(1)"/"(2)"
/// in seat order, the same suffix the engine uses.
@MainActor
func advisorName(_ store: CouncilStore, _ r: Round?, _ seatID: Int) -> String {
    func base(_ id: Int) -> String {
        r?.answerProviders[id] ?? store.seats.first { $0.id == id }?.provider?.panelName ?? "Advisor"
    }
    let name = base(seatID)
    // The round's seats: those that answered or were asked (a status); with no round, every seat.
    let members = store.seats.map(\.id).filter { id in
        guard let r else { return true }
        return r.answers[id] != nil || r.answerStatuses[id] != nil
    }
    let same = members.filter { base($0) == name }
    guard same.count > 1, let n = same.firstIndex(of: seatID) else { return name }
    return "\(name) (\(n + 1))"
}

/// The dim tag after an advisor's name when its answer ended early ("" for a whole answer): the
/// same short label the exports and the memo use. Plain text under NO_COLOR or off a terminal.
func statusTag(_ label: String?, color: Bool = Style.on) -> String {
    label.map { " " + Style.dim("(\($0))", color: color) } ?? ""
}

/// One stderr note per answer that ended early, so a CI log shows it and not only the dim tag:
/// why it is incomplete, and whether it deliberates (by default it sits out).
@MainActor
func incompleteAnswerNotes(_ store: CouncilStore, _ r: Round) -> [String] {
    let deliberating = store.viewedParticipantIDs
    return store.seats.compactMap { seat in
        guard r.incompleteSeatIDs.contains(seat.id), let label = r.statusLabel(seat.id) else { return nil }
        let fix = r.answerStatuses[seat.id] == .truncated ? " — raise this seat's max tokens" : ""
        let part = deliberating.contains(seat.id)
            ? "--deliberate kept it in peer review, divergence and synthesis"
            : "it sits out of peer review, divergence and synthesis (--deliberate brings it back)"
        return "\(advisorName(store, r, seat.id))'s answer is \(label)\(fix); \(part)"
    }
}

/// Why this run can't deliberate, or nil when it can: fewer than two positions, or fewer than two
/// FINISHED ones once the answers that ended early sat out (the engine's own predicate decides).
@MainActor
func deliberationSkipReason(_ store: CouncilStore, _ r: Round) -> String? {
    guard !store.canPeerReview else { return nil }
    let positions = store.viewedParticipantIDs
    let satOut = r.incompleteSeatIDs.subtracting(positions)
    guard !satOut.isEmpty, positions.count + satOut.count >= 2 else {
        return "only one advisor answered — peer review / divergence / synthesis need ≥2"
    }
    return "fewer than 2 finished answers — peer review / divergence / synthesis need ≥2"
        + " (the incomplete \(satOut.count == 1 ? "one" : "ones") sat out; --deliberate brings \(satOut.count == 1 ? "it" : "them") back)"
}

/// The seat a --deliberate name means: the name this run prints for it ("ollama (2)"), or a
/// provider name, which takes that provider's seats in order, so a second "ollama" is the second
/// Ollama seat. nil when the lineup has no such seat. (Without this a provider seated twice could
/// only ever name its first seat, and a cut-off second one had no way back in.)
@MainActor
func deliberateSeat(_ store: CouncilStore, _ r: Round?, named raw: String, taken: Set<Int>) -> Seat? {
    let wanted = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if let printed = store.seats.first(where: { $0.provider != nil && advisorName(store, r, $0.id).lowercased() == wanted }) {
        return printed
    }
    guard let p = provider(named: wanted) else { return nil }
    let seats = store.seats.filter { $0.provider == p }
    return seats.first { !taken.contains($0.id) } ?? seats.first
}

/// Applies --deliberate's choice to this run's round and says whether it took. Fewer than two
/// names never does, as in 1.3.1: the engine also takes a single answer that grows a smaller
/// selection (the app's way back, one chip at a time), but one position can't deliberate, so the
/// CLI would report a selection that runs nothing.
@MainActor
func applyDeliberateSelection(_ store: CouncilStore, _ ids: Set<Int>) -> Bool {
    guard ids.count >= 2 else { return false }
    store.setDeliberationSelection(ids, forRound: store.viewingRound)
    let r = store.rounds.indices.contains(store.viewingRound) ? store.rounds[store.viewingRound] : nil
    return r?.includedSeatIDs.map(Set.init) == ids
}

/// How one stage of this run's deliberation ended, for its stderr notes and the JSON `stages` key.
struct StageOutcome {
    /// The JSON key: peerReview, rebuttal, divergence, verdict, synthesis or chair.
    let key: String
    /// How a stderr note names the stage.
    let title: String
    /// complete · partial (some calls finished, some didn't) · failed (nothing kept) · skipped (didn't run).
    let status: String
    /// One line each: the engine's line for a call that didn't finish, or why the stage didn't run.
    let notes: [String]
}

/// Every stage, in pipeline order. Unfinished stage output is never kept, so a stage either kept
/// what finished or nothing. `skipped` is `deliberationSkipReason` (nil when the run deliberated).
/// The CLI never runs the debate, so `rebuttal` is skipped unless a library caller ran it.
/// `chair` is the chair moderating divergence and synthesis: skipped when there is none.
@MainActor
func stageOutcomes(_ store: CouncilStore, _ r: Round, skipped reason: String?) -> [StageOutcome] {
    func lines(_ error: String?) -> [String] { (error ?? "").split(separator: "\n").map(String.init) }
    /// A stage of one or more calls: complete when nothing is reported, else partial or failed.
    func outcome(_ key: String, _ title: String, kept: Bool, _ error: String?) -> StageOutcome {
        if let reason { return StageOutcome(key: key, title: title, status: "skipped", notes: [reason]) }
        let notes = lines(error)
        if notes.isEmpty, kept { return StageOutcome(key: key, title: title, status: "complete", notes: []) }
        return StageOutcome(key: key, title: title, status: kept ? "partial" : "failed",
                            notes: notes.isEmpty ? ["nothing came back"] : notes)
    }
    let reviewed = r.peerReviews.values.contains { !$0.isEmpty }
    let rebutted = r.rebuttals.values.contains { !$0.isEmpty }
    let mapped = r.divergence != nil, synthesized = r.synthesis != nil

    let verdict: StageOutcome
    if let reason {
        verdict = StageOutcome(key: "verdict", title: "divergence verdict", status: "skipped", notes: [reason])
    } else if !mapped {
        verdict = StageOutcome(key: "verdict", title: "divergence verdict", status: "skipped",
                               notes: ["there was no divergence map to judge"])
    } else {
        verdict = r.divergenceScore != nil
            ? StageOutcome(key: "verdict", title: "divergence verdict", status: "complete", notes: [])
            : StageOutcome(key: "verdict", title: "divergence verdict", status: "failed",
                           notes: ["no verdict came back, or it couldn't be read"])
    }

    let chair: StageOutcome
    if reason != nil || !store.isChairActive {
        chair = StageOutcome(key: "chair", title: "chair", status: "skipped", notes: [])
    } else if let note = store.chairFallbackNote {
        chair = StageOutcome(key: "chair", title: "chair", status: "failed", notes: [note])
    } else {
        // Nothing records who wrote a stage, but a chair that ran and finished leaves it kept.
        let missing = [mapped ? nil : "divergence", synthesized ? nil : "synthesis"].compactMap { $0 }
        chair = missing.isEmpty
            ? StageOutcome(key: "chair", title: "chair", status: "complete", notes: [])
            : StageOutcome(key: "chair", title: "chair", status: missing.count == 2 ? "failed" : "partial",
                           notes: ["\(store.chairName ?? "The chair") didn't write the \(missing.joined(separator: " or the "))"
                                   + " — see \(missing.count == 1 ? "that stage's" : "those stages'") note"])
    }

    return [
        outcome("peerReview", "peer review", kept: reviewed, store.peerReviewError),
        rebutted || store.rebuttalError != nil
            ? outcome("rebuttal", "debate", kept: rebutted, store.rebuttalError)
            : StageOutcome(key: "rebuttal", title: "debate", status: "skipped", notes: []),
        outcome("divergence", "divergence", kept: mapped, store.divergenceError),
        verdict,
        outcome("synthesis", "synthesis", kept: synthesized, store.synthesisError),
        chair,
    ]
}

/// The stderr notes for the stages that failed or only partly finished, each named.
func stageNotes(_ outcomes: [StageOutcome]) -> [String] {
    outcomes.filter { $0.status == "failed" || $0.status == "partial" }
        .flatMap { s in s.notes.map { "\(s.title): \($0)" } }
}

/// How --fail-above counted the answers that ended early (nil when none did): an incomplete answer
/// sits out of the divergence by default, so the gate counts it only when --deliberate named it.
@MainActor
func failAboveNote(_ store: CouncilStore, _ r: Round) -> String? {
    let incomplete = r.incompleteSeatIDs
    guard !incomplete.isEmpty else { return nil }
    let deliberating = store.viewedParticipantIDs
    func answers(_ ids: Set<Int>) -> String {
        "the incomplete answer\(ids.count == 1 ? "" : "s") from "
            + ids.sorted().map { advisorName(store, r, $0) }.joined(separator: ", ")
    }
    let left = incomplete.subtracting(deliberating), kept = incomplete.intersection(deliberating)
    var parts: [String] = []
    if !left.isEmpty { parts.append("leaves out \(answers(left))") }
    if !kept.isEmpty { parts.append("counts \(answers(kept)) (--deliberate)") }
    return "--fail-above gates on a divergence that " + parts.joined(separator: " and ")
}

/// The --json payload, schema council.cli.v1. Keys are only ever added to it, never renamed,
/// removed or retyped, so a script written against an older CLI keeps working. Added in 1.3.2:
/// each seats[] entry's `status` and `recordedModel` (the model id recorded with the answer; "" for
/// the guest); `answerStatus` (every name in `answers`, plus each advisor that was asked and kept
/// no answer → how it ended); `stages` (each stage's status and notes, see `StageOutcome`); and the
/// dissent's `status`. Answer statuses are the engine's: complete, truncated, stalled, cancelled, failed.
@MainActor
func resultJSON(_ store: CouncilStore, _ r: Round, stages: [StageOutcome],
                started: String, finished: String) -> [String: Any] {
    func name(_ seatID: Int) -> String { advisorName(store, r, seatID) }
    // A seat with no recorded status (a round saved before 1.3.2) counts as complete.
    func status(_ seatID: Int) -> String { (r.answerStatuses[seatID] ?? .complete).rawValue }
    var seatsArr: [[String: Any]] = []
    var answers: [String: String] = [:], reviews: [String: String] = [:], rebuttals: [String: String] = [:]
    var answerStatus: [String: String] = [:]
    for seat in store.seats {
        if let a = r.answers[seat.id], !a.isEmpty {
            seatsArr.append(["name": name(seat.id), "provider": seat.provider?.rawValue ?? "", "model": seat.model,
                             "status": status(seat.id), "recordedModel": r.answerModels[seat.id] ?? ""])
            answers[name(seat.id)] = a
            answerStatus[name(seat.id)] = status(seat.id)
        } else if r.answerStatuses[seat.id] != nil {
            answerStatus[name(seat.id)] = status(seat.id)   // asked, but kept no answer
        }
        if let rv = r.peerReviews[seat.id], !rv.isEmpty { reviews[name(seat.id)] = rv }
        if let rb = r.rebuttals[seat.id], !rb.isEmpty { rebuttals[name(seat.id)] = rb }
    }
    var guestKey = r.guestName
    if let g = r.guestAnswer {
        // A guest named after a real seat would collide as a dictionary key — disambiguate. A seat
        // that kept no answer still holds its name in answerStatus, and must keep it.
        let taken = answers[r.guestName] != nil || answerStatus[r.guestName] != nil
        let gname = taken ? "\(r.guestName) (guest)" : r.guestName
        guestKey = gname
        let pasted = AnswerStatus.complete.rawValue   // the user's own text: nothing to cut off
        seatsArr.append(["name": gname, "provider": "guest", "model": "", "status": pasted, "recordedModel": ""])
        answers[gname] = g
        answerStatus[gname] = pasted
    }
    /// The key a participant's answer sits under in this JSON, the guest included.
    func key(_ seatID: Int) -> String { seatID == Round.guestSeatID ? guestKey : name(seatID) }
    // The outlier under the same name as its answer's key. The engine names only the answers that
    // deliberated, so with two seats on one provider and one of them sitting out, its plain
    // "Claude" would match no key here (or, with three, the wrong one).
    let outlierName = r.outlier.map { engineName in r.outlierSeatID.map(key) ?? engineName }
    var obj: [String: Any] = [
        "schemaVersion": "council.cli.v1",
        // The round's question, not the raw arg: on the document-only path opts.question is empty
        // while the round ran with the engine-synthesized "Analyze the attached document."
        "question": r.question,
        "startedAt": started, "finishedAt": finished,
        "seats": seatsArr, "answers": answers,
        "peerReviews": reviews, "rebuttals": rebuttals,
        "answerStatus": answerStatus,
        "stages": Dictionary(uniqueKeysWithValues: stages.map {
            ($0.key, ["status": $0.status, "notes": $0.notes] as [String: Any])
        }),
    ]
    if let agreement = r.divergenceScore {
        var d: [String: Any] = ["agreement": agreement, "displayedDivergence": 100 - agreement]
        if let c = r.divergenceCamps { d["camps"] = c }
        if let o = outlierName { d["outlier"] = o }
        if let n = r.divergence { d["narrative"] = n }
        obj["divergence"] = d
    }
    if let s = r.synthesis { obj["synthesis"] = s }
    if let o = outlierName, let a = store.outlierAnswer {
        obj["dissent"] = ["name": o, "answer": a, "status": store.dissentSeatID.map(status) ?? AnswerStatus.complete.rawValue]
    }
    if let inc = r.includedSeatIDs {
        obj["deliberatedSeats"] = inc.sorted().map(key)
    }
    // Report the chair only when it actually authored something — a configured chair that
    // couldn't run must not appear in machine output as if it had chaired.
    if store.chairFallbackNote == nil, store.isChairActive, let cn = store.chairName { obj["chair"] = cn }
    if let note = store.chairFallbackNote { obj["chairFallback"] = note }
    if let c = r.chairSummary { obj["chairSummary"] = c }
    return obj
}

/// The exact text --json prints.
func jsonText(_ obj: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}

// MARK: - keys set

@MainActor
func keysSet(_ name: String) {
    guard let p = provider(named: name) else { die("unknown provider '\(name)'", code: 64) }
    guard p.requiresAPIKey else { die("\(p.displayName) needs no API key") }
    guard let raw = getpass("API key for \(p.displayName): ") else { die("no input") }
    let key = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { die("empty key") }
    do { try KeychainStore.save(key, account: p.keychainAccount) }
    catch KeychainStore.KeychainError.staleItem {
        // An updated build owns the old item name — hop to the next keychain generation
        // (carrying every still-readable key) and retry once. Same path the app takes.
        let all = LLMProvider.allCases.filter(\.requiresAPIKey).map(\.keychainAccount)
        _ = KeychainStore.migrateToNextGeneration(accounts: all)
        do { try KeychainStore.save(key, account: p.keychainAccount) }
        catch { die("Keychain save failed: \(error)") }
    }
    catch { die("Keychain save failed: \(error)") }
    print("saved to Keychain (account \(p.keychainAccount)) — shared with the Council app")
    exit(0)
}

// MARK: - Pipeline

/// The run's store. It never reads the app's saved history: a CLI run has no use for it, and
/// reading meant decoding every session in another app's container. A run that saves writes
/// exactly one file, its own new session (a fresh id), into that history. Nothing here rewrites,
/// renames or deletes another session file, and the app decodes each file on its own, so a file
/// it can't read is skipped, never lost. (Before 1.3.2 a run refused to save when no existing file
/// decoded. That check needed the whole history loaded, so it is gone with the read.)
@MainActor
func cliStore(saving: Bool) -> CouncilStore {
    let store = CouncilStore(loadHistory: false)
    store.persistenceEnabled = saving
    store.newSession()
    return store
}

@MainActor
func run(_ opts: Options) async {
    if opts.allowEnvKeys {
        KeychainStore.allowEnvOverride = true
        errPrint("warning: --allow-env-keys is on — COUNCIL_KEY_* env vars may supply API keys (CI mode)")
    }

    let store = cliStore(saving: !opts.noSave)

    // Every exit from here on goes through these two. saveConversation only QUEUES the session's
    // disk write (debounced, then off-thread), so a bare exit() right after the last stage used to
    // drop peer review, divergence and synthesis from the history the app shows.
    func finish(_ code: Int32) -> Never { store.flushPendingWrite(); exit(code) }
    func fail(_ msg: String, code: Int32 = 2) -> Never { store.flushPendingWrite(); die(msg, code: code) }

    // Lineup: --config > --seats > the CLI's own last lineup.
    // An explicit CLI lineup is TRANSIENT: apply it for THIS run, but don't let setProvider/applyConfig
    // persist it as the CLI's new default lineup/prompt (a one-off `--seats` shouldn't silently rewrite
    // future runs). We drop persistence only around the lineup mutation, then restore it so the SESSION
    // still saves to history.
    if let path = opts.configPath {
        guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath),
              let config = try? JSONDecoder().decode(CouncilConfig.self, from: data)
        else { fail("couldn't read council config at \(path)") }
        let wasPersistent = store.persistenceEnabled
        store.persistenceEnabled = false
        store.applyConfig(config)
        store.persistenceEnabled = wasPersistent
    } else if !opts.seatNames.isEmpty {
        guard opts.seatNames.count <= store.seats.count else { fail("at most \(store.seats.count) seats", code: 64) }
        let wasPersistent = store.persistenceEnabled
        store.persistenceEnabled = false
        for (i, seat) in store.seats.enumerated() {
            if i < opts.seatNames.count {
                guard let p = provider(named: opts.seatNames[i]) else { fail("unknown provider '\(opts.seatNames[i])'", code: 64) }
                store.setProvider(p, seatID: seat.id)
            } else {
                store.clearProvider(seatID: seat.id)
            }
        }
        store.persistenceEnabled = wasPersistent
    }

    // --chair is TRANSIENT, like --seats: moderate this run without persisting as the app's chair.
    if let cname = opts.chairName {
        guard let p = provider(named: cname) else { fail("unknown provider '\(cname)' for --chair", code: 64) }
        let wasPersistent = store.persistenceEnabled
        store.persistenceEnabled = false
        store.setChair(p)
        store.persistenceEnabled = wasPersistent
        if !store.isChairActive {
            errPrint("warning: \(p.displayName) (chair) has no API key — an advisor will synthesize instead")
        }
    }

    let connected = store.seats.filter { store.hasKey($0) }
    guard !connected.isEmpty else {
        fail("no seats configured — use --seats claude,gpt,gemini or --config lineup.council\n       (cloud providers also need: council keys set <provider>)", code: 64)
    }
    for seat in store.seats where seat.provider != nil && !store.hasKey(seat) {
        errPrint("warning: \(seat.provider!.displayName) has no API key (council keys set …) — seat skipped")
    }

    // Attached document: --file wins, else stdin when piped. Folded into every seat's prompt by
    // the engine — NOT appended to the question here, so the saved history stays clean. All --file
    // failure modes share the runtime exit code so a CI script sees one code for "bad input file".
    var document: String?
    if let path = opts.filePath {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            fail("can't read --file \(path)")
        }
        let doc = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !doc.isEmpty else { fail("--file \(path) is empty") }
        if let err = CouncilLimits.documentError(doc) { fail(err) }
        document = doc
        errPrint(Style.dim("attached \(doc.count)-char document from \(path)"))
    } else if isatty(0) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let doc = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !doc.isEmpty {
            if let err = CouncilLimits.documentError(doc) { fail(err) }
            document = doc
            errPrint(Style.dim("attached \(doc.count)-char document from stdin"))
        }
    }
    // A pasted guest answer joins the round as one more anonymous position in blind review.
    var guest: GuestAnswer?
    if let path = opts.guestPath {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            fail("can't read --guest \(path)")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { fail("--guest \(path) is empty") }
        if let err = CouncilLimits.guestError(text) { fail(err) }
        guest = GuestAnswer(name: opts.guestName, text: text)
        errPrint(Style.dim("guest answer: \(text.count) chars — joins blind review anonymously"))
    } else if opts.guestName != nil {
        fail("--guest-name needs --guest <path>", code: 64)
    }

    // A document alone is a valid run — the engine synthesizes "Analyze the attached document."
    let question = opts.question
    guard !question.isEmpty || document != nil else { fail("no question given (see --help)", code: 64) }

    let payloadMode = opts.json || opts.md          // keep stdout clean for machine output
    func stage(_ s: String) { errPrint(Style.dim("· \(s)…")) }
    func emit(_ s: String)  { if !payloadMode && !opts.quiet { print(s) } }

    let started = ISO8601DateFormatter().string(from: Date())

    // 1 — answers
    stage("answers (\(connected.count) seats)")
    await store.ask(question, document: document, guest: guest)
    let round = { () -> Round? in store.rounds.indices.contains(store.viewingRound) ? store.rounds[store.viewingRound] : nil }
    // The guest sentinel is the USER's own pasted text, not an advisor answering: it must never
    // make a round where every advisor failed look like a successful run (exit 0, guest echoed
    // back as "the result"). Same predicate the engine's hasSession uses.
    guard let r0 = round(), !r0.answeredSeatIDs.subtracting([Round.guestSeatID]).isEmpty else {
        let errs = store.seats.compactMap { seat -> String? in
            if case .failed(let m) = store.status[seat.id] ?? .idle { return "\(seat.provider?.panelName ?? "seat"): \(m)" }
            return nil
        }
        fail("no advisor answered" + (errs.isEmpty ? "" : "\n       " + errs.joined(separator: "\n       ")))
    }
    func name(_ seatID: Int) -> String { advisorName(store, round(), seatID) }
    if !payloadMode && !opts.quiet {
        print(Style.bold("ANSWERS"))
        for seat in store.seats {
            guard let a = round()?.answers[seat.id], !a.isEmpty else {
                if case .failed(let m) = store.status[seat.id] ?? .idle { print("  \(name(seat.id)): ✗ \(m)") }
                continue
            }
            let flat = a.replacingOccurrences(of: "\n", with: " ")
            let tag = statusTag(round()?.statusLabel(seat.id))
            print("  \(Style.bold(name(seat.id)))\(tag): \(flat.count > 220 ? String(flat.prefix(220)) + "…" : flat)")
        }
        if let g = round()?.guestAnswer {
            let flat = g.replacingOccurrences(of: "\n", with: " ")
            print("  \(Style.bold(round()?.guestName ?? "Guest")) (guest): \(flat.count > 220 ? String(flat.prefix(220)) + "…" : flat)")
        }
        print("")
    }

    // --deliberate: restrict which answers enter the pipeline (engine validates ≥2 + answered).
    if let names = opts.deliberateNames {
        var ids = Set<Int>()
        for n in names {
            if n == "guest" {
                guard round()?.guestAnswer != nil else { fail("--deliberate names 'guest' but no --guest was given", code: 64) }
                ids.insert(Round.guestSeatID)
            } else if let seat = deliberateSeat(store, round(), named: n, taken: ids) {
                ids.insert(seat.id)
            } else {
                fail("--deliberate: '\(n)' is not in the lineup", code: 64)
            }
        }
        // Compared with what was asked for: an answer that ended early already set a selection.
        if !applyDeliberateSelection(store, ids) {
            let over = round()?.includedSeatIDs == nil ? "everyone" : "every answer that finished"
            errPrint("warning: --deliberate not applied (needs ≥2 answered participants) — deliberating over \(over)")
        } else {
            // The seats that were taken, by the names this run prints them under.
            let applied = ids.sorted().map { $0 == Round.guestSeatID ? "guest" : name($0) }
            errPrint(Style.dim("deliberating over: \(applied.joined(separator: ", "))"))
        }
    }

    // An answer that ended early is kept, tagged, and sits out of deliberation by default: say so
    // where a CI log shows it, not only in the dim tag.
    for note in round().map({ incompleteAnswerNotes(store, $0) }) ?? [] { errPrint("note: \(note)") }

    // ≥2 positions AND at least one real advisor to do the reviewing (a guest can't review): the
    // engine's own predicate, so an answer sitting out isn't counted as a position.
    let skipReason = round().flatMap { deliberationSkipReason(store, $0) }
    let canDeliberate = skipReason == nil
    func stages() -> [StageOutcome] { round().map { stageOutcomes(store, $0, skipped: skipReason) } ?? [] }
    /// One stderr note per failed or partial stage among `keys`, right after it ran.
    func noteStages(_ keys: String...) {
        for line in stageNotes(stages().filter { keys.contains($0.key) }) { errPrint("note: \(line)") }
    }

    // 2 — peer review
    if canDeliberate {
        stage("peer review")
        await store.peerReview()
        if !payloadMode && !opts.quiet {
            if opts.verbose {
                print(Style.bold("PEER REVIEW"))
                for seat in store.seats {
                    if let rv = store.viewedPeerReview(seat.id), !rv.isEmpty {
                        print("  \(Style.bold(name(seat.id))):\n\(rv)\n")
                    }
                }
            } else {
                let review = stages().first { $0.key == "peerReview" }?.status
                print(Style.dim(review == "failed" ? "PEER REVIEW didn't finish — nothing was kept (see the notes)."
                    : review == "partial" ? "PEER REVIEW partly done (see the notes) — rerun with -v for the reviews that finished."
                    : "PEER REVIEW done — rerun with -v for the full critiques.") + "\n")
            }
        }
        noteStages("peerReview")

        // 3 — divergence (+ judge verdict)
        stage("divergence")
        await store.runDivergence()
        noteStages("divergence", "verdict")
        if let agreement = store.agreementScore {
            let displayed = 100 - agreement
            var line = "DIVERGENCE: \(displayed)/100"
            if let c = store.divergenceCamps { line += " · \(c) camp\(c == 1 ? "" : "s")" }
            if let o = store.outlierName { line += " · outlier: \(o)" }
            emit(Style.bold(line))
            emit(Style.dim("  (measures agreement, not correctness)") + "\n")
        } else {
            emit(Style.dim("DIVERGENCE: verdict unavailable for this run") + "\n")
        }

        // 4 — synthesis. --quiet prints it ONCE, bare, at the end (see the quiet block below):
        // this header + body is the normal-output copy, and printing it here too made `--quiet`
        // emit a "SYNTHESIS" header and the whole text twice.
        stage("synthesis")
        await store.runSynthesis()
        if let s = store.synthesisText, !payloadMode, !opts.quiet {
            print(Style.bold("SYNTHESIS"))
            print(s + "\n")
        }
        // The chair is optional and can fail; the run must say who actually wrote the analysis.
        noteStages("synthesis", "chair")

        // 5 — dissent
        if let outlier = store.outlierName, let answer = store.outlierAnswer, !payloadMode, !opts.quiet {
            let tag = statusTag(store.dissentSeatID.flatMap { round()?.statusLabel($0) })
            print(Style.bold("DISSENT — \(outlier) stood apart") + tag)
            let flat = answer.replacingOccurrences(of: "\n", with: " ")
            print("  " + (flat.count > 400 ? String(flat.prefix(400)) + "…" : flat) + "\n")
        }
        if opts.verbose, store.hasRebuttalForViewedRound, !payloadMode {
            print(Style.bold("REBUTTALS"))
            for seat in store.seats {
                if let rb = store.viewedRebuttal(seat.id) { print("  \(Style.bold(name(seat.id))):\n\(rb)\n") }
            }
        }
    } else if let skipReason {
        errPrint("note: \(skipReason)")
    }

    let finished = ISO8601DateFormatter().string(from: Date())

    // Machine outputs
    if opts.md {
        let memo = store.exportDecisionMemo()
        if let out = opts.mdOut {
            do { try memo.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8) }
            catch { fail("couldn't write \(out): \(error.localizedDescription)") }
            errPrint("wrote \(out)")
        } else {
            print(memo)
        }
    }
    if opts.json, let r = round() {
        print(jsonText(resultJSON(store, r, stages: stages(), started: started, finished: finished)))
    }
    if opts.quiet && !payloadMode, let s = store.synthesisText {
        print(s)
    }

    // CI gate — distinct from runtime errors: missing verdict is a runtime error (can't gate on it).
    if let gate = opts.failAbove {
        if let note = round().flatMap({ failAboveNote(store, $0) }) { errPrint("note: \(note)") }
        guard let agreement = store.agreementScore else { fail("--fail-above set but no divergence verdict was produced") }
        let displayed = 100 - agreement
        if displayed > gate {
            errPrint("divergence \(displayed) exceeds gate \(gate) — failing")
            finish(1)
        }
        errPrint(Style.dim("divergence \(displayed) within gate \(gate)"))
    }
    finish(0)
}

// MARK: - Entry

@main
struct CouncilCLI {
    static func main() async {
        var argv = Array(CommandLine.arguments.dropFirst())
        if argv.first == "keys" {
            guard argv.count >= 3, argv[1] == "set" else { die("usage: council keys set <provider>", code: 64) }
            await MainActor.run { keysSet(argv[2]) }
            return
        }
        let opts = parseArgs(argv)
        await run(opts)
    }
}
