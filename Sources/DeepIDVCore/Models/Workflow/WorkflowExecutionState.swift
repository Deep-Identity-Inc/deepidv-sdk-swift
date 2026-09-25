// DeepIDVCore › Models › Workflow

import Foundation

/// Execution-state response (`GET /v1/sessions/{session_id}/workflow`).
/// Read-only and safe to poll — the resync path after failures / conflicts.
public struct WorkflowExecutionState: Sendable, Equatable, Decodable {
    public let sessionID: String
    public let status: SessionStatus
    public let sessionProgress: SessionProgress
    public let steps: [WorkflowStepState]
    /// Zero-based index into ``steps``; `nil` when the run is finished.
    public let currentStep: Int?
    /// Session-wide attempt budget remaining; `nil` = unlimited.
    public let attemptsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case sessionProgress = "session_progress"
        case steps
        case currentStep = "current_step"
        case attemptsRemaining = "attempts_remaining"
    }

    public init(
        sessionID: String,
        status: SessionStatus,
        sessionProgress: SessionProgress,
        steps: [WorkflowStepState],
        currentStep: Int?,
        attemptsRemaining: Int?
    ) {
        self.sessionID = sessionID
        self.status = status
        self.sessionProgress = sessionProgress
        self.steps = steps
        self.currentStep = currentStep
        self.attemptsRemaining = attemptsRemaining
    }
}

/// Per-step execution state on a workflow session, including attempt counters
/// and config-derived ``requirements`` (always included so any step can render).
public struct WorkflowStepState: Sendable, Equatable, Decodable {
    public let stepID: WorkflowStepID
    public let status: WorkflowStepStatus
    public let attempts: Int
    public let startedAt: String?
    public let completedAt: String?
    public let failureReason: String?
    public let requirements: StepRequirements

    enum CodingKeys: String, CodingKey {
        case stepID = "step_id"
        case status
        case attempts
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case failureReason = "failure_reason"
        case requirements
    }

    public init(
        stepID: WorkflowStepID,
        status: WorkflowStepStatus,
        attempts: Int,
        startedAt: String?,
        completedAt: String?,
        failureReason: String?,
        requirements: StepRequirements
    ) {
        self.stepID = stepID
        self.status = status
        self.attempts = attempts
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.failureReason = failureReason
        self.requirements = requirements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stepID = try container.decode(WorkflowStepID.self, forKey: .stepID)
        self.stepID = stepID
        self.status = try container.decode(WorkflowStepStatus.self, forKey: .status)
        self.attempts = try container.decode(Int.self, forKey: .attempts)
        self.startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        self.completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        self.failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        let requirementsDecoder = try container.superDecoder(forKey: .requirements)
        self.requirements = try WorkflowStepRegistry.decodeRequirements(
            stepID: stepID,
            from: requirementsDecoder
        )
    }
}
