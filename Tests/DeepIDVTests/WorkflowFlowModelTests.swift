import Foundation
import Testing

@testable import DeepIDV

private func idRequirements() -> StepRequirements {
    .idVerification(
        IDVerificationRequirements(
            document: .init(
                requireFrontOnly: false,
                frontOnlyDocumentTypes: ["passport"],
                requireSecondaryID: false,
                requireTertiaryID: false,
                validIDTypes: ["passport", "drivers-license"],
                validStates: []),
            face: .init(faceFrontPhotoOnly: true)))
}

private func livenessRequirements() -> StepRequirements {
    .faceLiveness(
        FaceLivenessRequirements(
            challengeType: "FaceMovementChallenge",
            confidenceThreshold: 70))
}

private func plan(
    _ stepID: WorkflowStepID,
    requirements: StepRequirements
) -> WorkflowStepPlan {
    WorkflowStepPlan(
        stepID: stepID,
        status: .pending,
        requirements: requirements)
}

private func executionState() -> WorkflowExecutionState {
    WorkflowExecutionState(
        sessionID: "sess-1",
        status: .submitted,
        sessionProgress: .completed,
        steps: [
            WorkflowStepState(
                stepID: .idVerification,
                status: .completed,
                attempts: 1,
                startedAt: nil,
                completedAt: nil,
                failureReason: nil,
                requirements: idRequirements()),
            WorkflowStepState(
                stepID: .faceLiveness,
                status: .completed,
                attempts: 1,
                startedAt: nil,
                completedAt: nil,
                failureReason: nil,
                requirements: livenessRequirements()),
        ],
        currentStep: nil,
        attemptsRemaining: 2)
}

private final class WorkflowResultSpy: @unchecked Sendable {
    var results: [Result<WorkflowRunResult, DeepIDVError>] = []

    var value: WorkflowRunResult? {
        guard case .success(let value) = results.last else { return nil }
        return value
    }

    var failureKind: DeepIDVError.Kind? {
        guard case .failure(let error) = results.last else { return nil }
        return error.kind
    }
}

private final class WorkflowCancellationSpy: @unchecked Sendable {
    var calls = 0
}

private final class WorkflowStateSpy: @unchecked Sendable {
    var results: [Result<WorkflowExecutionState, DeepIDVError>]
    var calls = 0

    init(results: [Result<WorkflowExecutionState, DeepIDVError>]) {
        self.results = results
    }

    func fetch() async throws -> WorkflowExecutionState {
        let result = results[calls]
        calls += 1
        return try result.get()
    }
}

@MainActor
private func makeModel(
    session: WorkflowSession,
    state: WorkflowExecutionState = executionState(),
    supportsStep: @escaping (WorkflowStepID) -> Bool = {
        $0 == .idVerification || $0 == .faceLiveness
    },
    resultSpy: WorkflowResultSpy
) -> WorkflowFlowModel {
    WorkflowFlowModel(
        create: { session },
        fetchState: { _ in state },
        supportsStep: supportsStep,
        onResult: { resultSpy.results.append($0) })
}

@MainActor @Test
func workflowUsesEnvelopeCurrentStepAndFinalState() async {
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [
            plan(.idVerification, requirements: idRequirements()),
            plan(.faceLiveness, requirements: livenessRequirements()),
        ],
        currentStep: 0)
    let spy = WorkflowResultSpy()
    let model = makeModel(session: session, resultSpy: spy)

    model.start()
    await model.awaitPendingWork()
    #expect(model.phase == .runningStep(index: 0))
    #expect(model.currentStepPlan?.stepID == .idVerification)

    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .idVerification,
            stepStatus: .completed,
            failureReason: nil,
            currentStep: 1,
            attemptsRemaining: 2,
            sessionStatus: .pending,
            sessionProgress: .started))
    #expect(model.phase == .runningStep(index: 1))
    #expect(model.attemptsRemaining == 2)

    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .faceLiveness,
            stepStatus: .completed,
            failureReason: nil,
            currentStep: nil,
            attemptsRemaining: 2,
            sessionStatus: .submitted,
            sessionProgress: .completed))
    await model.awaitPendingWork()

    #expect(model.phase == .finished)
    #expect(spy.results.count == 1)
    #expect(spy.value?.sessionID == "sess-1")
    #expect(spy.value?.steps.count == 2)
}

@MainActor @Test
func unsupportedStepFailsFastAndOnlyOnce() async {
    let unknown = WorkflowStepID(rawValue: "FUTURE_STEP")
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [
            plan(
                unknown,
                requirements: .unsupported(stepID: unknown))
        ],
        currentStep: 0)
    let spy = WorkflowResultSpy()
    let model = makeModel(
        session: session,
        supportsStep: { _ in false },
        resultSpy: spy)

    model.start()
    await model.awaitPendingWork()
    model.cancel()
    model.stepFailed(.network("late"))

    #expect(model.phase == .finished)
    #expect(spy.results.count == 1)
    #expect(spy.failureKind == .validation)
}

@MainActor @Test
func cancellationIsTerminalAndDoesNotFetchState() async {
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [plan(.idVerification, requirements: idRequirements())],
        currentStep: 0)
    let spy = WorkflowResultSpy()
    let model = makeModel(session: session, resultSpy: spy)

    model.start()
    await model.awaitPendingWork()
    let cancellation = WorkflowCancellationSpy()
    model.registerActiveStepCancellation { cancellation.calls += 1 }
    model.cancel()
    model.cancel()

    #expect(spy.results.count == 1)
    #expect(spy.failureKind == .cancelled)
    #expect(model.phase == .finished)
    #expect(cancellation.calls == 1)
}

@MainActor @Test
func createFailureCanRetryWithoutLeakingState() async {
    final class CreateSpy: @unchecked Sendable {
        var calls = 0
    }
    let calls = CreateSpy()
    let resultSpy = WorkflowResultSpy()
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [plan(.idVerification, requirements: idRequirements())],
        currentStep: 0)
    let model = WorkflowFlowModel(
        create: {
            calls.calls += 1
            if calls.calls == 1 { throw DeepIDVError.network("offline") }
            return session
        },
        fetchState: { _ in executionState() },
        supportsStep: { $0 == .idVerification },
        onResult: { resultSpy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    #expect(model.phase == .failed(.network("offline")))

    #expect(model.canRetryEntry)
    model.retryEntry()
    await model.awaitPendingWork()
    #expect(model.phase == .runningStep(index: 0))
    #expect(model.sessionID == "sess-1")
    #expect(resultSpy.results.isEmpty)
}

@MainActor @Test
func exhaustedAttemptBudgetReturnsSuccessfulFailedRun() async {
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [plan(.idVerification, requirements: idRequirements())],
        currentStep: 0)
    let failedState = WorkflowExecutionState(
        sessionID: "sess-1",
        status: .failed,
        sessionProgress: .completed,
        steps: [
            WorkflowStepState(
                stepID: .idVerification,
                status: .failed,
                attempts: 3,
                startedAt: nil,
                completedAt: nil,
                failureReason: "DOCUMENT_MISMATCH",
                requirements: idRequirements())
        ],
        currentStep: nil,
        attemptsRemaining: 0)
    let spy = WorkflowResultSpy()
    let model = makeModel(session: session, state: failedState, resultSpy: spy)

    model.start()
    await model.awaitPendingWork()
    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .idVerification,
            stepStatus: .failed,
            failureReason: "DOCUMENT_MISMATCH",
            currentStep: nil,
            attemptsRemaining: 0,
            sessionStatus: .failed,
            sessionProgress: .completed,
            attempts: 3))
    await model.awaitPendingWork()

    #expect(spy.results.count == 1)
    #expect(spy.value?.sessionStatus == .failed)
    #expect(spy.value?.sessionProgress == .completed)
    #expect(spy.value?.steps.first?.attempts == 3)
    #expect(spy.value?.steps.first?.failureReason == "DOCUMENT_MISMATCH")
}

@MainActor @Test
func finalStateReadFailureFallsBackToTerminalEnvelope() async {
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [plan(.idVerification, requirements: idRequirements())],
        currentStep: 0)
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { session },
        fetchState: { _ in throw DeepIDVError.network("offline") },
        supportsStep: { $0 == .idVerification },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .idVerification,
            stepStatus: .failed,
            failureReason: "DOCUMENT_MISMATCH",
            currentStep: nil,
            attemptsRemaining: 0,
            sessionStatus: .failed,
            sessionProgress: .completed,
            attempts: 2))
    await model.awaitPendingWork()

    #expect(spy.results.count == 1)
    #expect(spy.value?.sessionID == "sess-1")
    #expect(spy.value?.sessionStatus == .failed)
    #expect(spy.value?.steps.first?.status == .failed)
    #expect(spy.value?.steps.first?.attempts == 2)
    #expect(spy.value?.steps.first?.failureReason == "DOCUMENT_MISMATCH")
}

@MainActor @Test
func conflictResyncsToServerCurrentStep() async {
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [
            plan(.idVerification, requirements: idRequirements()),
            plan(.faceLiveness, requirements: livenessRequirements()),
        ],
        currentStep: 0)
    let resyncedState = WorkflowExecutionState(
        sessionID: "sess-1",
        status: .pending,
        sessionProgress: .started,
        steps: [
            WorkflowStepState(
                stepID: .idVerification,
                status: .completed,
                attempts: 1,
                startedAt: nil,
                completedAt: nil,
                failureReason: nil,
                requirements: idRequirements()),
            WorkflowStepState(
                stepID: .faceLiveness,
                status: .pending,
                attempts: 0,
                startedAt: nil,
                completedAt: nil,
                failureReason: nil,
                requirements: livenessRequirements()),
        ],
        currentStep: 1,
        attemptsRemaining: 2)
    let states = WorkflowStateSpy(
        results: [.success(resyncedState), .success(executionState())])
    let resultSpy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { session },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification || $0 == .faceLiveness },
        onResult: { resultSpy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    model.stepFailed(
        .conflict(
            "Wrong step",
            info: ConflictInfo(
                currentStep: 1,
                stepID: "FACE_LIVENESS",
                failureReason: nil)))
    await model.awaitPendingWork()

    #expect(model.phase == .runningStep(index: 1))
    #expect(model.currentStepPlan?.stepID == .faceLiveness)
    #expect(model.attemptsRemaining == 2)

    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .faceLiveness,
            stepStatus: .completed,
            failureReason: nil,
            currentStep: nil,
            attemptsRemaining: 2,
            sessionStatus: .submitted,
            sessionProgress: .completed,
            attempts: 1))
    await model.awaitPendingWork()

    #expect(states.calls == 2)
    #expect(resultSpy.results.count == 1)
    #expect(resultSpy.value?.sessionStatus == .submitted)
}

@MainActor @Test
func fallbackPreservesAttemptsConfirmedDuringConflictResync() async {
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [plan(.idVerification, requirements: idRequirements())],
        currentStep: 0)
    let resyncedState = WorkflowExecutionState(
        sessionID: "sess-1",
        status: .pending,
        sessionProgress: .started,
        steps: [
            WorkflowStepState(
                stepID: .idVerification,
                status: .inProgress,
                attempts: 1,
                startedAt: nil,
                completedAt: nil,
                failureReason: "DOCUMENT_MISMATCH",
                requirements: idRequirements())
        ],
        currentStep: 0,
        attemptsRemaining: 1)
    let states = WorkflowStateSpy(
        results: [
            .success(resyncedState),
            .failure(.network("offline")),
        ])
    let resultSpy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { session },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification },
        onResult: { resultSpy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    model.stepFailed(
        .conflict(
            "Concurrent submission",
            info: ConflictInfo(
                currentStep: 0,
                stepID: "ID_VERIFICATION",
                failureReason: nil)))
    await model.awaitPendingWork()
    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .idVerification,
            stepStatus: .completed,
            failureReason: nil,
            currentStep: nil,
            attemptsRemaining: 1,
            sessionStatus: .submitted,
            sessionProgress: .completed,
            attempts: 1))
    await model.awaitPendingWork()

    #expect(resultSpy.value?.steps.first?.attempts == 2)
}

@MainActor @Test
func secondConsecutiveConflictEndsRun() async {
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [plan(.idVerification, requirements: idRequirements())],
        currentStep: 0)
    let currentState = WorkflowExecutionState(
        sessionID: "sess-1",
        status: .pending,
        sessionProgress: .started,
        steps: [
            WorkflowStepState(
                stepID: .idVerification,
                status: .pending,
                attempts: 0,
                startedAt: nil,
                completedAt: nil,
                failureReason: nil,
                requirements: idRequirements())
        ],
        currentStep: 0,
        attemptsRemaining: nil)
    let states = WorkflowStateSpy(results: [.success(currentState)])
    let resultSpy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { session },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification },
        onResult: { resultSpy.results.append($0) })
    let conflict = DeepIDVError.conflict(
        "Concurrent submission",
        info: ConflictInfo(
            currentStep: 0,
            stepID: "ID_VERIFICATION",
            failureReason: nil))

    model.start()
    await model.awaitPendingWork()
    model.stepFailed(conflict)
    await model.awaitPendingWork()
    #expect(model.phase == .runningStep(index: 0))

    model.stepFailed(conflict)

    #expect(states.calls == 1)
    #expect(resultSpy.results.count == 1)
    #expect(resultSpy.failureKind == .conflict)
}

@MainActor @Test
func terminalSessionConflictFailsWithoutResync() async {
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [plan(.idVerification, requirements: idRequirements())],
        currentStep: 0)
    let states = WorkflowStateSpy(results: [])
    let resultSpy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { session },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification },
        onResult: { resultSpy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    model.stepFailed(
        .conflict(
            "Session is terminal",
            info: ConflictInfo(
                currentStep: nil,
                stepID: nil,
                failureReason: nil)))

    #expect(states.calls == 0)
    #expect(resultSpy.results.count == 1)
    #expect(resultSpy.failureKind == .conflict)
}

// MARK: - Run by sessionID

/// The state a freshly started, un-run session comes back with.
private func bootstrapState(currentStep: Int? = 0) -> WorkflowExecutionState {
    WorkflowExecutionState(
        sessionID: "sess-1",
        status: .pending,
        sessionProgress: .pending,
        steps: [
            WorkflowStepState(
                stepID: .idVerification,
                status: .pending,
                attempts: 0,
                startedAt: nil,
                completedAt: nil,
                failureReason: nil,
                requirements: idRequirements()),
            WorkflowStepState(
                stepID: .faceLiveness,
                status: .pending,
                attempts: 0,
                startedAt: nil,
                completedAt: nil,
                failureReason: nil,
                requirements: livenessRequirements()),
        ],
        currentStep: currentStep,
        attemptsRemaining: 2)
}

@MainActor @Test
func sessionBootstrapRendersServerCurrentStep() async {
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        start: { bootstrapState(currentStep: 1) },
        fetchState: { _ in executionState() },
        supportsStep: { $0 == .idVerification || $0 == .faceLiveness },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()

    #expect(model.phase == .runningStep(index: 1))
    #expect(model.sessionID == "sess-1")
    #expect(model.currentStepPlan?.stepID == .faceLiveness)
    #expect(model.attemptsRemaining == 2)
    #expect(spy.results.isEmpty)
}

@MainActor @Test
func alreadyStartedSessionBootstrapIsNotRetryable() async {
    final class StartSpy: @unchecked Sendable {
        var calls = 0
    }
    let starts = StartSpy()
    let spy = WorkflowResultSpy()
    let conflict = DeepIDVError.conflict(
        "Session has already been started",
        info: ConflictInfo(currentStep: nil, stepID: nil, failureReason: nil))
    let model = WorkflowFlowModel(
        start: {
            starts.calls += 1
            throw conflict
        },
        fetchState: { _ in executionState() },
        supportsStep: { _ in true },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()

    #expect(model.phase == .failed(conflict))
    #expect(model.canRetryEntry == false)

    // The retry the entry screen would drive is refused outright.
    model.retryEntry()
    await model.awaitPendingWork()
    #expect(starts.calls == 1)
    #expect(spy.results.isEmpty)

    model.dismissFailure()
    #expect(spy.results.count == 1)
    #expect(spy.failureKind == .conflict)
}

@MainActor @Test
func transientBootstrapFailureRetriesTheStartCall() async {
    final class StartSpy: @unchecked Sendable {
        var calls = 0
    }
    let starts = StartSpy()
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        start: {
            starts.calls += 1
            if starts.calls == 1 { throw DeepIDVError.network("offline") }
            return bootstrapState()
        },
        fetchState: { _ in executionState() },
        supportsStep: { _ in true },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    #expect(model.phase == .failed(.network("offline")))
    #expect(model.canRetryEntry)

    model.retryEntry()
    await model.awaitPendingWork()

    #expect(starts.calls == 2)
    #expect(model.phase == .runningStep(index: 0))
    #expect(spy.results.isEmpty)
}

@MainActor @Test
func unknownOrCrossOrgSessionBootstrapFailsWithMappedError() async {
    for error in [DeepIDVError.notFound("Session not found"), .authorization("Forbidden")] {
        let spy = WorkflowResultSpy()
        let model = WorkflowFlowModel(
            start: { throw error },
            fetchState: { _ in executionState() },
            supportsStep: { _ in true },
            onResult: { spy.results.append($0) })

        model.start()
        await model.awaitPendingWork()

        #expect(model.phase == .failed(error))
        #expect(model.canRetryEntry)

        model.dismissFailure()
        #expect(spy.results.count == 1)
        #expect(spy.failureKind == error.kind)
    }
}

@MainActor @Test
func sessionBootstrappedRunCompletesLikeACreatedRun() async {
    let states = WorkflowStateSpy(results: [.success(executionState())])
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        start: { bootstrapState() },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification || $0 == .faceLiveness },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    #expect(model.phase == .runningStep(index: 0))

    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .idVerification,
            stepStatus: .completed,
            failureReason: nil,
            currentStep: 1,
            attemptsRemaining: 2,
            sessionStatus: .pending,
            sessionProgress: .started,
            attempts: 1))
    #expect(model.phase == .runningStep(index: 1))

    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .faceLiveness,
            stepStatus: .completed,
            failureReason: nil,
            currentStep: nil,
            attemptsRemaining: 2,
            sessionStatus: .submitted,
            sessionProgress: .completed,
            attempts: 1))
    await model.awaitPendingWork()

    #expect(states.calls == 1)
    #expect(spy.results.count == 1)
    #expect(spy.value?.sessionID == "sess-1")
    #expect(spy.value?.sessionStatus == .submitted)
    #expect(spy.value?.steps.count == 2)
}

@MainActor @Test
func cancellationDuringFinalReadWinsExactlyOnce() async {
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [plan(.idVerification, requirements: idRequirements())],
        currentStep: 0)
    let resultSpy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { session },
        fetchState: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return executionState()
        },
        supportsStep: { $0 == .idVerification },
        onResult: { resultSpy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .idVerification,
            stepStatus: .completed,
            failureReason: nil,
            currentStep: nil,
            attemptsRemaining: 1,
            sessionStatus: .submitted,
            sessionProgress: .completed,
            attempts: 1))
    await Task.yield()
    model.cancel()
    await model.awaitPendingWork()

    #expect(resultSpy.results.count == 1)
    #expect(resultSpy.failureKind == .cancelled)
}
