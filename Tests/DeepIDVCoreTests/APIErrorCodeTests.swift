import Foundation
import Testing

@testable import DeepIDVCore

// MARK: - Helpers

private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

/// Runs one GET against a canned response and returns the error it maps to.
private func mappedError(status: Int, body: String) async -> DeepIDVError? {
    let stub = HTTPTransportStub { _ in
        let response = HTTPURLResponse(
            url: URL(string: "https://api.deepidv.com/v1/test")!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: [:])!
        return (Data(body.utf8), response)
    }
    let config = DeepIDVConfig(apiKey: "sk_live_secret_abcd1234", timeout: 30, maxRetries: 0)
    let client = APIClient(
        config: config, transport: stub, retrySleep: noSleep, timeoutSleep: neverTimeout)
    do {
        let _: EmptyStepPayload = try await client.get("/v1/test")
        return nil
    } catch {
        return error as? DeepIDVError
    }
}

// MARK: - Body `code` mapping

@Test(arguments: [
    (400, "INVALID_MEDIA", DeepIDVError.Kind.validation),
    (401, "UNAUTHENTICATED", .authentication),
    (402, "INSUFFICIENT_FUNDS", .insufficientFunds),
    (403, "FORBIDDEN", .authorization),
    (404, "SESSION_NOT_FOUND", .notFound),
    (409, "STEP_OUT_OF_ORDER", .conflict),
    (429, "RATE_LIMITED", .rateLimit),
    (500, "INTERNAL_ERROR", .api),
    (503, "INTERNAL_ERROR", .serviceUnavailable),
])
func apiCodeIsReadFromTheBodyForEveryStatus(
    status: Int, code: String, kind: DeepIDVError.Kind
) async throws {
    let error = try #require(
        await mappedError(status: status, body: #"{"error":"Nope","code":"\#(code)"}"#))
    #expect(error.kind == kind)
    #expect(error.apiCode == APIErrorCode(rawValue: code))
}

@Test func jsonPaymentRequiredKeepsItsMessageAndCode() async throws {
    let error = try #require(
        await mappedError(
            status: 402, body: #"{"error":"Insufficient funds","code":"INSUFFICIENT_FUNDS"}"#))
    #expect(error.kind == .insufficientFunds)
    #expect(error.message == "Insufficient funds")
    #expect(error.apiCode == .insufficientFunds)
    #expect(error.code == "insufficient_funds_error")
}

@Test func conflictCarriesCodeAlongsideConflictInfo() async throws {
    let error = try #require(
        await mappedError(
            status: 409,
            body:
                #"{"error":"Frames missing","code":"LIVENESS_UPLOAD_INCOMPLETE","current_step":1,"step_id":"FACE_LIVENESS"}"#
        ))
    #expect(error.apiCode == .livenessUploadIncomplete)
    #expect(error.conflict?.currentStep == 1)
    #expect(error.conflict?.stepID == "FACE_LIVENESS")
}

@Test(arguments: [
    (402, "Insufficient funds"),
    (500, "<html>Bad Gateway</html>"),
    (404, #"{"error":"Session not found"}"#),
    (400, #"{"error":"Bad","code":42}"#),
    (400, #"["code","VALIDATION_ERROR"]"#),
])
func apiCodeIsNilWithoutAStringCodeInAJSONObject(status: Int, body: String) async throws {
    let error = try #require(await mappedError(status: status, body: body))
    #expect(error.apiCode == nil)
}

// MARK: - SDK-originated errors

@Test func sdkOriginatedErrorsHaveNoAPICode() {
    #expect(DeepIDVError.network("offline").apiCode == nil)
    #expect(DeepIDVError.timeout("slow").apiCode == nil)
    #expect(DeepIDVError.cancelled("bye").apiCode == nil)
    #expect(DeepIDVError.captureFailed("camera").apiCode == nil)
    #expect(DeepIDVError.validation("bad input").apiCode == nil)
}

@Test func apiCodeIsPartOfEqualityAndDescription() {
    let plain = DeepIDVError.conflict("Conflict", info: nil)
    let coded = DeepIDVError.conflict("Conflict", info: nil, apiCode: .stepConflict)
    #expect(plain != coded)
    #expect(coded.description.contains("apiCode: STEP_CONFLICT"))
    #expect(!plain.description.contains("apiCode"))
}
