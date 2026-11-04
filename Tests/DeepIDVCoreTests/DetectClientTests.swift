import Foundation
import Testing

@testable import DeepIDVCore

private let testKey = "sk_test_detect_0000"
private let sessionID = "sess-test-1"

private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

private func response(_ request: URLRequest, _ status: Int, headers: [String: String] = [:])
    -> HTTPURLResponse
{
    HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

private let answerBody = Data(
    """
    {"present": true, "box": {"xyxy": [10, 20, 300, 200], "score": 0.95},
     "document_type": {"id": "ca_on_dl", "confidence": 0.83, "top3": [["ca_on_dl", 0.83], ["ca_ab_dl", 0.05]]},
     "model_version": "m-test"}
    """.utf8)

private let request = DetectRequest(
    imageB64: "aGVsbG8=", scanID: "sess-test-1-abc123", frame: 7, method: "dl")

private func makeClient(
    timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = neverTimeout,
    handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
) -> (DetectClient, HTTPTransportStub) {
    let stub = HTTPTransportStub(handler: handler)
    let config = DeepIDVConfig(apiKey: testKey, timeout: 30, maxRetries: 3)
    let api = APIClient(
        config: config, transport: stub, retrySleep: { _ in }, timeoutSleep: timeoutSleep)
    return (DetectClient(client: api, sessionID: sessionID), stub)
}

@Suite struct DetectClientTests {
    @Test func postsTheFrameToTheSessionRelayWithTheAPIKey() async throws {
        let (client, stub) = makeClient { (answerBody, response($0, 200)) }
        let result = try await client.detect(request)

        let sent = try #require(await stub.recorder.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/v1/sessions/sess-test-1/id-capture/detect")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == testKey)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.timeoutInterval == DetectClient.timeout)

        let body = try #require(sent.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["image_b64"] as? String == "aGVsbG8=")
        #expect(json["scan_id"] as? String == "sess-test-1-abc123")
        #expect(json["frame"] as? Int == 7)
        #expect(json["method"] as? String == "dl")
        #expect(json.count == 4)

        guard case .answer(let answer) = result else {
            Issue.record("expected an answer, got \(result)")
            return
        }
        #expect(answer.documentType?.id == "ca_on_dl")
        #expect(answer.modelVersion == "m-test")
        #expect(result.outcome == .answer(answer))
    }

    @Test func aProbeLeavesOutTheFrameNumberAndANoPickLeavesOutTheMethod() async throws {
        let (client, stub) = makeClient { (answerBody, response($0, 200)) }
        _ = try await client.detect(DetectRequest(imageB64: "aGk=", scanID: "scan-abc123"))
        let body = try #require(await stub.recorder.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["image_b64", "scan_id"])
    }

    @Test func neverRetriesAFailedCall() async throws {
        let (client, stub) = makeClient { (Data(), response($0, 503)) }
        let result = try await client.detect(request)
        #expect(await stub.recorder.requests.count == 1)
        #expect(result == .failure(DetectFailure(status: 503, reason: .failed)))
        #expect(result.outcome == .failure(status: 503))
    }

    @Test(arguments: [401, 403, 404, 409])
    func aSessionWithoutTheClassifierIsUnavailable(status: Int) async throws {
        let (client, _) = makeClient { (Data(#"{"message":"no"}"#.utf8), response($0, status)) }
        #expect(
            try await client.detect(request)
                == .failure(DetectFailure(status: status, reason: .unavailable)))
    }

    @Test func aRateLimitCarriesRetryAfter() async throws {
        let (client, _) = makeClient { (Data(), response($0, 429, headers: ["Retry-After": "3"])) }
        #expect(
            try await client.detect(request)
                == .failure(DetectFailure(status: 429, reason: .rateLimited(retryAfter: 3))))
    }

    @Test(arguments: [400, 500, 502, 504])
    func otherErrorsCountAsFailures(status: Int) async throws {
        let (client, _) = makeClient { (Data(), response($0, status)) }
        #expect(
            try await client.detect(request)
                == .failure(DetectFailure(status: status, reason: .failed)))
    }

    @Test func aNetworkErrorIsStatusZero() async throws {
        let (client, _) = makeClient { _ in throw URLError(.notConnectedToInternet) }
        #expect(
            try await client.detect(request) == .failure(DetectFailure(status: 0, reason: .failed)))
    }

    @Test func aTimeoutIsStatusZero() async throws {
        let hang: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return (answerBody, response(request, 200))
        }
        let (client, _) = makeClient(timeoutSleep: { _ in }, handler: hang)
        #expect(
            try await client.detect(request) == .failure(DetectFailure(status: 0, reason: .failed)))
    }

    @Test func anUndecodableAnswerIsAFailure() async throws {
        let (client, _) = makeClient { (Data("not json".utf8), response($0, 200)) }
        #expect(
            try await client.detect(request)
                == .failure(DetectFailure(status: 200, reason: .failed)))
    }

    @Test func cancellationIsThrownNotReported() async {
        let (client, _) = makeClient { request in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return (answerBody, response(request, 200))
        }
        let task = Task { try await client.detect(request) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct DetectPacingTests {
    private func failure(_ status: Int, _ reason: DetectFailure.Reason = .failed) -> DetectResponse
    {
        .failure(DetectFailure(status: status, reason: reason))
    }

    @Test func callsGoAtMostTwiceASecond() {
        let pacing = DetectPacing()
        #expect(pacing.wait(afterCallTaking: 0.1) == 0.4)
        #expect(pacing.wait(afterCallTaking: 0.9) == 0)
    }

    @Test func aRateLimitBacksOffOneTwoFourSeconds() {
        var pacing = DetectPacing()
        var waits: [TimeInterval] = []
        for _ in 0..<4 {
            pacing.record(failure(429, .rateLimited(retryAfter: nil)))
            waits.append(pacing.wait(afterCallTaking: 0))
        }
        #expect(waits == [1, 2, 4, 4])
        pacing.record(.answer(DetectAnswer(present: false)))
        #expect(pacing.wait(afterCallTaking: 0) == DetectPacing.minimumInterval)
    }

    @Test func aRateLimitHonoursRetryAfterUpToTheCap() {
        var pacing = DetectPacing()
        pacing.record(failure(429, .rateLimited(retryAfter: 3)))
        #expect(pacing.backoff == 3)
        pacing.record(failure(429, .rateLimited(retryAfter: 60)))
        #expect(pacing.backoff == 4)
    }

    @Test(arguments: [0, 502, 503, 504])
    func aNetworkErrorOrGatewayFailureWaitsTwoSeconds(status: Int) {
        var pacing = DetectPacing()
        pacing.record(failure(status))
        #expect(pacing.wait(afterCallTaking: 0.3) == 2)
    }

    @Test func otherFailuresKeepTheNormalPace() {
        var pacing = DetectPacing()
        pacing.record(failure(400))
        #expect(pacing.wait(afterCallTaking: 0.2) == 0.3)
    }
}

@Suite struct ScanIDTests {
    @Test func isTheSessionIDPlusSixRandomCharacters() {
        let id = ScanID.make(sessionID: "3f2a9c1e-0000-4000-8000-000000000001", random: "a1b2c3")
        #expect(id == "3f2a9c1e-0000-4000-8000-000000000001-a1b2c3")
        #expect(ScanID.isValid(id))
    }

    @Test func dropsCharactersTheClassifierRefusesAndShortensToFit() {
        #expect(ScanID.make(sessionID: "sess_1/x", random: "abcdef") == "sess1x-abcdef")
        let long = ScanID.make(sessionID: String(repeating: "a", count: 100), random: "abcdef")
        #expect(long.count == ScanID.maxLength)
        #expect(long.hasSuffix("-abcdef"))
        #expect(ScanID.make(sessionID: "__", random: "abcdef") == "scan-abcdef")
    }

    @Test func theRandomPartIsBase36() {
        let random = ScanID.randomBase36()
        #expect(random.count == ScanID.randomLength)
        #expect(random.allSatisfy { $0.isNumber || ("a"..."z").contains($0) })
        #expect(ScanID.isValid(ScanID.make(sessionID: "s")))
    }

    @Test func validityFollowsThePattern() {
        #expect(!ScanID.isValid("short"))
        #expect(!ScanID.isValid("has space-abc"))
        #expect(!ScanID.isValid(String(repeating: "a", count: 65)))
    }

    @Test func groupsHaveTheirWireNames() {
        #expect(
            DocumentGroup.allCases.map(\.wireValue) == [
                "dl", "passport", "national", "pr", "military", "firearm",
            ])
    }
}
