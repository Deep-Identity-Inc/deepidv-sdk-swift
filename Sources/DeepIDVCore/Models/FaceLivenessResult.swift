// DeepIDVCore › Models

/// The outcome of a face-liveness check (the workflow step's `complete`
/// action, movement liveness, and re-verification).
///
/// Unlike ``DocumentScanResult`` / ``IdentityVerifyResult`` this maps **1:1** to
/// the result body `{ status, confidence?, passed }` — there are no SDK-injected
/// fields and no imagery (the server drops `ReferenceImage` / `AuditImages`), so
/// the type is directly `Decodable` with no wire-DTO split. All three keys
/// are single lowercase words that match the default `JSONDecoder` 1:1, so no
/// `CodingKeys` are needed.
///
/// A completed-but-not-live check is a **success** (`passed == false`), not an
/// error — the service / view layers surface it verbatim.
public struct FaceLivenessResult: Sendable, Equatable, Decodable {
    /// Normalized session status. The wire raw values are uppercase
    /// (`SUCCEEDED` / `IN_PROGRESS` / `FAILED`).
    public enum Status: String, Sendable, Equatable, Decodable {
        case succeeded = "SUCCEEDED"
        case inProgress = "IN_PROGRESS"
        case failed = "FAILED"
    }

    /// Normalized session status. Terminal when surfaced to callers
    /// (`.succeeded` / `.failed`).
    public let status: Status
    /// Liveness confidence on a **0–100** scale. `nil` until the session resolves
    /// (and may stay absent on `.failed`).
    public let confidence: Double?
    /// Server-computed pass flag: `status == .succeeded && confidence >= threshold`
    /// (threshold from the liveness step's server-side config). The SDK
    /// surfaces it verbatim — it does **not** recompute the rule.
    public let passed: Bool

    /// Memberwise initializer. `public` because the synthesized one is only
    /// `internal`, so without it a client could name the type but never build one
    /// (useful for tests and previews). Coexists with the synthesized
    /// `Decodable` `init(from:)`.
    public init(status: Status, confidence: Double?, passed: Bool) {
        self.status = status
        self.confidence = confidence
        self.passed = passed
    }
}
