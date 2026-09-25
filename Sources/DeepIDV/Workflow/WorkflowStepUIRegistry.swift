// DeepIDV › Workflow

import DeepIDVCore
import SwiftUI

/// Envelope fields the flow coordinator needs after a typed step submission.
struct WorkflowStepOutcome: Sendable, Equatable {
    let stepID: WorkflowStepID
    let stepStatus: WorkflowStepStatus
    let failureReason: String?
    let currentStep: Int?
    let attemptsRemaining: Int?
    let sessionStatus: SessionStatus
    let sessionProgress: SessionProgress
    let attempts: Int

    init<Payload>(_ result: StepSubmissionResult<Payload>) {
        self.init(
            stepID: result.stepID,
            stepStatus: result.stepStatus,
            failureReason: result.failureReason,
            currentStep: result.currentStep,
            attemptsRemaining: result.attemptsRemaining,
            sessionStatus: result.sessionStatus,
            sessionProgress: result.sessionProgress,
            attempts: 0)
    }

    init(
        stepID: WorkflowStepID,
        stepStatus: WorkflowStepStatus,
        failureReason: String?,
        currentStep: Int?,
        attemptsRemaining: Int?,
        sessionStatus: SessionStatus,
        sessionProgress: SessionProgress,
        attempts: Int = 0
    ) {
        self.stepID = stepID
        self.stepStatus = stepStatus
        self.failureReason = failureReason
        self.currentStep = currentStep
        self.attemptsRemaining = attemptsRemaining
        self.sessionStatus = sessionStatus
        self.sessionProgress = sessionProgress
        self.attempts = attempts
    }

    var isTerminalRun: Bool {
        currentStep == nil
            || sessionProgress == .completed
            || sessionStatus == .submitted
            || sessionStatus == .failed
            || sessionStatus == .completed
            || sessionStatus == .expired
    }

    var canRetry: Bool {
        !isTerminalRun
            && stepStatus != .completed
            && stepStatus != .failed
            && (attemptsRemaining.map { $0 > 0 } ?? true)
    }

    func recordingAttempts(_ attempts: Int) -> WorkflowStepOutcome {
        WorkflowStepOutcome(
            stepID: stepID,
            stepStatus: stepStatus,
            failureReason: failureReason,
            currentStep: currentStep,
            attemptsRemaining: attemptsRemaining,
            sessionStatus: sessionStatus,
            sessionProgress: sessionProgress,
            attempts: attempts)
    }
}

/// Dependencies and completion callbacks shared by every workflow step view.
@MainActor
struct WorkflowStepContext {
    /// The host's client — carries the resolved config and builds per-step
    /// services.
    let client: DeepIDVClient
    let sessionID: String
    let stepID: WorkflowStepID
    let requirements: StepRequirements
    let service: WorkflowService
    let uploader: SessionUploader
    let attemptsRemaining: Int?
    let registerCancellation: (@escaping () -> Void) -> Void
    let onStepCompleted: (WorkflowStepOutcome) -> Void
    let onStepFailed: (DeepIDVError) -> Void
}

/// Maps a workflow step id to its concrete SwiftUI flow.
@MainActor
enum WorkflowStepUIRegistry {
    static func supports(_ stepID: WorkflowStepID) -> Bool {
        stepID == .idVerification || stepID == .faceLiveness
    }

    static func makeFlowView(
        for stepID: WorkflowStepID,
        context: WorkflowStepContext
    ) -> AnyView? {
        switch (stepID, context.requirements) {
        case (.idVerification, .idVerification(let requirements)):
            return AnyView(
                IDVerificationStepFlowView(
                    context: context,
                    requirements: requirements))
        case (.faceLiveness, .faceLiveness(let requirements)):
            return AnyView(
                CustomFaceLivenessStepFlowView(
                    context: context,
                    requirements: requirements))
        default:
            return nil
        }
    }
}
