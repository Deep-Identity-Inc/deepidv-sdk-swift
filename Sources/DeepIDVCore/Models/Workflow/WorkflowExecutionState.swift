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
    /// Why the run ended without reaching submission; `nil` otherwise.
    public let sessionFailure: WorkflowSessionFailure?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case sessionProgress = "session_progress"
        case steps
        case currentStep = "current_step"
        case attemptsRemaining = "attempts_remaining"
        case sessionFailure = "session_failure"
    }

    public init(
        sessionID: String,
        status: SessionStatus,
        sessionProgress: SessionProgress,
        steps: [WorkflowStepState],
        currentStep: Int?,
        attemptsRemaining: Int?,
        sessionFailure: WorkflowSessionFailure? = nil
    ) {
        self.sessionID = sessionID
        self.status = status
        self.sessionProgress = sessionProgress
        self.steps = steps
        self.currentStep = currentStep
        self.attemptsRemaining = attemptsRemaining
        self.sessionFailure = sessionFailure
    }

    /// Whether the session has no step left to run: it is finished, failed or
    /// expired.
    package var isTerminal: Bool {
        currentStep == nil
            || sessionProgress == .completed
            || status == .submitted
            || status == .failed
            || status == .completed
            || status == .expired
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
    /// Why the step's most recent attempt failed a check; `nil` when it has
    /// not failed.
    public let failure: WorkflowFailure?
    public let requirements: StepRequirements

    enum CodingKeys: String, CodingKey {
        case stepID = "step_id"
        case status
        case attempts
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case failure
        case requirements
    }

    public init(
        stepID: WorkflowStepID,
        status: WorkflowStepStatus,
        attempts: Int,
        startedAt: String?,
        completedAt: String?,
        failure: WorkflowFailure?,
        requirements: StepRequirements
    ) {
        self.stepID = stepID
        self.status = status
        self.attempts = attempts
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.failure = failure
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
        self.failure = try container.decodeIfPresent(WorkflowFailure.self, forKey: .failure)
        let requirementsDecoder = try container.superDecoder(forKey: .requirements)
        self.requirements = try WorkflowStepRegistry.decodeRequirements(
            stepID: stepID,
            from: requirementsDecoder
        )
    }
}
