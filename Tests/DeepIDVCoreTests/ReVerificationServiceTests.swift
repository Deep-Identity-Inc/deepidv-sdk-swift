import Foundation
import Testing

@testable import DeepIDVCore

// MARK: - Helpers

private let testKey = "sk_live_secret_abcd1234"
private let reVerificationID = "5f0c6a52-2d0e-4c1b-9b8e-3f7a1d2e4c6b"

private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

private actor SleepRecorder {
    private(set) var intervals: [TimeInterval] = []
    func record(_ interval: TimeInterval) { intervals.append(interval) }
}

private actor CallCounter {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private func makeResponse(status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.test")!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: [:])!
}

private func makeService(
    timeout: TimeInterval = 30,
    maxRetries: Int = 3,
    timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = neverTimeout,
    handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
) -> (ReVerificationService, HTTPTransportStub) {
    let stub = HTTPTransportStub(handler: handler)
    let config = DeepIDVConfig(apiKey: testKey, timeout: timeout, maxRetries: maxRetries)
    let service = ReVerificationService(
        config: config, transport: stub, retrySleep: noSleep, timeoutSleep: timeoutSleep)
    return (service, stub)
}

/// Runs `operation`, expecting it to throw a `DeepIDVError`, and returns it.
private func captureError(
    _ operation: () async throws -> Void
) async -> DeepIDVError? {
    do {
        try await operation()
        Issue.record("expected a DeepIDVError")
    } catch let error as DeepIDVError {
        return error
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
    return nil
}

/// Parses a recorded request's JSON body into a dictionary.
private func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
    let data = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Fixtures (§4.6 wire shapes)

private func createBody(challengeType: ChallengeType) -> Data {
    Data(
        """
        {"re_verification_id":"\(reVerificationID)","workflow_id":"wf-1","status":"PENDING",
         "expires_at":"2026-09-24T12:15:00.000Z",
         "liveness":{"challenge_type":"\(challengeType.rawValue)"}}
        """.utf8)
}

private let lightStartBody = Data(
    """
    {"liveness_session_id":"lv-1",
     "script":{"challengeType":"FaceMovementAndLightChallenge","durationMs":4000,
               "steps":[{"kind":"move-closer","atMs":0},{"kind":"color","atMs":1500,"color":"#FF0000"}]}}
    """.utf8)

private let uploadURLsBody = Data(
    """
    {"frame_upload_urls":["https://s3.test/f0","https://s3.test/f1","https://s3.test/f2"],
     "frame_keys":["k/frame_0.jpg","k/frame_1.jpg","k/frame_2.jpg"],
     "timeline_upload_url":"https://s3.test/t","timeline_key":"k/timeline.json"}
    """.utf8)

private let uploadURLsWithClipBody = Data(
    """
    {"frame_upload_urls":["https://s3.test/f0","https://s3.test/f1","https://s3.test/f2"],
     "frame_keys":["k/frame_0.jpg","k/frame_1.jpg","k/frame_2.jpg"],
     "timeline_upload_url":"https://s3.test/t","timeline_key":"k/timeline.json",
     "clip_upload_url":"https://s3.test/c","clip_key":"k/clip.mp4"}
    """.utf8)

private let verifiedOutcomeBody = Data(
    """
    {"decision":"verified","failed_attempts":0,"max_attempts":3,
     "liveness":{"status":"SUCCEEDED","confidence":91.2},
     "user_id":"user-1","original_session_id":"sess-orig"}
    """.utf8)

// MARK: - create (AC #1)

struct ReVerificationServiceTests {
    @Test(arguments: [ChallengeType.faceMovement, .faceMovementAndLight])
    func createSendsWorkflowIDOnlyAndDecodesSession(challengeType: ChallengeType) async throws {
        let (service, stub) = makeService { _ in
            (createBody(challengeType: challengeType), makeResponse(status: 201))
        }

        let session = try await service.create(workflowID: "wf-1")

        #expect(session.reVerificationID == reVerificationID)
        #expect(session.workflowID == "wf-1")
        #expect(session.status == "PENDING")
        #expect(session.expiresAt == "2026-09-24T12:15:00.000Z")
        #expect(session.livenessChallengeType == challengeType)

        let requests = await stub.recorder.requests
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.path == "/v1/re-verifications")
        #expect(requests[0].timeoutInterval == 30)  // config.timeout, no floor
        let body = try jsonBody(requests[0])
        #expect(Set(body.keys) == ["workflow_id"])  // no device_fingerprint
        #expect(body["workflow_id"] as? String == "wf-1")
    }

    /// `create` keeps the default retry policy: a 503 is retried and the
    /// following 201 succeeds.
    @Test func createStillRetriesOn503() async throws {
        let counter = CallCounter()
        let (service, stub) = makeService(maxRetries: 3) { _ in
            let call = await counter.next()
            return call == 1
                ? (Data(), makeResponse(status: 503))
                : (createBody(challengeType: .faceMovement), makeResponse(status: 201))
        }

        let session = try await service.create(workflowID: "wf-1")

        #expect(session.reVerificationID == reVerificationID)
        let count = await stub.recorder.requests.count
        #expect(count == 2)
    }

    // MARK: - startLiveness (AC #2)

    @Test func startLivenessPostsEmptyBodyAndDecodesLightScript() async throws {
        let (service, stub) = makeService { _ in (lightStartBody, makeResponse(status: 200)) }

        let session = try await service.startLiveness(id: reVerificationID)

        #expect(session.livenessSessionID == "lv-1")
        #expect(session.script.challengeType == .faceMovementAndLight)
        #expect(session.script.durationMs == 4000)
        #expect(
            session.script.steps == [
                ChallengeStep(kind: "move-closer", atMs: 0),
                ChallengeStep(kind: "color", atMs: 1500, color: "#FF0000"),
            ])

        let requests = await stub.recorder.requests
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.path == "/v1/re-verifications/\(reVerificationID)/liveness/start")
        #expect(try jsonBody(requests[0]).isEmpty)
    }

    /// `script` is required on this route, so its absence is an ordinary
    /// decode failure — no credentials branch, no special case.
    @Test func startLivenessWithoutScriptIsDecodeFailure() async throws {
        let (service, _) = makeService { _ in
            (Data(#"{"liveness_session_id":"lv-1"}"#.utf8), makeResponse(status: 200))
        }

        let error = try #require(
            await captureError { _ = try await service.startLiveness(id: reVerificationID) })
        #expect(error.kind == .api)
        #expect(error.message.hasPrefix("Failed to decode response body"))
    }

    // MARK: - requestUploadURLs (AC #3)

    @Test func requestUploadURLsWithoutClipOmitsClipMimeType() async throws {
        let (service, stub) = makeService { _ in (uploadURLsBody, makeResponse(status: 200)) }

        let urls = try await service.requestUploadURLs(id: reVerificationID, frameCount: 3)

        #expect(urls.frameUploadURLs.count == 3)
        #expect(urls.frameKeys == ["k/frame_0.jpg", "k/frame_1.jpg", "k/frame_2.jpg"])
        #expect(urls.timelineUploadURL == URL(string: "https://s3.test/t"))
        #expect(urls.timelineKey == "k/timeline.json")
        #expect(urls.clipUploadURL == nil)
        #expect(urls.clipKey == nil)

        let requests = await stub.recorder.requests
        #expect(requests[0].httpMethod == "POST")
        #expect(
            requests[0].url?.path == "/v1/re-verifications/\(reVerificationID)/liveness/upload-url")
        let body = try jsonBody(requests[0])
        #expect(Set(body.keys) == ["frame_count"])  // absent, never `null`
        #expect(body["frame_count"] as? Int == 3)
        let raw = try #require(requests[0].httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(!raw.contains("null"))
    }

    @Test func requestUploadURLsWithClipSendsMimeAndDecodesClipURL() async throws {
        let (service, stub) = makeService { _ in
            (uploadURLsWithClipBody, makeResponse(status: 200))
        }

        let urls = try await service.requestUploadURLs(
            id: reVerificationID, frameCount: 8, clipMimeType: "video/mp4")

        #expect(urls.clipUploadURL == URL(string: "https://s3.test/c"))
        #expect(urls.clipKey == "k/clip.mp4")

        let requests = await stub.recorder.requests
        let body = try jsonBody(requests[0])
        #expect(Set(body.keys) == ["frame_count", "clip_mime_type"])
        #expect(body["frame_count"] as? Int == 8)
        #expect(body["clip_mime_type"] as? String == "video/mp4")
    }

    // MARK: - completeLiveness (AC #4)

    @Test func completeLivenessPostsEmptyBodyAndDecodesOutcome() async throws {
        let (service, stub) = makeService { _ in (verifiedOutcomeBody, makeResponse(status: 200)) }

        let outcome = try await service.completeLiveness(id: reVerificationID)

        #expect(outcome.decision == .verified)
        #expect(outcome.attempts == ReVerifyAttempts(failed: 0, max: 3))
        #expect(outcome.livenessStatus == .succeeded)
        #expect(outcome.livenessConfidence == 91.2)
        #expect(outcome.userID == "user-1")
        #expect(outcome.originalSessionID == "sess-orig")

        let requests = await stub.recorder.requests
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "POST")
        #expect(
            requests[0].url?.path == "/v1/re-verifications/\(reVerificationID)/liveness/complete")
        #expect(try jsonBody(requests[0]).isEmpty)
    }

    /// The server enum is closed: an unknown decision is a contract change and
    /// surfaces as a decode failure, not a fallback.
    @Test func completeLivenessUnknownDecisionIsDecodeFailure() async throws {
        let (service, _) = makeService { _ in
            (
                Data(
                    #"{"decision":"maybe","failed_attempts":0,"max_attempts":3,"liveness":{"status":"SUCCEEDED","confidence":90}}"#
                        .utf8),
                makeResponse(status: 200)
            )
        }

        let error = try #require(
            await captureError { _ = try await service.completeLiveness(id: reVerificationID) })
        #expect(error.kind == .api)
        #expect(error.message.hasPrefix("Failed to decode response body"))
    }

    /// `complete` never waits less than 60 s; a larger host timeout is honoured.
    /// Both the request's `timeoutInterval` and the timeout-race seam see it.
    @Test(arguments: zip([30.0, 90.0], [60.0, 90.0]))
    func completeLivenessAppliesTimeoutFloor(
        configTimeout: TimeInterval, expected: TimeInterval
    ) async throws {
        let sleeps = SleepRecorder()
        let (service, stub) = makeService(
            timeout: configTimeout,
            timeoutSleep: { interval in
                await sleeps.record(interval)
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            },
            handler: { _ in (verifiedOutcomeBody, makeResponse(status: 200)) })

        _ = try await service.completeLiveness(id: reVerificationID)

        let requests = await stub.recorder.requests
        #expect(requests[0].timeoutInterval == expected)
        #expect(await sleeps.intervals == [expected])
    }

    /// Failures `APIClient` would normally retry — plus a 409 — reach the
    /// caller after exactly one transport call: no retry, no poll.
    enum CompleteFailure: String, CaseIterable, Sendable {
        case serviceUnavailable503
        case gatewayTimeout504
        case conflict409
        case urlTimedOut
        case connectionLost
    }

    @Test(arguments: CompleteFailure.allCases)
    func completeLivenessMakesExactlyOneCall(failure: CompleteFailure) async throws {
        let (service, stub) = makeService(maxRetries: 3) { _ in
            switch failure {
            case .serviceUnavailable503: return (Data(), makeResponse(status: 503))
            case .gatewayTimeout504: return (Data(), makeResponse(status: 504))
            case .conflict409:
                return (Data(#"{"error":"liveness_not_started"}"#.utf8), makeResponse(status: 409))
            case .urlTimedOut: throw URLError(.timedOut)
            case .connectionLost: throw URLError(.networkConnectionLost)
            }
        }

        let error = try #require(
            await captureError { _ = try await service.completeLiveness(id: reVerificationID) })
        switch failure {
        case .serviceUnavailable503: #expect(error.kind == .serviceUnavailable)
        case .gatewayTimeout504: #expect(error.kind == .api && error.status == 504)
        case .conflict409: #expect(error.kind == .conflict)
        case .urlTimedOut: #expect(error.kind == .timeout)
        case .connectionLost: #expect(error.kind == .network)
        }
        let count = await stub.recorder.requests.count
        #expect(count == 1)
    }

    /// The per-attempt timeout race firing is not retried either.
    @Test func completeLivenessTimeoutRaceIsNotRetried() async throws {
        let (service, stub) = makeService(
            maxRetries: 3,
            timeoutSleep: { _ in },
            handler: { _ in
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
                return (verifiedOutcomeBody, makeResponse(status: 200))
            })

        let error = try #require(
            await captureError { _ = try await service.completeLiveness(id: reVerificationID) })
        #expect(error.kind == .timeout)
        let count = await stub.recorder.requests.count
        #expect(count == 1)
    }
}

// MARK: - Error remap (AC #5)

/// The four routes, so a remap case can name which one it runs against.
enum ReVerifyRoute: String, Sendable {
    case create, start, uploadURL, complete
}

private func call(_ route: ReVerifyRoute, on service: ReVerificationService) async throws {
    switch route {
    case .create: _ = try await service.create(workflowID: "wf-1")
    case .start: _ = try await service.startLiveness(id: reVerificationID)
    case .uploadURL: _ = try await service.requestUploadURLs(id: reVerificationID, frameCount: 3)
    case .complete: _ = try await service.completeLiveness(id: reVerificationID)
    }
}

/// One row of the §4.4 table, on a route that returns it.
struct RemapCase: Sendable, CustomTestStringConvertible {
    let code: String
    let status: Int
    let route: ReVerifyRoute
    let kind: DeepIDVError.Kind
    let message: String

    var testDescription: String { "\(code) (\(status)) on \(route.rawValue)" }
}

private let notFoundMessage = "Re-verification isn't available here."
private let notStartedMessage = "No liveness check is in progress. Please start again."
private let expiredMessage = "This re-verification has expired. Please start again."
private let completedMessage = "This re-verification has already finished."

private let remapCases: [RemapCase] = [
    // not_found — every route
    RemapCase(
        code: "not_found", status: 404, route: .create, kind: .notFound, message: notFoundMessage),
    RemapCase(
        code: "not_found", status: 404, route: .start, kind: .notFound, message: notFoundMessage),
    RemapCase(
        code: "not_found", status: 404, route: .uploadURL, kind: .notFound,
        message: notFoundMessage),
    RemapCase(
        code: "not_found", status: 404, route: .complete, kind: .notFound,
        message: notFoundMessage),
    // reverify_disabled — create
    RemapCase(
        code: "reverify_disabled", status: 422, route: .create, kind: .api,
        message: "Re-verification isn't enabled for this workflow."),
    // liveness_not_started — upload-url, complete
    RemapCase(
        code: "liveness_not_started", status: 409, route: .uploadURL, kind: .conflict,
        message: notStartedMessage),
    RemapCase(
        code: "liveness_not_started", status: 409, route: .complete, kind: .conflict,
        message: notStartedMessage),
    // liveness_upload_incomplete — complete
    RemapCase(
        code: "liveness_upload_incomplete", status: 409, route: .complete, kind: .conflict,
        message: "Your capture didn't finish uploading. Please try again."),
    // expired — start, upload-url, complete
    RemapCase(
        code: "expired", status: 409, route: .start, kind: .conflict, message: expiredMessage),
    RemapCase(
        code: "expired", status: 409, route: .uploadURL, kind: .conflict, message: expiredMessage),
    RemapCase(
        code: "expired", status: 409, route: .complete, kind: .conflict, message: expiredMessage),
    // already_completed — start, upload-url, complete
    RemapCase(
        code: "already_completed", status: 409, route: .start, kind: .conflict,
        message: completedMessage),
    RemapCase(
        code: "already_completed", status: 409, route: .uploadURL, kind: .conflict,
        message: completedMessage),
    RemapCase(
        code: "already_completed", status: 409, route: .complete, kind: .conflict,
        message: completedMessage),
    // insufficient_balance — complete
    RemapCase(
        code: "insufficient_balance", status: 402, route: .complete, kind: .insufficientFunds,
        message: "Re-verification is temporarily unavailable."),
]

struct ReVerificationErrorRemapTests {
    @Test(arguments: remapCases)
    func serverCodeSurfacesAsTypedError(testCase: RemapCase) async throws {
        let body = Data(#"{"error":"\#(testCase.code)"}"#.utf8)
        let (service, stub) = makeService { _ in (body, makeResponse(status: testCase.status)) }

        let error = try #require(await captureError { try await call(testCase.route, on: service) })

        #expect(error.kind == testCase.kind)
        #expect(error.status == testCase.status)
        #expect(error.code == testCase.code)
        #expect(error.message == testCase.message)
        #expect(error.rawResponse?.status == testCase.status)
        #expect(error.rawResponse?.body == body)
        if testCase.status == 409 {
            #expect(
                error.conflict
                    == ConflictInfo(currentStep: nil, stepID: nil, failureReason: testCase.code))
        } else {
            #expect(error.conflict == nil)
        }
        let count = await stub.recorder.requests.count
        #expect(count == 1)  // none of the mapped kinds is retryable
    }

    /// A 403 sandbox body carries a sentence in `error`, not a known code —
    /// it stays exactly as `APIClient` produced it.
    @Test func sandboxForbiddenPassesThroughUnchanged() async throws {
        let sentence = "Sandbox API keys cannot access this endpoint."
        let (service, _) = makeService { _ in
            (Data(#"{"error":"\#(sentence)"}"#.utf8), makeResponse(status: 403))
        }

        let error = try #require(await captureError { try await call(.create, on: service) })

        #expect(error.kind == .authorization)
        #expect(error.status == 403)
        #expect(error.code == "authorization_error")
        #expect(error.message == sentence)
    }

    /// An unrecognised snake_case code is not remapped either.
    @Test func unknownCodePassesThroughUnchanged() async throws {
        let (service, _) = makeService { _ in
            (Data(#"{"error":"some_future_code"}"#.utf8), makeResponse(status: 409))
        }

        let error = try #require(await captureError { try await call(.start, on: service) })

        #expect(error.kind == .conflict)
        #expect(error.code == "conflict_error")
        #expect(error.message == "some_future_code")
        #expect(error.conflict == nil)
    }

    @Test func nonJSONBodyPassesThroughUnchanged() async throws {
        let (service, _) = makeService { _ in
            (Data("upstream conflict".utf8), makeResponse(status: 409))
        }

        let error = try #require(await captureError { try await call(.complete, on: service) })

        #expect(error.kind == .conflict)
        #expect(error.status == 409)
        #expect(error.code == "conflict_error")
        #expect(error.message == "upstream conflict")
        #expect(error.conflict == nil)
    }

    @Test func serverErrorSentencePassesThroughUnchanged() async throws {
        let (service, _) = makeService { _ in
            (Data(#"{"error":"Something went wrong."}"#.utf8), makeResponse(status: 500))
        }

        let error = try #require(await captureError { try await call(.complete, on: service) })

        #expect(error.kind == .api)
        #expect(error.status == 500)
        #expect(error.code == "api_error")
        #expect(error.message == "Something went wrong.")
    }

    @Test func validationErrorPassesThroughUnchanged() async throws {
        let (service, _) = makeService(maxRetries: 0) { _ in
            (
                Data(#"{"message":"Invalid body","hints":[{"path":["frame_count"]}]}"#.utf8),
                makeResponse(status: 400)
            )
        }

        let error = try #require(await captureError { try await call(.uploadURL, on: service) })

        #expect(error.kind == .validation)
        #expect(error.status == 400)
        #expect(error.code == "validation_error")
        #expect(error.message == "Invalid body")
    }
}
