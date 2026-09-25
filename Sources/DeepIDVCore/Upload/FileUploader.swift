// DeepIDVCore › Upload

import Foundation

/// Detects an image's MIME type from its leading magic bytes.
///
/// Supports the two formats the verification pipeline accepts:
/// - JPEG — `FF D8 FF`
/// - PNG  — `89 50 4E 47`
///
/// Fewer than 4 bytes, or any other signature, throws a `.validation` error.
func detectContentType(_ data: Data) throws -> String {
    guard data.count >= 4 else {
        throw DeepIDVError.validation(
            "File is too small to detect content type (minimum 4 bytes).")
    }
    let bytes = [UInt8](data.prefix(4))
    if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
        return "image/jpeg"
    }
    if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
        return "image/png"
    }
    throw DeepIDVError.validation("Unsupported image format. Accepted formats: JPEG, PNG.")
}

/// The shared presigned-upload path every feature module uses.
///
/// One presign call describes the whole batch; each file is then PUT straight to
/// S3 in parallel. Two transport rules differ from a normal API call: S3 PUTs go
/// over the raw transport so the `x-api-key` never reaches S3, and each PUT uses
/// the longer `uploadTimeout` rather than the API `timeout`.
struct FileUploader: Sendable {
    private let config: DeepIDVConfig
    private let client: APIClient
    private let putClient: PresignedPutClient

    init(
        config: DeepIDVConfig,
        client: APIClient,
        transport: HTTPTransport,
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep,
        timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep
    ) {
        self.config = config
        self.client = client
        self.putClient = PresignedPutClient(
            config: config, transport: transport,
            retrySleep: retrySleep, timeoutSleep: timeoutSleep)
    }

    /// Uploads `inputs` and returns their `fileKey`s in input order.
    ///
    /// `contentType`, when given, overrides magic-byte detection for every file.
    /// The presign response's `uploads` are index-aligned with `inputs` — upload
    /// *i* carries file *i* — which is the contract the backend guarantees.
    func upload(_ inputs: [FileInput], contentType: String? = nil) async throws -> [String] {
        let files = try inputs.map { input -> PreparedFile in
            let data = try input.normalizedData()
            let resolvedType = try contentType ?? detectContentType(data)
            return PreparedFile(data: data, contentType: resolvedType)
        }

        let request = PresignRequest(
            files: files.map {
                PresignRequest.File(contentType: $0.contentType, byteLength: $0.data.count)
            })
        let presign: PresignResponse = try await client.post("/v1/upload/presign", body: request)

        guard presign.uploads.count <= files.count else {
            throw DeepIDVError.api("Presign returned more uploads than requested.", status: nil)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, upload) in presign.uploads.enumerated() {
                let file = files[index]
                guard let uploadURL = URL(string: upload.uploadUrl) else {
                    throw DeepIDVError.api("Presign returned an invalid upload URL.", status: nil)
                }
                group.addTask {
                    try await self.putClient.put(
                        url: uploadURL, data: file.data, contentType: file.contentType)
                }
            }
            try await group.waitForAll()
        }

        return presign.uploads.map(\.fileKey)
    }

    private struct PreparedFile: Sendable {
        let data: Data
        let contentType: String
    }
}

// MARK: - Presign wire models

/// Body of `POST /v1/upload/presign` — describes each file in the batch.
private struct PresignRequest: Encodable {
    struct File: Encodable {
        let contentType: String
        let byteLength: Int
    }
    let files: [File]
}

/// Response from `POST /v1/upload/presign`: a presigned S3 URL plus the `fileKey`
/// to reference the object after upload, one entry per requested file.
struct PresignResponse: Decodable, Sendable {
    struct Upload: Decodable, Sendable {
        let uploadUrl: String
        let fileKey: String
    }
    let uploads: [Upload]
}
