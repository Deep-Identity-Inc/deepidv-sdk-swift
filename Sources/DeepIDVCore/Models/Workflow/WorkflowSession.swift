// DeepIDVCore › Models › Workflow

import Foundation

/// Create-session response (`POST /v1/workflows/{workflow_id}/sessions`,).
public struct WorkflowSession: Sendable, Equatable, Decodable {
    public let sessionID: String
    /// ISO 8601 expiry, or `nil` when the session has no expiry.
    public let expiresAt: String?
    public let steps: [WorkflowStepPlan]
    /// Zero-based index into ``steps``. `nil` when the run is already finished
    /// (unusual on create).
    public let currentStep: Int?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case expiresAt = "expires_at"
        case steps
        case currentStep = "current_step"
    }

    public init(
        sessionID: String,
        expiresAt: String?,
        steps: [WorkflowStepPlan],
        currentStep: Int?
    ) {
        self.sessionID = sessionID
        self.expiresAt = expiresAt
        self.steps = steps
        self.currentStep = currentStep
    }
}

/// One planned step on a newly created session — identity, status, and
/// config-derived ``requirements`` (registry-decoded).
public struct WorkflowStepPlan: Sendable, Equatable, Decodable {
    public let stepID: WorkflowStepID
    public let status: WorkflowStepStatus
    public let requirements: StepRequirements

    enum CodingKeys: String, CodingKey {
        case stepID = "step_id"
        case status
        case requirements
    }

    public init(
        stepID: WorkflowStepID,
        status: WorkflowStepStatus,
        requirements: StepRequirements
    ) {
        self.stepID = stepID
        self.status = status
        self.requirements = requirements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stepID = try container.decode(WorkflowStepID.self, forKey: .stepID)
        self.stepID = stepID
        self.status = try container.decode(WorkflowStepStatus.self, forKey: .status)
        let requirementsDecoder = try container.superDecoder(forKey: .requirements)
        self.requirements = try WorkflowStepRegistry.decodeRequirements(
            stepID: stepID,
            from: requirementsDecoder
        )
    }
}
