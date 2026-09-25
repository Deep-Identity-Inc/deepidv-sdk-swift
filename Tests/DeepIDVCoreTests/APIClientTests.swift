import Foundation
import Testing

@testable import DeepIDVCore

// MARK: - Test helpers

/// A small Codable model used as the success payload for client requests.
private struct Echo: Codable, Equatable {
    let ok: Bool
}

/// Builds an `HTTPURLResponse` for the canned stub responses.
private func makeResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.deepidv.com/v1/test")!,
        statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

/// A "never fires" timeout sleeper for tests that aren't exercising the timeout
/// path: it parks for an hour, but the transport always wins the race first, so
/// the group cancels this immediately — no real waiting ever happens.
private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

/// Builds an `APIClient` wired to `stub` with instant retry backoff and a
/// non-firing timeout by default, so tests run without touching the wall clock.
private func makeClient(
    stub: HTTPTransportStub,
    apiKey: String = "sk_live_secret_abcd1234",
    timeout: TimeInterval = 30,
    maxRetries: Int = 3,
    retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
    timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = neverTimeout
) -> APIClient {
    let config = DeepIDVConfig(apiKey: apiKey, timeout: timeout, maxRetries: maxRetries)
    return APIClient(
        config: config, transport: stub, retrySleep: retrySleep, timeoutSleep: timeoutSleep)
}

/// Plays back a fixed sequence of `(status, body)` responses across calls,
/// repeating the last one once exhausted. Used to model "503 then 200".
private actor ResponseSequencer {
    private let responses: [(Int, Data)]
    private var index = 0

    init(_ responses: [(Int, Data)]) { self.responses = responses }

    func next() -> (Int, Data) {
        let response = responses[Swift.min(index, responses.count - 1)]
        index += 1
        return response
    }
}

// MARK: - Status → kind/code mapping

@Test func test400MapsToValidation() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 400)) }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected a validation error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
        #expect(error.code == "validation_error")
        #expect(error.status == 400)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func test401MapsToAuthentication() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 401)) }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected an authentication error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .authentication)
        #expect(error.code == "authentication_error")
        #expect(error.status == 401)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func test402MapsToInsufficientFunds() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 402)) }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected an insufficient-funds error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .insufficientFunds)
        #expect(error.code == "insufficient_funds_error")
        #expect(error.status == 402)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func test403MapsToAuthorization() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 403)) }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected an authorization error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .authorization)
        #expect(error.code == "authorization_error")
        #expect(error.status == 403)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func test404MapsToNotFound() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 404)) }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected a not-found error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .notFound)
        #expect(error.code == "not_found_error")
        #expect(error.status == 404)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func test429MapsToRateLimitWithRetryAfter() async {
    let stub = HTTPTransportStub { _ in
        (Data(), makeResponse(status: 429, headers: ["Retry-After": "7"]))
    }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected a rate-limit error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .rateLimit)
        #expect(error.code == "rate_limit_error")
        #expect(error.retryAfter == 7)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func test503MapsToServiceUnavailable() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 503)) }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected a service-unavailable error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .serviceUnavailable)
        #expect(error.code == "service_unavailable_error")
        #expect(error.status == 503)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func testOther5xxMapsToAPIError() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 500)) }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected an api error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .api)
        #expect(error.code == "api_error")
        #expect(error.status == 500)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func testOther4xxMapsToAPIError() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 418)) }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected an api error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .api)
        #expect(error.code == "api_error")
        #expect(error.status == 418)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

// MARK: - API-key redaction

@Test func test401RedactsApiKeyAndNeverLeaksIt() async {
    let fullKey = "sk_live_supersecret_abcd1234"
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 401)) }
    let client = makeClient(stub: stub, apiKey: fullKey, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected an authentication error")
    } catch let error as DeepIDVError {
        #expect(!error.message.contains(fullKey))  // full key never appears
        #expect(!error.description.contains(fullKey))
        #expect(error.message.contains("sk_...1234"))  // redacted reference present
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

// MARK: - Message extraction

@Test func testMessageExtractionPlainText() async {
    let stub = HTTPTransportStub { _ in
        (Data("Not enough credits".utf8), makeResponse(status: 402))
    }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected an error")
    } catch let error as DeepIDVError {
        #expect(error.message == "Not enough credits")
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func testMessageExtractionJSONMessageField() async {
    let stub = HTTPTransportStub { _ in
        (Data(#"{"message":"missing field"}"#.utf8), makeResponse(status: 400))
    }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected an error")
    } catch let error as DeepIDVError {
        #expect(error.message == "missing field")
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func testMessageExtractionJSONErrorField() async {
    let stub = HTTPTransportStub { _ in
        (Data(#"{"error":"something broke"}"#.utf8), makeResponse(status: 400))
    }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected an error")
    } catch let error as DeepIDVError {
        #expect(error.message == "something broke")
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func testMessageExtractionFallsBackToHTTPStatus() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 500)) }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected an error")
    } catch let error as DeepIDVError {
        #expect(error.message == "HTTP 500")
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

// MARK: - Success path

@Test func testSuccessDecodesBody() async throws {
    let body = try JSONEncoder().encode(Echo(ok: true))
    let stub = HTTPTransportStub { _ in (body, makeResponse(status: 200)) }
    let client = makeClient(stub: stub)

    let result: Echo = try await client.get("/v1/test")
    #expect(result == Echo(ok: true))
}

@Test func testDecodeFailureOn2xxMapsToAPIError() async {
    let stub = HTTPTransportStub { _ in
        (Data(#"{"unexpected":1}"#.utf8), makeResponse(status: 200))
    }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected a decode error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .api)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

// MARK: - Header building

@Test func testGetOmitsContentTypeAndCarriesAuthHeaders() async throws {
    let body = try JSONEncoder().encode(Echo(ok: true))
    let stub = HTTPTransportStub { _ in (body, makeResponse(status: 200)) }
    let client = makeClient(stub: stub, apiKey: "test-key")

    let _: Echo = try await client.get("/v1/test")

    let requests = await stub.recorder.requests
    let request = requests[0]
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
}

@Test func testPostIncludesContentTypeAndBody() async throws {
    let body = try JSONEncoder().encode(Echo(ok: true))
    let stub = HTTPTransportStub { _ in (body, makeResponse(status: 200)) }
    let client = makeClient(stub: stub)

    let _: Echo = try await client.post("/v1/test", body: Echo(ok: true))

    let requests = await stub.recorder.requests
    let request = requests[0]
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.httpBody != nil)
}

@Test func testSDKHeadersOverrideCallerHeaders() async throws {
    let body = try JSONEncoder().encode(Echo(ok: true))
    let stub = HTTPTransportStub { _ in (body, makeResponse(status: 200)) }
    let client = makeClient(stub: stub, apiKey: "sdk-key")
    let options = RequestOptions(headers: [
        "x-api-key": "caller-key",
        "Content-Type": "text/plain",
        "Idempotency-Key": "idem-123",
    ])

    let _: Echo = try await client.post("/v1/test", body: Echo(ok: true), options: options)

    let requests = await stub.recorder.requests
    let request = requests[0]
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sdk-key")  // SDK wins
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")  // SDK wins
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "idem-123")  // caller survives
}

// MARK: - URL joining

@Test func testRequestJoinsBaseAndPath() async throws {
    let body = try JSONEncoder().encode(Echo(ok: true))
    let stub = HTTPTransportStub { _ in (body, makeResponse(status: 200)) }
    let client = makeClient(stub: stub)

    let _: Echo = try await client.get("/v1/sessions/abc123")

    let requests = await stub.recorder.requests
    #expect(requests[0].url?.absoluteString == "https://api.deepidv.com/v1/sessions/abc123")
}

// MARK: - Per-attempt timeout

@Test func testPerAttemptTimeoutThrowsTimeout() async {
    // Transport hangs; the injected timeout sleeper fires immediately, so the
    // race resolves to `.timeout`.
    let stub = HTTPTransportStub { _ in
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
        return (Data(), makeResponse(status: 200))
    }
    let client = makeClient(stub: stub, maxRetries: 0, timeoutSleep: { _ in })
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected a timeout error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .timeout)
        #expect(error.code == "timeout_error")
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let count = await stub.recorder.requests.count
    #expect(count == 1)  // maxRetries 0 → single attempt
}

// MARK: - Transport failures

@Test func testTransportFailureMapsToNetwork() async {
    let stub = HTTPTransportStub { _ in throw URLError(.notConnectedToInternet) }
    let client = makeClient(stub: stub, maxRetries: 0)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected a network error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .network)
        #expect(error.code == "network_error")
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

// MARK: - Per-request overrides

@Test func testTimeoutOverridePropagatesToRequest() async throws {
    let body = try JSONEncoder().encode(Echo(ok: true))
    let stub = HTTPTransportStub { _ in (body, makeResponse(status: 200)) }
    let client = makeClient(stub: stub, timeout: 30)

    let _: Echo = try await client.get("/v1/test", options: RequestOptions(timeout: 5))

    let requests = await stub.recorder.requests
    #expect(requests[0].timeoutInterval == 5)
}

@Test func testTimeoutFallsBackToConfig() async throws {
    let body = try JSONEncoder().encode(Echo(ok: true))
    let stub = HTTPTransportStub { _ in (body, makeResponse(status: 200)) }
    let client = makeClient(stub: stub, timeout: 17)

    let _: Echo = try await client.get("/v1/test")

    let requests = await stub.recorder.requests
    #expect(requests[0].timeoutInterval == 17)
}

@Test func testMaxRetriesOverrideZeroDoesNotRetry() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 503)) }
    let client = makeClient(stub: stub, maxRetries: 3)  // config allows retries...
    do {
        // ...but the per-request override disables them.
        let _: Echo = try await client.get("/v1/test", options: RequestOptions(maxRetries: 0))
        Issue.record("expected a service-unavailable error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .serviceUnavailable)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let count = await stub.recorder.requests.count
    #expect(count == 1)  // no retries
}

@Test func testMaxRetriesFallsBackToConfig() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 503)) }
    let client = makeClient(stub: stub, maxRetries: 2)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected a service-unavailable error")
    } catch is DeepIDVError {
        // expected
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let count = await stub.recorder.requests.count
    #expect(count == 3)  // 1 initial + 2 retries
}

// MARK: - Retry composition

@Test func testRetriesOn503ThenSucceeds() async throws {
    let ok = try JSONEncoder().encode(Echo(ok: true))
    let sequencer = ResponseSequencer([(503, Data()), (200, ok)])
    let stub = HTTPTransportStub { _ in
        let (status, data) = await sequencer.next()
        return (data, makeResponse(status: status))
    }
    let client = makeClient(stub: stub, maxRetries: 3)

    let result: Echo = try await client.get("/v1/test")

    #expect(result == Echo(ok: true))
    let count = await stub.recorder.requests.count
    #expect(count == 2)  // 503, then 200
}

@Test func testDoesNotRetryOn400() async {
    let stub = HTTPTransportStub { _ in (Data(), makeResponse(status: 400)) }
    let client = makeClient(stub: stub, maxRetries: 3)
    do {
        let _: Echo = try await client.get("/v1/test")
        Issue.record("expected a validation error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let count = await stub.recorder.requests.count
    #expect(count == 1)  // 400 is non-retryable
}
