// DeepIDVCore › Models › Workflow

import Foundation

/// End-user identity fields for `POST /v1/workflows/{workflow_id}/sessions`
/// Required by session creation — the entry point takes this
/// as `user:`.
public struct WorkflowUser: Sendable, Equatable, Encodable {
    public let email: String
    public let firstName: String
    public let lastName: String
    public let phone: String
    /// Optional host-side correlation id (`external_id`).
    public let externalID: String?

    enum CodingKeys: String, CodingKey {
        case email
        case firstName = "first_name"
        case lastName = "last_name"
        case phone
        case externalID = "external_id"
    }

    public init(
        email: String,
        firstName: String,
        lastName: String,
        phone: String,
        externalID: String? = nil
    ) {
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.phone = phone
        self.externalID = externalID
    }
}
