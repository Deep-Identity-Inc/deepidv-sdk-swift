import DeepIDVCore
import Foundation
import Testing

@testable import DeepIDV

// The anti-cheat orchestration model, driven headless against a stubbed
// transport: start → (capture callback) → check → emit. The camera is not
// involved — the view's SelfieCaptureView forwards its Result into
// `imageCaptured`/`captureFailed`, which these tests supply directly.

private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }
private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

private let duplicateBody = Data(#"{"verdict":"DUPLICATE","action":"manual-review"}"#.utf8)

private func ok(_ request: URLRequest, _ body: Data) -> (Data, HTTPURLResponse) {
    (
        body,
        HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
}

private actor RequestLog {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

private struct StubTransport: HTTPTransport {
    let log: RequestLog
    let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await log.record(request)
        return try await handler(request)
    }
}

/// Captures the model's single-per-attempt `onResult`. Mutated only on the
/// main actor, so the unchecked storage is race-free.
private final class AntiCheatResultSpy: @unchecked Sendable {
    var results: [Result<AntiCheatResult, DeepIDVError>] = []
    var value: AntiCheatResult? {
        if case .success(let value) = results.last { return value }
        return nil
    }
    var failureKind: DeepIDVError.Kind? {
        if case .failure(let error) = results.last { return error.kind }
        return nil
    }
}

@MainActor
private func makeModel(
    spy: AntiCheatResultSpy,
    handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
) -> (model: AntiCheatModel, log: RequestLog) {
    let log = RequestLog()
    let service = IGamingService(
        config: DeepIDVConfig(apiKey: "sk_test", maxRetries: 0),
        transport: StubTransport(log: log, handler: handler),
        retrySleep: noSleep, timeoutSleep: neverTimeout)
    let model = AntiCheatModel(
        service: service, sessionID: "sess-1", deviceFingerprint: "fp-9",
        onResult: { spy.results.append($0) })
    return (model, log)
}

private func jpeg() -> FileInput { .data(Data([0xFF, 0xD8, 0xFF, 0xE0])) }

// MARK: - Happy path

@MainActor @Test func capturedImageRunsCheckAndEmitsOnce() async throws {
    let spy = AntiCheatResultSpy()
    let (model, log) = makeModel(spy: spy) { request in ok(request, duplicateBody) }

    #expect(model.state == .idle)
    model.start()
    #expect(model.state == .capturing)

    model.imageCaptured(jpeg())
    #expect(model.state == .checking)
    await model.awaitPendingWork()

    #expect(model.state == .finished(AntiCheatResult(verdict: .duplicate, action: .manualReview)))
    #expect(spy.results.count == 1)
    #expect(spy.value?.verdict == .duplicate)

    let requests = await log.requests
    #expect(requests.count == 1)
    #expect(requests.first?.url?.path == "/v1/igaming/anti-cheat")
}

@MainActor @Test func startIsANoOpUnlessIdle() async {
    let spy = AntiCheatResultSpy()
    let (model, _) = makeModel(spy: spy) { request in ok(request, duplicateBody) }

    model.start()
    model.imageCaptured(jpeg())
    model.start()  // must not reset the in-flight check
    #expect(model.state == .checking)
    await model.awaitPendingWork()
    #expect(spy.results.count == 1)
}

// MARK: - Failure paths

@MainActor @Test func captureFailureEmitsTheError() async {
    let spy = AntiCheatResultSpy()
    let (model, log) = makeModel(spy: spy) { request in ok(request, duplicateBody) }

    model.start()
    model.captureFailed(.cameraPermissionDenied("Camera access is required."))

    #expect(spy.failureKind == .cameraPermissionDenied)
    if case .failed = model.state {} else { Issue.record("expected .failed") }
    #expect(await log.requests.isEmpty)
}

@MainActor @Test func checkFailureEmitsTheMappedError() async {
    let spy = AntiCheatResultSpy()
    let (model, _) = makeModel(spy: spy) { request in
        (
            Data(#"{"error":"Session not found"}"#.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }

    model.start()
    model.imageCaptured(jpeg())
    await model.awaitPendingWork()

    #expect(spy.failureKind == .notFound)
}

// MARK: - Retry

@MainActor @Test func retryReArmsForAFreshAttemptThatEmitsAgain() async {
    let spy = AntiCheatResultSpy()
    let (model, log) = makeModel(spy: spy) { request in ok(request, duplicateBody) }

    model.start()
    model.imageCaptured(jpeg())
    await model.awaitPendingWork()
    #expect(spy.results.count == 1)

    model.retry()
    #expect(model.state == .capturing)

    model.imageCaptured(jpeg())
    await model.awaitPendingWork()

    #expect(spy.results.count == 2)
    #expect(await log.requests.count == 2)
}
