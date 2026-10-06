// DeepIDVCore › Models › Workflow

import Foundation

/// Why a workflow run ended without reaching submission.
public struct WorkflowSessionFailure: Sendable, Equatable, Decodable {
    /// Why the run ended. Unknown server codes decode as-is.
    public let code: Code
    /// The step that ended the run, when known.
    public let stepID: WorkflowStepID?
    /// That step's last failure, when it had one.
    public let failure: WorkflowFailure?

    /// A server-defined run-ending code. Open set: compare against the
    /// constants, and expect values this SDK version does not know.
    public struct Code: RawRepresentable, Hashable, Sendable, Decodable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let attemptsExhausted = Code(rawValue: "ATTEMPTS_EXHAUSTED")
        public static let stepBlocked = Code(rawValue: "STEP_BLOCKED")
        public static let sessionExpired = Code(rawValue: "SESSION_EXPIRED")
    }

    enum CodingKeys: String, CodingKey {
        case code
        case stepID = "step_id"
        case failure
    }

    public init(code: Code, stepID: WorkflowStepID?, failure: WorkflowFailure?) {
        self.code = code
        self.stepID = stepID
        self.failure = failure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(Code.self, forKey: .code)
        self.stepID = try container.decodeIfPresent(WorkflowStepID.self, forKey: .stepID)
        self.failure = try container.decodeIfPresent(WorkflowFailure.self, forKey: .failure)
    }
}
