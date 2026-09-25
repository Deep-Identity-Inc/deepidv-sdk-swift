// DeepIDVCore › Services

import Foundation

/// Headless orchestration for the identity-verify path.
///
/// Owns the two steps: presign-upload the document image(s) + selfie through
/// ``FileUploader``, then call `/v1/identity/verify` with the document **front**
/// and **selfie** `fileKey`s. The endpoint runs document OCR + face detect + face
/// compare server-side; the SDK's job is capture, upload, and result
/// presentation. No camera here — it takes already-captured ``FileInput``s, so it
/// is fully exercisable through the transport stub.
///
/// `public` so `DeepIDVClient` can construct it; the initializer is `package`, so
/// external clients reach this only through `client.verifyIdentity(...)`.
public struct IdentityVerifyService: Sendable {
    private let client: APIClient
    private let uploader: FileUploader

    /// Builds the service from the shared `(config, transport)` seam — same shape
    /// as ``DocumentScanService``. The `APIClient` and ``FileUploader`` share the
    /// one transport (`URLSessionTransport` in production, the stub in tests).
    /// `retrySleep`/`timeoutSleep` are injectable for hermetic retry/timeout tests
    /// and default to the wall-clock sleeper.
    package init(
        config: DeepIDVConfig,
        transport: HTTPTransport,
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep,
        timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep
    ) {
        let client = APIClient(
            config: config, transport: transport,
            retrySleep: retrySleep, timeoutSleep: timeoutSleep)
        self.client = client
        self.uploader = FileUploader(
            config: config, client: client, transport: transport,
            retrySleep: retrySleep, timeoutSleep: timeoutSleep)
    }

    /// Uploads the document and selfie and runs the combined verify.
    ///
    /// `documentBack` (when supplied) is uploaded so its `fileKey` exists and is
    /// returned, but it is **not** consumed by `/v1/identity/verify` — only the
    /// document front and the selfie are sent. Input problems surface as
    /// `.validation` from the uploader before any network I/O; endpoint failures
    /// propagate as the mapped `DeepIDVError`.
    public func verify(
        documentFront: FileInput,
        documentBack: FileInput? = nil,
        selfie: FileInput,
        type: DocumentType = .auto
    ) async throws -> IdentityVerifyResult {
        var inputs = [documentFront]
        if let documentBack { inputs.append(documentBack) }
        inputs.append(selfie)
        let selfieIndex = inputs.count - 1
        let keys = try await uploader.upload(inputs)

        guard keys.count == inputs.count else {
            throw DeepIDVError.api(
                "Upload returned \(keys.count) keys for \(inputs.count) image(s).", status: nil)
        }
        let frontKey = keys[0]
        let backKey = documentBack == nil ? nil : keys[1]
        let selfieKey = keys[selfieIndex]

        let request = IdentityVerifyRequest(
            documentImage: frontKey, faceImage: selfieKey, documentType: type.wireValue)
        let wire: IdentityVerifyWireResponse = try await client.post(
            "/v1/identity/verify", body: request)

        return IdentityVerifyResult(
            wire: wire, documentFrontKey: frontKey, documentBackKey: backKey, selfieKey: selfieKey)
    }
}

/// Request body for `POST /v1/identity/verify`.
///
/// Both images are S3 `fileKey`s; `documentType` is always sent
/// (`type.wireValue`, defaulting to `"auto"`). The document **back** key is never
/// part of this body. `private` — internal to this service.
private struct IdentityVerifyRequest: Encodable {
    let documentImage: String
    let faceImage: String
    let documentType: String
}
