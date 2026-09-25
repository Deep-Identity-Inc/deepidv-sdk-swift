// DeepIDVCore › Networking

import Foundation

/// Internal HTTP client for talking to the DeepIDV backend (verification
/// submission, liveness tokens, etc.). `internal` on purpose — networking is an
/// implementation detail, never part of the client-facing API.
///
/// Composes the pieces built in the earlier phases into the single point of
/// contact with the API: `buildURL`/`buildHeaders` for the request, a
/// per-attempt timeout race, `withRetry` for backoff, and a status→`DeepIDVError`
/// mapping.
struct APIClient: Sendable {
    private let config: DeepIDVConfig
    private let transport: HTTPTransport
    /// Backoff sleeper handed to `withRetry`. Injectable so tests assert the
    /// retry schedule without touching the wall clock.
    private let retrySleep: @Sendable (TimeInterval) async throws -> Void
    /// Sleeper that drives the per-attempt timeout race. Kept separate from
    /// `retrySleep` so a test can make the *timeout* fire instantly (hanging
    /// transport) while keeping retry backoff deterministic — and vice versa.
    private let timeoutSleep: @Sendable (TimeInterval) async throws -> Void

    /// HTTP verbs we send. Raw values are the on-the-wire method names.
    private enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    /// Result of the per-attempt timeout race: either the
    /// transport produced a response, or the timeout sleeper fired first.
    private enum RaceResult {
        case completed(Data, HTTPURLResponse)
        case timedOut
    }

    /// Default sleeper used by both seams — `Task.sleep`, converting seconds to
    /// nanoseconds at the call site (iOS 15 floor, no `Clock`).
    static let defaultSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    init(
        config: DeepIDVConfig,
        transport: HTTPTransport = URLSessionTransport(),
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep,
        timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep
    ) {
        self.config = config
        self.transport = transport
        self.retrySleep = retrySleep
        self.timeoutSleep = timeoutSleep
    }

    // MARK: - Verbs

    /// Sends a GET request.
    func get<T: Decodable>(_ path: String, options: RequestOptions = .init()) async throws -> T {
        try await request(method: .get, path: path, bodyData: nil, options: options)
    }

    /// Sends a POST request with a JSON body.
    func post<Body: Encodable, T: Decodable>(
        _ path: String, body: Body, options: RequestOptions = .init()
    ) async throws -> T {
        try await request(method: .post, path: path, bodyData: encodeBody(body), options: options)
    }

    /// Sends a PUT request with a JSON body.
    func put<Body: Encodable, T: Decodable>(
        _ path: String, body: Body, options: RequestOptions = .init()
    ) async throws -> T {
        try await request(method: .put, path: path, bodyData: encodeBody(body), options: options)
    }

    /// Sends a PATCH request with a JSON body.
    func patch<Body: Encodable, T: Decodable>(
        _ path: String, body: Body, options: RequestOptions = .init()
    ) async throws -> T {
        try await request(method: .patch, path: path, bodyData: encodeBody(body), options: options)
    }

    /// Sends a DELETE request.
    func delete<T: Decodable>(_ path: String, options: RequestOptions = .init()) async throws -> T {
        try await request(method: .delete, path: path, bodyData: nil, options: options)
    }

    // MARK: - Request pipeline

    /// Resolves per-request overrides against the config, then wraps a single
    /// `attempt` in the retry loop. The URL and encoded body are computed once —
    /// every retry replays the same attempt.
    private func request<T: Decodable>(
        method: HTTPMethod, path: String, bodyData: Data?, options: RequestOptions
    ) async throws -> T {
        let url = buildURL(base: config.baseURL.absoluteString, path: path)
        let timeout = options.timeout ?? config.timeout
        let maxRetries = options.maxRetries ?? config.maxRetries
        let callerHeaders = options.headers ?? [:]

        return try await withRetry(
            maxRetries: maxRetries,
            initialDelay: config.initialRetryDelay,
            sleep: retrySleep
        ) {
            try await self.attempt(
                method: method, url: url, bodyData: bodyData,
                timeout: timeout, callerHeaders: callerHeaders)
        }
    }

    /// One network attempt with no retry logic: build the `URLRequest`, run it
    /// under a fresh timeout race, then map the response (success → decode,
    /// error status → typed `DeepIDVError`).
    private func attempt<T: Decodable>(
        method: HTTPMethod, url: URL, bodyData: Data?,
        timeout: TimeInterval, callerHeaders: [String: String]
    ) async throws -> T {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.rawValue
        urlRequest.httpBody = bodyData
        urlRequest.timeoutInterval = timeout  // secondary backstop; the race is authoritative

        // Caller headers first, then SDK-managed headers overwrite — SDK wins:
        // SDK headers are applied last, so a caller can't
        // clobber `x-api-key` / `Accept` / `Content-Type`.
        for (key, value) in callerHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in buildHeaders(apiKey: config.apiKey, hasBody: bodyData != nil) {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await send(urlRequest, timeout: timeout)

        guard (200..<300).contains(response.statusCode) else {
            throw mapError(
                status: response.statusCode, raw: makeRawResponse(data: data, response: response))
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // A 2xx body we can't decode is a client-side contract mismatch, not a
            // transient failure — classify as non-retryable `.api`.
            throw DeepIDVError.api(
                "Failed to decode response body: \(error.localizedDescription)",
                status: response.statusCode,
                rawResponse: makeRawResponse(data: data, response: response))
        }
    }

    /// Races the transport call against a fresh `timeoutSleep(timeout)`. Whichever
    /// finishes first wins; the loser is cancelled. The sleep winning → `.timeout`.
    /// A fresh race per attempt — never reused, so one attempt's timeout can't
    /// cancel a later attempt.
    private func send(
        _ request: URLRequest, timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        try await withThrowingTaskGroup(of: RaceResult.self) { group in
            group.addTask { [transport] in
                do {
                    let (data, response) = try await transport.send(request)
                    return .completed(data, response)
                } catch let error as DeepIDVError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()  // we lost the race; discarded by the group
                } catch let urlError as URLError where urlError.code == .timedOut {
                    throw DeepIDVError.timeout(
                        "Request timed out", causeDescription: urlError.localizedDescription)
                } catch let urlError as URLError where urlError.code == .cancelled {
                    throw CancellationError()
                } catch {
                    throw DeepIDVError.network(
                        "Network request failed: \(error.localizedDescription)",
                        causeDescription: error.localizedDescription)
                }
            }
            group.addTask { [timeoutSleep] in
                try await timeoutSleep(timeout)
                return .timedOut
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DeepIDVError.timeout("Request timed out after \(timeout)s")
            }
            switch first {
            case .completed(let data, let response):
                return (data, response)
            case .timedOut:
                throw DeepIDVError.timeout("Request timed out after \(timeout)s")
            }
        }
    }

    // MARK: - Mapping helpers

    /// Maps an error HTTP status to the typed `DeepIDVError`, pulling
    /// the message from the body and, for 429, the `Retry-After` delay.
    private func mapError(status: Int, raw: RawResponse) -> DeepIDVError {
        let message = extractErrorMessage(data: raw.body, status: status)
        switch status {
        case 400:
            return .validation(message, rawResponse: raw)
        case 401:
            // The value-type error carries no dedicated `redactedKey` field, so
            // the redacted reference is surfaced in the message. The full key is
            // never stored or serialized.
            return .authentication(
                "\(message) (api key: \(redactApiKey(config.apiKey)))", rawResponse: raw)
        case 402:
            return .insufficientFunds(message, rawResponse: raw)
        case 403:
            return .authorization(message, rawResponse: raw)
        case 404:
            return .notFound(message, rawResponse: raw)
        case 409:
            return .conflict(message, info: parseConflictInfo(from: raw.body), rawResponse: raw)
        case 429:
            return .rateLimit(message, retryAfter: extractRetryAfter(from: raw), rawResponse: raw)
        case 503:
            return .serviceUnavailable(message, rawResponse: raw)
        default:
            return .api(message, status: status, rawResponse: raw)
        }
    }

    /// Leniently parses a 409 JSON body into ``ConflictInfo``. Missing or
    /// non-JSON bodies yield `nil` (not a throw) so callers can still branch on
    /// `.conflict` without field data.
    private func parseConflictInfo(from data: Data?) -> ConflictInfo? {
        guard let data, !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else { return nil }

        let currentStep: Int?
        if dict["current_step"] is NSNull {
            currentStep = nil
        } else {
            currentStep = dict["current_step"] as? Int
        }
        let stepID = dict["step_id"] as? String
        let failureReason = dict["failure_reason"] as? String
        // Only surface an info value when at least one field was present.
        guard dict.keys.contains("current_step") || stepID != nil || failureReason != nil else {
            return nil
        }
        return ConflictInfo(
            currentStep: currentStep, stepID: stepID, failureReason: failureReason)
    }

    /// Extracts a human-readable error message from a response body: a JSON
    /// object's `message` then `error` field → non-empty trimmed plain text →
    /// `"HTTP {status}"`.
    private func extractErrorMessage(data: Data?, status: Int) -> String {
        guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return "HTTP \(status)"
        }
        // A JSON object body: prefer `message`, then `error`. Anything else
        // (object without those fields) falls back to `"HTTP {status}"`.
        if let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        {
            if let message = dict["message"] as? String { return message }
            if let error = dict["error"] as? String { return error }
            return "HTTP \(status)"
        }
        // Non-JSON (plain text, e.g. the 402 funds message) → trimmed text.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "HTTP \(status)" : trimmed
    }

    /// Captures the raw response for `DeepIDVError.rawResponse`. Header keys are
    /// lowercased so case-insensitive lookups (e.g. `"retry-after"`) work;
    /// an empty body is stored as `nil`.
    private func makeRawResponse(data: Data, response: HTTPURLResponse) -> RawResponse {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        return RawResponse(
            status: response.statusCode, headers: headers, body: data.isEmpty ? nil : data)
    }

    /// JSON-encodes a request body, surfacing the rare encode failure as a
    /// non-retryable `.validation` (it happens before any network I/O).
    private func encodeBody<Body: Encodable>(_ body: Body) throws -> Data {
        do {
            // `.withoutEscapingSlashes`: Foundation's default escapes "/" as
            // "\/" — legal JSON, but "/" is a base64 alphabet character, so it
            // inflates the anti-cheat image payload ~1.6% and can push a
            // body that passed the client-side 5 MB cap past the server's
            // body-parser limit (413).
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return try encoder.encode(body)
        } catch {
            throw DeepIDVError.validation(
                "Failed to encode request body: \(error.localizedDescription)",
                causeDescription: error.localizedDescription)
        }
    }
}

/// Options for a single HTTP request. Each field falls back to the corresponding
/// `DeepIDVConfig` value when `nil`. (`body` is a separate parameter, not an option.)
struct RequestOptions: Sendable {
    /// Per-request timeout override. Falls back to `DeepIDVConfig.timeout`.
    let timeout: TimeInterval?
    /// Maximum retry attempts for 429/5xx. Falls back to `DeepIDVConfig.maxRetries`.
    let maxRetries: Int?
    /// Caller-supplied headers (e.g. `Idempotency-Key`). SDK-managed headers
    /// (`x-api-key`, `Accept`, `Content-Type`) take precedence and cannot be
    /// overridden.
    let headers: [String: String]?

    init(
        timeout: TimeInterval? = nil, maxRetries: Int? = nil, headers: [String: String]? = nil
    ) {
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.headers = headers
    }
}
