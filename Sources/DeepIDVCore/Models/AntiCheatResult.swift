// DeepIDVCore › Models

/// The outcome of the iGaming anti-cheat face check
/// (`POST /v1/igaming/anti-cheat`) — face dedup + self-exclusion.
///
/// The endpoint is **fail-soft**: bad input, a terminal session, an
/// unconfigured `anti-cheat` workflow step, or an internal server error all
/// come back as `200 {verdict: "UNAVAILABLE", action: "allow"}` — a normal
/// success, never a thrown error. The only hard failure is
/// `404 "Session not found"` → `DeepIDVError.notFound`.
///
/// The response is deliberately redacted server-side (matched session,
/// similarity, and face id are persisted but not returned), so this maps 1:1
/// to the two-field wire body. Both enums decode tolerantly: an unrecognized
/// wire string folds into `.unknown(raw)` rather than failing the decode, so
/// new server verdicts/actions never break existing SDK builds.
public struct AntiCheatResult: Sendable, Equatable, Decodable {
    /// The dedup/self-exclusion verdict. Wire raw values are uppercase
    /// (`DUPLICATE` / `UNIQUE` / `UNAVAILABLE` / `SELF_EXCLUSION`).
    public enum Verdict: Sendable, Equatable {
        /// The face matches one already enrolled on another session.
        case duplicate
        /// First sighting — the face was enrolled by this call.
        case unique
        /// The check could not run (fail-soft path); treated as pass-through.
        case unavailable
        /// The face (or linked identity) is on the self-exclusion registry.
        case selfExclusion
        /// A wire value this SDK version doesn't know yet.
        case unknown(String)

        init(wire: String) {
            switch wire {
            case "DUPLICATE": self = .duplicate
            case "UNIQUE": self = .unique
            case "UNAVAILABLE": self = .unavailable
            case "SELF_EXCLUSION": self = .selfExclusion
            default: self = .unknown(wire)
            }
        }
    }

    /// The action the org's workflow policy chose for the verdict. Wire raw
    /// values are lowercase (`allow` / `flag` / `manual-review` / `block`).
    /// `block` means the server has already marked the session FAILED.
    public enum Action: Sendable, Equatable {
        case allow
        case flag
        case manualReview
        case block
        /// A wire value this SDK version doesn't know yet.
        case unknown(String)

        init(wire: String) {
            switch wire {
            case "allow": self = .allow
            case "flag": self = .flag
            case "manual-review": self = .manualReview
            case "block": self = .block
            default: self = .unknown(wire)
            }
        }
    }

    /// The dedup/self-exclusion verdict.
    public let verdict: Verdict
    /// The workflow policy's chosen action.
    public let action: Action

    /// Whether the face was recognized — a `duplicate` or `selfExclusion`
    /// verdict. The SDK reports; the host decides what to do (unless the
    /// action is `block`, which the server has already enforced).
    public var isDuplicate: Bool {
        verdict == .duplicate || verdict == .selfExclusion
    }

    /// Whether the policy action is `block` (the session is already FAILED
    /// server-side).
    public var isBlocked: Bool { action == .block }

    /// Memberwise initializer — `public` because the synthesized one is only
    /// `internal` (used by tests, previews, and hosts stubbing results).
    public init(verdict: Verdict, action: Action) {
        self.verdict = verdict
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case verdict
        case action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verdict = Verdict(wire: try container.decode(String.self, forKey: .verdict))
        action = Action(wire: try container.decode(String.self, forKey: .action))
    }
}
