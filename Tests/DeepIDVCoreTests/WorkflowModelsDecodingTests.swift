// DeepIDVCoreTests › Workflow

import Foundation
import Testing

@testable import DeepIDVCore

struct WorkflowModelsDecodingTests {

    // MARK: - Identifiers & statuses

    @Test func workflowStepIDRoundTripsRawValue() throws {
        let id = WorkflowStepID(rawValue: "ID_VERIFICATION")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(WorkflowStepID.self, from: data)
        #expect(decoded == .idVerification)
        #expect(WorkflowStepID.faceLiveness.rawValue == "FACE_LIVENESS")
    }

    @Test func sessionStatusPreservesUnknownRawValue() throws {
        let json = Data(#""SOMETHING_NEW""#.utf8)
        let status = try JSONDecoder().decode(SessionStatus.self, from: json)
        #expect(status.rawValue == "SOMETHING_NEW")
        #expect(status != .pending)
        #expect(SessionStatus.submitted.rawValue == "SUBMITTED")
        #expect(SessionStatus.failed.rawValue == "FAILED")
        #expect(SessionStatus.expired.rawValue == "EXPIRED")
    }

    // MARK: - Create session

    @Test func workflowSessionDecodesTwoStepPlan() throws {
        let json = Data(
            """
            {
              "session_id": "sess-1",
              "expires_at": "2026-08-01T00:00:00Z",
              "current_step": 0,
              "steps": [
                {
                  "step_id": "ID_VERIFICATION",
                  "status": "PENDING",
                  "requirements": {
                    "document": {
                      "require_front_only": false,
                      "front_only_document_types": ["passport"],
                      "require_secondary_id": true,
                      "require_tertiary_id": false,
                      "valid_id_types": ["drivers-license", "passport"],
                      "valid_states": ["CA"]
                    },
                    "face": { "face_front_photo_only": true }
                  }
                },
                {
                  "step_id": "FACE_LIVENESS",
                  "status": "PENDING",
                  "requirements": {
                    "challenge_type": "FaceMovementChallenge",
                    "confidence_threshold": 70
                  }
                }
              ]
            }
            """.utf8)

        let session = try JSONDecoder().decode(WorkflowSession.self, from: json)
        #expect(session.sessionID == "sess-1")
        #expect(session.expiresAt == "2026-08-01T00:00:00Z")
        #expect(session.currentStep == 0)
        #expect(session.steps.count == 2)

        guard case .idVerification(let idReqs) = session.steps[0].requirements else {
            Issue.record("expected idVerification requirements")
            return
        }
        #expect(idReqs.document.requireFrontOnly == false)
        #expect(idReqs.document.frontOnlyDocumentTypes == ["passport"])
        #expect(idReqs.document.requireSecondaryID == true)
        #expect(idReqs.document.requireTertiaryID == false)
        #expect(idReqs.document.validIDTypes == ["drivers-license", "passport"])
        #expect(idReqs.document.validStates == ["CA"])
        #expect(idReqs.face.faceFrontPhotoOnly == true)

        guard case .faceLiveness(let liveReqs) = session.steps[1].requirements else {
            Issue.record("expected faceLiveness requirements")
            return
        }
        #expect(liveReqs.challengeType == "FaceMovementChallenge")
        #expect(liveReqs.confidenceThreshold == 70)
    }

    @Test func workflowSessionNullExpiresAtAndAbsentCurrentStep() throws {
        let json = Data(
            """
            {
              "session_id": "sess-2",
              "expires_at": null,
              "steps": [
                {
                  "step_id": "FACE_LIVENESS",
                  "status": "PENDING",
                  "requirements": {
                    "challenge_type": "FaceMovementChallenge",
                    "confidence_threshold": 70
                  }
                }
              ]
            }
            """.utf8)

        let session = try JSONDecoder().decode(WorkflowSession.self, from: json)
        #expect(session.expiresAt == nil)
        #expect(session.currentStep == nil)
    }

    // MARK: - Execution state

    @Test func executionStateDecodesNullCurrentStepAndAttemptsRemaining() throws {
        let json = Data(
            """
            {
              "session_id": "sess-3",
              "status": "SUBMITTED",
              "session_progress": "COMPLETED",
              "current_step": null,
              "attempts_remaining": null,
              "steps": [
                {
                  "step_id": "ID_VERIFICATION",
                  "status": "COMPLETED",
                  "attempts": 1,
                  "started_at": "2026-08-01T00:00:00Z",
                  "completed_at": "2026-08-01T00:01:00Z",
                  "failure_reason": null,
                  "requirements": {
                    "document": {
                      "require_front_only": false,
                      "front_only_document_types": ["passport"],
                      "require_secondary_id": false,
                      "require_tertiary_id": false,
                      "valid_id_types": ["passport"],
                      "valid_states": []
                    },
                    "face": { "face_front_photo_only": true }
                  }
                }
              ]
            }
            """.utf8)

        let state = try JSONDecoder().decode(WorkflowExecutionState.self, from: json)
        #expect(state.sessionID == "sess-3")
        #expect(state.status == .submitted)
        #expect(state.sessionProgress == .completed)
        #expect(state.currentStep == nil)
        #expect(state.attemptsRemaining == nil)
        #expect(state.steps[0].attempts == 1)
        #expect(state.steps[0].failureReason == nil)
        #expect(state.steps[0].startedAt == "2026-08-01T00:00:00Z")
    }

    @Test func executionStateAbsentOptionalFields() throws {
        // Absent (not null) current_step / attempts_remaining / timestamps.
        let json = Data(
            """
            {
              "session_id": "sess-4",
              "status": "PENDING",
              "session_progress": "STARTED",
              "attempts_remaining": 2,
              "current_step": 0,
              "steps": [
                {
                  "step_id": "FACE_LIVENESS",
                  "status": "IN_PROGRESS",
                  "attempts": 0,
                  "requirements": {
                    "challenge_type": "FaceMovementChallenge",
                    "confidence_threshold": 70
                  }
                }
              ]
            }
            """.utf8)

        let state = try JSONDecoder().decode(WorkflowExecutionState.self, from: json)
        #expect(state.attemptsRemaining == 2)
        #expect(state.currentStep == 0)
        #expect(state.steps[0].startedAt == nil)
        #expect(state.steps[0].completedAt == nil)
        #expect(state.steps[0].failureReason == nil)
    }

    @Test func unknownStepIDYieldsUnsupportedAndStateStillDecodes() throws {
        let json = Data(
            """
            {
              "session_id": "sess-5",
              "status": "PENDING",
              "session_progress": "PENDING",
              "current_step": 0,
              "attempts_remaining": 3,
              "steps": [
                {
                  "step_id": "FUTURE_BIOMETRIC",
                  "status": "PENDING",
                  "attempts": 0,
                  "failure_reason": null,
                  "requirements": { "anything": true, "nested": { "ok": 1 } }
                },
                {
                  "step_id": "ID_VERIFICATION",
                  "status": "PENDING",
                  "attempts": 0,
                  "requirements": {
                    "document": {
                      "require_front_only": false,
                      "front_only_document_types": [],
                      "require_secondary_id": false,
                      "require_tertiary_id": false,
                      "valid_id_types": ["drivers-license"],
                      "valid_states": []
                    },
                    "face": { "face_front_photo_only": false }
                  }
                }
              ]
            }
            """.utf8)

        let state = try JSONDecoder().decode(WorkflowExecutionState.self, from: json)
        #expect(state.steps.count == 2)

        guard case .unsupported(let stepID) = state.steps[0].requirements else {
            Issue.record("expected .unsupported for FUTURE_BIOMETRIC")
            return
        }
        #expect(stepID.rawValue == "FUTURE_BIOMETRIC")

        guard case .idVerification = state.steps[1].requirements else {
            Issue.record("expected idVerification for second step")
            return
        }
    }

    // MARK: - Step submission envelope

    @Test func idVerificationEnvelopeDecodesEmptyPayload() throws {
        let json = Data(
            """
            {
              "step_id": "ID_VERIFICATION",
              "step_status": "COMPLETED",
              "failure_reason": null,
              "current_step": 1,
              "attempts_remaining": 2,
              "session_status": "PENDING",
              "session_progress": "STARTED"
            }
            """.utf8)

        let result = try JSONDecoder().decode(
            StepSubmissionResult<EmptyStepPayload>.self,
            from: json
        )
        #expect(result.stepID == .idVerification)
        #expect(result.stepStatus == .completed)
        #expect(result.failureReason == nil)
        #expect(result.currentStep == 1)
        #expect(result.attemptsRemaining == 2)
        #expect(result.sessionStatus == .pending)
        #expect(result.sessionProgress == .started)
        #expect(result.payload == EmptyStepPayload())
    }

    // MARK: - Encode paths

    @Test func workflowUserEncodesSnakeCase() throws {
        let user = WorkflowUser(
            email: "user@example.com",
            firstName: "Ada",
            lastName: "Lovelace",
            phone: "+15555550100",
            externalID: "ext-1"
        )
        let data = try JSONEncoder().encode(user)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["email"] as? String == "user@example.com")
        #expect(object?["first_name"] as? String == "Ada")
        #expect(object?["last_name"] as? String == "Lovelace")
        #expect(object?["phone"] as? String == "+15555550100")
        #expect(object?["external_id"] as? String == "ext-1")
    }

    @Test func workflowUserOmitsNilExternalID() throws {
        let user = WorkflowUser(
            email: "a@b.co",
            firstName: "A",
            lastName: "B",
            phone: "+15555550100"
        )
        let data = try JSONEncoder().encode(user)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["external_id"] == nil)
    }

    @Test func idVerificationSubmissionEncodesSlotKeyedUploads() throws {
        let submission = IDVerificationSubmission(
            documentType: "drivers-license",
            secondaryDocumentType: "passport",
            tertiaryDocumentType: nil,
            uploads: [
                .idFront: "org/sess/1-id_front.jpg",
                .idBack: "org/sess/1-id_back.jpg",
                .secondaryIDFront: "org/sess/1-secondary_id_front.jpg",
                .selfieFront: "org/sess/1-selfie_front.jpg",
            ]
        )
        let data = try JSONEncoder().encode(submission)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["document_type"] as? String == "drivers-license")
        #expect(object?["secondary_document_type"] as? String == "passport")
        #expect(object?["tertiary_document_type"] == nil)

        let uploads = object?["uploads"] as? [String: String]
        #expect(uploads?["id_front"] == "org/sess/1-id_front.jpg")
        #expect(uploads?["id_back"] == "org/sess/1-id_back.jpg")
        #expect(uploads?["secondary_id_front"] == "org/sess/1-secondary_id_front.jpg")
        #expect(uploads?["selfie_front"] == "org/sess/1-selfie_front.jpg")
        #expect(uploads?.keys.contains("secondary_id_back") == false)
    }
}
