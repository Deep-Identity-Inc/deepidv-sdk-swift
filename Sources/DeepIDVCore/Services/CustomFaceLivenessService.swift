// DeepIDVCore › Services

import Foundation

/// The four methods the custom liveness flow needs from its backend. Exists as a
/// protocol so the UI-layer model can be unit-tested against a stub without a
/// live transport.
public protocol CustomFaceLivenessServicing: Sendable {
    func createSession(sessionID: String) async throws -> CustomLivenessSession
    func requestUploadURLs(sessionID: String, frameCount: Int, clipMimeType: String?) async throws
        -> LivenessUploadURLs
    func uploadFrames(_ frames: [Data], timeline: Data, clip: Data?, to urls: LivenessUploadURLs)
        async throws
    func fetchResult(sessionID: String) async throws -> FaceLivenessResult
}

/// Drives the `FaceLiveness` workflow step (`start → upload-url → complete`)
/// against an existing verification session — `POST
/// /v1/sessions/{sessionID}/steps/face-liveness` with `{action: …}`.
///
/// Challenge type and the pass threshold now live in the workflow step's
/// server-side config — the client sends neither. The step-submit response
/// spreads each action's executor payload under a top-level `liveness` key, so
/// every non-upload call here decodes `Envelope { liveness: T }` and returns
/// `.liveness`. `complete` returns a server-computed `passed`, decoded directly
/// into ``FaceLivenessResult`` with no client-side recompute.
public struct CustomFaceLivenessService: CustomFaceLivenessServicing {
    private let client: APIClient
    private let uploader: LivenessFrameUploader

    package init(
        config: DeepIDVConfig,
        transport: HTTPTransport = URLSessionTransport(),
        uploadSession: URLSession = .shared
    ) {
        self.client = APIClient(config: config, transport: transport)
        self.uploader = LivenessFrameUploader(session: uploadSession)
    }

    private func stepPath(_ sessionID: String) -> String {
        "/v1/sessions/\(sessionID)/steps/face-liveness"
    }

    public func createSession(sessionID: String) async throws -> CustomLivenessSession {
        struct Body: Encodable { let action: String }
        /// `script` is optional so a start without one is a clear error rather
        /// than "failed to decode response body".
        struct Envelope: Decodable {
            struct Liveness: Decodable {
                let script: ChallengeScript?
                let livenessSessionID: String

                enum CodingKeys: String, CodingKey {
                    case script
                    case livenessSessionID = "liveness_session_id"
                }
            }
            let liveness: Liveness
        }
        let env: Envelope = try await client.post(stepPath(sessionID), body: Body(action: "start"))
        guard let script = env.liveness.script else {
            throw DeepIDVError.validation("Custom liveness start returned no challenge script.")
        }
        return CustomLivenessSession(
            livenessSessionID: env.liveness.livenessSessionID, script: script)
    }

    public func requestUploadURLs(
        sessionID: String, frameCount: Int, clipMimeType: String? = nil
    ) async throws -> LivenessUploadURLs {
        struct Body: Encodable {
            let action: String
            let frame_count: Int
            let clip_mime_type: String?
        }
        struct Envelope: Decodable { let liveness: LivenessUploadURLs }
        let env: Envelope = try await client.post(
            stepPath(sessionID),
            body: Body(action: "upload-url", frame_count: frameCount, clip_mime_type: clipMimeType))
        return env.liveness
    }

    public func uploadFrames(
        _ frames: [Data], timeline: Data, clip: Data? = nil, to urls: LivenessUploadURLs
    ) async throws {
        try await uploader.upload(frames, timeline: timeline, clip: clip, to: urls)
    }

    public func fetchResult(sessionID: String) async throws -> FaceLivenessResult {
        struct Body: Encodable { let action: String }
        struct Envelope: Decodable { let liveness: FaceLivenessResult }
        let env: Envelope = try await client.post(
            stepPath(sessionID), body: Body(action: "complete"))
        return env.liveness
    }
}
