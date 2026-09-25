// DeepIDV › Workflow › Steps

import Combine
import DeepIDVCore
import Foundation

/// Bridges the custom (native) liveness flow into the workflow runner.
///
/// ``CustomFaceLivenessFlowView`` already drives the step endpoint
/// (`start → upload-url → complete`) and reports one ``FaceLivenessResult`` per
/// attempt, but its service decodes only the `liveness` payload and drops the
/// step envelope. This model re-reads the execution state after each attempt and
/// turns it into the ``WorkflowStepOutcome`` the flow coordinator expects.
@MainActor
final class CustomFaceLivenessStepFlowModel: ObservableObject {
    enum State: Equatable {
        /// The custom view owns the screen (capturing, uploading, or showing its
        /// own retry chrome).
        case running
        /// Reading the execution state after an attempt resolved.
        case syncing
        case finished
    }

    typealias FetchStateOperation = () async throws -> WorkflowExecutionState

    @Published private(set) var state: State = .running
    private(set) var attemptsRemaining: Int?

    private let stepID: WorkflowStepID
    private let fetchState: FetchStateOperation
    private let onStepCompleted: (WorkflowStepOutcome) -> Void
    private let onStepFailed: (DeepIDVError) -> Void

    private var task: Task<Void, Never>?
    private var hasCompleted = false

    init(
        stepID: WorkflowStepID = .faceLiveness,
        attemptsRemaining: Int?,
        fetchState: @escaping FetchStateOperation,
        onStepCompleted: @escaping (WorkflowStepOutcome) -> Void,
        onStepFailed: @escaping (DeepIDVError) -> Void
    ) {
        self.stepID = stepID
        self.attemptsRemaining = attemptsRemaining
        self.fetchState = fetchState
        self.onStepCompleted = onStepCompleted
        self.onStepFailed = onStepFailed
    }

    /// One custom-liveness attempt ended. A scored result (passed or not) is
    /// reconciled against the server state; a hard error ends the step.
    func attemptFinished(_ result: Result<FaceLivenessResult, DeepIDVError>) {
        guard !hasCompleted, state == .running else { return }
        switch result {
        case .success(let liveness):
            reconcile(passed: liveness.passed)
        case .failure(let error):
            handle(error)
        }
    }

    func cancel() {
        guard !hasCompleted else { return }
        fail(.cancelled("Face liveness was cancelled."))
    }

    func awaitPendingWork() async {
        await task?.value
    }

    // MARK: - Private

    private func reconcile(passed: Bool) {
        state = .syncing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let execution = try await self.fetchState()
                guard !Task.isCancelled, !self.hasCompleted else { return }
                guard let outcome = Self.outcome(for: self.stepID, in: execution) else {
                    self.fail(
                        .validation(
                            "Workflow state has no '\(self.stepID.rawValue)' step."))
                    return
                }
                self.attemptsRemaining = outcome.attemptsRemaining
                if passed
                    || outcome.stepStatus == .completed
                    || outcome.stepStatus == .failed
                    || outcome.isTerminalRun
                {
                    self.complete(outcome)
                } else if outcome.canRetry {
                    // Not live, budget left: the custom view is already showing
                    // its own "Try again" — hand the screen back to it.
                    self.state = .running
                } else {
                    self.complete(outcome)
                }
            } catch let error as DeepIDVError {
                guard !Task.isCancelled, !self.hasCompleted else { return }
                self.fail(error)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !self.hasCompleted else { return }
                self.fail(
                    .network(
                        "Face liveness failed unexpectedly.",
                        causeDescription: String(describing: error)))
            }
        }
    }

    /// Transient failures stay on the custom view, which offers its own retry
    /// (no server attempt is consumed until `complete` scores frames). Anything
    /// else — permission, cancellation, auth, conflict — ends the step.
    private func handle(_ error: DeepIDVError) {
        let hasAttempts = attemptsRemaining.map { $0 > 0 } ?? true
        if Self.isRetryable(error), hasAttempts {
            return
        }
        fail(error)
    }

    private func complete(_ outcome: WorkflowStepOutcome) {
        guard !hasCompleted else { return }
        hasCompleted = true
        state = .finished
        onStepCompleted(outcome)
    }

    private func fail(_ error: DeepIDVError) {
        guard !hasCompleted else { return }
        hasCompleted = true
        task?.cancel()
        state = .finished
        onStepFailed(error)
    }

    /// Projects the execution state onto the envelope shape the coordinator
    /// consumes for the given step.
    static func outcome(
        for stepID: WorkflowStepID,
        in execution: WorkflowExecutionState
    ) -> WorkflowStepOutcome? {
        guard let step = execution.steps.first(where: { $0.stepID == stepID }) else {
            return nil
        }
        return WorkflowStepOutcome(
            stepID: step.stepID,
            stepStatus: step.status,
            failureReason: step.failureReason,
            currentStep: execution.currentStep,
            attemptsRemaining: execution.attemptsRemaining,
            sessionStatus: execution.status,
            sessionProgress: execution.sessionProgress,
            attempts: step.attempts)
    }

    private static func isRetryable(_ error: DeepIDVError) -> Bool {
        switch error.kind {
        case .network, .timeout, .rateLimit, .serviceUnavailable, .api, .captureFailed:
            return true
        default:
            return false
        }
    }
}
