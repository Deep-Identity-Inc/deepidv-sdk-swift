import Foundation
import Testing

@testable import DeepIDV
@testable import DeepIDVCore

// MARK: - Fixtures

private func livenessStepState(
    status: WorkflowStepStatus,
    attempts: Int,
    failureReason: String? = nil
) -> WorkflowStepState {
    WorkflowStepState(
        stepID: .faceLiveness,
        status: status,
        attempts: attempts,
        startedAt: nil,
        completedAt: nil,
        failureReason: failureReason,
        requirements: .faceLiveness(
            FaceLivenessRequirements(
                challengeType: "FaceMovementChallenge",
                confidenceThreshold: 70)))
}

private func executionState(
    liveness: WorkflowStepState,
    currentStep: Int?,
    attemptsRemaining: Int?,
    status: SessionStatus = .pending,
    progress: SessionProgress = .started
) -> WorkflowExecutionState {
    WorkflowExecutionState(
        sessionID: "sess-1",
        status: status,
        sessionProgress: progress,
        steps: [liveness],
        currentStep: currentStep,
        attemptsRemaining: attemptsRemaining)
}

private let live = FaceLivenessResult(status: .succeeded, confidence: 91, passed: true)
private let notLive = FaceLivenessResult(status: .succeeded, confidence: 40, passed: false)

private final class StepSpy: @unchecked Sendable {
    var states: [Result<WorkflowExecutionState, DeepIDVError>]
    var fetchCalls = 0
    var completed: [WorkflowStepOutcome] = []
    var failures: [DeepIDVError] = []

    init(states: [Result<WorkflowExecutionState, DeepIDVError>]) {
        self.states = states
    }

    func fetch() async throws -> WorkflowExecutionState {
        let next = states[fetchCalls]
        fetchCalls += 1
        return try next.get()
    }
}

@MainActor
private func makeModel(
    attemptsRemaining: Int? = nil,
    spy: StepSpy
) -> CustomFaceLivenessStepFlowModel {
    CustomFaceLivenessStepFlowModel(
        attemptsRemaining: attemptsRemaining,
        fetchState: { try await spy.fetch() },
        onStepCompleted: { spy.completed.append($0) },
        onStepFailed: { spy.failures.append($0) })
}

// MARK: - Tests

@MainActor
struct CustomFaceLivenessStepFlowModelTests {
    @Test func passedAttemptCompletesStepFromServerState() async {
        let state = executionState(
            liveness: livenessStepState(status: .completed, attempts: 1),
            currentStep: nil,
            attemptsRemaining: 2,
            status: .submitted,
            progress: .completed)
        let spy = StepSpy(states: [.success(state)])
        let model = makeModel(attemptsRemaining: 3, spy: spy)

        model.attemptFinished(.success(live))
        #expect(model.state == .syncing)
        await model.awaitPendingWork()

        #expect(model.state == .finished)
        #expect(spy.fetchCalls == 1)
        #expect(spy.completed.count == 1)
        let outcome = spy.completed[0]
        #expect(outcome.stepID == .faceLiveness)
        #expect(outcome.stepStatus == .completed)
        #expect(outcome.attempts == 1)
        #expect(outcome.currentStep == nil)
        #expect(outcome.sessionStatus == .submitted)
        #expect(outcome.isTerminalRun)
        #expect(spy.failures.isEmpty)
    }

    @Test func notLiveWithBudgetLeftHandsScreenBackForRetry() async {
        let state = executionState(
            liveness: livenessStepState(
                status: .pending, attempts: 1, failureReason: "FACE_LIVENESS_CHECK_FAILED"),
            currentStep: 1,
            attemptsRemaining: 1)
        let spy = StepSpy(states: [.success(state)])
        let model = makeModel(attemptsRemaining: 2, spy: spy)

        model.attemptFinished(.success(notLive))
        await model.awaitPendingWork()

        #expect(model.state == .running)
        #expect(model.attemptsRemaining == 1)
        #expect(spy.completed.isEmpty)
        #expect(spy.failures.isEmpty)
    }

    @Test func notLiveAfterLastAttemptCompletesFailedStep() async {
        let state = executionState(
            liveness: livenessStepState(
                status: .failed, attempts: 2, failureReason: "FACE_LIVENESS_CHECK_FAILED"),
            currentStep: nil,
            attemptsRemaining: 0,
            status: .failed,
            progress: .completed)
        let spy = StepSpy(states: [.success(state)])
        let model = makeModel(attemptsRemaining: 1, spy: spy)

        model.attemptFinished(.success(notLive))
        await model.awaitPendingWork()

        #expect(model.state == .finished)
        #expect(spy.completed.count == 1)
        #expect(spy.completed[0].stepStatus == .failed)
        #expect(spy.completed[0].failureReason == "FACE_LIVENESS_CHECK_FAILED")
        #expect(spy.completed[0].attempts == 2)
    }

    @Test func secondAttemptAfterRetryCompletes() async {
        let retryable = executionState(
            liveness: livenessStepState(status: .pending, attempts: 1),
            currentStep: 1,
            attemptsRemaining: 1)
        let done = executionState(
            liveness: livenessStepState(status: .completed, attempts: 2),
            currentStep: nil,
            attemptsRemaining: 1,
            status: .submitted,
            progress: .completed)
        let spy = StepSpy(states: [.success(retryable), .success(done)])
        let model = makeModel(attemptsRemaining: 2, spy: spy)

        model.attemptFinished(.success(notLive))
        await model.awaitPendingWork()
        #expect(model.state == .running)

        model.attemptFinished(.success(live))
        await model.awaitPendingWork()
        #expect(model.state == .finished)
        #expect(spy.fetchCalls == 2)
        #expect(spy.completed.map(\.attempts) == [2])
    }

    @Test func cancellationFailsStepWithoutFetching() async {
        let spy = StepSpy(states: [])
        let model = makeModel(spy: spy)

        model.attemptFinished(.failure(.cancelled("Face liveness was cancelled.")))

        #expect(model.state == .finished)
        #expect(spy.fetchCalls == 0)
        #expect(spy.failures.map(\.kind) == [.cancelled])
        #expect(spy.completed.isEmpty)
    }

    @Test func permissionDeniedFailsStep() async {
        let spy = StepSpy(states: [])
        let model = makeModel(spy: spy)

        model.attemptFinished(.failure(.cameraPermissionDenied("Camera access is required.")))

        #expect(spy.failures.map(\.kind) == [.cameraPermissionDenied])
    }

    @Test func transientErrorStaysOnCustomViewForItsOwnRetry() async {
        let spy = StepSpy(states: [])
        let model = makeModel(attemptsRemaining: 2, spy: spy)

        model.attemptFinished(.failure(.network("Liveness frame upload failed")))

        #expect(model.state == .running)
        #expect(spy.failures.isEmpty)
        #expect(spy.completed.isEmpty)
    }

    @Test func transientErrorWithNoBudgetFailsStep() async {
        let spy = StepSpy(states: [])
        let model = makeModel(attemptsRemaining: 0, spy: spy)

        model.attemptFinished(.failure(.network("Liveness frame upload failed")))

        #expect(model.state == .finished)
        #expect(spy.failures.map(\.kind) == [.network])
    }

    @Test func fetchStateFailureFailsStep() async {
        let spy = StepSpy(states: [.failure(.serviceUnavailable("down"))])
        let model = makeModel(spy: spy)

        model.attemptFinished(.success(live))
        await model.awaitPendingWork()

        #expect(model.state == .finished)
        #expect(spy.failures.map(\.kind) == [.serviceUnavailable])
    }

    @Test func missingStepInStateIsValidationFailure() async {
        let state = WorkflowExecutionState(
            sessionID: "sess-1",
            status: .pending,
            sessionProgress: .started,
            steps: [],
            currentStep: 0,
            attemptsRemaining: nil)
        let spy = StepSpy(states: [.success(state)])
        let model = makeModel(spy: spy)

        model.attemptFinished(.success(live))
        await model.awaitPendingWork()

        #expect(spy.failures.map(\.kind) == [.validation])
    }

    @Test func cancelAfterCompletionIsIgnored() async {
        let state = executionState(
            liveness: livenessStepState(status: .completed, attempts: 1),
            currentStep: nil,
            attemptsRemaining: nil,
            status: .submitted,
            progress: .completed)
        let spy = StepSpy(states: [.success(state)])
        let model = makeModel(spy: spy)

        model.attemptFinished(.success(live))
        await model.awaitPendingWork()
        model.cancel()

        #expect(spy.completed.count == 1)
        #expect(spy.failures.isEmpty)
    }
}
