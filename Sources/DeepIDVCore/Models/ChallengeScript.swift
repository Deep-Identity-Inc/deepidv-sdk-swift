// DeepIDVCore › Models

import Foundation

/// The liveness challenge type the backend `script` asks the client to perform.
/// Raw values are the wire strings from `POST …/custom/sessions`.
public enum ChallengeType: String, Sendable, Equatable, Decodable {
    case faceMovement = "FaceMovementChallenge"
    case faceMovementAndLight = "FaceMovementAndLightChallenge"
}

/// A single step in a ``ChallengeScript``: either a `"move-closer"` prompt or a
/// `"color"` step carrying the hex color to flash.
public struct ChallengeStep: Sendable, Equatable, Decodable {
    /// `"move-closer"` | `"color"`.
    public let kind: String
    /// Offset from the start of the challenge, in milliseconds.
    public let atMs: Int
    /// `"#RRGGBB"` for `color` steps; `nil` otherwise.
    public let color: String?

    public init(kind: String, atMs: Int, color: String? = nil) {
        self.kind = kind
        self.atMs = atMs
        self.color = color
    }
}

/// The server-authored challenge the client must run before capturing frames.
///
/// Keys are camelCase on the wire (`challengeType` / `durationMs` / `atMs`), so
/// no `CodingKeys` are needed here — only ``CustomLivenessSession`` wraps this in
/// a snake_case envelope.
public struct ChallengeScript: Sendable, Equatable, Decodable {
    public let challengeType: ChallengeType
    public let durationMs: Int
    public let steps: [ChallengeStep]

    public init(challengeType: ChallengeType, durationMs: Int, steps: [ChallengeStep]) {
        self.challengeType = challengeType
        self.durationMs = durationMs
        self.steps = steps
    }
}
