import Foundation
import Testing

@testable import DeepIDV
@testable import DeepIDVCore

/// A server string that must never reach the screen.
private let sentinel = "SERVER_TEXT_DO_NOT_SHOW"

private let genericTitle = "Let's try that again"
private let genericBody = "We couldn't complete this step. Please try again."

private func failure(
    _ code: WorkflowFailure.Code,
    action: WorkflowFailure.UserAction = .retryStep
) -> WorkflowFailure {
    WorkflowFailure(
        code: code,
        category: .other,
        userAction: action,
        isRetryable: true,
        slot: .primary,
        message: sentinel)
}

private let catalogueCodes: [WorkflowFailure.Code] = [
    .idFaceNotDetected,
    .idTextNotReadable,
    .documentTypeNotAccepted,
    .documentTypeUnrecognized,
    .documentTypeLowConfidence,
    .selfieFaceNotDetected,
    .selfieMultipleFaces,
    .selfieIDFaceMismatch,
    .livenessIDMismatch,
    .livenessFailed,
]

private let allActions: [WorkflowFailure.UserAction] = [
    .retakeDocument, .useDifferentDocument, .retakeSelfie, .retryLiveness, .retryStep, .none,
]

struct WorkflowFailureCopyTests {

    // MARK: - Step failures

    @Test(arguments: catalogueCodes)
    func everyCatalogueCodeHasItsOwnCopy(code: WorkflowFailure.Code) {
        for step in [WorkflowStepID.idVerification, .faceLiveness] {
            let copy = WorkflowFailureCopy.failure(failure(code), step: step)
            #expect(copy.title != genericTitle)
            #expect(copy.body != genericBody)
            #expect(!copy.title.isEmpty)
            #expect(!copy.body.isEmpty)
        }
    }

    @Test func tableRowsMatchTheirCodes() {
        let unreadable = WorkflowFailureCopy.failure(
            failure(.idTextNotReadable), step: .idVerification)
        #expect(unreadable.title == "We couldn't read your ID")

        let notAccepted = WorkflowFailureCopy.failure(
            failure(.documentTypeNotAccepted), step: .idVerification)
        #expect(notAccepted.title == "This document isn't accepted")
        #expect(notAccepted.body == "Please use a different type of ID.")

        let unrecognized = WorkflowFailureCopy.failure(
            failure(.documentTypeUnrecognized), step: .idVerification)
        let lowConfidence = WorkflowFailureCopy.failure(
            failure(.documentTypeLowConfidence), step: .idVerification)
        #expect(unrecognized == lowConfidence)

        let liveness = WorkflowFailureCopy.failure(failure(.livenessFailed), step: .faceLiveness)
        #expect(liveness.title == "We couldn't verify you")
    }

    @Test func livenessIDMismatchReadsDifferentlyOnEachStep() {
        let onLiveness = WorkflowFailureCopy.failure(
            failure(.livenessIDMismatch), step: .faceLiveness)
        let onID = WorkflowFailureCopy.failure(
            failure(.livenessIDMismatch), step: .idVerification)

        #expect(onLiveness.title == "Your face check doesn't match your ID")
        #expect(onID.title == "Your ID doesn't match your face check")
        #expect(onLiveness.body != onID.body)
    }

    @Test(arguments: allActions)
    func unknownCodeFallsBackToItsUserAction(action: WorkflowFailure.UserAction) {
        let copy = WorkflowFailureCopy.failure(
            failure(WorkflowFailure.Code(rawValue: "SOMETHING_NEW"), action: action),
            step: .idVerification)
        #expect(copy.title == genericTitle)
        #expect(!copy.body.isEmpty)
    }

    @Test func unknownCodeActionLinesAreSpecific() {
        let unknown = WorkflowFailure.Code(rawValue: "SOMETHING_NEW")
        #expect(
            WorkflowFailureCopy.failure(
                failure(unknown, action: .retakeDocument), step: .idVerification
            ).body == "Please capture your ID again.")
        #expect(
            WorkflowFailureCopy.failure(
                failure(unknown, action: .retakeSelfie), step: .idVerification
            ).body == "Please take your selfie again.")
        #expect(
            WorkflowFailureCopy.failure(
                failure(.unknown, action: .retryStep), step: .idVerification
            ).body == genericBody)
    }

    @Test func missingFailureUsesTheGenericLine() {
        let copy = WorkflowFailureCopy.failure(nil, step: .idVerification)
        #expect(copy.title == genericTitle)
        #expect(copy.body == genericBody)
    }

    // MARK: - Run-ending failures

    @Test func sessionFailureRows() {
        let exhausted = WorkflowFailureCopy.sessionFailure(
            WorkflowSessionFailure(
                code: .attemptsExhausted, stepID: .idVerification,
                failure: failure(.idTextNotReadable)))
        #expect(exhausted.title == "We couldn't verify your identity")
        #expect(exhausted.body == "You've used all your attempts.")

        let expired = WorkflowFailureCopy.sessionFailure(
            WorkflowSessionFailure(code: .sessionExpired, stepID: nil, failure: nil))
        #expect(expired.title == "This verification has expired")
        #expect(expired.body == "Please start again.")

        let blocked = WorkflowFailureCopy.sessionFailure(
            WorkflowSessionFailure(code: .stepBlocked, stepID: nil, failure: nil))
        #expect(!blocked.title.isEmpty)
        #expect(!blocked.body.isEmpty)
    }

    // MARK: - Errors

    @Test func apiCodeTakesPrecedenceOverKind() {
        let terminal = DeepIDVError.conflict(sentinel, info: nil, apiCode: .sessionTerminal)
        #expect(
            WorkflowFailureCopy.error(terminal).body == "This verification is already finished.")
        #expect(
            WorkflowFailureCopy.error(.conflict(sentinel, info: nil)).body
                != WorkflowFailureCopy.error(terminal).body)

        let media = DeepIDVError.validation(sentinel, apiCode: .invalidMedia)
        #expect(
            WorkflowFailureCopy.error(media).body
                == "We couldn't use that photo. Please try again.")
        #expect(
            WorkflowFailureCopy.error(.validation(sentinel)).body
                == "Something went wrong. Please contact support.")
    }

    @Test func unlistedAPICodeFallsBackToKind() {
        let error = DeepIDVError.notFound(
            sentinel, apiCode: APIErrorCode(rawValue: "SOMETHING_NEW"))
        #expect(WorkflowFailureCopy.error(error) == WorkflowFailureCopy.error(.notFound("x")))
    }

    @Test(arguments: [
        DeepIDVError.network(sentinel),
        .timeout(sentinel),
        .rateLimit(sentinel),
        .serviceUnavailable(sentinel),
        .api(sentinel, status: 502),
        .captureFailed(sentinel),
        .cameraPermissionDenied(sentinel),
        .authentication("\(sentinel) (api key: sk_...abcd)"),
        .authorization(sentinel),
        .insufficientFunds(sentinel),
        .validation(sentinel),
        .notFound(sentinel),
        .conflict(sentinel, info: nil),
        .cancelled(sentinel),
        .antiCheatBlocked(sentinel),
    ])
    func everyErrorKindHasCopy(error: DeepIDVError) {
        let copy = WorkflowFailureCopy.error(error)
        #expect(!copy.title.isEmpty)
        #expect(!copy.body.isEmpty)
        #expect(!copy.title.contains(sentinel))
        #expect(!copy.body.contains(sentinel))
        #expect(!copy.body.contains("sk_"))
    }

    // MARK: - No leak of server text

    @Test func serverMessageNeverAppearsInFailureCopy() {
        let codes = catalogueCodes + [.unknown, WorkflowFailure.Code(rawValue: sentinel)]
        for code in codes {
            for action in allActions {
                for step in [WorkflowStepID.idVerification, .faceLiveness] {
                    let copy = WorkflowFailureCopy.failure(
                        failure(code, action: action), step: step)
                    #expect(!copy.title.contains(sentinel))
                    #expect(!copy.body.contains(sentinel))
                }
            }
        }
    }

    @Test func serverMessageNeverAppearsInSessionFailureCopy() {
        let codes: [WorkflowSessionFailure.Code] = [
            .attemptsExhausted, .stepBlocked, .sessionExpired,
            WorkflowSessionFailure.Code(rawValue: sentinel),
        ]
        for code in codes {
            let copy = WorkflowFailureCopy.sessionFailure(
                WorkflowSessionFailure(
                    code: code, stepID: .idVerification, failure: failure(.unknown)))
            #expect(!copy.title.contains(sentinel))
            #expect(!copy.body.contains(sentinel))
        }
    }

    @Test func serverMessageNeverAppearsForAnyAPICode() {
        let codes: [APIErrorCode] = [
            .validationError, .workflowInactive, .unsupportedWorkflowSteps, .invalidUploadKey,
            .invalidMedia, .uploadSlotNotRequired, .insufficientFunds, .forbidden,
            .organizationNotFound, .workflowNotFound, .sessionNotFound, .executionStateNotFound,
            .stepNotFound, .sessionTerminal, .sessionAlreadyStarted, .noActiveStep,
            .stepOutOfOrder, .stepNotSubmittable, .stepConflict, .livenessNotStarted,
            .livenessResultNotReady, .livenessUploadIncomplete, .stepNotRunnable, .internalError,
            APIErrorCode(rawValue: sentinel),
        ]
        for code in codes {
            let copy = WorkflowFailureCopy.error(.api(sentinel, status: 418, apiCode: code))
            #expect(!copy.title.contains(sentinel))
            #expect(!copy.body.contains(sentinel))
        }
    }
}
