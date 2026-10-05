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

private let documentFailure = WorkflowFailure(
    code: .idTextNotReadable,
    category: .document,
    userAction: .retakeDocument,
    isRetryable: false,
    slot: .primary,
    message: "ID text not readable")

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
                failure: nil,
                requirements: idRequirements()),
            WorkflowStepState(
                stepID: .faceLiveness,
                status: .completed,
                attempts: 1,
                startedAt: nil,
                completedAt: nil,
                failure: nil,
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
            failure: nil,
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
            failure: nil,
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
                failure: documentFailure,
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
            failure: documentFailure,
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
    #expect(spy.value?.steps.first?.failure == documentFailure)
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
            failure: documentFailure,
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
    #expect(spy.value?.steps.first?.failure == documentFailure)
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
                failure: nil,
                requirements: idRequirements()),
            WorkflowStepState(
                stepID: .faceLiveness,
                status: .pending,
                attempts: 0,
                startedAt: nil,
                completedAt: nil,
                failure: nil,
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
            failure: nil,
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
                failure: documentFailure,
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
            failure: nil,
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
                failure: nil,
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
    #expect(resultSpy.results.isEmpty)
    #expect(model.canRetryStepError == false)

    model.dismissStepError()
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
                failure: nil,
                requirements: idRequirements()),
            WorkflowStepState(
                stepID: .faceLiveness,
                status: .pending,
                attempts: 0,
                startedAt: nil,
                completedAt: nil,
                failure: nil,
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
            failure: nil,
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
            failure: nil,
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
            failure: nil,
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

// MARK: - Mid-run errors

private func singleIDSession() -> WorkflowSession {
    WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [plan(.idVerification, requirements: idRequirements())],
        currentStep: 0)
}

/// A started session whose ID step is done and whose liveness step is current.
private func midRunState(
    livenessStatus: WorkflowStepStatus = .pending,
    livenessAttempts: Int = 0,
    livenessFailure: WorkflowFailure? = nil,
    attemptsRemaining: Int? = 2
) -> WorkflowExecutionState {
    WorkflowExecutionState(
        sessionID: "sess-1",
        status: .pending,
        sessionProgress: .started,
        steps: [
            WorkflowStepState(
                stepID: .idVerification,
                status: .completed,
                attempts: 2,
                startedAt: nil,
                completedAt: nil,
                failure: nil,
                requirements: idRequirements()),
            WorkflowStepState(
                stepID: .faceLiveness,
                status: livenessStatus,
                attempts: livenessAttempts,
                startedAt: nil,
                completedAt: nil,
                failure: livenessFailure,
                requirements: livenessRequirements()),
        ],
        currentStep: 1,
        attemptsRemaining: attemptsRemaining)
}

@MainActor @Test
func fatalStepErrorShowsErrorScreenAndReportsOnceOnClose() async {
    let states = WorkflowStateSpy(results: [])
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { singleIDSession() },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification },
        onResult: { spy.results.append($0) })
    let error = DeepIDVError.validation("Bad upload", apiCode: .invalidMedia)

    model.start()
    await model.awaitPendingWork()
    model.stepFailed(error)

    #expect(model.phase == .stepError(error))
    #expect(spy.results.isEmpty)
    #expect(model.canRetryStepError == false)

    // The retry the screen does not offer is refused outright.
    model.retryAfterStepError()
    await model.awaitPendingWork()
    #expect(states.calls == 0)
    #expect(model.phase == .stepError(error))

    model.dismissStepError()
    model.dismissStepError()
    model.cancel()

    #expect(model.phase == .finished)
    #expect(spy.results.count == 1)
    #expect(spy.results.first == .failure(error))
}

@MainActor @Test
func stepCancellationStillEndsTheRunImmediately() async {
    let spy = WorkflowResultSpy()
    let model = makeModel(session: singleIDSession(), resultSpy: spy)

    model.start()
    await model.awaitPendingWork()
    model.stepFailed(.cancelled("Identity verification was cancelled."))

    #expect(model.phase == .finished)
    #expect(spy.results.count == 1)
    #expect(spy.failureKind == .cancelled)
}

@MainActor @Test
func transientStepErrorOffersRetryOnlyForTransientKinds() async {
    let cases: [(DeepIDVError, Bool)] = [
        (.network("offline"), true),
        (.timeout("slow"), true),
        (.rateLimit("busy"), true),
        (.serviceUnavailable("down"), true),
        (.api("Bad Gateway", status: 502), true),
        (.api("Teapot", status: 418), false),
        (.validation("bad"), false),
        (.authentication("nope"), false),
        (.captureFailed("camera"), false),
        (.cameraPermissionDenied("denied"), false),
        (.notFound("gone"), false),
    ]
    for (error, expected) in cases {
        let spy = WorkflowResultSpy()
        let model = makeModel(session: singleIDSession(), resultSpy: spy)

        model.start()
        await model.awaitPendingWork()
        model.stepFailed(error)

        #expect(model.phase == .stepError(error))
        #expect(model.canRetryStepError == expected)
        #expect(spy.results.isEmpty)
    }
}

@MainActor @Test
func tryAgainAfterTransientStepErrorResumesTheCurrentStep() async {
    let session = WorkflowSession(
        sessionID: "sess-1",
        expiresAt: nil,
        steps: [
            plan(.idVerification, requirements: idRequirements()),
            plan(.faceLiveness, requirements: livenessRequirements()),
        ],
        currentStep: 0)
    let states = WorkflowStateSpy(results: [.success(midRunState(attemptsRemaining: 1))])
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { session },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification || $0 == .faceLiveness },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    let generation = model.renderGeneration
    model.stepFailed(.network("offline"))
    #expect(model.canRetryStepError)

    model.retryAfterStepError()
    #expect(model.phase == .resyncing)
    await model.awaitPendingWork()

    // The server had already moved on to the next step.
    #expect(states.calls == 1)
    #expect(model.phase == .runningStep(index: 1))
    #expect(model.attemptsRemaining == 1)
    #expect(model.renderGeneration > generation)
    #expect(spy.results.isEmpty)
}

@MainActor @Test
func tryAgainIntoATerminalStateFinalizes() async {
    let states = WorkflowStateSpy(results: [.success(executionState())])
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { singleIDSession() },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    model.stepFailed(.timeout("slow"))
    model.retryAfterStepError()
    await model.awaitPendingWork()

    #expect(model.phase == .finished)
    #expect(spy.results.count == 1)
    #expect(spy.value?.sessionStatus == .submitted)
}

@MainActor @Test
func failedTryAgainReturnsToTheErrorScreenWithTheNewError() async {
    let states = WorkflowStateSpy(
        results: [
            .failure(.serviceUnavailable("down")),
            .failure(.authentication("revoked")),
        ])
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { singleIDSession() },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    model.stepFailed(.network("offline"))

    model.retryAfterStepError()
    await model.awaitPendingWork()
    #expect(model.phase == .stepError(.serviceUnavailable("down")))
    #expect(model.canRetryStepError)

    model.retryAfterStepError()
    await model.awaitPendingWork()
    #expect(model.phase == .stepError(.authentication("revoked")))
    #expect(model.canRetryStepError == false)
    #expect(spy.results.isEmpty)

    model.dismissStepError()
    #expect(spy.results.count == 1)
    #expect(spy.failureKind == .authentication)
}

@MainActor @Test
func cancelDuringStepErrorReportsCancelledOnce() async {
    let spy = WorkflowResultSpy()
    let model = makeModel(session: singleIDSession(), resultSpy: spy)

    model.start()
    await model.awaitPendingWork()
    model.stepFailed(.validation("bad"))
    model.cancel()
    model.dismissStepError()
    model.cancel()

    #expect(model.phase == .finished)
    #expect(spy.results.count == 1)
    #expect(spy.failureKind == .cancelled)
}

// MARK: - Session failure on results

private let exhaustedSessionFailure = WorkflowSessionFailure(
    code: .attemptsExhausted,
    stepID: .idVerification,
    failure: documentFailure)

@MainActor @Test
func exhaustedRunResultCarriesSessionFailure() async {
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
                failure: documentFailure,
                requirements: idRequirements())
        ],
        currentStep: nil,
        attemptsRemaining: 0,
        sessionFailure: exhaustedSessionFailure)
    let spy = WorkflowResultSpy()
    let model = makeModel(session: singleIDSession(), state: failedState, resultSpy: spy)

    model.start()
    await model.awaitPendingWork()
    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .idVerification,
            stepStatus: .failed,
            failure: documentFailure,
            sessionFailure: exhaustedSessionFailure,
            currentStep: nil,
            attemptsRemaining: 0,
            sessionStatus: .failed,
            sessionProgress: .completed,
            attempts: 3))
    await model.awaitPendingWork()

    #expect(spy.results.count == 1)
    #expect(spy.value?.sessionFailure == exhaustedSessionFailure)
    #expect(spy.value?.sessionFailure?.code == .attemptsExhausted)
    #expect(spy.value?.sessionFailure?.stepID == .idVerification)
    #expect(spy.value?.sessionFailure?.failure == documentFailure)
    #expect(spy.value?.steps.first?.failure == documentFailure)
}

@MainActor @Test
func fallbackResultPassesSessionFailureThroughFromTheLastOutcome() async {
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        create: { singleIDSession() },
        fetchState: { _ in throw DeepIDVError.network("offline") },
        supportsStep: { $0 == .idVerification },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .idVerification,
            stepStatus: .failed,
            failure: documentFailure,
            sessionFailure: exhaustedSessionFailure,
            currentStep: nil,
            attemptsRemaining: 0,
            sessionStatus: .failed,
            sessionProgress: .completed,
            attempts: 3))
    await model.awaitPendingWork()

    #expect(spy.results.count == 1)
    #expect(spy.value?.sessionFailure == exhaustedSessionFailure)
    #expect(spy.value?.steps.first?.failure == documentFailure)
}

// MARK: - Resume by sessionID

@MainActor @Test
func resumedRunStartsAtServerCurrentStepWithServerAttempts() async {
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        resume: {
            midRunState(
                livenessStatus: .inProgress,
                livenessAttempts: 1,
                livenessFailure: WorkflowFailure(
                    code: .livenessFailed,
                    category: .liveness,
                    userAction: .retryLiveness,
                    isRetryable: true,
                    message: "Liveness check failed"),
                attemptsRemaining: 1)
        },
        fetchState: { _ in executionState() },
        supportsStep: { $0 == .idVerification || $0 == .faceLiveness },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()

    // An in-progress step with a stored failure renders as a fresh step, not
    // as a retry screen.
    #expect(model.phase == .runningStep(index: 1))
    #expect(model.sessionID == "sess-1")
    #expect(model.currentStepPlan?.stepID == .faceLiveness)
    #expect(model.attemptsRemaining == 1)
    #expect(spy.results.isEmpty)
}

@MainActor @Test
func resumedRunResultIncludesStepsCompletedBeforeTheResume() async {
    // The final read fails, so the result is assembled from what the run saw.
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        resume: { midRunState() },
        fetchState: { _ in throw DeepIDVError.network("offline") },
        supportsStep: { $0 == .idVerification || $0 == .faceLiveness },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .faceLiveness,
            stepStatus: .completed,
            failure: nil,
            currentStep: nil,
            attemptsRemaining: 2,
            sessionStatus: .submitted,
            sessionProgress: .completed,
            attempts: 1))
    await model.awaitPendingWork()

    #expect(spy.results.count == 1)
    #expect(spy.value?.sessionStatus == .submitted)
    #expect(spy.value?.steps.map(\.stepID) == [.idVerification, .faceLiveness])
    #expect(spy.value?.steps.map(\.status) == [.completed, .completed])
    #expect(spy.value?.steps.first?.attempts == 2)
}

@MainActor @Test
func resumedRunCompletesWithTheFinalServerState() async {
    let states = WorkflowStateSpy(results: [.success(executionState())])
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        resume: { midRunState() },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification || $0 == .faceLiveness },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    model.stepCompleted(
        WorkflowStepOutcome(
            stepID: .faceLiveness,
            stepStatus: .completed,
            failure: nil,
            currentStep: nil,
            attemptsRemaining: 2,
            sessionStatus: .submitted,
            sessionProgress: .completed,
            attempts: 1))
    await model.awaitPendingWork()

    #expect(states.calls == 1)
    #expect(spy.value?.steps.count == 2)
    #expect(spy.value?.sessionStatus == .submitted)
}

@MainActor @Test
func resumingATerminalSessionLandsOnTheEntryErrorWithNoRetry() async {
    final class ResumeSpy: @unchecked Sendable {
        var calls = 0
    }
    let resumes = ResumeSpy()
    let spy = WorkflowResultSpy()
    let terminal = DeepIDVError.conflict(
        "The session has already finished and cannot be resumed.",
        info: ConflictInfo(currentStep: nil, stepID: nil, failureReason: nil),
        apiCode: .sessionTerminal)
    let model = WorkflowFlowModel(
        resume: {
            resumes.calls += 1
            throw terminal
        },
        fetchState: { _ in executionState() },
        supportsStep: { _ in true },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()

    #expect(model.phase == .failed(terminal))
    #expect(model.canRetryEntry == false)

    model.retryEntry()
    await model.awaitPendingWork()
    #expect(resumes.calls == 1)
    #expect(spy.results.isEmpty)

    model.dismissFailure()
    #expect(spy.results.count == 1)
    #expect(spy.results.first == .failure(terminal))
}

@MainActor @Test
func transientResumeFailureRetriesTheResumeCall() async {
    final class ResumeSpy: @unchecked Sendable {
        var calls = 0
    }
    let resumes = ResumeSpy()
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        resume: {
            resumes.calls += 1
            if resumes.calls == 1 { throw DeepIDVError.network("offline") }
            return midRunState()
        },
        fetchState: { _ in executionState() },
        supportsStep: { _ in true },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    #expect(model.canRetryEntry)

    model.retryEntry()
    await model.awaitPendingWork()

    #expect(resumes.calls == 2)
    #expect(model.phase == .runningStep(index: 1))
    #expect(spy.results.isEmpty)
}

@MainActor @Test
func resumedRunWithAnUnsupportedCurrentStepFailsFast() async {
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        resume: { midRunState() },
        fetchState: { _ in executionState() },
        supportsStep: { $0 == .idVerification },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()

    #expect(spy.results.count == 1)
    #expect(spy.failureKind == .validation)
}

@MainActor @Test
func conflictDuringAResumedRunUsesTheExistingResync() async {
    let states = WorkflowStateSpy(results: [.success(midRunState())])
    let spy = WorkflowResultSpy()
    let model = WorkflowFlowModel(
        resume: { bootstrapState(currentStep: 0) },
        fetchState: { _ in try await states.fetch() },
        supportsStep: { $0 == .idVerification || $0 == .faceLiveness },
        onResult: { spy.results.append($0) })

    model.start()
    await model.awaitPendingWork()
    #expect(model.phase == .runningStep(index: 0))

    model.stepFailed(
        .conflict(
            "Concurrent submission",
            info: ConflictInfo(currentStep: 1, stepID: "FACE_LIVENESS", failureReason: nil),
            apiCode: .stepConflict))
    await model.awaitPendingWork()

    #expect(states.calls == 1)
    #expect(model.phase == .runningStep(index: 1))
    #expect(spy.results.isEmpty)
}
