// DeepIDVCore › Models

/// The outcome of an iGaming IP eligibility check — shared by
/// `POST /v1/igaming/vpn-detection` and `POST /v1/igaming/ip-jurisdiction`
/// (the two endpoints return the same shape).
///
/// A workflow without the corresponding step short-circuits to
/// `{verdict: "UNAVAILABLE", action: "allow", evidence: {reason:
/// "step-not-configured"}}` with 200 — a success, not an error. `action` is
/// **not** enum-constrained in the API schema for these endpoints, so it stays
/// a raw string; `verdict` decodes tolerantly with an `.unknown(raw)`
/// fallback. `evidence` is free-form JSON — scalar values are stringified so
/// an unexpected value shape never fails the decode.
public struct IPCheckResult: Sendable, Equatable, Decodable {
    /// The check verdict. Wire raw values are uppercase
    /// (`HIT` / `CLEAR` / `UNAVAILABLE`).
    public enum Verdict: Sendable, Equatable {
        /// The IP tripped the check (VPN/proxy/Tor/datacenter, or an
        /// ineligible jurisdiction).
        case hit
        /// The IP passed.
        case clear
        /// The check could not run (unconfigured step, non-IPv4 input, …).
        case unavailable
        /// A wire value this SDK version doesn't know yet.
        case unknown(String)

        init(wire: String) {
            switch wire {
            case "HIT": self = .hit
            case "CLEAR": self = .clear
            case "UNAVAILABLE": self = .unavailable
            default: self = .unknown(wire)
            }
        }
    }

    /// Escalation directive attached when the workflow routes a hit to manual
    /// handling rather than an outright block.
    public struct Escalation: Sendable, Equatable, Decodable {
        /// The routing outcome (e.g. `"ESCALATE"`).
        public let decision: String
        /// What kind of escalation the workflow chose (e.g. `"step-up"`).
        public let type: String
        /// Human-readable cause (e.g. `"datacenter ip"`).
        public let reason: String

        public init(decision: String, type: String, reason: String) {
            self.decision = decision
            self.type = type
            self.reason = reason
        }
    }

    /// The check verdict.
    public let verdict: Verdict
    /// The workflow policy's chosen action (`"allow"`, `"block"`, …). Raw
    /// string — the schema doesn't constrain it on these endpoints.
    public let action: String
    /// Free-form supporting detail (country codes, provider names, reasons).
    /// Values are stringified from whatever JSON scalar the server sent;
    /// nested objects/arrays render as `"<unsupported>"`.
    public let evidence: [String: String]
    /// Present when the workflow escalates instead of blocking; `nil`
    /// otherwise.
    public let escalation: Escalation?

    /// Memberwise initializer — `public` because the synthesized one is only
    /// `internal` (used by tests, previews, and hosts stubbing results).
    public init(
        verdict: Verdict, action: String, evidence: [String: String],
        escalation: Escalation?
    ) {
        self.verdict = verdict
        self.action = action
        self.evidence = evidence
        self.escalation = escalation
    }

    enum CodingKeys: String, CodingKey {
        case verdict
        case action
        case evidence
        case escalation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verdict = Verdict(wire: try container.decode(String.self, forKey: .verdict))
        action = try container.decode(String.self, forKey: .action)
        let raw =
            try container
                .decodeIfPresent([String: StringifiedJSONValue].self, forKey: .evidence)
            ?? [:]
        evidence = raw.mapValues(\.stringValue)
        escalation = try container.decodeIfPresent(Escalation.self, forKey: .escalation)
    }
}

/// Decodes any JSON scalar into its string rendering (`true` → `"true"`,
/// `87` → `"87"`, `null` → `"null"`); nested containers fall back to
/// `"<unsupported>"`. Keeps the free-form `evidence` dictionary decodable no
/// matter what the server puts in it.
private struct StringifiedJSONValue: Decodable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string
        } else if let bool = try? container.decode(Bool.self) {
            stringValue = String(bool)
        } else if let int = try? container.decode(Int.self) {
            stringValue = String(int)
        } else if let double = try? container.decode(Double.self) {
            stringValue = String(double)
        } else if container.decodeNil() {
            stringValue = "null"
        } else {
            stringValue = "<unsupported>"
        }
    }
}
