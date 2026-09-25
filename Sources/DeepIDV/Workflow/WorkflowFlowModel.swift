// DeepIDV › Workflow

import Combine
import DeepIDVCore
import Foundation

/// Server-driven coordinator for a complete workflow run.
@MainActor
final class WorkflowFlowModel: ObservableObject {
    enum Phase: Equatable {
        case creating
        case runningStep(index: Int)
        case resyncing
        case finishing
        case finished
        case failed(DeepIDVError)
    }

    typealias CreateOperation = () async throws -> WorkflowSession
    typealias StartOperation = () async throws -> WorkflowExecutionState
    typealias FetchStateOperation = (_ sessionID: String) async throws -> WorkflowExecutionState
    typealias StepSupportOperation = (_ stepID: WorkflowStepID) -> Bool

    /// How a run enters: a session this SDK creates, or an existing un-started
    /// session started by id. Only the entry call differs — everything
    /// downstream is shared.
    private enum Entry {
        case created(WorkflowSession)
        case started(WorkflowExecutionState)
    }

    @Published private(set) var phase: Phase = .creating
    private(set) var sessionID: String?
    private(set) var steps: [WorkflowStepPlan] = []
    private(set) var attemptsRemaining: Int?
    private(set) var renderGeneration = 0

    private let entry: () async throws -> Entry
    private let fetchState: FetchStateOperation
    private let supportsStep: StepSupportOperation
    private let onResult: (Result<WorkflowRunResult, DeepIDVError>) -> Void

    private var task: Task<Void, Never>?
    private var cancelActiveStep: (() -> Void)?
    private var hasStarted = false
    private var hasFinished = false
    private var hasResyncedCurrentConflict = false
    private var stepResults: [Int: WorkflowRunResult.StepOutcome] = [:]

    /// Runs a workflow by creating its session.
    init(
        create: @escaping CreateOperation,
        fetchState: @escaping FetchStateOperation,
        supportsStep: @escaping StepSupportOperation,
        onResult: @escaping (Result<WorkflowRunResult, DeepIDVError>) -> Void
    ) {
        self.entry = { .created(try await create()) }
        self.fetchState = fetchState
        self.supportsStep = supportsStep
        self.onResult = onResult
    }

    /// Runs an existing un-started session by id. The start call seeds
    /// the run from the state it returns; everything after is identical to a
    /// created run.
    init(
        start: @escaping StartOperation,
        fetchState: @escaping FetchStateOperation,
        supportsStep: @escaping StepSupportOperation,
        onResult: @escaping (Result<WorkflowRunResult, DeepIDVError>) -> Void
    ) {
        self.entry = { .started(try await start()) }
        self.fetchState = fetchState
        self.supportsStep = supportsStep
        self.onResult = onResult
    }

    /// Performs the entry call once.
    func start() {
        guard !hasStarted, !hasFinished else { return }
        hasStarted = true
        phase = .creating
        runEntry()
    }

    /// Re-attempts the entry call after it failed.
    func retryEntry() {
        guard canRetryEntry else { return }
        task?.cancel()
        phase = .creating
        runEntry()
    }

    /// Whether the entry error screen offers a retry. A `.conflict` never can
    /// succeed on retry — the session is already started or terminal, which no
    /// amount of re-calling changes — so that failure is
    /// dismiss-only.
    var canRetryEntry: Bool {
        guard !hasFinished, case .failed(let error) = phase, sessionID == nil else {
            return false
        }
        return error.kind != .conflict
    }

    /// Closes the entry-error screen with the original typed error.
    func dismissFailure() {
        guard case .failed(let error) = phase else { return }
        finish(.failure(error))
    }

    /// Ends the run locally. No abandonment request is sent.
    func cancel() {
        guard !hasFinished else { return }
        task?.cancel()
        let cancelStep = cancelActiveStep
        cancelActiveStep = nil
        finish(.failure(.cancelled("Workflow verification was cancelled.")))
        cancelStep?()
    }

    /// Gives the coordinator an immediate cancellation hook for the rendered step.
    func registerActiveStepCancellation(_ action: @escaping () -> Void) {
        guard !hasFinished, case .runningStep = phase else { return }
        cancelActiveStep = action
    }

    /// Receives the envelope-derived outcome from the active step flow.
    func stepCompleted(_ outcome: WorkflowStepOutcome) {
        guard !hasFinished, case .runningStep(let index) = phase else { return }
        guard steps.indices.contains(index), steps[index].stepID == outcome.stepID else {
            finish(
                .failure(
                    .validation(
                        "The workflow returned a result for an unexpected step.")))
            return
        }

        cancelActiveStep = nil
        attemptsRemaining = outcome.attemptsRemaining
        hasResyncedCurrentConflict = false
        let priorAttempts = stepResults[index]?.attempts ?? 0
        stepResults[index] = WorkflowRunResult.StepOutcome(
            stepID: outcome.stepID,
            status: outcome.stepStatus,
            attempts: priorAttempts + outcome.attempts,
            failureReason: outcome.failureReason)
        if outcome.isTerminalRun {
            finalize(using: outcome)
        } else if let next = outcome.currentStep {
            moveToStep(at: next)
        } else {
            finalize(using: outcome)
        }
    }

    /// Ends the run when an active step reports an unrecoverable error.
    func stepFailed(_ error: DeepIDVError) {
        guard !hasFinished, case .runningStep = phase else { return }
        cancelActiveStep = nil
        if error.kind == .conflict, error.conflict?.currentStep != nil {
            recoverFromConflict(error)
        } else {
            finish(.failure(error))
        }
    }

    var currentStepPlan: WorkflowStepPlan? {
        guard case .runningStep(let index) = phase, steps.indices.contains(index) else {
            return nil
        }
        return steps[index]
    }

    /// Test synchronization seam for create and final-state reads.
    func awaitPendingWork() async {
        await task?.value
    }

    private func runEntry() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.entry()
                guard !Task.isCancelled, !self.hasFinished else { return }
                switch entry {
                case .created(let session):
                    self.sessionID = session.sessionID
                    self.steps = session.steps
                    if let currentStep = session.currentStep {
                        self.moveToStep(at: currentStep)
                    } else {
                        self.finalize()
                    }
                case .started(let state):
                    self.applyAndRender(state)
                }
            } catch let error as DeepIDVError {
                guard !Task.isCancelled, !self.hasFinished else { return }
                self.phase = .failed(error)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !self.hasFinished else { return }
                self.phase = .failed(Self.unexpected(error))
            }
        }
    }

    private func moveToStep(at index: Int) {
        guard !hasFinished else { return }
        cancelActiveStep = nil
        guard steps.indices.contains(index) else {
            finish(
                .failure(
                    .validation(
                        "Workflow current step \(index) is outside its step plan.")))
            return
        }
        let stepID = steps[index].stepID
        guard supportsStep(stepID) else {
            finish(
                .failure(
                    .validation(
                        "This SDK does not support workflow step '\(stepID.rawValue)'.")))
            return
        }
        renderGeneration += 1
        phase = .runningStep(index: index)
    }

    private func recoverFromConflict(_ conflict: DeepIDVError) {
        guard !hasResyncedCurrentConflict else {
            finish(.failure(conflict))
            return
        }
        guard let sessionID else {
            finish(.failure(conflict))
            return
        }

        hasResyncedCurrentConflict = true
        phase = .resyncing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await self.fetchState(sessionID)
                guard !Task.isCancelled, !self.hasFinished else { return }
                self.applyAndRender(state)
            } catch let error as DeepIDVError {
                guard !Task.isCancelled, !self.hasFinished else { return }
                self.finish(.failure(error))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !self.hasFinished else { return }
                self.finish(.failure(Self.unexpected(error)))
            }
        }
    }

    private func finalize(using outcome: WorkflowStepOutcome? = nil) {
        guard !hasFinished, let sessionID else { return }
        phase = .finishing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await self.fetchState(sessionID)
                guard !Task.isCancelled, !self.hasFinished else { return }
                self.finish(.success(WorkflowRunResult(state: state)))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !self.hasFinished else { return }
                if let outcome {
                    self.finish(
                        .success(
                            self.fallbackResult(
                                sessionID: sessionID,
                                using: outcome)))
                } else if let error = error as? DeepIDVError {
                    self.finish(.failure(error))
                } else {
                    self.finish(.failure(Self.unexpected(error)))
                }
            }
        }
    }

    /// Seeds the run from a server state envelope and renders the step the
    /// server says is current. Shared by the run-by-sessionID bootstrap and
    /// conflict resync, so a bootstrapped run is in exactly the state a
    /// resynced one would be.
    private func applyAndRender(_ state: WorkflowExecutionState) {
        apply(state)
        if Self.isTerminal(state) {
            finish(.success(WorkflowRunResult(state: state)))
        } else if let currentStep = state.currentStep {
            moveToStep(at: currentStep)
        } else {
            finish(.success(WorkflowRunResult(state: state)))
        }
    }

    private func apply(_ state: WorkflowExecutionState) {
        sessionID = state.sessionID
        attemptsRemaining = state.attemptsRemaining
        steps = state.steps.map {
            WorkflowStepPlan(
                stepID: $0.stepID,
                status: $0.status,
                requirements: $0.requirements)
        }
        for (index, step) in state.steps.enumerated() {
            stepResults[index] = WorkflowRunResult.StepOutcome(
                stepID: step.stepID,
                status: step.status,
                attempts: step.attempts,
                failureReason: step.failureReason)
        }
    }

    private func fallbackResult(
        sessionID: String,
        using outcome: WorkflowStepOutcome
    ) -> WorkflowRunResult {
        let outcomes = steps.enumerated().map { index, step in
            stepResults[index]
                ?? WorkflowRunResult.StepOutcome(
                    stepID: step.stepID,
                    status: step.status,
                    attempts: 0,
                    failureReason: nil)
        }
        return WorkflowRunResult(
            sessionID: sessionID,
            sessionStatus: outcome.sessionStatus,
            sessionProgress: outcome.sessionProgress,
            steps: outcomes)
    }

    private func finish(_ result: Result<WorkflowRunResult, DeepIDVError>) {
        guard !hasFinished else { return }
        hasFinished = true
        cancelActiveStep = nil
        phase = .finished
        onResult(result)
    }

    private static func unexpected(_ error: Error) -> DeepIDVError {
        .network(
            "Workflow verification failed unexpectedly.",
            causeDescription: String(describing: error))
    }

    private static func isTerminal(_ state: WorkflowExecutionState) -> Bool {
        state.currentStep == nil
            || state.sessionProgress == .completed
            || state.status == .submitted
            || state.status == .failed
            || state.status == .completed
            || state.status == .expired
    }
}
