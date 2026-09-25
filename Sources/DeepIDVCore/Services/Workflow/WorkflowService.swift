// DeepIDVCore › Services › Workflow

import Foundation

/// Headless orchestration for workflow session lifecycle (create + state).
///
/// Typed step operations live as extensions on this type in each step's
/// definition file. `public` so ``DeepIDVClient`` can construct it; the
/// initializer is `package`, so external clients never build it directly.
public struct WorkflowService: Sendable {
    private let client: APIClient
    /// Shared step-submit path + envelope decode used by step extensions.
    let steps: WorkflowStepClient

    /// Builds the service from the shared `(config, transport)` seam — same shape
    /// as ``IdentityVerifyService``. `retrySleep` / `timeoutSleep` feed
    /// `APIClient`'s per-attempt retry + timeout race.
    package init(
        config: DeepIDVConfig,
        transport: HTTPTransport,
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep,
        timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep
    ) {
        let api = APIClient(
            config: config, transport: transport,
            retrySleep: retrySleep, timeoutSleep: timeoutSleep)
        self.client = api
        self.steps = WorkflowStepClient(client: api)
    }

    /// Creates a headless workflow session.
    ///
    /// `POST /v1/workflows/{workflow_id}/sessions` with the end-user identity
    /// fields and optional `expires_in_hours`.
    public func createSession(
        workflowID: String,
        user: WorkflowUser,
        expiresInHours: Int? = nil
    ) async throws -> WorkflowSession {
        let body = CreateWorkflowSessionRequest(user: user, expiresInHours: expiresInHours)
        return try await client.post(
            "/v1/workflows/\(workflowID)/sessions", body: body)
    }

    /// Fetches the current execution state for a session.
    ///
    /// `GET /v1/sessions/{session_id}/workflow` — read-only and safe to poll.
    public func fetchState(sessionID: String) async throws -> WorkflowExecutionState {
        try await client.get("/v1/sessions/\(sessionID)/workflow")
    }

    /// Starts a run for an existing headless session that has not begun yet.
    ///
    /// `POST /v1/sessions/{session_id}/workflow/start` — for integrators whose
    /// backend creates the session and hands the app only its id. The call is
    /// validate-only: the server enforces `PENDING` status *and* progress
    /// (409 otherwise) and writes nothing, so it stays repeatable until the
    /// first step submission. The 200 body is the same execution-state
    /// envelope as ``fetchState(sessionID:)``.
    public func startRun(sessionID: String) async throws -> WorkflowExecutionState {
        try await client.post("/v1/sessions/\(sessionID)/workflow/start", body: EmptyBody())
    }
}

// MARK: - Start body

/// The start endpoint takes no parameters beyond the path.
private struct EmptyBody: Encodable {}

// MARK: - Create body

/// Flattened create-session body: user identity fields + optional expiry override.
private struct CreateWorkflowSessionRequest: Encodable {
    let email: String
    let firstName: String
    let lastName: String
    let phone: String
    let externalID: String?
    let expiresInHours: Int?

    enum CodingKeys: String, CodingKey {
        case email
        case firstName = "first_name"
        case lastName = "last_name"
        case phone
        case externalID = "external_id"
        case expiresInHours = "expires_in_hours"
    }

    init(user: WorkflowUser, expiresInHours: Int?) {
        self.email = user.email
        self.firstName = user.firstName
        self.lastName = user.lastName
        self.phone = user.phone
        self.externalID = user.externalID
        self.expiresInHours = expiresInHours
    }
}
