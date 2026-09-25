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
    url: String = "https://api.deepidv.com/v1/test",
    status: Int,
    headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: headers)!
}

private func makeClient(
    stub: HTTPTransportStub,
    maxRetries: Int = 0
) -> APIClient {
    let config = DeepIDVConfig(apiKey: testKey, timeout: 30, maxRetries: maxRetries)
    return APIClient(
        config: config, transport: stub, retrySleep: noSleep, timeoutSleep: neverTimeout)
}

// MARK: - Conflict mapping

@Test func conflictMapsTerminalSessionBody() async throws {
    let body = Data(
        #"{"error":"Session is terminal","current_step":null}"#.utf8)
    let stub = HTTPTransportStub { _ in
        (body, makeResponse(status: 409))
    }
    let client = makeClient(stub: stub)

    do {
        let _: EmptyStepPayload = try await client.get("/v1/test")
        Issue.record("expected a conflict error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .conflict)
        #expect(error.status == 409)
        #expect(error.code == "conflict_error")
        #expect(error.message == "Session is terminal")
        let info = try #require(error.conflict)
        #expect(info.currentStep == nil)
        #expect(info.stepID == nil)
        #expect(info.failureReason == nil)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func conflictMapsOutOfOrderBody() async throws {
    let body = Data(
        #"{"error":"Wrong step","current_step":1,"step_id":"FACE_LIVENESS"}"#.utf8)
    let stub = HTTPTransportStub { _ in
        (body, makeResponse(status: 409))
    }
    let client = makeClient(stub: stub)

    do {
        let _: EmptyStepPayload = try await client.get("/v1/test")
        Issue.record("expected a conflict error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .conflict)
        let info = try #require(error.conflict)
        #expect(info.currentStep == 1)
        #expect(info.stepID == "FACE_LIVENESS")
        #expect(info.failureReason == nil)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func conflictMapsConcurrentDuplicateBody() async throws {
    let body = Data(
        #"{"error":"Conflict","current_step":0,"step_id":"ID_VERIFICATION"}"#.utf8)
    let stub = HTTPTransportStub { _ in
        (body, makeResponse(status: 409))
    }
    let client = makeClient(stub: stub)

    do {
        let _: EmptyStepPayload = try await client.get("/v1/test")
        Issue.record("expected a conflict error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .conflict)
        let info = try #require(error.conflict)
        #expect(info.currentStep == 0)
        #expect(info.stepID == "ID_VERIFICATION")
        #expect(info.failureReason == nil)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func conflictMapsNotReadyBody() async throws {
    let body = Data(
        """
        {
          "error": "Result not ready",
          "current_step": 1,
          "step_id": "FACE_LIVENESS",
          "failure_reason": "FACE_LIVENESS_RESULT_NOT_READY"
        }
        """.utf8)
    let stub = HTTPTransportStub { _ in
        (body, makeResponse(status: 409))
    }
    let client = makeClient(stub: stub)

    do {
        let _: EmptyStepPayload = try await client.get("/v1/test")
        Issue.record("expected a conflict error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .conflict)
        let info = try #require(error.conflict)
        #expect(info.currentStep == 1)
        #expect(info.stepID == "FACE_LIVENESS")
        #expect(info.failureReason == "FACE_LIVENESS_RESULT_NOT_READY")
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func conflictWithNonJSONBodyHasNilInfo() async {
    let stub = HTTPTransportStub { _ in
        (Data("plain conflict".utf8), makeResponse(status: 409))
    }
    let client = makeClient(stub: stub)

    do {
        let _: EmptyStepPayload = try await client.get("/v1/test")
        Issue.record("expected a conflict error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .conflict)
        #expect(error.conflict == nil)
        #expect(error.message == "plain conflict")
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func conflictIsNotRetryable() {
    let error = DeepIDVError.conflict(
        "Session is terminal",
        info: ConflictInfo(currentStep: nil, stepID: nil, failureReason: nil))
    #expect(isRetryable(error) == false)
}
