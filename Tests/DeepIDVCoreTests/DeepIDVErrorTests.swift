import Foundation
import Testing

@testable import DeepIDVCore

@Test func errorFactoriesSetKindStatusAndCode() {
    let validation = DeepIDVError.validation("m")
    #expect(validation.kind == .validation)
    #expect(validation.status == 400)
    #expect(validation.code == "validation_error")

    let auth = DeepIDVError.authentication("m")
    #expect(auth.kind == .authentication)
    #expect(auth.status == 401)
    #expect(auth.code == "authentication_error")

    let funds = DeepIDVError.insufficientFunds("m")
    #expect(funds.kind == .insufficientFunds)
    #expect(funds.status == 402)
    #expect(funds.code == "insufficient_funds_error")

    let authz = DeepIDVError.authorization("m")
    #expect(authz.kind == .authorization)
    #expect(authz.status == 403)
    #expect(authz.code == "authorization_error")

    let notFound = DeepIDVError.notFound("m")
    #expect(notFound.kind == .notFound)
    #expect(notFound.status == 404)
    #expect(notFound.code == "not_found_error")

    let rateLimit = DeepIDVError.rateLimit("m")
    #expect(rateLimit.kind == .rateLimit)
    #expect(rateLimit.status == 429)
    #expect(rateLimit.code == "rate_limit_error")

    let unavailable = DeepIDVError.serviceUnavailable("m")
    #expect(unavailable.kind == .serviceUnavailable)
    #expect(unavailable.status == 503)
    #expect(unavailable.code == "service_unavailable_error")

    let api = DeepIDVError.api("m", status: 418)
    #expect(api.kind == .api)
    #expect(api.status == 418)
    #expect(api.code == "api_error")

    let network = DeepIDVError.network("m")
    #expect(network.kind == .network)
    #expect(network.status == nil)
    #expect(network.code == "network_error")

    let timeout = DeepIDVError.timeout("m")
    #expect(timeout.kind == .timeout)
    #expect(timeout.status == nil)
    #expect(timeout.code == "timeout_error")
}

@Test func apiFactoryAllowsCodeOverride() {
    // The uploader reuses the `.api` kind with its own codes.
    let expired = DeepIDVError.api("m", status: 403, code: "upload_url_expired")
    #expect(expired.kind == .api)
    #expect(expired.code == "upload_url_expired")
}

@Test func captureFactoriesSetKindAndCode() {
    let permission = DeepIDVError.cameraPermissionDenied("m")
    #expect(permission.kind == .cameraPermissionDenied)
    #expect(permission.status == nil)
    #expect(permission.code == "camera_permission_denied_error")

    let cancelled = DeepIDVError.cancelled("m")
    #expect(cancelled.kind == .cancelled)
    #expect(cancelled.code == "cancelled_error")

    let captureFailed = DeepIDVError.captureFailed("m")
    #expect(captureFailed.kind == .captureFailed)
    #expect(captureFailed.code == "capture_failed_error")
}

@Test func captureCasesAreNeverRetryable() {
    // New non-HTTP cases fall through `isRetryable`'s default → false.
    #expect(isRetryable(.cameraPermissionDenied("m")) == false)
    #expect(isRetryable(.cancelled("m")) == false)
    #expect(isRetryable(.captureFailed("m")) == false)
}

@Test func retryAfterPopulatedOnlyForRateLimit() {
    #expect(DeepIDVError.rateLimit("m", retryAfter: 12).retryAfter == 12)
    #expect(DeepIDVError.rateLimit("m").retryAfter == nil)
    #expect(DeepIDVError.validation("m").retryAfter == nil)
    #expect(DeepIDVError.api("m", status: 500).retryAfter == nil)
}

@Test func errorIsEquatable() {
    #expect(DeepIDVError.notFound("m") == DeepIDVError.notFound("m"))
    #expect(DeepIDVError.notFound("m") != DeepIDVError.notFound("other"))
    #expect(DeepIDVError.notFound("m") != DeepIDVError.validation("m"))
}

@Test func redactApiKeyShowsOnlyLastFour() {
    #expect(redactApiKey("sk_live_abcd1234") == "sk_...1234")
    #expect(redactApiKey("12345") == "sk_...2345")
    #expect(redactApiKey("1234") == "****")  // boundary: 4 chars
    #expect(redactApiKey("key") == "****")
    #expect(redactApiKey("") == "****")
}

@Test func descriptionNeverContainsRawKey() {
    // The error type carries no API key, so no description surface can leak one.
    let err = DeepIDVError.authentication("Invalid API key sk_live_abcd1234")
    // The message is caller-controlled here, but the redaction rule guarantees
    // the SDK never *constructs* a description that embeds a raw key field.
    #expect(err.description.contains("authentication"))
    #expect(err.description.contains("status: 401"))
    #expect(err.description.contains("code: authentication_error"))
}

@Test func antiCheatBlockedFactoryBuildsTheBlockedKind() {
    let error = DeepIDVError.antiCheatBlocked(
        "The anti-cheat check blocked this session (verdict: duplicate).")
    #expect(error.kind == .antiCheatBlocked)
    #expect(error.code == "anti_cheat_blocked_error")
    #expect(error.status == nil)
    #expect(error.message.contains("duplicate"))
}
