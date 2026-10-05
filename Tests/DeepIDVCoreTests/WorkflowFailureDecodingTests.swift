// DeepIDVCoreTests › Workflow

import Foundation
import Testing

@testable import DeepIDVCore

private func decodeFailure(_ json: String) throws -> WorkflowFailure {
    try JSONDecoder().decode(WorkflowFailure.self, from: Data(json.utf8))
}

private func stateJSON(failure: String?, sessionFailure: String?) -> Data {
    let failureField = failure.map { #""failure": \#($0),"# } ?? ""
    let sessionFailureField = sessionFailure.map { #""session_failure": \#($0),"# } ?? ""
    return Data(
        """
        {
          "session_id": "sess-1",
          "status": "FAILED",
          "session_progress": "COMPLETED",
          "current_step": null,
          \(sessionFailureField)
          "attempts_remaining": 0,
          "steps": [
            {
              "step_id": "FACE_LIVENESS",
              "status": "FAILED",
              "attempts": 3,
              \(failureField)
              "failure_reason": "FACE_LIVENESS_CHECK_FAILED",
              "requirements": {
                "challenge_type": "FaceMovementChallenge",
                "confidence_threshold": 70
              }
            }
          ]
        }
        """.utf8)
}

private let livenessFailedJSON = """
    {
      "code": "LIVENESS_FAILED",
      "category": "LIVENESS",
      "user_action": "RETRY_LIVENESS",
      "retryable": false,
      "slot": null,
      "message": "Liveness check failed"
    }
    """

struct WorkflowFailureDecodingTests {

    // MARK: - Failure object

    @Test(arguments: [
        ("ID_FACE_NOT_DETECTED", WorkflowFailure.Code.idFaceNotDetected),
        ("ID_TEXT_NOT_READABLE", .idTextNotReadable),
        ("DOCUMENT_TYPE_NOT_ACCEPTED", .documentTypeNotAccepted),
        ("DOCUMENT_TYPE_UNRECOGNIZED", .documentTypeUnrecognized),
        ("DOCUMENT_TYPE_LOW_CONFIDENCE", .documentTypeLowConfidence),
        ("SELFIE_FACE_NOT_DETECTED", .selfieFaceNotDetected),
        ("SELFIE_MULTIPLE_FACES", .selfieMultipleFaces),
        ("SELFIE_ID_FACE_MISMATCH", .selfieIDFaceMismatch),
        ("LIVENESS_ID_MISMATCH", .livenessIDMismatch),
        ("LIVENESS_FAILED", .livenessFailed),
        ("UNKNOWN", .unknown),
    ])
    func everyKnownCodeDecodes(wire: String, expected: WorkflowFailure.Code) throws {
        let failure = try decodeFailure(
            """
            {
              "code": "\(wire)",
              "category": "OTHER",
              "user_action": "RETRY_STEP",
              "retryable": true,
              "slot": null,
              "message": "m"
            }
            """)
        #expect(failure.code == expected)
    }

    @Test func fullFailureDecodesEveryField() throws {
        let failure = try decodeFailure(
            """
            {
              "code": "DOCUMENT_TYPE_NOT_ACCEPTED",
              "category": "DOCUMENT",
              "user_action": "USE_DIFFERENT_DOCUMENT",
              "retryable": true,
              "slot": "SECONDARY",
              "message": "Document type is not accepted"
            }
            """)
        #expect(
            failure
                == WorkflowFailure(
                    code: .documentTypeNotAccepted,
                    category: .document,
                    userAction: .useDifferentDocument,
                    isRetryable: true,
                    slot: .secondary,
                    message: "Document type is not accepted"))
    }

    @Test(arguments: [
        ("DOCUMENT", WorkflowFailure.Category.document),
        ("SELFIE", .selfie),
        ("FACE_MATCH", .faceMatch),
        ("LIVENESS", .liveness),
        ("OTHER", .other),
    ])
    func everyCategoryDecodes(wire: String, expected: WorkflowFailure.Category) throws {
        let failure = try decodeFailure(
            #"{"code":"UNKNOWN","category":"\#(wire)","user_action":"NONE","retryable":false,"message":"m"}"#
        )
        #expect(failure.category == expected)
    }

    @Test(arguments: [
        ("RETAKE_DOCUMENT", WorkflowFailure.UserAction.retakeDocument),
        ("USE_DIFFERENT_DOCUMENT", .useDifferentDocument),
        ("RETAKE_SELFIE", .retakeSelfie),
        ("RETRY_LIVENESS", .retryLiveness),
        ("RETRY_STEP", .retryStep),
        ("NONE", .none),
    ])
    func everyUserActionDecodes(wire: String, expected: WorkflowFailure.UserAction) throws {
        let failure = try decodeFailure(
            #"{"code":"UNKNOWN","category":"OTHER","user_action":"\#(wire)","retryable":true,"message":"m"}"#
        )
        #expect(failure.userAction == expected)
    }

    @Test func unknownCodeIsPreserved() throws {
        let failure = try decodeFailure(
            #"{"code":"ID_HOLOGRAM_MISSING","category":"DOCUMENT","user_action":"RETAKE_DOCUMENT","retryable":true,"slot":"PRIMARY","message":"m"}"#
        )
        #expect(failure.code.rawValue == "ID_HOLOGRAM_MISSING")
        #expect(failure.code != .unknown)
        #expect(failure.userAction == .retakeDocument)
    }

    @Test func unknownCategoryFallsBackToOther() throws {
        let failure = try decodeFailure(
            #"{"code":"UNKNOWN","category":"ADDRESS","user_action":"RETRY_STEP","retryable":true,"message":"m"}"#
        )
        #expect(failure.category == .other)
    }

    @Test func unknownUserActionFallsBackByRetryability() throws {
        let retryable = try decodeFailure(
            #"{"code":"UNKNOWN","category":"OTHER","user_action":"CALL_SUPPORT","retryable":true,"message":"m"}"#
        )
        #expect(retryable.userAction == .retryStep)

        let exhausted = try decodeFailure(
            #"{"code":"UNKNOWN","category":"OTHER","user_action":"CALL_SUPPORT","retryable":false,"message":"m"}"#
        )
        #expect(exhausted.userAction == .none)
    }

    @Test func unknownSlotFallsBackToNil() throws {
        let failure = try decodeFailure(
            #"{"code":"UNKNOWN","category":"DOCUMENT","user_action":"RETAKE_DOCUMENT","retryable":true,"slot":"QUATERNARY","message":"m"}"#
        )
        #expect(failure.slot == nil)
    }

    @Test func missingFieldsNeverFailTheDecode() throws {
        let failure = try decodeFailure(#"{"code":"LIVENESS_FAILED"}"#)
        #expect(failure.code == .livenessFailed)
        #expect(failure.category == .other)
        #expect(failure.userAction == .none)
        #expect(failure.isRetryable == false)
        #expect(failure.slot == nil)
        #expect(failure.message == "")
    }

    // MARK: - On the execution state

    @Test func stateDecodesStepFailureAndSessionFailure() throws {
        let json = stateJSON(
            failure: livenessFailedJSON,
            sessionFailure: """
                {
                  "code": "ATTEMPTS_EXHAUSTED",
                  "step_id": "FACE_LIVENESS",
                  "failure": \(livenessFailedJSON)
                }
                """)

        let state = try JSONDecoder().decode(WorkflowExecutionState.self, from: json)

        let stepFailure = try #require(state.steps[0].failure)
        #expect(stepFailure.code == .livenessFailed)
        #expect(stepFailure.category == .liveness)
        #expect(stepFailure.isRetryable == false)

        let sessionFailure = try #require(state.sessionFailure)
        #expect(sessionFailure.code == .attemptsExhausted)
        #expect(sessionFailure.stepID == .faceLiveness)
        #expect(sessionFailure.failure == stepFailure)

        let result = WorkflowRunResult(state: state)
        #expect(result.steps[0].failure == stepFailure)
        #expect(result.sessionFailure == sessionFailure)
    }

    @Test func sessionFailureDecodesWithoutNestedFailure() throws {
        let json = stateJSON(
            failure: "null",
            sessionFailure: #"{"code":"SESSION_EXPIRED","step_id":null,"failure":null}"#)

        let state = try JSONDecoder().decode(WorkflowExecutionState.self, from: json)

        #expect(state.steps[0].failure == nil)
        let sessionFailure = try #require(state.sessionFailure)
        #expect(sessionFailure.code == .sessionExpired)
        #expect(sessionFailure.stepID == nil)
        #expect(sessionFailure.failure == nil)
    }

    @Test func unknownSessionFailureCodeIsPreserved() throws {
        let json = stateJSON(
            failure: nil, sessionFailure: #"{"code":"OPERATOR_REJECTED"}"#)

        let state = try JSONDecoder().decode(WorkflowExecutionState.self, from: json)

        #expect(state.sessionFailure?.code.rawValue == "OPERATOR_REJECTED")
    }

    @Test func nullAndAbsentFailureKeysBothDecodeAsNil() throws {
        let nulls = try JSONDecoder().decode(
            WorkflowExecutionState.self, from: stateJSON(failure: "null", sessionFailure: "null"))
        #expect(nulls.steps[0].failure == nil)
        #expect(nulls.sessionFailure == nil)

        let absent = try JSONDecoder().decode(
            WorkflowExecutionState.self, from: stateJSON(failure: nil, sessionFailure: nil))
        #expect(absent.steps[0].failure == nil)
        #expect(absent.sessionFailure == nil)
    }

    // MARK: - On the step submission envelope

    @Test func submissionDecodesFailureAndSessionFailure() throws {
        let json = Data(
            """
            {
              "step_id": "ID_VERIFICATION",
              "step_status": "FAILED",
              "failure_reason": "FACE_MISMATCH",
              "failure": {
                "code": "SELFIE_ID_FACE_MISMATCH",
                "category": "FACE_MATCH",
                "user_action": "RETAKE_SELFIE",
                "retryable": false,
                "slot": null,
                "message": "Selfie does not match the ID"
              },
              "session_failure": {
                "code": "ATTEMPTS_EXHAUSTED",
                "step_id": "ID_VERIFICATION",
                "failure": null
              },
              "current_step": null,
              "attempts_remaining": 0,
              "session_status": "FAILED",
              "session_progress": "COMPLETED"
            }
            """.utf8)

        let result = try JSONDecoder().decode(
            StepSubmissionResult<EmptyStepPayload>.self, from: json)

        #expect(result.failure?.code == .selfieIDFaceMismatch)
        #expect(result.failure?.category == .faceMatch)
        #expect(result.failure?.userAction == .retakeSelfie)
        #expect(result.sessionFailure?.code == .attemptsExhausted)
        #expect(result.sessionFailure?.stepID == .idVerification)
    }

    @Test func submissionWithoutFailureKeysDecodesAsNil() throws {
        let json = Data(
            """
            {
              "step_id": "ID_VERIFICATION",
              "step_status": "COMPLETED",
              "current_step": 1,
              "attempts_remaining": 2,
              "session_status": "PENDING",
              "session_progress": "STARTED"
            }
            """.utf8)

        let result = try JSONDecoder().decode(
            StepSubmissionResult<EmptyStepPayload>.self, from: json)

        #expect(result.failure == nil)
        #expect(result.sessionFailure == nil)
    }
}
