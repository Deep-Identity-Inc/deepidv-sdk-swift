// DeepIDVCore › Models › Workflow

import Foundation

/// Generic decode target for `POST /v1/sessions/{id}/steps/{step_id}`.
/// Envelope keys decode from the top-level container; ``payload`` decodes from
/// the **same** decoder — the server spreads step-specific keys (e.g. `"liveness"`)
/// at the top level rather than nesting them under a `payload` key.
public struct StepSubmissionResult<Payload: Decodable & Sendable & Equatable>:
    Sendable, Equatable, Decodable
{
    public let stepID: WorkflowStepID
    public let stepStatus: WorkflowStepStatus
    public let failureReason: String?
    /// Post-submission current step index; `nil` when the run is finished.
    public let currentStep: Int?
    /// Session-wide attempts remaining; `nil` = unlimited (WR-15).
    public let attemptsRemaining: Int?
    public let sessionStatus: SessionStatus
    public let sessionProgress: SessionProgress
    public let payload: Payload

    enum CodingKeys: String, CodingKey {
        case stepID = "step_id"
        case stepStatus = "step_status"
        case failureReason = "failure_reason"
        case currentStep = "current_step"
        case attemptsRemaining = "attempts_remaining"
        case sessionStatus = "session_status"
        case sessionProgress = "session_progress"
    }

    public init(
        stepID: WorkflowStepID,
        stepStatus: WorkflowStepStatus,
        failureReason: String?,
        currentStep: Int?,
        attemptsRemaining: Int?,
        sessionStatus: SessionStatus,
        sessionProgress: SessionProgress,
        payload: Payload
    ) {
        self.stepID = stepID
        self.stepStatus = stepStatus
        self.failureReason = failureReason
        self.currentStep = currentStep
        self.attemptsRemaining = attemptsRemaining
        self.sessionStatus = sessionStatus
        self.sessionProgress = sessionProgress
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stepID = try container.decode(WorkflowStepID.self, forKey: .stepID)
        self.stepStatus = try container.decode(WorkflowStepStatus.self, forKey: .stepStatus)
        self.failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        self.currentStep = try container.decodeIfPresent(Int.self, forKey: .currentStep)
        self.attemptsRemaining = try container.decodeIfPresent(Int.self, forKey: .attemptsRemaining)
        self.sessionStatus = try container.decode(SessionStatus.self, forKey: .sessionStatus)
        self.sessionProgress = try container.decode(SessionProgress.self, forKey: .sessionProgress)
        // Step-specific keys are spread at the top level — re-enter the same decoder.
        self.payload = try Payload(from: decoder)
    }
}

/// Empty payload for `ID_VERIFICATION` submissions (no step-specific keys).
public struct EmptyStepPayload: Sendable, Equatable, Decodable {
    public init() {}
}
