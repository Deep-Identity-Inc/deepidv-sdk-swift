// DeepIDVCore › Upload

import Foundation

/// Session-scoped uploads for workflow runs:
/// `POST /v1/sessions/{id}/uploads` → parallel S3 PUTs → slot → opaque `file_key`.
///
/// Dictionary input makes duplicate slots unreachable client-side. `file_key` is
/// opaque — echoed back verbatim at step submit, never reconstructed.
public struct SessionUploader: Sendable {
    private let client: APIClient
    private let putClient: PresignedPutClient

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
        self.putClient = PresignedPutClient(
            config: config, transport: transport,
            retrySleep: retrySleep, timeoutSleep: timeoutSleep)
    }

    /// Presigns via `POST /v1/sessions/{id}/uploads`, PUTs all files in parallel,
    /// and returns each slot's opaque `file_key`. Content type is detected from
    /// magic bytes; `file_name` is derived as `"{slot}.{ext}"`.
    public func upload(
        sessionID: String, files: [SessionUploadSlot: FileInput]
    ) async throws -> [SessionUploadSlot: String] {
        let prepared:
            [(slot: SessionUploadSlot, data: Data, contentType: String, fileName: String)] =
                try files.map { slot, input in
                    let data = try input.normalizedData()
                    let contentType = try detectContentType(data)
                    let ext = contentType == "image/png" ? "png" : "jpg"
                    return (slot, data, contentType, "\(slot.rawValue).\(ext)")
                }

        let request = SessionPresignRequest(
            files: prepared.map {
                SessionPresignRequest.File(
                    fileName: $0.fileName,
                    contentType: $0.contentType,
                    uploadType: $0.slot.rawValue)
            })
        let response: SessionPresignResponse = try await client.post(
            "/v1/sessions/\(sessionID)/uploads", body: request)

        var keysBySlot: [SessionUploadSlot: String] = [:]
        try await withThrowingTaskGroup(of: (SessionUploadSlot, String).self) { group in
            for signed in response.signedURLs {
                guard let slot = SessionUploadSlot(rawValue: signed.uploadType) else {
                    throw DeepIDVError.api(
                        "Presign returned unknown upload_type '\(signed.uploadType)'.",
                        status: nil)
                }
                guard let preparedFile = prepared.first(where: { $0.slot == slot }) else {
                    throw DeepIDVError.api(
                        "Presign returned upload_type '\(signed.uploadType)' not in the request.",
                        status: nil)
                }
                guard let uploadURL = URL(string: signed.uploadURL) else {
                    throw DeepIDVError.api("Presign returned an invalid upload URL.", status: nil)
                }
                let fileKey = signed.fileKey
                let data = preparedFile.data
                let contentType = preparedFile.contentType
                group.addTask {
                    try await self.putClient.put(
                        url: uploadURL, data: data, contentType: contentType)
                    return (slot, fileKey)
                }
            }
            for try await (slot, fileKey) in group {
                keysBySlot[slot] = fileKey
            }
        }

        guard keysBySlot.count == files.count else {
            throw DeepIDVError.api(
                "Presign did not return a signed URL for every requested slot.", status: nil)
        }
        return keysBySlot
    }
}

// MARK: - Wire models

private struct SessionPresignRequest: Encodable {
    struct File: Encodable {
        let fileName: String
        let contentType: String
        let uploadType: String

        enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
            case contentType = "content_type"
            case uploadType = "upload_type"
        }
    }

    let files: [File]
}

private struct SessionPresignResponse: Decodable, Sendable {
    struct SignedURL: Decodable, Sendable {
        let fileKey: String
        let uploadType: String
        let uploadURL: String

        enum CodingKeys: String, CodingKey {
            case fileKey = "file_key"
            case uploadType = "upload_type"
            case uploadURL = "upload_url"
        }
    }

    let signedURLs: [SignedURL]

    enum CodingKeys: String, CodingKey {
        case signedURLs = "signed_urls"
    }
}
