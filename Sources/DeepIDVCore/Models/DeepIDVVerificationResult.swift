// DeepIDVCore › Models

/// The aggregate outcome of the guided ``DeepIDVVerificationView`` flow — the
/// identity-verification result paired with the optional iGaming anti-cheat
/// result. `antiCheat` is `nil` when the flow ran without an
/// `igamingSessionID`.
///
/// Pure data: produced by the guided flow, but declared here in `DeepIDVCore`
/// alongside the other result models so it stays plain, camera-free, and
/// directly testable.
public struct DeepIDVVerificationResult: Sendable, Equatable {
    /// The `POST /v1/identity/verify` outcome (always present).
    public let identity: IdentityVerifyResult
    /// The iGaming anti-cheat outcome, or `nil` when the flow ran without an
    /// `igamingSessionID`. A duplicate/flagged verdict rides here for the host
    /// to act on — only `action == .block` ends the flow early (as
    /// `DeepIDVError.antiCheatBlocked`), because the server has already failed
    /// the session.
    public let antiCheat: AntiCheatResult?

    public init(
        identity: IdentityVerifyResult,
        antiCheat: AntiCheatResult? = nil
    ) {
        self.identity = identity
        self.antiCheat = antiCheat
    }
}
