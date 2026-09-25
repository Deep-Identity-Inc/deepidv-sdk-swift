import Foundation
import Testing

@testable import DeepIDVCore

// MARK: - Test helpers

/// Records the delays passed to a stubbed sleeper so tests can assert the retry
/// schedule without waiting on the wall clock. An `actor` for the same reason
/// `HTTPTransportStub` uses one: concurrency-safe mutation under Swift 6.
private actor SleepRecorder {
    private(set) var delays: [TimeInterval] = []
    func record(_ delay: TimeInterval) { delays.append(delay) }
}

/// Counts how many times an operation closure was invoked.
private actor CallCounter {
    private(set) var count = 0
    @discardableResult func increment() -> Int {
        count += 1
        return count
    }
}

/// A non-`DeepIDVError` error used to prove the retry loop never retries
/// foreign error types.
private struct ForeignError: Error {}

/// Builds the RFC 1123 HTTP-date string for an instant, matching the format
/// `extractRetryAfter` parses.
private func httpDate(_ epoch: TimeInterval) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.string(from: Date(timeIntervalSince1970: epoch))
}

// MARK: - isRetryable

@Test func testRetryableKindsAreRetryable() {
    #expect(isRetryable(.timeout("timed out")))
    #expect(isRetryable(.network("socket hang-up")))
    #expect(isRetryable(.rateLimit("slow down")))
    #expect(isRetryable(.serviceUnavailable("down")))  // factory sets status 503
    #expect(isRetryable(.api("server", status: 500)))
    #expect(isRetryable(.api("bad gateway", status: 502)))
    #expect(isRetryable(.api("unavailable", status: 599)))
}

@Test func testNonRetryableKindsAreNotRetryable() {
    #expect(!isRetryable(.validation("bad input")))
    #expect(!isRetryable(.authentication("no key")))
    #expect(!isRetryable(.authorization("forbidden")))
    #expect(!isRetryable(.notFound("missing")))
    #expect(!isRetryable(.insufficientFunds("topup")))
    #expect(!isRetryable(.api("bad request", status: 400)))
    #expect(!isRetryable(.api("teapot", status: 418)))
    #expect(!isRetryable(.api("no status", status: nil)))
}

// MARK: - extractRetryAfter

@Test func testExtractRetryAfterParsesNumericSeconds() {
    let response = RawResponse(status: 429, headers: ["retry-after": "5"], body: nil)
    #expect(extractRetryAfter(from: response) == 5)
}

@Test func testExtractRetryAfterClampsNegativeNumericToZero() {
    let response = RawResponse(status: 429, headers: ["retry-after": "-3"], body: nil)
    #expect(extractRetryAfter(from: response) == 0)
}

@Test func testExtractRetryAfterParsesHTTPDate() {
    let epoch: TimeInterval = 1_700_000_000
    let response = RawResponse(
        status: 429, headers: ["retry-after": httpDate(epoch)], body: nil)
    let now = { Date(timeIntervalSince1970: epoch - 10) }

    #expect(extractRetryAfter(from: response, now: now) == 10)
}

@Test func testExtractRetryAfterFloorsPastHTTPDateToZero() {
    let epoch: TimeInterval = 1_700_000_000
    let response = RawResponse(
        status: 429, headers: ["retry-after": httpDate(epoch)], body: nil)
    let now = { Date(timeIntervalSince1970: epoch + 30) }  // header is in the past

    #expect(extractRetryAfter(from: response, now: now) == 0)
}

@Test func testExtractRetryAfterReturnsNilForGarbage() {
    let response = RawResponse(status: 429, headers: ["retry-after": "soon"], body: nil)
    #expect(extractRetryAfter(from: response) == nil)
}

@Test func testExtractRetryAfterReturnsNilWhenHeaderMissing() {
    let response = RawResponse(status: 429, headers: [:], body: nil)
    #expect(extractRetryAfter(from: response) == nil)
}

@Test func testExtractRetryAfterReturnsNilForNilResponse() {
    #expect(extractRetryAfter(from: nil) == nil)
}

// MARK: - computeDelay

@Test func testComputeDelayHonorsRetryAfterAndCapsAt60() {
    // Over the cap → clamped to 60s.
    let capped = computeDelay(
        error: .rateLimit("slow", retryAfter: 120), attempt: 0, initialDelay: 0.5,
        jitter: { 1.0 })
    #expect(capped == 60)

    // Under the cap → honored verbatim, regardless of attempt/jitter.
    let honored = computeDelay(
        error: .rateLimit("slow", retryAfter: 10), attempt: 5, initialDelay: 0.5,
        jitter: { 1.0 })
    #expect(honored == 10)
}

@Test func testComputeDelayFullJitterMatchesCappedWindow() {
    // jitter == 1.0 → exactly min(initialDelay * 2^attempt, maxBackoff).
    #expect(
        computeDelay(error: .network("n"), attempt: 0, initialDelay: 0.5, jitter: { 1.0 })
            == 0.5)
    #expect(
        computeDelay(error: .network("n"), attempt: 3, initialDelay: 0.5, jitter: { 1.0 })
            == 4)  // 0.5 * 2^3
    #expect(
        computeDelay(error: .network("n"), attempt: 7, initialDelay: 0.5, jitter: { 1.0 })
            == 30)  // 0.5 * 2^7 = 64 → capped at 30
}

@Test func testComputeDelayScalesWithJitter() {
    // window = 0.5 * 2^1 = 1.0
    #expect(
        computeDelay(error: .network("n"), attempt: 1, initialDelay: 0.5, jitter: { 0.5 })
            == 0.5)
    #expect(
        computeDelay(error: .network("n"), attempt: 0, initialDelay: 0.5, jitter: { 0.0 })
            == 0)
}

@Test func testComputeDelayDefaultJitterStaysWithinWindow() {
    let initialDelay = 0.5
    let attempt = 2
    let window = min(initialDelay * pow(2.0, Double(attempt)), 30)  // 2.0

    for _ in 0..<200 {
        let delay = computeDelay(
            error: .network("n"), attempt: attempt, initialDelay: initialDelay)
        #expect(delay >= 0)
        #expect(delay < window)
    }
}

// MARK: - withRetry

@Test func testWithRetrySucceedsFirstTryWithoutSleeping() async throws {
    let recorder = SleepRecorder()

    let result = try await withRetry(
        maxRetries: 3, initialDelay: 0.5,
        sleep: { await recorder.record($0) }
    ) {
        "ok"
    }

    #expect(result == "ok")
    let delays = await recorder.delays
    #expect(delays.isEmpty)
}

@Test func testWithRetryExhaustsRetriesThenRethrowsLastError() async {
    let recorder = SleepRecorder()
    let counter = CallCounter()
    let thrown = DeepIDVError.serviceUnavailable("down")

    do {
        try await withRetry(
            maxRetries: 3, initialDelay: 0.5,
            sleep: { await recorder.record($0) }
        ) { () async throws -> Void in
            await counter.increment()
            throw thrown
        }
        Issue.record("expected withRetry to rethrow after exhausting retries")
    } catch let error as DeepIDVError {
        #expect(error == thrown)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let calls = await counter.count
    let delays = await recorder.delays
    #expect(calls == 4)  // 1 initial + 3 retries
    #expect(delays.count == 3)
}

@Test func testWithRetryRethrowsNonRetryableImmediately() async {
    let recorder = SleepRecorder()
    let counter = CallCounter()
    let thrown = DeepIDVError.validation("bad input")

    do {
        try await withRetry(
            maxRetries: 3, initialDelay: 0.5,
            sleep: { await recorder.record($0) }
        ) { () async throws -> Void in
            await counter.increment()
            throw thrown
        }
        Issue.record("expected withRetry to rethrow the non-retryable error")
    } catch let error as DeepIDVError {
        #expect(error == thrown)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let calls = await counter.count
    let delays = await recorder.delays
    #expect(calls == 1)  // never retried
    #expect(delays.isEmpty)
}

@Test func testWithRetryRecordsRateLimitDelays() async {
    // Rate-limit errors carry a deterministic retryAfter, so the recorded
    // schedule is exact (no jitter involved).
    let recorder = SleepRecorder()
    let thrown = DeepIDVError.rateLimit("slow down", retryAfter: 2)

    do {
        try await withRetry(
            maxRetries: 3, initialDelay: 0.5,
            sleep: { await recorder.record($0) }
        ) { () async throws -> Void in
            throw thrown
        }
        Issue.record("expected withRetry to rethrow after exhausting retries")
    } catch is DeepIDVError {
        // expected
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let delays = await recorder.delays
    #expect(delays == [2, 2, 2])
}

@Test func testWithRetryRetriesThenSucceeds() async throws {
    let recorder = SleepRecorder()
    let counter = CallCounter()

    let result = try await withRetry(
        maxRetries: 3, initialDelay: 0.5,
        sleep: { await recorder.record($0) }
    ) { () async throws -> String in
        let attempt = await counter.increment()
        if attempt == 1 { throw DeepIDVError.rateLimit("once", retryAfter: 1) }
        return "recovered"
    }

    let calls = await counter.count
    let delays = await recorder.delays
    #expect(result == "recovered")
    #expect(calls == 2)  // failed once, succeeded on the retry
    #expect(delays == [1])
}

@Test func testWithRetryDoesNotRetryForeignErrors() async {
    let recorder = SleepRecorder()
    let counter = CallCounter()

    do {
        try await withRetry(
            maxRetries: 3, initialDelay: 0.5,
            sleep: { await recorder.record($0) }
        ) { () async throws -> Void in
            await counter.increment()
            throw ForeignError()
        }
        Issue.record("expected withRetry to propagate the foreign error")
    } catch is ForeignError {
        // expected — non-DeepIDVError never retries
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let calls = await counter.count
    let delays = await recorder.delays
    #expect(calls == 1)  // propagated immediately
    #expect(delays.isEmpty)
}
