// DeepIDVCore › Services › Workflow

import Foundation

/// One conformance per runnable step type — the template that keeps each
/// step's contract in one file. Mirrors open-api's `StepRegistryEntry`.
package protocol WorkflowStepDefinition {
    associatedtype Requirements: Decodable & Sendable & Equatable
    static var stepID: WorkflowStepID { get }
    /// Wraps this step's ``Requirements`` into the shared ``StepRequirements`` enum.
    static func requirements(from decoder: Decoder) throws -> StepRequirements
}

/// Core-layer registry: `step_id` → requirements decoder .
///
/// A registry miss yields ``StepRequirements/unsupported(stepID:)`` instead of
/// throwing, so a future server-side step type can never brick `fetchState` on
/// an old SDK. Known-type schema failures still throw via the entry closure.
package enum WorkflowStepRegistry {
    /// The single list that grows when a step type is added.
    static let entries: [WorkflowStepID: @Sendable (Decoder) throws -> StepRequirements] = [
        IDVerificationStep.stepID: IDVerificationStep.requirements,
        FaceLivenessWorkflowStep.stepID: FaceLivenessWorkflowStep.requirements,
    ]

    /// Decode `requirements` for `stepID`. Miss → `.unsupported` (never throws
    /// for unknowns). Known entries propagate decode errors.
    static func decodeRequirements(
        stepID: WorkflowStepID,
        from decoder: Decoder
    ) throws -> StepRequirements {
        guard let decode = entries[stepID] else {
            return .unsupported(stepID: stepID)
        }
        return try decode(decoder)
    }
}
