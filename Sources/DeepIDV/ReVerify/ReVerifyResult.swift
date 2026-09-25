// DeepIDV › ReVerify

import Foundation

/// The business outcome of a re-verification run started with
/// ``DeepIDVClient/makeReVerifyView(workflowID:onResult:)``, delivered as the
/// `.success` side of its `onResult`.
///
/// Errors and user cancellation are the `.failure` side of that `Result`
/// (a ``DeepIDVError``), never a case here. The view renders nothing once
/// `onResult` fires: the host shows its own screen for every outcome.
public enum ReVerifyResult: Sendable, Equatable {
    /// The applicant's face matched exactly one identity with an approved
    /// session in your organization, under this workflow.
    ///
    /// - Parameters:
    ///   - reVerificationID: The re-verification this run created.
    ///   - originalSessionID: The approved session the applicant was
    ///     re-verified against.
    ///   - userID: The user that original session belongs to.
    case verified(reVerificationID: String, originalSessionID: String, userID: String)

    /// The run ended without re-verifying the applicant. Terminal: presenting
    /// the view again starts a new re-verification.
    case failed(reason: FailureReason)

    /// Why a run ended in ``ReVerifyResult/failed(reason:)``.
    public enum FailureReason: Sendable, Equatable {
        /// The applicant's face was recognised, but it can't be re-verified
        /// for this workflow in your organization. Retrying can't change who
        /// the face is, so this ends the run on the first occurrence.
        ///
        /// When this happens on the **last** allowed attempt it is reported as
        /// ``attemptsExhausted`` instead (see there).
        case notReVerified

        /// The attempt budget is spent. Usually nobody was recognised in any
        /// attempt.
        ///
        /// The server doesn't say why an attempt failed, only how many failed
        /// out of how many allowed. So a recognised-but-not-re-verifiable
        /// applicant whose outcome lands on the final allowed attempt (or on
        /// the only one, for a workflow that allows one attempt) is also
        /// reported here rather than as ``notReVerified``. Both are terminal.
        case attemptsExhausted

        /// Re-verification can't run for this workflow or API key. Never
        /// fixable by the applicant, so the view offers no retry.
        case notEligible(NotEligibleReason)

        /// The re-verification expired, or had already ended, before a
        /// decision was made. Present the view again to start a new one.
        case expired
    }

    /// Why re-verification can't run at all. Switch on it to choose your own
    /// copy — the SDK never shows server strings.
    public enum NotEligibleReason: Sendable, Equatable {
        /// The workflow doesn't exist for this API key's organization, or
        /// re-verification isn't available to the organization. The server
        /// answers both the same way on purpose.
        case notFound
        /// The workflow is inactive, or re-verification is switched off on it.
        case disabled
        /// The organization's balance can't cover the check.
        case insufficientBalance
        /// This API key can't use re-verification (for example, a sandbox key).
        case notAuthorized
    }
}
