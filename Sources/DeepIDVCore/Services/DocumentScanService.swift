// DeepIDVCore › Services

import Foundation

/// Headless orchestration for the ID-scan → OCR path (`POST /v1/document/scan`).
///
/// Owns the two steps the OCR flow needs: presign-upload the captured image(s)
/// through ``FileUploader``, then call `/v1/document/scan` with the
/// resolved **front** `fileKey`. There is no camera here — it takes
/// already-captured ``FileInput``s, so it is fully exercisable through the
/// transport stub. The SwiftUI capture views drive the camera
/// and hand their frames to this layer.
///
/// `public` so the `DeepIDV` umbrella's `DeepIDVClient` can construct it, but the
/// initializer is `package`, so it stays unconstructable by external clients —
/// they reach this only through `client.scanDocument(...)`.
public struct DocumentScanService: Sendable {
    private let client: APIClient
    private let uploader: FileUploader

    /// Builds the service from the same `(config, transport)` seam the rest of the
    /// SDK threads through, so the transport stub carries straight into this
    /// flow for testing. The `APIClient` (presign POST + scan POST) and the
    /// ``FileUploader`` (S3 PUTs) share the one transport — in production both are
    /// the `URLSessionTransport`; in tests both are the stub.
    ///
    /// `retrySleep`/`timeoutSleep` default to the wall-clock sleeper and are
    /// injectable so service-level retry/timeout tests stay hermetic,
    /// mirroring `APIClient`/`FileUploader`.
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

    /// Uploads the document image(s) and runs server-side OCR.
    ///
    /// Only `front` is OCR'd; `back` (when supplied) is uploaded so its `fileKey`
    /// exists and is returned to the caller, but it is **not** sent to
    /// `/v1/document/scan` (the endpoint accepts a single image). Input problems
    /// (unreadable file, bad base64, unsupported format) surface as `.validation`
    /// from the uploader **before** any network I/O; endpoint failures propagate as
    /// the mapped `DeepIDVError` (auth, validation, rate-limit, timeout, …).
    public func scan(
        front: FileInput,
        back: FileInput? = nil,
        type: DocumentType = .auto
    ) async throws -> DocumentScanResult {
        var inputs = [front]
        if let back { inputs.append(back) }
        let keys = try await uploader.upload(inputs)

        guard keys.count == inputs.count else {
            throw DeepIDVError.api(
                "Upload returned \(keys.count) keys for \(inputs.count) image(s).", status: nil)
        }
        let frontKey = keys[0]
        let backKey = back == nil ? nil : keys[1]

        let request = DocumentScanRequest(image: frontKey, documentType: type.wireValue)
        let wire: DocumentScanWireResponse = try await client.post(
            "/v1/document/scan", body: request)

        return DocumentScanResult(wire: wire, frontImageKey: frontKey, backImageKey: backKey)
    }
}

/// Request body for `POST /v1/document/scan`.
///
/// The SDK always sends an S3 `fileKey` for `image` (never inline base64) and
/// an explicit `documentType` (`type.wireValue`, defaulting to `"auto"`). `private`
/// — the wire shape is an implementation detail of this service.
private struct DocumentScanRequest: Encodable {
    let image: String
    let documentType: String
}
