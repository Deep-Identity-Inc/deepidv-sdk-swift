// DeepIDVCore › Models › Workflow

import Foundation

/// Why a workflow step attempt failed, as classified by the server.
///
/// Present on a step whenever its most recent attempt failed a check — both
/// while the step can still be retried and once it has failed for good. Use
/// `category` and `userAction` for decisions (they are small and stable); use
/// `code` when you need the specific cause. `message` is for logs, not for
/// display to applicants.
public struct WorkflowFailure: Sendable, Equatable, Decodable {
    /// The specific cause. Unknown server codes decode as-is.
    public let code: Code
    /// Coarse grouping of `code`.
    public let category: Category
    /// What the applicant should do next.
    public let userAction: UserAction
    /// Whether the step can still be submitted again. `false` once the step
    /// has failed for good (attempt budget exhausted).
    public let isRetryable: Bool
    /// The document the failure is attributed to, when it is document-specific.
    public let slot: WorkflowDocumentSlot?
    /// Developer-facing English description from the server. Never shown to applicants.
    public let message: String

    /// A server-defined failure code. Open set: compare against the constants,
    /// and expect values this SDK version does not know.
    public struct Code: RawRepresentable, Hashable, Sendable, Decodable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let idFaceNotDetected = Code(rawValue: "ID_FACE_NOT_DETECTED")
        public static let idTextNotReadable = Code(rawValue: "ID_TEXT_NOT_READABLE")
        public static let documentTypeNotAccepted = Code(rawValue: "DOCUMENT_TYPE_NOT_ACCEPTED")
        public static let documentTypeUnrecognized = Code(rawValue: "DOCUMENT_TYPE_UNRECOGNIZED")
        public static let documentTypeLowConfidence = Code(
            rawValue: "DOCUMENT_TYPE_LOW_CONFIDENCE")
        public static let selfieFaceNotDetected = Code(rawValue: "SELFIE_FACE_NOT_DETECTED")
        public static let selfieMultipleFaces = Code(rawValue: "SELFIE_MULTIPLE_FACES")
        public static let selfieIDFaceMismatch = Code(rawValue: "SELFIE_ID_FACE_MISMATCH")
        public static let livenessIDMismatch = Code(rawValue: "LIVENESS_ID_MISMATCH")
        public static let livenessFailed = Code(rawValue: "LIVENESS_FAILED")
        public static let unknown = Code(rawValue: "UNKNOWN")
    }

    /// Coarse grouping of failure codes.
    @nonexhaustive
    public enum Category: String, Sendable, Equatable {
        case document = "DOCUMENT"
        case selfie = "SELFIE"
        case faceMatch = "FACE_MATCH"
        case liveness = "LIVENESS"
        case other = "OTHER"
    }

    /// The remedy for the failure. Whether a retry is still allowed is `isRetryable`.
    @nonexhaustive
    public enum UserAction: String, Sendable, Equatable {
        case retakeDocument = "RETAKE_DOCUMENT"
        case useDifferentDocument = "USE_DIFFERENT_DOCUMENT"
        case retakeSelfie = "RETAKE_SELFIE"
        case retryLiveness = "RETRY_LIVENESS"
        case retryStep = "RETRY_STEP"
        case none = "NONE"
    }

    enum CodingKeys: String, CodingKey {
        case code
        case category
        case userAction = "user_action"
        case isRetryable = "retryable"
        case slot
        case message
    }

    public init(
        code: Code,
        category: Category,
        userAction: UserAction,
        isRetryable: Bool,
        slot: WorkflowDocumentSlot? = nil,
        message: String
    ) {
        self.code = code
        self.category = category
        self.userAction = userAction
        self.isRetryable = isRetryable
        self.slot = slot
        self.message = message
    }

    /// Decodes leniently so a value this SDK version does not know can never
    /// fail the response it arrives in: an unknown category becomes `.other`,
    /// an unknown action becomes `.retryStep` (or `.none` when the step can no
    /// longer be retried), an unknown slot becomes `nil`, and an unknown code is
    /// kept as sent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isRetryable = (try? container.decode(Bool.self, forKey: .isRetryable)) ?? false
        self.code = (try? container.decode(Code.self, forKey: .code)) ?? .unknown
        self.category =
            (try? container.decode(String.self, forKey: .category))
            .flatMap(Category.init(rawValue:)) ?? .other
        self.userAction =
            (try? container.decode(String.self, forKey: .userAction))
            .flatMap(UserAction.init(rawValue:)) ?? (isRetryable ? .retryStep : .none)
        self.isRetryable = isRetryable
        self.slot = (try? container.decode(String.self, forKey: .slot))
            .flatMap(WorkflowDocumentSlot.init(rawValue:))
        self.message = (try? container.decode(String.self, forKey: .message)) ?? ""
    }
}

/// A document position within an ID-verification step.
@nonexhaustive
public enum WorkflowDocumentSlot: String, Sendable, Equatable, Decodable {
    case primary = "PRIMARY"
    case secondary = "SECONDARY"
    case tertiary = "TERTIARY"
}
