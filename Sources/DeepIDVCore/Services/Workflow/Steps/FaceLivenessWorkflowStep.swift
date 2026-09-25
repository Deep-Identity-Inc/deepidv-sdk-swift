// DeepIDVCore › Services › Workflow › Steps

import Foundation

/// `FACE_LIVENESS` step definition — requirements decode. The step's
/// start/upload/complete operations live on ``CustomFaceLivenessService``.
package enum FaceLivenessWorkflowStep: WorkflowStepDefinition {
    package typealias Requirements = FaceLivenessRequirements

    package static let stepID = WorkflowStepID.faceLiveness

    package static func requirements(from decoder: Decoder) throws -> StepRequirements {
        .faceLiveness(try FaceLivenessRequirements(from: decoder))
    }
}
