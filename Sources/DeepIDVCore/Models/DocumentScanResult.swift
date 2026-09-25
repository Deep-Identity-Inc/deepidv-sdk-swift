// DeepIDVCore › Models

/// The OCR outcome of a document scan (`POST /v1/document/scan`), plus the S3
/// references for the image(s) the SDK uploaded on the caller's behalf.
///
/// Failures are thrown as `DeepIDVError`, so this type models success only.
///
/// This is *not* `Decodable`: the two `…ImageKey` fields are resolved by the SDK
/// after presign-upload and never appear on the wire, so a direct decode of the
/// API body would fail on the missing keys. The wire half decodes into the
/// private ``DocumentScanWireResponse``; ``DocumentScanService`` then injects the
/// keys via the memberwise/`wire:` initializers below.
public struct DocumentScanResult: Sendable, Equatable {
    // ── OCR fields from /v1/document/scan (front page) ──
    public let documentType: String
    public let fullName: String
    public let firstName: String
    public let lastName: String
    public let dateOfBirth: String
    public let gender: String
    public let nationality: String
    public let documentNumber: String
    public let expirationDate: String
    /// ISO 3166-1 alpha-2 issuing country (e.g. `"US"`).
    public let issuingCountry: String
    public let address: String?
    public let mrzData: String?
    /// Every extracted key/value pair, verbatim from the OCR engine.
    public let rawFields: [String: String]
    /// Average extraction confidence on a **0–1** scale . Note this differs
    /// from `identity/verify`, whose confidences are 0–100 (`IdentityVerifyResult`).
    public let confidence: Double

    // ── SDK-added: S3 references for the uploaded images ──
    /// `fileKey` of the front image (the one OCR'd). Injected by the SDK.
    public let frontImageKey: String
    /// `fileKey` of the back image, when one was captured/uploaded. `nil` for
    /// passport / front-only scans, or when the caller supplied no back image.
    public let backImageKey: String?

    /// Memberwise initializer. `public` because the synthesized one is only
    /// `internal`, so without it a client could name the type but never build one
    /// (useful for tests and previews).
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
        mrzData: String?,
        rawFields: [String: String],
        confidence: Double,
        frontImageKey: String,
        backImageKey: String?
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
        self.mrzData = mrzData
        self.rawFields = rawFields
        self.confidence = confidence
        self.frontImageKey = frontImageKey
        self.backImageKey = backImageKey
    }
}

extension DocumentScanResult {
    /// Builds the public result from a decoded wire response plus the SDK's
    /// uploaded image keys. The single place the network DTO and the SDK-resolved
    /// keys are stitched together (used by ``DocumentScanService``).
    init(wire: DocumentScanWireResponse, frontImageKey: String, backImageKey: String?) {
        self.init(
            documentType: wire.documentType,
            fullName: wire.fullName,
            firstName: wire.firstName,
            lastName: wire.lastName,
            dateOfBirth: wire.dateOfBirth,
            gender: wire.gender,
            nationality: wire.nationality,
            documentNumber: wire.documentNumber,
            expirationDate: wire.expirationDate,
            issuingCountry: wire.issuingCountry,
            address: wire.address,
            mrzData: wire.mrzData,
            rawFields: wire.rawFields,
            confidence: wire.confidence,
            frontImageKey: frontImageKey,
            backImageKey: backImageKey)
    }
}

/// The on-the-wire body of `POST /v1/document/scan`.
///
/// `internal` so the Core service can decode it while it stays hidden from the
/// `DeepIDV` umbrella and external clients. Property names match the API's
/// camelCase keys 1:1, so the default `JSONDecoder` (no snake_case strategy, per
/// `APIClient`) decodes them directly — no `CodingKeys` needed. `address` and
/// `mrzData` are optional in the contract.
struct DocumentScanWireResponse: Decodable, Sendable, Equatable {
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
    let mrzData: String?
    let rawFields: [String: String]
    let confidence: Double
}
