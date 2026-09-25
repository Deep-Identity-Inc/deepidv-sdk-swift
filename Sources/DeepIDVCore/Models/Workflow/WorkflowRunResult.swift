// DeepIDVCore › Models › Workflow

import Foundation

/// The server-authoritative terminal state returned by a workflow run.
public struct WorkflowRunResult: Sendable, Equatable {
    /// One step's final status and attempt information.
    public struct StepOutcome: Sendable, Equatable {
        public let stepID: WorkflowStepID
        public let status: WorkflowStepStatus
        public let attempts: Int
        public let failureReason: String?

        public init(
            stepID: WorkflowStepID,
            status: WorkflowStepStatus,
            attempts: Int,
            failureReason: String?
        ) {
            self.stepID = stepID
            self.status = status
            self.attempts = attempts
            self.failureReason = failureReason
        }
    }

    public let sessionID: String
    public let sessionStatus: SessionStatus
    public let sessionProgress: SessionProgress
    public let steps: [StepOutcome]

    public init(
        sessionID: String,
        sessionStatus: SessionStatus,
        sessionProgress: SessionProgress,
        steps: [StepOutcome]
    ) {
        self.sessionID = sessionID
        self.sessionStatus = sessionStatus
        self.sessionProgress = sessionProgress
        self.steps = steps
    }

    /// Builds the public result from a final execution-state read.
    public init(state: WorkflowExecutionState) {
        self.init(
            sessionID: state.sessionID,
            sessionStatus: state.status,
            sessionProgress: state.sessionProgress,
            steps: state.steps.map {
                StepOutcome(
                    stepID: $0.stepID,
                    status: $0.status,
                    attempts: $0.attempts,
                    failureReason: $0.failureReason)
            })
    }
}
