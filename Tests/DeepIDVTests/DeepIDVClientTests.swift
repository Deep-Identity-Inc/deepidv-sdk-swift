// Public-surface tests for the SDK entry point — plain `import DeepIDV`, the way
// a host app sees it.
import DeepIDV
import DeepIDVCore
import Foundation
import Testing

// MARK: - Construction & config resolution

@Test func testInitWithApiKeyAppliesDefaults() {
    let client = DeepIDVClient(apiKey: "sk_live_key")
    #expect(client.config.apiKey == "sk_live_key")
    #expect(client.config.baseURL == DeepIDVConfig.defaultBaseURL)
    #expect(client.config.timeout == 30)
    #expect(client.config.maxRetries == 3)
    #expect(client.config.initialRetryDelay == 0.5)
    #expect(client.config.uploadTimeout == 120)
}

@Test func testInitWithConfigPreservesOverrides() {
    let config = DeepIDVConfig(apiKey: "sk_live_key", timeout: 5, maxRetries: 1)
    let client = DeepIDVClient(config: config)
    #expect(client.config == config)
    #expect(client.config.timeout == 5)
    #expect(client.config.maxRetries == 1)
}

// MARK: - View surface

@MainActor @Test func testPublicViewsInstantiate() {
    // Compile-level smoke: every public view initializer constructs from a client
    // plus a result callback (rendering isn't exercised here). Reaching the
    // assertion means the guided-flow and composable-step surfaces are wired.
    let client = DeepIDVClient(apiKey: "sk_test")
    // Guided flow: the callback now carries the aggregate `IdentityVerifyResult`
    // payload; anti-cheat session smoke too.
    _ = DeepIDVVerificationView(client: client) {
        (_: Result<DeepIDVVerificationResult, DeepIDVError>) in
    }
    _ = DeepIDVVerificationView(client: client, igamingSessionID: "sess-1") { _ in }
    _ = DocumentScannerView(client: client, documentType: .idCard) { _ in }
    // Composable liveness: runs against a host-created verification session.
    _ = CustomFaceLivenessView(client: client, sessionID: "sess-1") {
        (_: Result<FaceLivenessResult, DeepIDVError>) in
    }
    #expect(client.config.apiKey == "sk_test")
}

@MainActor @Test func antiCheatCheckViewInstantiatesFromClient() {
    let client = DeepIDVClient(apiKey: "sk_test")
    _ = AntiCheatCheckView(client: client, sessionID: "sess-1") { _ in }
}

@MainActor @Test func workflowViewInstantiatesFromClient() {
    let client = DeepIDVClient(apiKey: "sk_test")
    _ = DeepIDVWorkflowView(
        client: client,
        workflowID: "workflow-1",
        user: WorkflowUser(
            email: "user@example.com",
            firstName: "Ada",
            lastName: "Lovelace",
            phone: "+15555550100")
    ) { _ in }
}

// MARK: - iGaming client surface

private struct IGamingStubTransport: HTTPTransport {
    let body: Data
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            body,
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}

@Test func clientRunsAntiCheatThroughItsTransport() async throws {
    let client = DeepIDVClient(
        config: DeepIDVConfig(apiKey: "sk_test", maxRetries: 0),
        transport: IGamingStubTransport(
            body: Data(#"{"verdict":"DUPLICATE","action":"flag"}"#.utf8)))

    let result = try await client.checkAntiCheat(
        sessionID: "sess-1", image: .data(Data([0xFF, 0xD8])))

    #expect(result.verdict == .duplicate)
    #expect(result.isDuplicate)
}

@Test func clientRunsIPChecksThroughItsTransport() async throws {
    let client = DeepIDVClient(
        config: DeepIDVConfig(apiKey: "sk_test", maxRetries: 0),
        transport: IGamingStubTransport(
            body: Data(#"{"verdict":"CLEAR","action":"allow","evidence":{}}"#.utf8)))

    let vpn = try await client.checkVPN(sessionID: "sess-1", ipAddress: "203.0.113.7")
    let geo = try await client.checkIPJurisdiction(sessionID: "sess-1", ipAddress: "203.0.113.7")

    #expect(vpn.verdict == .clear)
    #expect(geo.verdict == .clear)
}

// MARK: - Workflow client surface

private struct WorkflowCreateStubTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = Data(
            """
            {
              "session_id": "sess-wf",
              "expires_at": null,
              "current_step": 0,
              "steps": [
                {
                  "step_id": "ID_VERIFICATION",
                  "status": "PENDING",
                  "requirements": {
                    "document": {
                      "require_front_only": false,
                      "front_only_document_types": ["passport"],
                      "require_secondary_id": false,
                      "require_tertiary_id": false,
                      "valid_id_types": ["drivers-license"],
                      "valid_states": []
                    },
                    "face": { "face_front_photo_only": true }
                  }
                }
              ]
            }
            """.utf8)
        return (
            body,
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}

@Test func clientCreatesWorkflowSessionThroughItsTransport() async throws {
    let client = DeepIDVClient(
        config: DeepIDVConfig(apiKey: "sk_test", maxRetries: 0),
        transport: WorkflowCreateStubTransport())

    let session = try await client.createWorkflowSession(
        workflowID: "wf-1",
        user: WorkflowUser(
            email: "a@b.com", firstName: "A", lastName: "B", phone: "+15555550100"))

    #expect(session.sessionID == "sess-wf")
    #expect(session.currentStep == 0)
}
