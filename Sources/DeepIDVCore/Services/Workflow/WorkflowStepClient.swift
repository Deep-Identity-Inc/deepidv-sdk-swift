// DeepIDVCore › Services › Workflow

import Foundation

/// Shared submit plumbing for `POST /v1/sessions/{id}/steps/{STEP_ID}`.
/// Path uses the step id's UPPER_SNAKE `rawValue`; envelope decode is generic
/// over the step payload type.
struct WorkflowStepClient: Sendable {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    /// Submits `body` for `stepID` and decodes the typed envelope.
    func submit<Body: Encodable, Payload: Decodable & Sendable & Equatable>(
        sessionID: String,
        stepID: WorkflowStepID,
        body: Body
    ) async throws -> StepSubmissionResult<Payload> {
        try await client.post(
            "/v1/sessions/\(sessionID)/steps/\(stepID.rawValue)",
            body: body)
    }
}
