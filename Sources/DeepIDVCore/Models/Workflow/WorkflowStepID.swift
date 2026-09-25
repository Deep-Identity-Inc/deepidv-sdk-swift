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
public enum WorkflowStepStatus: String, Sendable, Codable, Equatable {
    case pending = "PENDING"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case skipped = "SKIPPED"
}

/// Closed set of session-progress values.
public enum SessionProgress: String, Sendable, Codable, Equatable {
    case pending = "PENDING"
    case started = "STARTED"
    case completed = "COMPLETED"
}

/// Session status is an open set server-side → `RawRepresentable` struct with
/// well-known constants. Unknown values survive decode.
public struct SessionStatus: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // Prebuilt instances of the `SessionStatus` for static references
    public static let pending = SessionStatus(rawValue: "PENDING")
    public static let submitted = SessionStatus(rawValue: "SUBMITTED")
    public static let failed = SessionStatus(rawValue: "FAILED")
    public static let expired = SessionStatus(rawValue: "EXPIRED")
    public static let completed = SessionStatus(rawValue: "COMPLETED")
}
