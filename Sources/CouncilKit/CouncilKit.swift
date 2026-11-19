//  CouncilKit.swift
//  Package-level identity for the engine: version + attribution. The app and the `council` CLI are
//  thin shells over this package, so they read their signature from here rather than hardcoding it.
//  Caseless-enum namespace, mirroring the `CouncilLimits` pattern (CouncilStore.swift).

import Foundation

/// Engine identity. Surfaced verbatim by the thin shells: the app's Settings footer and the CLI's
/// `--version` / `--help` banner.
public enum CouncilKit {
    /// Engine version, kept in step with the Council release line (app MARKETING_VERSION).
    public static let version = "1.3.2"

    /// Version of the text the engine sends to models: everything in `CouncilStore.promptCatalog`
    /// (the personas, the stage briefs and the request templates). Bumped with any change to that
    /// text, never with anything else, so outputs made with different prompts can be told apart.
    /// The tests pin a fingerprint for every version.
    /// - 1: the text 0.3.1 shipped.
    /// - 2: peer review reads the question, the seat's own persona and the round's kept document,
    ///   and says plainly when an attachment isn't in front of it.
    /// - 3: the synthesis no longer recommends an answer: it says what the council settled and who
    ///   agrees, then what the user still has to decide, then where they diverged.
    public static let promptVersion = 3

    /// Maintainer of CouncilKit and the Council app.
    public static let author = "Joseph"

    /// Short one-line signature for footers and version output.
    public static let signature = "Powered by CouncilKit"

    /// Full attribution line: signature + copyright.
    public static let attribution = "\(signature) · © 2026 \(author)"
}
