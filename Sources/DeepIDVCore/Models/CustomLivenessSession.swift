// DeepIDVCore › Models

import Foundation

/// The decoded `POST /v1/face/liveness/custom/sessions` response: the
/// server-minted liveness session id and the ``ChallengeScript`` to run.
///
/// The wire envelope is **snake_case** (`liveness_session_id`), so it carries an
/// explicit `CodingKeys` — the nested `script` is already camelCase.
public struct CustomLivenessSession: Sendable, Equatable, Decodable {
    public let livenessSessionID: String
    public let script: ChallengeScript

    enum CodingKeys: String, CodingKey {
        case livenessSessionID = "liveness_session_id"
        case script
    }

    public init(livenessSessionID: String, script: ChallengeScript) {
        self.livenessSessionID = livenessSessionID
        self.script = script
    }
}

/// The decoded `POST …/custom/sessions/{id}/upload-url` response: the presigned
/// S3 PUT URLs for each frame plus the timeline, and their object keys. Wire is
/// **snake_case**.
public struct LivenessUploadURLs: Sendable, Equatable, Decodable {
    public let frameUploadURLs: [URL]
    public let frameKeys: [String]
    public let timelineUploadURL: URL
    public let timelineKey: String
    /// Presigned PUT URL for the full-attempt replay clip. Present only when the
    /// server recognized the requested clip mime; `nil` otherwise.
    public let clipUploadURL: URL?
    public let clipKey: String?

    enum CodingKeys: String, CodingKey {
        case frameUploadURLs = "frame_upload_urls"
        case frameKeys = "frame_keys"
        case timelineUploadURL = "timeline_upload_url"
        case timelineKey = "timeline_key"
        case clipUploadURL = "clip_upload_url"
        case clipKey = "clip_key"
    }

    public init(
        frameUploadURLs: [URL], frameKeys: [String], timelineUploadURL: URL, timelineKey: String,
        clipUploadURL: URL? = nil, clipKey: String? = nil
    ) {
        self.frameUploadURLs = frameUploadURLs
        self.frameKeys = frameKeys
        self.timelineUploadURL = timelineUploadURL
        self.timelineKey = timelineKey
        self.clipUploadURL = clipUploadURL
        self.clipKey = clipKey
    }
}
