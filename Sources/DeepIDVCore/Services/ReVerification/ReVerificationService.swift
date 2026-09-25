// DeepIDVCore › Services › ReVerification

import Foundation

/// Typed client for the re-verification endpoints
/// (`create → liveness/start → liveness/upload-url → liveness/complete`).
///
/// The liveness leg runs the custom provider — challenge script, presigned
/// frame uploads, synchronous `complete`. `package`: the only public
/// re-verification surface is the re-verify view.
///
/// Every endpoint call routes its error through ``remap(_:)``, which turns the
/// server's business codes (`{ "error": "<code>" }`) into `DeepIDVError.code`.
/// Callers branch on `error.code`, never on `message`.
package struct ReVerificationService: Sendable {
    private let client: APIClient
    private let uploader: LivenessFrameUploader
    /// `complete` can take ~25 s server-side (PAD model + face search), so its
    /// timeout never drops below this, whatever the host set.
    private let completeTimeout: TimeInterval

    /// Minimum timeout for `liveness/complete`.
    private static let completeTimeoutFloor: TimeInterval = 60

    package init(
        config: DeepIDVConfig,
        transport: any HTTPTransport,
        uploadSession: URLSession = .shared,
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep,
        timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep
    ) {
        self.client = APIClient(
            config: config, transport: transport,
            retrySleep: retrySleep, timeoutSleep: timeoutSleep)
        self.uploader = LivenessFrameUploader(session: uploadSession)
        self.completeTimeout = max(config.timeout, Self.completeTimeoutFloor)
    }

    private func livenessPath(_ id: String, _ action: String) -> String {
        "/v1/re-verifications/\(id)/liveness/\(action)"
    }

    /// Opens a re-verification against a workflow.
    ///
    /// `POST /v1/re-verifications` `{ workflow_id }` → 201. Default retry
    /// policy: a repeat only leaves an orphan `PENDING` row that expires.
    package func create(workflowID: String) async throws -> ReVerificationSession {
        try await remapping {
            try await client.post(
                "/v1/re-verifications", body: CreateReVerificationRequest(workflowID: workflowID))
        }
    }

    /// Starts a liveness attempt and returns its challenge script.
    ///
    /// `POST /v1/re-verifications/{id}/liveness/start` → the bare
    /// `{ liveness_session_id, script }`. Every call mints a new attempt and
    /// drops any earlier attempt's upload keys.
    package func startLiveness(id: String) async throws -> CustomLivenessSession {
        try await remapping {
            try await client.post(livenessPath(id, "start"), body: EmptyBody())
        }
    }

    /// Mints the presigned PUT URLs for the current attempt.
    ///
    /// `POST /v1/re-verifications/{id}/liveness/upload-url`
    /// `{ frame_count, clip_mime_type? }`. The server accepts 3–8 frames and
    /// answers 400 otherwise; `clip_mime_type` is omitted when `nil`, never
    /// sent as `null` (the server schema is strict).
    ///
    /// Pass `"video/mp4"` or `nil`: ``LivenessFrameUploader`` PUTs the clip as
    /// `video/mp4` regardless of the mime announced here, so announcing
    /// `"video/webm"` silently loses the (best-effort) clip.
    package func requestUploadURLs(
        id: String, frameCount: Int, clipMimeType: String? = nil
    ) async throws -> LivenessUploadURLs {
        try await remapping {
            try await client.post(
                livenessPath(id, "upload-url"),
                body: LivenessUploadURLRequest(frameCount: frameCount, clipMimeType: clipMimeType))
        }
    }

    /// PUTs frames + timeline (required) and the clip (best-effort) to the
    /// presigned URLs. Failures surface as `.network`.
    package func uploadFrames(
        _ frames: [Data], timeline: Data, clip: Data? = nil, to urls: LivenessUploadURLs
    ) async throws {
        try await uploader.upload(frames, timeline: timeline, clip: clip, to: urls)
    }

    /// Scores the uploaded capture and returns the decision.
    ///
    /// `POST /v1/re-verifications/{id}/liveness/complete` — synchronous, no
    /// poll loop. Sent with a timeout of at least ``completeTimeoutFloor`` and
    /// **no automatic retry**: a retry overlapping a still-running evaluation
    /// makes the server score the capture twice. Recovery is the caller's
    /// user-initiated retry, which replays a terminal decision.
    package func completeLiveness(id: String) async throws -> ReVerifyOutcome {
        try await remapping {
            try await client.post(
                livenessPath(id, "complete"), body: EmptyBody(),
                options: RequestOptions(timeout: completeTimeout, maxRetries: 0))
        }
    }

    // MARK: - Error remap

    private func remapping<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw remap(error)
        }
    }

    /// Rebuilds a `DeepIDVError` whose body is `{ "error": "<code>" }` with one
    /// of the known re-verification codes: `kind`, `status` and `rawResponse`
    /// are kept, `code` becomes the server string, `message` becomes
    /// end-user-safe copy, and a 409 carries the code as
    /// `conflict.failureReason`. Anything else is returned untouched.
    private func remap(_ error: any Error) -> any Error {
        guard let error = error as? DeepIDVError,
            let body = error.rawResponse?.body,
            let object = try? JSONSerialization.jsonObject(with: body),
            let dict = object as? [String: Any],
            let raw = dict["error"] as? String,
            let code = ReVerifyErrorCode(rawValue: raw)
        else { return error }

        let conflict =
            error.kind == .conflict
            ? ConflictInfo(currentStep: nil, stepID: nil, failureReason: code.rawValue)
            : nil
        return DeepIDVError(
            kind: error.kind, message: code.message, status: error.status,
            code: code.rawValue, rawResponse: error.rawResponse, conflict: conflict)
    }
}

// MARK: - Server error codes

/// The business-rule codes the re-verification routes answer with.
private enum ReVerifyErrorCode: String {
    case notFound = "not_found"
    case reverifyDisabled = "reverify_disabled"
    case livenessNotStarted = "liveness_not_started"
    case livenessUploadIncomplete = "liveness_upload_incomplete"
    case expired
    case alreadyCompleted = "already_completed"
    case insufficientBalance = "insufficient_balance"

    var message: String {
        switch self {
        case .notFound: "Re-verification isn't available here."
        case .reverifyDisabled: "Re-verification isn't enabled for this workflow."
        case .livenessNotStarted: "No liveness check is in progress. Please start again."
        case .livenessUploadIncomplete: "Your capture didn't finish uploading. Please try again."
        case .expired: "This re-verification has expired. Please start again."
        case .alreadyCompleted: "This re-verification has already finished."
        case .insufficientBalance: "Re-verification is temporarily unavailable."
        }
    }
}

// MARK: - Request bodies

/// `start` and `complete` take no parameters beyond the path.
private struct EmptyBody: Encodable {}

/// `workflow_id` only — v1 never sends `device_fingerprint`.
private struct CreateReVerificationRequest: Encodable {
    let workflowID: String

    enum CodingKeys: String, CodingKey {
        case workflowID = "workflow_id"
    }
}

/// Synthesized `Encodable` uses `encodeIfPresent`, so a `nil` clip mime is
/// absent from the JSON rather than `null`.
private struct LivenessUploadURLRequest: Encodable {
    let frameCount: Int
    let clipMimeType: String?

    enum CodingKeys: String, CodingKey {
        case frameCount = "frame_count"
        case clipMimeType = "clip_mime_type"
    }
}
