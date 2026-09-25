// DeepIDVCore › Models

import Foundation

// Re-verification wire models. All `package`: they cross only from
// `ReVerificationService` into the re-verify view's internal flow model,
// never to the host. `liveness/start` and `liveness/upload-url` reuse
// ``CustomLivenessSession`` and ``LivenessUploadURLs`` as they are.

/// The decoded `POST /v1/re-verifications` 201 body. Wire is snake_case with
/// the challenge type nested under `liveness`, so decoding is hand-written to
/// flatten it.
package struct ReVerificationSession: Decodable, Sendable, Equatable {
    package let reVerificationID: String
    package let workflowID: String
    /// Always `"PENDING"` on create.
    package let status: String
    /// ISO 8601, kept verbatim — `APIClient` decodes with no date strategy.
    package let expiresAt: String
    package let livenessChallengeType: ChallengeType

    private enum CodingKeys: String, CodingKey {
        case reVerificationID = "re_verification_id"
        case workflowID = "workflow_id"
        case status
        case expiresAt = "expires_at"
        case liveness
    }

    private enum LivenessKeys: String, CodingKey {
        case challengeType = "challenge_type"
    }

    package init(
        reVerificationID: String, workflowID: String, status: String, expiresAt: String,
        livenessChallengeType: ChallengeType
    ) {
        self.reVerificationID = reVerificationID
        self.workflowID = workflowID
        self.status = status
        self.expiresAt = expiresAt
        self.livenessChallengeType = livenessChallengeType
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reVerificationID = try container.decode(String.self, forKey: .reVerificationID)
        self.workflowID = try container.decode(String.self, forKey: .workflowID)
        self.status = try container.decode(String.self, forKey: .status)
        self.expiresAt = try container.decode(String.self, forKey: .expiresAt)
        let liveness = try container.nestedContainer(keyedBy: LivenessKeys.self, forKey: .liveness)
        self.livenessChallengeType = try liveness.decode(ChallengeType.self, forKey: .challengeType)
    }
}

/// The re-verification decision. The server enum is closed, so an unknown value
/// is a contract change and fails to decode rather than falling back.
package enum ReVerifyDecision: String, Decodable, Sendable, Equatable {
    case verified
    case retry
    case retryLiveness = "retry_liveness"
    case failed
}

/// Attempt counters, built from the flat `failed_attempts` / `max_attempts`.
package struct ReVerifyAttempts: Sendable, Equatable {
    package let failed: Int
    package let max: Int

    package init(failed: Int, max: Int) {
        self.failed = failed
        self.max = max
    }
}

/// The decoded `POST /v1/re-verifications/{id}/liveness/complete` 200 body
/// (also the replayed stored decision on a terminal row).
package struct ReVerifyOutcome: Decodable, Sendable, Equatable {
    package let decision: ReVerifyDecision
    package let attempts: ReVerifyAttempts
    /// The server sends only `SUCCEEDED` / `FAILED` here.
    package let livenessStatus: FaceLivenessResult.Status
    /// `null` on the wire when the capture was never scored.
    package let livenessConfidence: Double?
    /// Present on `verified` only.
    package let userID: String?
    /// Present on `verified` only.
    package let originalSessionID: String?

    package var attemptsRemaining: Int { max(0, attempts.max - attempts.failed) }

    private enum CodingKeys: String, CodingKey {
        case decision
        case failedAttempts = "failed_attempts"
        case maxAttempts = "max_attempts"
        case liveness
        case userID = "user_id"
        case originalSessionID = "original_session_id"
    }

    private enum LivenessKeys: String, CodingKey {
        case status
        case confidence
    }

    package init(
        decision: ReVerifyDecision, attempts: ReVerifyAttempts,
        livenessStatus: FaceLivenessResult.Status, livenessConfidence: Double?,
        userID: String? = nil, originalSessionID: String? = nil
    ) {
        self.decision = decision
        self.attempts = attempts
        self.livenessStatus = livenessStatus
        self.livenessConfidence = livenessConfidence
        self.userID = userID
        self.originalSessionID = originalSessionID
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.decision = try container.decode(ReVerifyDecision.self, forKey: .decision)
        self.attempts = ReVerifyAttempts(
            failed: try container.decode(Int.self, forKey: .failedAttempts),
            max: try container.decode(Int.self, forKey: .maxAttempts))
        let liveness = try container.nestedContainer(keyedBy: LivenessKeys.self, forKey: .liveness)
        self.livenessStatus = try liveness.decode(FaceLivenessResult.Status.self, forKey: .status)
        self.livenessConfidence = try liveness.decodeIfPresent(Double.self, forKey: .confidence)
        self.userID = try container.decodeIfPresent(String.self, forKey: .userID)
        self.originalSessionID = try container.decodeIfPresent(
            String.self, forKey: .originalSessionID)
    }
}
