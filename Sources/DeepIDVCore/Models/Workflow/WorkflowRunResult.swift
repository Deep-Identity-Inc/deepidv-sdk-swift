// DeepIDVCore › Models › Workflow

import Foundation

/// The server-authoritative terminal state returned by a workflow run.
public struct WorkflowRunResult: Sendable, Equatable {
    /// One step's final status and attempt information.
    public struct StepOutcome: Sendable, Equatable {
        public let stepID: WorkflowStepID
        public let status: WorkflowStepStatus
        public let attempts: Int
        /// Why the step's most recent attempt failed a check; `nil` when it
        /// has not failed.
        public let failure: WorkflowFailure?

        public init(
            stepID: WorkflowStepID,
            status: WorkflowStepStatus,
            attempts: Int,
            failure: WorkflowFailure?
        ) {
            self.stepID = stepID
            self.status = status
            self.attempts = attempts
            self.failure = failure
        }
    }

    public let sessionID: String
    public let sessionStatus: SessionStatus
    public let sessionProgress: SessionProgress
    public let steps: [StepOutcome]
    /// Why the run ended without reaching submission; `nil` otherwise.
    public let sessionFailure: WorkflowSessionFailure?

    public init(
        sessionID: String,
        sessionStatus: SessionStatus,
        sessionProgress: SessionProgress,
        steps: [StepOutcome],
        sessionFailure: WorkflowSessionFailure? = nil
    ) {
        self.sessionID = sessionID
        self.sessionStatus = sessionStatus
        self.sessionProgress = sessionProgress
        self.steps = steps
        self.sessionFailure = sessionFailure
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
                    failure: $0.failure)
            },
            sessionFailure: state.sessionFailure)
    }
}
