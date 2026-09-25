// DeepIDVCore › Models › Workflow

import Foundation

/// Hosted-flow `Uploads` slots accepted by
/// `POST /v1/sessions/{session_id}/uploads` and echoed as keys in an
/// `ID_VERIFICATION` submission's `uploads` object.
public enum SessionUploadSlot: String, Sendable, CaseIterable, Codable, Hashable {
    case idFront = "id_front"
    case idBack = "id_back"
    case secondaryIDFront = "secondary_id_front"
    case secondaryIDBack = "secondary_id_back"
    case tertiaryIDFront = "tertiary_id_front"
    case tertiaryIDBack = "tertiary_id_back"
    case selfieFront = "selfie_front"
}

/// Request body for `ID_VERIFICATION` step submission. `uploads` maps each
/// slot to an opaque `file_key` from the session uploader — echoed back
/// verbatim, never reconstructed.
public struct IDVerificationSubmission: Sendable, Equatable, Encodable {
    public let documentType: String
    /// Required by the server iff `require_secondary_id`.
    public let secondaryDocumentType: String?
    /// Required by the server iff `require_tertiary_id`.
    public let tertiaryDocumentType: String?
    /// Slot → opaque `file_key`, encoded as a string-keyed JSON object.
    public let uploads: [SessionUploadSlot: String]

    enum CodingKeys: String, CodingKey {
        case documentType = "document_type"
        case secondaryDocumentType = "secondary_document_type"
        case tertiaryDocumentType = "tertiary_document_type"
        case uploads
    }

    public init(
        documentType: String,
        secondaryDocumentType: String? = nil,
        tertiaryDocumentType: String? = nil,
        uploads: [SessionUploadSlot: String]
    ) {
        self.documentType = documentType
        self.secondaryDocumentType = secondaryDocumentType
        self.tertiaryDocumentType = tertiaryDocumentType
        self.uploads = uploads
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(documentType, forKey: .documentType)
        try container.encodeIfPresent(secondaryDocumentType, forKey: .secondaryDocumentType)
        try container.encodeIfPresent(tertiaryDocumentType, forKey: .tertiaryDocumentType)

        // Dictionary keyed by `SessionUploadSlot` would encode with enum-key
        // representation; the wire wants a plain string-keyed object.
        var uploadsContainer = container.nestedContainer(
            keyedBy: StringCodingKey.self,
            forKey: .uploads
        )
        for (slot, fileKey) in uploads {
            try uploadsContainer.encode(fileKey, forKey: StringCodingKey(slot.rawValue))
        }
    }
}

/// Coding key backed by an arbitrary string — used to encode slot → file_key maps.
struct StringCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}
