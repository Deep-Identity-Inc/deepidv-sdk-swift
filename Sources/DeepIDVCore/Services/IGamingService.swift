// DeepIDVCore › Services

import Foundation

/// Headless client for the iGaming compliance checks
/// (`POST /v1/igaming/anti-cheat` / `vpn-detection` / `ip-jurisdiction`).
///
/// Three thin one-shot POSTs on `APIClient` — no polling, no upload presign
/// (the anti-cheat image goes inline as base64, unlike the S3-keyed document
/// flows). Every call references an existing verification `session_id`; the
/// SDK never creates sessions — the host app (or its backend) mints one via
/// `POST /v1/sessions` against a workflow with the corresponding steps.
///
/// `public` so `DeepIDVClient` can construct it; the initializer is `package`,
/// so external clients reach these only through the `checkAntiCheat` /
/// `checkVPN` / `checkIPJurisdiction` client methods.
public struct IGamingService: Sendable {
    private let client: APIClient

    /// The API's JSON body limit is 5 MB (`bodyParser.json({limit: "5mb"})`);
    /// cap the base64 image payload just under it, leaving headroom for the
    /// other body fields. Checked pre-flight so an oversized image fails as
    /// `.validation` before any network I/O. Compared against
    /// `base64.utf8.count` — base64 output is pure ASCII, so one UTF-8 code
    /// unit is exactly one wire byte.
    static let maxBase64ImageBytes = 5 * 1024 * 1024 - 4 * 1024

    /// Builds the service from the shared `(config, transport)` seam — same
    /// shape as the sibling services. The sleep seams feed `APIClient`'s
    /// retry/timeout race and default to the wall clock; tests inject no-ops.
    package init(
        config: DeepIDVConfig,
        transport: HTTPTransport,
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep,
        timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep
    ) {
        self.client = APIClient(
            config: config, transport: transport,
            retrySleep: retrySleep, timeoutSleep: timeoutSleep)
    }

    /// Runs the anti-cheat face check: dedup ("has this face already signed
    /// up?"), self-exclusion, and multi-accounting linkage. Enrolls the face
    /// on first sight.
    ///
    /// The image is sent as **raw base64 in the JSON body** (no
    /// `data:…;base64,` prefix, no multipart) — the endpoint's only accepted
    /// shape. An image too large for the 5 MB body cap is automatically
    /// downscaled/re-encoded to fit (face dedup doesn't need full resolution);
    /// images that already fit are sent byte-identical. Input problems
    /// (unreadable file, bad base64, oversized data that isn't a decodable
    /// image) surface as `.validation` before any network I/O.
    ///
    /// The endpoint is fail-soft: `{verdict: UNAVAILABLE, action: allow}` is a
    /// normal success covering bad input, terminal sessions, an unconfigured
    /// step, and server errors. The only hard failure is 404 → `.notFound`
    /// (missing **or** cross-org session — indistinguishable by design).
    /// `action == .block` means the server already marked the session FAILED.
    public func checkAntiCheat(
        sessionID: String,
        image: FileInput,
        deviceFingerprint: String? = nil
    ) async throws -> AntiCheatResult {
        let normalized = try AntiCheatImageNormalizer.normalize(
            image.normalizedData(), maxBase64Bytes: Self.maxBase64ImageBytes)
        let base64 = normalized.base64EncodedString()
        return try await client.post(
            "/v1/igaming/anti-cheat",
            body: AntiCheatRequest(
                sessionId: sessionID, image: base64, deviceFingerprint: deviceFingerprint))
    }

    /// Runs the VPN/proxy/Tor/datacenter IP check against the session's
    /// `vpn-detection` workflow step.
    ///
    /// The caller supplies `ipAddress` — the endpoint takes it in the body
    /// rather than deriving it from the request. A workflow without the step
    /// short-circuits to `{verdict: UNAVAILABLE, action: allow}` (success).
    public func checkVPN(sessionID: String, ipAddress: String) async throws -> IPCheckResult {
        try await client.post(
            "/v1/igaming/vpn-detection",
            body: IPCheckRequest(sessionId: sessionID, ipAddress: ipAddress))
    }

    /// Resolves the IP to a jurisdiction and evaluates it against the
    /// session's `ip-jurisdiction` workflow step. Same request/response
    /// contract and short-circuit behavior as ``checkVPN(sessionID:ipAddress:)``.
    public func checkIPJurisdiction(
        sessionID: String, ipAddress: String
    ) async throws -> IPCheckResult {
        try await client.post(
            "/v1/igaming/ip-jurisdiction",
            body: IPCheckRequest(sessionId: sessionID, ipAddress: ipAddress))
    }
}

/// Request body for `POST /v1/igaming/anti-cheat`. `private` — the wire shape
/// is an implementation detail of this service. A nil `deviceFingerprint` is
/// omitted from the JSON (synthesized `Encodable` uses `encodeIfPresent`).
private struct AntiCheatRequest: Encodable {
    let sessionId: String
    let image: String
    let deviceFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case image
        case deviceFingerprint = "device_fingerprint"
    }
}

/// Shared request body for the two IP checks. `private` — wire detail.
private struct IPCheckRequest: Encodable {
    let sessionId: String
    let ipAddress: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case ipAddress = "ip_address"
    }
}
