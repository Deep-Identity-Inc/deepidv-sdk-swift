import Foundation

/// Maximum delay enforced even when the `Retry-After` header requests more.
/// Set to 60 seconds.
private let retryAfterCap: TimeInterval = 60

/// Maximum value for exponential backoff before jitter is applied.
private let maxBackoff: TimeInterval = 30

/// Parser for the RFC 1123 HTTP-date form of `Retry-After`
/// (e.g. "Wed, 21 Oct 2015 07:28:00 GMT"). Built once and reused —
/// `DateFormatter` is expensive to construct on every call.
private let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")  // fixed locale for machine dates
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()

/// Checks if a given DeepIDV error is retryable.
func isRetryable(_ error: DeepIDVError) -> Bool {
    switch error.kind {
    case .network, .timeout, .rateLimit:
        return true
    case .api, .serviceUnavailable:
        return (error.status ?? 0) >= 500
    default:
        return false
    }
}

/// Extracts the `Retry-After` header value in seconds from an error's raw response.
func extractRetryAfter(from response: RawResponse?, now: () -> Date = Date.init) -> TimeInterval? {
    guard let response else { return nil }
    guard let raw = response.headers["retry-after"] else { return nil }

    if let seconds = Double(raw) {
        return max(0, seconds)
    }

    guard let date = httpDateFormatter.date(from: raw) else { return nil }
    return max(0, ceil(date.timeIntervalSince(now())))
}

/// Computes how long to wait before the next retry attempt.
///
/// When the error carries a `Retry-After` value (populated for rate limits),
/// that wins — capped at `retryAfterCap` so a hostile or buggy server can't
/// park us for minutes. Otherwise it's full-jitter exponential backoff: the
/// window grows as `initialDelay * 2^attempt` (clamped to `maxBackoff`) and
/// `jitter` picks a point inside `[0, window)`, spreading concurrent clients
/// out to avoid a thundering herd.
///
/// `jitter` is injectable so tests can pin the delay (`{ 1.0 }` yields the full
/// window); it defaults to a uniform random in `0..<1`.
func computeDelay(
    error: DeepIDVError,
    attempt: Int,
    initialDelay: TimeInterval,
    jitter: () -> Double = { Double.random(in: 0..<1) }
) -> TimeInterval {
    if let retryAfter = error.retryAfter {
        return min(retryAfter, retryAfterCap)
    }

    let window = min(initialDelay * pow(2.0, Double(attempt)), maxBackoff)
    return jitter() * window
}

/// Runs `operation`, retrying transient failures with backoff.
///
/// Retries up to `maxRetries` times (so `operation` runs at most
/// `maxRetries + 1` times). A thrown error is retried only when it is a
/// `DeepIDVError` that `isRetryable` accepts *and* attempts remain; otherwise
/// the last error is rethrown. Non-`DeepIDVError` throws (e.g.
/// `CancellationError`) are never retried — they propagate immediately.
///
/// `sleep` is injectable so tests run instantly without touching the wall
/// clock; it defaults to `Task.sleep`. (`TimeInterval` seconds are converted to
/// nanoseconds at the call site — iOS 15 floor, no `Clock`.)
func withRetry<T>(
    maxRetries: Int,
    initialDelay: TimeInterval,
    sleep: (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    },
    operation: () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch let error as DeepIDVError {
            guard isRetryable(error), attempt < maxRetries else { throw error }

            let delay = computeDelay(
                error: error, attempt: attempt, initialDelay: initialDelay)

            try await sleep(delay)
            attempt += 1
        }
    }
}
