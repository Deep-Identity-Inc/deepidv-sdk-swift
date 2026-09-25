// DeepIDV — the umbrella module clients `import`.

import CoreVideo
import SwiftUI
// `@_exported import` re-exposes DeepIDVCore's PUBLIC types (DocumentType,
// FileInput, DocumentScanResult, IdentityVerifyResult, DeepIDVError, …) through
// DeepIDV. Without this, a client doing `import DeepIDV` could call
// `client.scanDocument` but couldn't name `FileInput` to build its argument —
// because DeepIDVCore isn't a product they can import. The underscore means
// "officially unsupported but widely used"; the supported alternatives are (a)
// make DeepIDVCore a product too, or (b) declare `public typealias` re-exports
// here. Note this only re-exports `public` symbols — the `package` networking
// stack stays hidden.
@_exported import DeepIDVCore

/// The single public entry point to the SDK.
///
/// Configure it with your `x-api-key` (or a full ``DeepIDVConfig``) and use it to
/// run the verification flows. The client is a lightweight `Sendable` value that
/// owns the resolved config and the injectable transport seam; copy or share it
/// freely across concurrency domains.
///
/// ```swift
/// import DeepIDV
///
/// let client = DeepIDVClient(apiKey: "sk_live_…")
/// let result = try await client.scanDocument(front: .fileURL(frontImageURL), type: .passport)
/// ```
public struct DeepIDVClient: Sendable {
    /// The fully-resolved configuration backing this client (defaults applied).
    public let config: DeepIDVConfig

    /// The injectable transport the networking stack is built on. Stored
    /// on the instance so the headless flow methods construct their Core services
    /// against it — and so tests can drive those services with a stub instead of a
    /// live `URLSession`.
    private let transport: any HTTPTransport

    /// Creates a client with default configuration and the given API key.
    public init(apiKey: String) {
        self.init(config: DeepIDVConfig(apiKey: apiKey))
    }

    /// Creates a client from a fully-specified configuration.
    public init(config: DeepIDVConfig) {
        self.init(config: config, transport: URLSessionTransport())
    }

    /// Designated initializer with the injectable transport seam.
    /// `package` so tests elsewhere in this package can substitute a stubbed
    /// transport for the default `URLSession`, while it stays hidden from external
    /// clients (`package` symbols aren't re-exported by `@_exported import`).
    package init(config: DeepIDVConfig, transport: any HTTPTransport) {
        self.config = config
        self.transport = transport
    }

    // MARK: - Headless flows

    /// Uploads the document image(s) and runs server-side OCR
    /// (`POST /v1/document/scan`).
    ///
    /// Only `front` is OCR'd; `back` (when supplied) is uploaded so its `fileKey`
    /// exists and is returned on the result, but it is **not** scanned. `type`
    /// defaults to `.auto` (let the server classify the document); the capture
    /// views pass an explicit type since they must know whether to shoot one side
    /// or two before capture.
    ///
    /// There's no camera here — it takes already-captured ``FileInput``s. Input
    /// problems (unreadable file, bad base64,
    /// unsupported format) surface as `.validation` before any network I/O;
    /// endpoint failures propagate as the mapped ``DeepIDVError``.
    public func scanDocument(
        front: FileInput,
        back: FileInput? = nil,
        type: DocumentType = .auto
    ) async throws -> DocumentScanResult {
        try await DocumentScanService(config: config, transport: transport)
            .scan(front: front, back: back, type: type)
    }

    /// Uploads the document and selfie and runs the combined identity verify
    /// (`POST /v1/identity/verify`) — document OCR + face detect + face compare,
    /// all server-side.
    ///
    /// `documentBack` (when supplied) is uploaded and keyed but **not** consumed by
    /// the endpoint. Same testability and error contract as
    /// ``scanDocument(front:back:type:)``.
    public func verifyIdentity(
        documentFront: FileInput,
        documentBack: FileInput? = nil,
        selfie: FileInput,
        type: DocumentType = .auto
    ) async throws -> IdentityVerifyResult {
        try await IdentityVerifyService(config: config, transport: transport)
            .verify(
                documentFront: documentFront, documentBack: documentBack,
                selfie: selfie, type: type)
    }

    // MARK: - Workflows

    /// Creates a headless workflow session
    /// (`POST /v1/workflows/{workflow_id}/sessions`).
    public func createWorkflowSession(
        workflowID: String,
        user: WorkflowUser,
        expiresInHours: Int? = nil
    ) async throws -> WorkflowSession {
        try await makeWorkflowService().createSession(
            workflowID: workflowID, user: user, expiresInHours: expiresInHours)
    }

    /// Fetches workflow execution state
    /// (`GET /v1/sessions/{session_id}/workflow`).
    public func fetchWorkflowState(sessionID: String) async throws -> WorkflowExecutionState {
        try await makeWorkflowService().fetchState(sessionID: sessionID)
    }

    /// Starts an existing un-started headless session
    /// (`POST /v1/sessions/{session_id}/workflow/start`), returning the
    /// execution state the run begins from.
    ///
    /// Use this when the session was created by your backend rather than by
    /// ``createWorkflowSession(workflowID:user:expiresInHours:)``. A session
    /// that has already started, or is terminal, fails with
    /// ``DeepIDVError/Kind/conflict``.
    public func startWorkflowSession(sessionID: String) async throws -> WorkflowExecutionState {
        try await makeWorkflowService().startRun(sessionID: sessionID)
    }

    /// Builds a ``WorkflowService`` from this client's `(config, transport)`.
    /// `package` so the workflow view/model and tests share the seam — external
    /// clients use the public create/state wrappers (and the workflow view for
    /// step execution).
    package func makeWorkflowService() -> WorkflowService {
        WorkflowService(config: config, transport: transport)
    }

    /// Builds a ``SessionUploader`` from this client's `(config, transport)`.
    /// `package` for the workflow view/model and tests.
    package func makeSessionUploader() -> SessionUploader {
        SessionUploader(config: config, transport: transport)
    }

    // MARK: - iGaming checks

    /// Runs the iGaming anti-cheat face check (`POST /v1/igaming/anti-cheat`):
    /// face dedup ("has this face already signed up?"), self-exclusion, and
    /// multi-accounting linkage. Enrolls the face on first sight.
    ///
    /// `sessionID` references an existing verification session created via
    /// `POST /v1/sessions` (by your backend — the SDK never creates sessions)
    /// against a workflow with the `anti-cheat` step. The image goes inline as
    /// base64 (≲5 MB) — larger images are automatically downscaled to fit;
    /// unreadable or undecodable input fails as `.validation`
    /// before any network I/O. The endpoint is fail-soft — `verdict ==
    /// .unavailable` with `action == .allow` is a normal success, and the only
    /// hard failure is `.notFound` for a missing session. The SDK reports the
    /// verdict; blocking policy is yours (except `action == .block`, which the
    /// server has already enforced by failing the session).
    public func checkAntiCheat(
        sessionID: String,
        image: FileInput,
        deviceFingerprint: String? = nil
    ) async throws -> AntiCheatResult {
        try await makeIGamingService().checkAntiCheat(
            sessionID: sessionID, image: image, deviceFingerprint: deviceFingerprint)
    }

    /// Runs the iGaming VPN/proxy/Tor IP check
    /// (`POST /v1/igaming/vpn-detection`) against the session's
    /// `vpn-detection` workflow step. You supply `ipAddress` — the endpoint
    /// takes it in the body rather than deriving it server-side, and a phone
    /// can't reliably know its own public IP, which is why this check has no
    /// SDK UI. A workflow without the step short-circuits to
    /// `verdict == .unavailable` / `action == "allow"` (a success).
    public func checkVPN(
        sessionID: String, ipAddress: String
    ) async throws -> IPCheckResult {
        try await makeIGamingService().checkVPN(sessionID: sessionID, ipAddress: ipAddress)
    }

    /// Resolves the IP to a jurisdiction and evaluates eligibility
    /// (`POST /v1/igaming/ip-jurisdiction`) against the session's
    /// `ip-jurisdiction` workflow step. Same contract and caveats as
    /// ``checkVPN(sessionID:ipAddress:)``.
    public func checkIPJurisdiction(
        sessionID: String, ipAddress: String
    ) async throws -> IPCheckResult {
        try await makeIGamingService().checkIPJurisdiction(
            sessionID: sessionID, ipAddress: ipAddress)
    }

    /// Builds an ``IGamingService`` from this client's `(config, transport)`.
    /// `package` so the anti-cheat view/model and tests share the seam —
    /// external clients use the three public check methods above.
    package func makeIGamingService() -> IGamingService {
        IGamingService(config: config, transport: transport)
    }

    package func makeCustomFaceLivenessService() -> CustomFaceLivenessService {
        CustomFaceLivenessService(config: config, transport: transport)
    }

    /// Builds a `ReVerificationService` from this client's `(config, transport)`.
    /// `package` so the re-verify view's flow model and tests share the seam —
    /// there is no public headless re-verification API.
    package func makeReVerificationService() -> ReVerificationService {
        ReVerificationService(config: config, transport: transport)
    }

    // MARK: - Re-verification

    /// Builds the view that re-verifies a returning applicant by face: one
    /// native liveness capture, searched against the already verified
    /// applicants of the same organization
    ///
    /// Presenting the view starts the flow. It delivers exactly one result:
    /// business outcomes arrive as `.success` (``ReVerifyResult``); errors,
    /// including the view being dismissed before an outcome
    /// (``DeepIDVError/Kind/cancelled``), arrive as `.failure`. The view renders
    /// nothing once `onResult` fires — dismiss it and show your own result
    /// screen. It has no cancel control of its own. UIKit hosts can present it
    /// with `UIHostingController`.
    @MainActor
    public func makeReVerifyView(
        workflowID: String,
        onResult: @escaping (Result<ReVerifyResult, DeepIDVError>) -> Void
    ) -> some View {
        ReVerifyFlowView(client: self, workflowID: workflowID, onResult: onResult)
    }

    /// Runs custom face-MOVEMENT liveness headlessly: you capture an ordered
    /// "move closer" sequence (the face growing larger frame to frame) in your own
    /// camera + UI, and the SDK uploads it and returns the server's verdict — no
    /// SDK chrome. Pair with ``faceProbe(_:)`` to time the capture.
    ///
    /// `sessionID` references an existing verification session created via
    /// `POST /v1/sessions` (by your backend — the SDK never creates sessions)
    /// against a workflow with a `face-liveness` step. The step's server-side
    /// config owns both the challenge type and the pass threshold — this call
    /// sends neither; if the step turns out to be configured for the flashing
    /// -light challenge, it throws `.validation` (headless movement can't run
    /// that challenge; use ``CustomFaceLivenessView`` instead).
    ///
    /// Provide **3–8 frames in capture order**. Fewer than 3 throws
    /// `.validation`; more than 8 is evenly down-sampled to 8 (the server's
    /// per-request cap). The liveness verdict — including `passed` — is
    /// server-computed; this call orchestrates create → upload → score.
    ///
    /// Movement only — the flashing-light challenge requires SDK UI and can't run
    /// headless.
    ///
    /// `clip` is an optional operator replay: record it with a
    /// ``MovementReplayRecorder`` (fed the same frames as ``faceProbe(_:)``) and
    /// the SDK uploads it as the session's replay clip. `nil` skips it.
    public func checkMovementLiveness(
        sessionID: String,
        frames: [FileInput],
        clip: Data? = nil
    ) async throws -> FaceLivenessResult {
        try await runMovementLiveness(
            sessionID: sessionID,
            frames: frames,
            clip: clip,
            service: makeCustomFaceLivenessService())
    }

    /// Creates a replay recorder for the headless movement flow. Feed it the same
    /// `CVPixelBuffer`s you pass to ``faceProbe(_:)``, then hand `finish()`'s bytes
    /// to ``checkMovementLiveness(sessionID:frames:clip:)`` as `clip`.
    /// The SDK owns the encoding; you own one `append` per frame.
    public func makeMovementReplayRecorder() -> MovementReplayRecorder {
        MovementReplayRecorder()
    }

    /// On-device face detection for one camera frame — stateless and local (no
    /// network, no session). Call it per frame in your own capture loop to drive a
    /// "center your face → move closer" UI and decide when to grab a
    /// ``checkMovementLiveness(sessionID:frames:clip:)`` frame (e.g. capture
    /// each time ``FaceProbe/widthRatio`` crosses the next step between
    /// ``FaceProbe/centeredMinWidth`` and ``FaceProbe/closeTargetWidth``).
    public func faceProbe(_ pixelBuffer: CVPixelBuffer) -> FaceProbe {
        FaceProbe(
            VisionFaceFrameEvaluator().quality(of: CameraFrame(index: 0, pixelBuffer: pixelBuffer)))
    }
}
