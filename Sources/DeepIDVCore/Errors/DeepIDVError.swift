// DeepIDVCore › Errors

import Foundation

/// Everything the SDK can throw at the HTTP layer.
///
/// A single value type — not a class hierarchy. `Kind` is the exhaustive
/// switch surface callers `catch` and branch on; the struct carries the shared
/// HTTP context (status, code, raw response). Being a `struct` keeps it
/// `Sendable` and `Equatable`, so it crosses concurrency boundaries and is
/// trivial to assert on in tests.
public struct DeepIDVError: Error, Sendable, Equatable {
    /// The exhaustive set of error categories callers branch on.
    public enum Kind: Sendable, Equatable {
        case authentication  // 401
        case authorization  // 403
        case notFound  // 404
        case validation  // 400
        case insufficientFunds  // 402
        case rateLimit  // 429
        case serviceUnavailable  // 503
        case api  // other 4xx/5xx
        case network  // transport-level failure
        case timeout  // per-attempt timeout fired

        case cameraPermissionDenied  // AVCaptureDevice authorization denied/restricted
        case cancelled  // user backed out of the flow
        case captureFailed  // camera/session error, no usable frame

        case antiCheatBlocked  // iGaming anti-cheat "block" ended the guided flow
        case conflict  // 409 — workflow progression conflicts
    }

    /// The error category.
    public let kind: Kind
    /// Human-readable message, extracted from the response body where possible.
    public let message: String
    /// HTTP status code, when the error originated from a response.
    public let status: Int?
    /// Machine-readable error code (e.g. `"rate_limit_error"`).
    public let code: String?
    /// Raw HTTP response (status, headers, body) captured for debugging.
    public let rawResponse: RawResponse?
    /// Seconds to wait before retrying. Populated only for `.rateLimit`.
    public let retryAfter: TimeInterval?
    /// Parsed 409 body fields. Populated only for `.conflict`; all fields optional
    /// because 409 bodies vary by cause and may be non-JSON.
    public let conflict: ConflictInfo?

    /// Best-effort description of the underlying cause (a transport error, a
    /// decode failure, …), retained internally for diagnostics. Stored as a
    /// `String` rather than a live `Error` so the value type stays `Sendable`
    /// and `Equatable` (a live `any Error` is neither).
    let causeDescription: String?

    init(
        kind: Kind,
        message: String,
        status: Int? = nil,
        code: String? = nil,
        rawResponse: RawResponse? = nil,
        retryAfter: TimeInterval? = nil,
        conflict: ConflictInfo? = nil,
        causeDescription: String? = nil
    ) {
        self.kind = kind
        self.message = message
        self.status = status
        self.code = code
        self.rawResponse = rawResponse
        self.retryAfter = retryAfter
        self.conflict = conflict
        self.causeDescription = causeDescription
    }
}

/// Parsed body of a workflow 409 response. Fields are optional and decoded
/// leniently — absent on non-JSON bodies or when the server omits them.
public struct ConflictInfo: Sendable, Equatable {
    /// Zero-based current step index; `nil` when the session is terminal or the
    /// run is finished.
    public let currentStep: Int?
    /// The server's expected step id (out-of-order) or the submitted step.
    public let stepID: String?
    /// Machine-readable reason; present on not-ready 409s
    /// (e.g. `FACE_LIVENESS_RESULT_NOT_READY`).
    public let failureReason: String?

    public init(currentStep: Int?, stepID: String?, failureReason: String?) {
        self.currentStep = currentStep
        self.stepID = stepID
        self.failureReason = failureReason
    }
}

/// Raw HTTP response captured on errors for debugging
public struct RawResponse: Sendable, Equatable {
    /// HTTP status code.
    public let status: Int
    /// Response headers. Keys are lowercased (so `"retry-after"` lookups are
    /// case-insensitive).
    public let headers: [String: String]
    /// Raw response body bytes, if any.
    public let body: Data?

    public init(status: Int, headers: [String: String], body: Data?) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

// MARK: - Factories

extension DeepIDVError {
    // One factory per kind so the HTTP client and uploader build
    // errors without repeating the `code` strings or status codes.

    /// 400 Bad Request.
    public static func validation(
        _ message: String, rawResponse: RawResponse? = nil, causeDescription: String? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .validation, message: message, status: 400, code: "validation_error",
            rawResponse: rawResponse, causeDescription: causeDescription)
    }

    /// 401 Unauthorized.
    public static func authentication(
        _ message: String, rawResponse: RawResponse? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .authentication, message: message, status: 401, code: "authentication_error",
            rawResponse: rawResponse)
    }

    /// 402 Payment Required — pre-flight funds/subscription gate failed.
    public static func insufficientFunds(
        _ message: String, rawResponse: RawResponse? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .insufficientFunds, message: message, status: 402,
            code: "insufficient_funds_error", rawResponse: rawResponse)
    }

    /// 403 Forbidden.
    public static func authorization(
        _ message: String, rawResponse: RawResponse? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .authorization, message: message, status: 403, code: "authorization_error",
            rawResponse: rawResponse)
    }

    /// 404 Not Found.
    public static func notFound(
        _ message: String, rawResponse: RawResponse? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .notFound, message: message, status: 404, code: "not_found_error",
            rawResponse: rawResponse)
    }

    /// 429 Too Many Requests. `retryAfter` is parsed from the `Retry-After`
    /// header by the client.
    public static func rateLimit(
        _ message: String, retryAfter: TimeInterval? = nil, rawResponse: RawResponse? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .rateLimit, message: message, status: 429, code: "rate_limit_error",
            rawResponse: rawResponse, retryAfter: retryAfter)
    }

    /// 503 Service Unavailable.
    public static func serviceUnavailable(
        _ message: String, rawResponse: RawResponse? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .serviceUnavailable, message: message, status: 503,
            code: "service_unavailable_error", rawResponse: rawResponse)
    }

    /// Any other 4xx/5xx response. `code` defaults to `"api_error"` but can be
    /// overridden (e.g. the uploader's `"upload_url_expired"` / `"upload_error"`).
    public static func api(
        _ message: String, status: Int?, code: String = "api_error",
        rawResponse: RawResponse? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .api, message: message, status: status, code: code, rawResponse: rawResponse)
    }

    /// Transport-level failure (DNS, connection refused, socket hang-up).
    public static func network(
        _ message: String, causeDescription: String? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .network, message: message, code: "network_error",
            causeDescription: causeDescription)
    }

    /// Per-attempt timeout fired.
    public static func timeout(
        _ message: String, causeDescription: String? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .timeout, message: message, code: "timeout_error",
            causeDescription: causeDescription)
    }

    /// Camera access was denied or restricted (`AVCaptureDevice` authorization).
    /// The feature view also surfaces a Settings deep-link CTA.
    public static func cameraPermissionDenied(
        _ message: String, causeDescription: String? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .cameraPermissionDenied, message: message,
            code: "camera_permission_denied_error", causeDescription: causeDescription)
    }

    /// The user backed out of a capture flow — distinct from a real failure so
    /// hosts can tell "user quit" apart from an error.
    public static func cancelled(
        _ message: String, causeDescription: String? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .cancelled, message: message, code: "cancelled_error",
            causeDescription: causeDescription)
    }

    /// The camera/session errored and produced no usable frame.
    public static func captureFailed(
        _ message: String, causeDescription: String? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .captureFailed, message: message, code: "capture_failed_error",
            causeDescription: causeDescription)
    }

    /// The iGaming anti-cheat step returned `action == "block"` inside the
    /// guided flow — the server has already marked the session FAILED, so the
    /// flow ends here instead of proceeding to verify. Only the guided flow
    /// produces this; the headless `checkAntiCheat` surfaces the block as a
    /// normal ``AntiCheatResult`` for the host to act on.
    public static func antiCheatBlocked(_ message: String) -> DeepIDVError {
        DeepIDVError(
            kind: .antiCheatBlocked, message: message, code: "anti_cheat_blocked_error")
    }

    /// 409 Conflict — workflow progression conflict (out-of-order step, terminal
    /// session, concurrent duplicate, or liveness result not ready). Never
    /// generically retryable; only the face-liveness complete poll loop
    /// special-cases `FACE_LIVENESS_RESULT_NOT_READY`.
    public static func conflict(
        _ message: String, info: ConflictInfo?, rawResponse: RawResponse? = nil
    ) -> DeepIDVError {
        DeepIDVError(
            kind: .conflict, message: message, status: 409, code: "conflict_error",
            rawResponse: rawResponse, conflict: info)
    }
}

// MARK: - Description

extension DeepIDVError: CustomStringConvertible {
    /// Renders the diagnostic fields. The type stores no API key, so no
    /// description surface can leak one (see `redactApiKey` for the rule applied
    /// wherever a key *would* otherwise appear).
    public var description: String {
        var parts = ["kind: \(kind)"]
        if let code { parts.append("code: \(code)") }
        if let status { parts.append("status: \(status)") }
        parts.append("message: \(message)")
        return "DeepIDVError(\(parts.joined(separator: ", ")))"
    }
}

// MARK: - API key redaction

/// Redacts an API key for safe logging — shows only the last 4 characters,
/// or `"****"` for keys of 4 or fewer characters
func redactApiKey(_ key: String) -> String {
    key.count <= 4 ? "****" : "sk_...\(key.suffix(4))"
}
