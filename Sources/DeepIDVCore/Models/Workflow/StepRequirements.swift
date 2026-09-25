// DeepIDVCore › Models › Workflow

import Foundation

/// Heterogeneous per-step capture requirements. Decoded through
/// ``WorkflowStepRegistry`` keyed by `step_id`: unknown step ids become
/// `.unsupported` instead of throwing, so a future server-side step type can
/// never brick `fetchState` on an old SDK. Adding a case is a minor-version
/// change — hosts must `switch` with a `default`.
public enum StepRequirements: Sendable, Equatable {
    case idVerification(IDVerificationRequirements)
    case faceLiveness(FaceLivenessRequirements)
    /// Unknown step type — never a decode error.
    case unsupported(stepID: WorkflowStepID)
}

/// Config-derived capture requirements for `ID_VERIFICATION`.
public struct IDVerificationRequirements: Sendable, Equatable, Decodable {
    public struct Document: Sendable, Equatable, Decodable {
        /// Always `false` on create/state — no document type known yet.
        /// Clients check the picked type against ``frontOnlyDocumentTypes``.
        public let requireFrontOnly: Bool
        /// API document types that never need a `*_back` upload (currently
        /// `["passport"]`). Drives back-capture skip per slot.
        public let frontOnlyDocumentTypes: [String]
        public let requireSecondaryID: Bool
        public let requireTertiaryID: Bool
        /// Filters the document-type picker (`valid_id_types`).
        public let validIDTypes: [String]
        public let validStates: [String]

        enum CodingKeys: String, CodingKey {
            case requireFrontOnly = "require_front_only"
            case frontOnlyDocumentTypes = "front_only_document_types"
            case requireSecondaryID = "require_secondary_id"
            case requireTertiaryID = "require_tertiary_id"
            case validIDTypes = "valid_id_types"
            case validStates = "valid_states"
        }

        public init(
            requireFrontOnly: Bool,
            frontOnlyDocumentTypes: [String],
            requireSecondaryID: Bool,
            requireTertiaryID: Bool,
            validIDTypes: [String],
            validStates: [String]
        ) {
            self.requireFrontOnly = requireFrontOnly
            self.frontOnlyDocumentTypes = frontOnlyDocumentTypes
            self.requireSecondaryID = requireSecondaryID
            self.requireTertiaryID = requireTertiaryID
            self.validIDTypes = validIDTypes
            self.validStates = validStates
        }
    }

    public struct Face: Sendable, Equatable, Decodable {
        public let faceFrontPhotoOnly: Bool

        enum CodingKeys: String, CodingKey {
            case faceFrontPhotoOnly = "face_front_photo_only"
        }

        public init(faceFrontPhotoOnly: Bool) {
            self.faceFrontPhotoOnly = faceFrontPhotoOnly
        }
    }

    public let document: Document
    public let face: Face

    public init(document: Document, face: Face) {
        self.document = document
        self.face = face
    }
}

/// Config-derived requirements for `FACE_LIVENESS`. Informational —
/// challenge type and threshold are enforced server-side.
public struct FaceLivenessRequirements: Sendable, Equatable, Decodable {
    /// e.g. `"FaceMovementChallenge"`.
    public let challengeType: String
    /// Server-enforced confidence threshold (workflow default 70).
    public let confidenceThreshold: Int

    enum CodingKeys: String, CodingKey {
        case challengeType = "challenge_type"
        case confidenceThreshold = "confidence_threshold"
    }

    public init(challengeType: String, confidenceThreshold: Int) {
        self.challengeType = challengeType
        self.confidenceThreshold = confidenceThreshold
    }
}
