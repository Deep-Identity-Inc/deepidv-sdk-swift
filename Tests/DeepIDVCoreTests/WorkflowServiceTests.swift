import Foundation
import Testing

@testable import DeepIDVCore

// MARK: - Helpers

private let testKey = "sk_live_secret_abcd1234"

private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

private func makeResponse(
    url: String, status: Int, headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: headers)!
}

private let sampleUser = WorkflowUser(
    email: "user@example.com",
    firstName: "Ada",
    lastName: "Lovelace",
    phone: "+15555550100",
    externalID: "ext-1")

private let createSessionBody = Data(
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
              "require_secondary_id": false,
              "require_tertiary_id": false,
              "valid_id_types": ["drivers-license"],
              "valid_states": []
            },
            "face": { "face_front_photo_only": true }
          }
        }
      ]
    }
    """.utf8)

private let stateBody = Data(
    """
    {
      "session_id": "sess-1",
      "status": "PENDING",
      "session_progress": "STARTED",
      "current_step": 0,
      "attempts_remaining": 2,
      "steps": [
        {
          "step_id": "ID_VERIFICATION",
          "status": "IN_PROGRESS",
          "attempts": 0,
          "started_at": "2026-08-01T00:00:00Z",
          "completed_at": null,
          "failure_reason": null,
          "requirements": {
            "document": {
              "require_front_only": false,
              "front_only_document_types": ["passport"],
              "require_secondary_id": false,
              "require_tertiary_id": false,
              "valid_id_types": ["drivers-license"],
              "valid_states": []
            },
            "face": { "face_front_photo_only": true }
          }
        }
      ]
    }
    """.utf8)

private let idSubmitBody = Data(
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

private func makeService(
    maxRetries: Int = 0,
    handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
) -> (service: WorkflowService, stub: HTTPTransportStub) {
    let config = DeepIDVConfig(apiKey: testKey, timeout: 30, maxRetries: maxRetries)
    let stub = HTTPTransportStub(handler: handler)
    let service = WorkflowService(
        config: config, transport: stub,
        retrySleep: noSleep, timeoutSleep: neverTimeout)
    return (service, stub)
}

// MARK: - createSession / fetchState

@Test func createSessionSendsUserFieldsAndDecodes() async throws {
    let (service, stub) = makeService { request in
        (createSessionBody, makeResponse(url: request.url!.absoluteString, status: 200))
    }

    let session = try await service.createSession(
        workflowID: "wf-1", user: sampleUser, expiresInHours: 24)

    let request = try #require(await stub.recorder.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/workflows/wf-1/sessions")

    let json =
        try JSONSerialization.jsonObject(with: try #require(request.httpBody))
        as? [String: Any]
    #expect(json?["email"] as? String == "user@example.com")
    #expect(json?["first_name"] as? String == "Ada")
    #expect(json?["last_name"] as? String == "Lovelace")
    #expect(json?["phone"] as? String == "+15555550100")
    #expect(json?["external_id"] as? String == "ext-1")
    #expect(json?["expires_in_hours"] as? Int == 24)

    #expect(session.sessionID == "sess-1")
    #expect(session.currentStep == 0)
    #expect(session.steps.count == 1)
}

@Test func fetchStateBuildsPathAndDecodes() async throws {
    let (service, stub) = makeService { request in
        (stateBody, makeResponse(url: request.url!.absoluteString, status: 200))
    }

    let state = try await service.fetchState(sessionID: "sess-1")

    let request = try #require(await stub.recorder.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/v1/sessions/sess-1/workflow")
    #expect(state.sessionID == "sess-1")
    #expect(state.sessionProgress == .started)
    #expect(state.attemptsRemaining == 2)
}

// MARK: - startRun

@Test func startRunPostsToStartPathAndDecodesState() async throws {
    let (service, stub) = makeService { request in
        (stateBody, makeResponse(url: request.url!.absoluteString, status: 200))
    }

    let state = try await service.startRun(sessionID: "sess-1")

    let request = try #require(await stub.recorder.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/sessions/sess-1/workflow/start")

    // Validate-only handover: the path carries everything the server needs.
    let json =
        try JSONSerialization.jsonObject(with: try #require(request.httpBody))
        as? [String: Any]
    #expect(json?.isEmpty == true)

    #expect(state.sessionID == "sess-1")
    #expect(state.currentStep == 0)
    #expect(state.attemptsRemaining == 2)
    #expect(state.steps.first?.stepID == .idVerification)
}

@Test func startRunOnStartedSessionSurfacesConflict() async {
    let alreadyStartedBody = Data(
        """
        {
          "error": "Session has already been started",
          "current_step": null
        }
        """.utf8)
    let (service, _) = makeService { request in
        (alreadyStartedBody, makeResponse(url: request.url!.absoluteString, status: 409))
    }

    do {
        _ = try await service.startRun(sessionID: "sess-1")
        Issue.record("expected a conflict error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .conflict)
        #expect(error.conflict?.currentStep == nil)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

// MARK: - submitIDVerification

@Test func submitIDVerificationEncodesUploadsAndDecodesEmptyPayload() async throws {
    let (service, stub) = makeService { request in
        (idSubmitBody, makeResponse(url: request.url!.absoluteString, status: 200))
    }

    let submission = IDVerificationSubmission(
        documentType: "drivers-license",
        secondaryDocumentType: "passport",
        tertiaryDocumentType: nil,
        uploads: [
            .idFront: "org/sess/front.jpg",
            .selfieFront: "org/sess/selfie.jpg",
        ])

    let result = try await service.submitIDVerification(
        sessionID: "sess-1", submission: submission)

    let request = try #require(await stub.recorder.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/sessions/sess-1/steps/ID_VERIFICATION")

    let json =
        try JSONSerialization.jsonObject(with: try #require(request.httpBody))
        as? [String: Any]
    #expect(json?["document_type"] as? String == "drivers-license")
    #expect(json?["secondary_document_type"] as? String == "passport")
    #expect(json?["tertiary_document_type"] == nil)
    let uploads = try #require(json?["uploads"] as? [String: String])
    #expect(uploads["id_front"] == "org/sess/front.jpg")
    #expect(uploads["selfie_front"] == "org/sess/selfie.jpg")

    #expect(result.stepID == .idVerification)
    #expect(result.stepStatus == .completed)
    #expect(result.currentStep == 1)
    #expect(result.payload == EmptyStepPayload())
}
