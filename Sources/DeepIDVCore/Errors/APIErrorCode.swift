// DeepIDVCore › Errors

import Foundation

/// Server error codes returned by the workflow endpoints. Open set: compare
/// against the constants, and expect values this SDK version does not know.
public struct APIErrorCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let validationError = APIErrorCode(rawValue: "VALIDATION_ERROR")
    public static let workflowInactive = APIErrorCode(rawValue: "WORKFLOW_INACTIVE")
    public static let unsupportedWorkflowSteps = APIErrorCode(
        rawValue: "UNSUPPORTED_WORKFLOW_STEPS")
    public static let invalidUploadKey = APIErrorCode(rawValue: "INVALID_UPLOAD_KEY")
    public static let invalidMedia = APIErrorCode(rawValue: "INVALID_MEDIA")
    public static let uploadSlotNotRequired = APIErrorCode(rawValue: "UPLOAD_SLOT_NOT_REQUIRED")
    public static let insufficientFunds = APIErrorCode(rawValue: "INSUFFICIENT_FUNDS")
    public static let forbidden = APIErrorCode(rawValue: "FORBIDDEN")
    public static let organizationNotFound = APIErrorCode(rawValue: "ORGANIZATION_NOT_FOUND")
    public static let workflowNotFound = APIErrorCode(rawValue: "WORKFLOW_NOT_FOUND")
    public static let sessionNotFound = APIErrorCode(rawValue: "SESSION_NOT_FOUND")
    public static let executionStateNotFound = APIErrorCode(rawValue: "EXECUTION_STATE_NOT_FOUND")
    public static let stepNotFound = APIErrorCode(rawValue: "STEP_NOT_FOUND")
    public static let sessionTerminal = APIErrorCode(rawValue: "SESSION_TERMINAL")
    public static let sessionAlreadyStarted = APIErrorCode(rawValue: "SESSION_ALREADY_STARTED")
    public static let noActiveStep = APIErrorCode(rawValue: "NO_ACTIVE_STEP")
    public static let stepOutOfOrder = APIErrorCode(rawValue: "STEP_OUT_OF_ORDER")
    public static let stepNotSubmittable = APIErrorCode(rawValue: "STEP_NOT_SUBMITTABLE")
    public static let stepConflict = APIErrorCode(rawValue: "STEP_CONFLICT")
    public static let livenessNotStarted = APIErrorCode(rawValue: "LIVENESS_NOT_STARTED")
    public static let livenessResultNotReady = APIErrorCode(rawValue: "LIVENESS_RESULT_NOT_READY")
    public static let livenessUploadIncomplete = APIErrorCode(
        rawValue: "LIVENESS_UPLOAD_INCOMPLETE")
    public static let stepNotRunnable = APIErrorCode(rawValue: "STEP_NOT_RUNNABLE")
    public static let internalError = APIErrorCode(rawValue: "INTERNAL_ERROR")
}
