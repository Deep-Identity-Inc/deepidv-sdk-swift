// DeepIDVCore › Services › Workflow › Steps

import Foundation

/// `ID_VERIFICATION` step definition — requirements decode plus typed submit.
package enum IDVerificationStep: WorkflowStepDefinition {
    package typealias Requirements = IDVerificationRequirements

    package static let stepID = WorkflowStepID.idVerification

    package static func requirements(from decoder: Decoder) throws -> StepRequirements {
        .idVerification(try IDVerificationRequirements(from: decoder))
    }
}

extension WorkflowService {
    /// Submits an `ID_VERIFICATION` step with document types and opaque upload keys.
    public func submitIDVerification(
        sessionID: String,
        submission: IDVerificationSubmission
    ) async throws -> StepSubmissionResult<EmptyStepPayload> {
        try await steps.submit(
            sessionID: sessionID,
            stepID: .idVerification,
            body: submission)
    }
}
