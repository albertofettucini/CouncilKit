import Foundation
import Security

/// Secure storage for API keys, backed by the macOS Keychain.
/// Keys are never written to disk in plaintext, to UserDefaults, or to the repo.
///
/// GENERATIONS — why item names carry a suffix:
/// Council ships ad-hoc signed (no Apple Developer cert — the project is pseudonymous), and macOS
/// pins file-keychain items to the CREATING build: for any non-Apple-issued signature the item's
/// partition ID is that build's cdhash, which changes every release. After a Sparkle update the
/// old items answer only to per-item login-password prompts, and empirically they can be neither
/// read (errSecAuthFailed), deleted (errSecInvalidOwnerEdit), nor re-created under the same name
/// (errSecDuplicateItem) — the old `save()` threw here, locking users out of re-entering keys.
/// A stable self-signed cert does NOT help (the partition gate ignores the designated requirement
/// for non-Apple-issued signatures). So items are namespaced by a generation counter stored in the
/// app's Application Support (shared with the CLI, which uses the same container): when a silent
/// probe finds the current generation unreadable, we bump the generation, carry every readable key
/// forward, and abandon the orphaned items in place (harmless cruft in Keychain Access).
public enum KeychainStore {
    private static let baseService = Bundle.main.bundleIdentifier ?? "com.joseph.Council"

    public enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        /// The item under this name belongs to a previous build's generation — it can't be read,
        /// deleted, or replaced. Callers should run `migrateToNextGeneration` and retry.
        case staleItem
    }

    // MARK: Generation (shared app+CLI via the app container, NOT UserDefaults — the CLI has its own defaults domain)

    private static var generationURL: URL? {
        let fm = FileManager.default
        // Mirror CouncilStore.sessionsFolderURL's container resolution (kept here nonisolated so the
        // Keychain layer never touches the MainActor): a non-sandboxed process (the CLI) targets the
        // app's container explicitly so both see the same generation.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
            let container = fm.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Containers/com.joseph.Council/Data/Library/Application Support/Council")
            if fm.fileExists(atPath: container.path) {
                let inContainer = container.appendingPathComponent("KeychainGeneration")
                // A CLI-first user has a generation file OUTSIDE the container; the day they install
                // the app, the container appears and this path would silently switch to "generation
                // 0" and lose their keys. Carry the legacy file across on first sight instead.
                if !fm.fileExists(atPath: inContainer.path),
                   let legacy = legacyGenerationURL, fm.fileExists(atPath: legacy.path) {
                    try? fm.copyItem(at: legacy, to: inContainer)
                }
                return inContainer
            }
        }
        return legacyGenerationURL
    }

    /// The non-container location (used by a CLI running before the app ever launched).
    private static var legacyGenerationURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("Council", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("KeychainGeneration")
    }

    /// Current keychain generation. 0 = the original, unsuffixed item names (every pre-1.2 install).
    static var generation: Int {
        guard let url = generationURL,
              let s = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func setGeneration(_ g: Int) {
        guard let url = generationURL else { return }
        try? "\(g)".write(to: url, atomically: true, encoding: .utf8)
    }

    /// The service name items are stored under. Generation 0 keeps the historical name so existing
    /// installs need no migration until a stale item is actually detected.
    private static var service: String {
        let g = generation
        return g == 0 ? baseService : "\(baseService).g\(g)"
    }

    // MARK: Silent probe + migration

    /// Turn OFF macOS's own Keychain dialogs for this process, for good.
    ///
    /// The APP calls this before its very first read. Every item the app can legitimately use is
    /// one it created itself, and those never prompt; a prompt therefore only ever means "a
    /// previous build's orphaned item" — for which the right UX is Council's own calm re-enter
    /// sheet, not a stack of system password dialogs the user can't make sense of. Suppressed,
    /// those reads return errSecAuthFailed instead, which is exactly what `staleAccounts` looks
    /// for. Writes/deletes of our own items don't need interaction either.
    ///
    /// The CLI deliberately does NOT call this: a fresh `council` binary reading the app's items
    /// legitimately needs the one-time "allow access" prompt — that's how the shared-Keychain
    /// story works there (and it's documented in `council --help`).
    public static func suppressSystemPrompts() {
        guard !isRunningTests else { return }
        SecKeychainSetUserInteractionAllowed(false)
    }

    /// Which of these accounts have an item that EXISTS but is unreadable by this build (a previous
    /// build's generation)? Interaction is disabled for the probe, so this NEVER shows a password
    /// dialog — a stale item reports errSecAuthFailed / errSecInteractionNotAllowed instead.
    public static func staleAccounts(_ accounts: [String]) -> [String] {
        if isRunningTests { return [] }
        SecKeychainSetUserInteractionAllowed(false)
        // Restore only for a process that allows prompts at all (the CLI); the app suppresses them
        // permanently via suppressSystemPrompts and must not have them switched back on here.
        defer { if Bundle.main.bundleIdentifier == nil { SecKeychainSetUserInteractionAllowed(true) } }
        var stale: [String] = []
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String:  true,
                kSecMatchLimit as String:  kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                stale.append(account)
            }
        }
        return stale
    }

    /// One-shot migration to a fresh generation. Probes every account; when at least one is stale,
    /// carries all still-readable keys into the next generation and returns the accounts that were
    /// lost (the user must re-enter those). Returns [] — and changes nothing — when nothing is stale.
    ///
    /// The generation counter is SHARED with the other process (app ↔ CLI), so "unreadable by me"
    /// must never be taken as "gone for everyone": a CLI binary that was simply never authorized
    /// for the app's items would otherwise bump the generation and strand keys the app could still
    /// read perfectly well. Where prompts are allowed (the CLI), each apparently-stale account is
    /// re-probed WITH interaction, so the user's one-time "allow" keeps the key alive.
    public static func migrateToNextGeneration(accounts: [String]) -> [String] {
        var stale = staleAccounts(accounts)
        guard !stale.isEmpty else { return [] }
        if Bundle.main.bundleIdentifier == nil {   // CLI: prompts are legitimate here
            SecKeychainSetUserInteractionAllowed(true)
            stale = stale.filter { ((try? keychainRead(account: $0)) ?? nil) == nil }
            guard !stale.isEmpty else { return [] }
        }
        // Read the readable keys BEFORE bumping (reads are generation-scoped via `service`).
        var carried: [String: String] = [:]
        for account in accounts where !stale.contains(account) {
            if let v = (try? keychainRead(account: account)) ?? nil { carried[account] = v }
        }
        setGeneration(generation + 1)
        for (account, v) in carried { try? save(v, account: account) }
        return stale
    }

    // MARK: Save / read / delete

    /// Save (or overwrite) a secret for the given account.
    public static func save(_ value: String, account: String) throws {
        if isRunningTests { return }   // tests must never write the real Keychain
        let data = Data(value.utf8)

        // Remove any existing item first, then add a fresh one (simpler than an update).
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    service,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status != errSecDuplicateItem else {
            // The delete silently failed because the surviving item belongs to a previous build's
            // generation (errSecInvalidOwnerEdit) — it can't be adopted either (SecItemUpdate from
            // this build leaves it readable only by the OLD build). Surface it as the specific
            // condition so the caller can migrate generations and retry, instead of dead-ending.
            throw KeychainError.staleItem
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// CI escape hatch (CLI `--allow-env-keys` only): lets COUNCIL_KEY_<PROVIDER> env vars
    /// override Keychain reads. NEVER enabled by default; the CLI prints a warning when it is.
    public static var allowEnvOverride = false

    /// Read the secret for the given account, or nil if none is stored.
    public static func read(account: String) throws -> String? {
        if allowEnvOverride,
           let suffix = account.split(separator: ".").last,
           let env = ProcessInfo.processInfo.environment["COUNCIL_KEY_\(suffix.uppercased())"],
           !env.isEmpty {
            return env
        }
        return try keychainRead(account: account)
    }

    /// True when running inside a test runner. Unit tests must NEVER touch the real Keychain: on a
    /// dev machine the app's items exist but the xctest binary isn't on their ACL, so a read blocks
    /// the whole (headless) suite on a login-password dialog. Tests supply keys via the env
    /// override; everything else behaves as "no item stored".
    private static let isRunningTests = NSClassFromString("XCTestCase") != nil

    private static func keychainRead(account: String) throws -> String? {
        if isRunningTests { return nil }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Delete the secret for the given account. Returns true if it is gone afterwards.
    @discardableResult
    public static func delete(account: String) -> Bool {
        if isRunningTests { return true }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
