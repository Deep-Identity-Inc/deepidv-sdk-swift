// DeepIDVCore › Models

/// The combined outcome of `POST /v1/identity/verify` — server-side document OCR,
/// face detection, and face compare — plus the S3 references for the images the
/// SDK uploaded (document front/back + selfie).
///
/// Like ``DocumentScanResult`` this is *not* `Decodable`: the `…Key` fields are
/// SDK-resolved and never on the wire. The wire half decodes into the
/// private ``IdentityVerifyWireResponse``; ``IdentityVerifyService`` injects the
/// image keys.
///
/// **Scale note:** every confidence here is **0–100** — unlike
/// `document/scan.confidence`, which is 0–1. The SDK preserves each field's
/// native scale rather than silently rescaling.
public struct IdentityVerifyResult: Sendable, Equatable {
    public let verified: Bool
    public let document: Document
    public let faceDetection: FaceDetection
    public let faceMatch: FaceMatch
    /// Weighted aggregate, **0–100**.
    public let overallConfidence: Double

    /// The OCR subset returned inside a verify response (a trimmed
    /// ``DocumentScanResult`` — no `mrzData`/`rawFields`, confidence on 0–100).
    public struct Document: Sendable, Equatable {
        public let documentType: String
        public let fullName: String
        public let firstName: String
        public let lastName: String
        public let dateOfBirth: String
        public let gender: String
        public let nationality: String
        public let documentNumber: String
        public let expirationDate: String
        /// ISO 3166-1 alpha-2 issuing country.
        public let issuingCountry: String
        public let address: String?
        /// Extraction confidence, **0–100**
        public let confidence: Double

        public init(
            documentType: String,
            fullName: String,
            firstName: String,
            lastName: String,
            dateOfBirth: String,
            gender: String,
            nationality: String,
            documentNumber: String,
            expirationDate: String,
            issuingCountry: String,
            address: String?,
            confidence: Double
        ) {
            self.documentType = documentType
            self.fullName = fullName
            self.firstName = firstName
            self.lastName = lastName
            self.dateOfBirth = dateOfBirth
            self.gender = gender
            self.nationality = nationality
            self.documentNumber = documentNumber
            self.expirationDate = expirationDate
            self.issuingCountry = issuingCountry
            self.address = address
            self.confidence = confidence
        }
    }

    /// Whether a face was found in the selfie, with detection confidence (0–100).
    public struct FaceDetection: Sendable, Equatable {
        public let faceDetected: Bool
        public let confidence: Double

        public init(faceDetected: Bool, confidence: Double) {
            self.faceDetected = faceDetected
            self.confidence = confidence
        }
    }

    /// The selfie-vs-document face comparison: match flag, similarity, and the
    /// threshold the match was decided against (all 0–100).
    public struct FaceMatch: Sendable, Equatable {
        public let isMatch: Bool
        public let confidence: Double
        public let threshold: Double

        public init(isMatch: Bool, confidence: Double, threshold: Double) {
            self.isMatch = isMatch
            self.confidence = confidence
            self.threshold = threshold
        }
    }

    // ── SDK-added: S3 references for the uploaded images ──
    /// `fileKey` of the document front (the image OCR'd + matched). Injected by the SDK.
    public let documentFrontKey: String
    /// `fileKey` of the document back when captured. Uploaded per the type's
    /// capture rule but **not** sent to `/v1/identity/verify`; `nil` otherwise.
    public let documentBackKey: String?
    /// `fileKey` of the selfie. Injected by the SDK.
    public let selfieKey: String

    public init(
        verified: Bool,
        document: Document,
        faceDetection: FaceDetection,
        faceMatch: FaceMatch,
        overallConfidence: Double,
        documentFrontKey: String,
        documentBackKey: String?,
        selfieKey: String
    ) {
        self.verified = verified
        self.document = document
        self.faceDetection = faceDetection
        self.faceMatch = faceMatch
        self.overallConfidence = overallConfidence
        self.documentFrontKey = documentFrontKey
        self.documentBackKey = documentBackKey
        self.selfieKey = selfieKey
    }
}

extension IdentityVerifyResult {
    /// Builds the public result from a decoded wire response plus the SDK's three
    /// uploaded image keys. Used by ``IdentityVerifyService``.
    init(
        wire: IdentityVerifyWireResponse,
        documentFrontKey: String,
        documentBackKey: String?,
        selfieKey: String
    ) {
        self.init(
            verified: wire.verified,
            document: Document(
                documentType: wire.document.documentType,
                fullName: wire.document.fullName,
                firstName: wire.document.firstName,
                lastName: wire.document.lastName,
                dateOfBirth: wire.document.dateOfBirth,
                gender: wire.document.gender,
                nationality: wire.document.nationality,
                documentNumber: wire.document.documentNumber,
                expirationDate: wire.document.expirationDate,
                issuingCountry: wire.document.issuingCountry,
                address: wire.document.address,
                confidence: wire.document.confidence),
            faceDetection: FaceDetection(
                faceDetected: wire.faceDetection.faceDetected,
                confidence: wire.faceDetection.confidence),
            faceMatch: FaceMatch(
                isMatch: wire.faceMatch.isMatch,
                confidence: wire.faceMatch.confidence,
                threshold: wire.faceMatch.threshold),
            overallConfidence: wire.overallConfidence,
            documentFrontKey: documentFrontKey,
            documentBackKey: documentBackKey,
            selfieKey: selfieKey)
    }
}

/// The on-the-wire body of `POST /v1/identity/verify`
///
/// `internal` so the Core service decodes it while it stays hidden from the
/// umbrella and external clients. Nested types mirror the response's nested
/// objects; camelCase keys match the default `JSONDecoder` 1:1 (no `CodingKeys`).
struct IdentityVerifyWireResponse: Decodable, Sendable, Equatable {
    let verified: Bool
    let document: Document
    let faceDetection: FaceDetection
    let faceMatch: FaceMatch
    let overallConfidence: Double

    struct Document: Decodable, Sendable, Equatable {
        let documentType: String
        let fullName: String
        let firstName: String
        let lastName: String
        let dateOfBirth: String
        let gender: String
        let nationality: String
        let documentNumber: String
        let expirationDate: String
        let issuingCountry: String
        let address: String?
        let confidence: Double
    }
    struct FaceDetection: Decodable, Sendable, Equatable {
        let faceDetected: Bool
        let confidence: Double
    }
    struct FaceMatch: Decodable, Sendable, Equatable {
        let isMatch: Bool
        let confidence: Double
        let threshold: Double
    }
}
