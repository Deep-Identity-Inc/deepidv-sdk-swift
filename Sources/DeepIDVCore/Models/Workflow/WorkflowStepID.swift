// DeepIDVCore › Models › Workflow

import Foundation

/// Extensible step id — a `RawRepresentable` struct, not an enum, so unknown
/// server-side step types survive decode. Wire form is canonical
/// UPPER_SNAKE; the SDK always sends UPPER_SNAKE.
public struct WorkflowStepID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // Prebuilt instances of the `WorkflowStepID` for static references
    public static let idVerification = WorkflowStepID(rawValue: "ID_VERIFICATION")
    public static let faceLiveness = WorkflowStepID(rawValue: "FACE_LIVENESS")
}

/// Closed set of per-step statuses.
@nonexhaustive
public enum WorkflowStepStatus: String, Sendable, Codable, Equatable {
    case pending = "PENDING"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case skipped = "SKIPPED"
}

/// Closed set of session-progress values.
@nonexhaustive
public enum SessionProgress: String, Sendable, Codable, Equatable {
    case pending = "PENDING"
    case started = "STARTED"
    case completed = "COMPLETED"
}

/// Session status is an open set server-side → `RawRepresentable` struct with
/// well-known constants. Unknown values survive decode.
///
/// Uses the same words as `GET /v1/sessions/{id}` and the webhooks. Some
/// workflow responses carry the stored form of an automatic decision
/// (`AUTO_APPROVE`, `DECLINED`); decoding reads those as ``verified`` and
/// ``rejected``, so a session has one status wherever it is read.
public struct SessionStatus: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: Self.publicForms[raw] ?? raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Stored decision values and the public status each is shown as.
    private static let publicForms = ["AUTO_APPROVE": "VERIFIED", "DECLINED": "REJECTED"]

    // Prebuilt instances of the `SessionStatus` for static references
    public static let pending = SessionStatus(rawValue: "PENDING")
    public static let submitted = SessionStatus(rawValue: "SUBMITTED")
    public static let failed = SessionStatus(rawValue: "FAILED")
    public static let expired = SessionStatus(rawValue: "EXPIRED")
    public static let completed = SessionStatus(rawValue: "COMPLETED")
    /// The session was approved.
    public static let verified = SessionStatus(rawValue: "VERIFIED")
    /// The session was declined.
    public static let rejected = SessionStatus(rawValue: "REJECTED")
}
