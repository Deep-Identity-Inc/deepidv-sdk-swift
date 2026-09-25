import Foundation
import Testing

@testable import DeepIDVCore

/// A minimal identity result, built via the public memberwise initializers, so
/// the aggregate tests stay focused on the pairing rather than wire decoding.
private func makeIdentityResult() -> IdentityVerifyResult {
    IdentityVerifyResult(
        verified: true,
        document: IdentityVerifyResult.Document(
            documentType: "passport", fullName: "Ada Lovelace", firstName: "Ada",
            lastName: "Lovelace", dateOfBirth: "1815-12-10", gender: "F",
            nationality: "GB", documentNumber: "P1234567", expirationDate: "2030-01-01",
            issuingCountry: "GB", address: nil, confidence: 90),
        faceDetection: IdentityVerifyResult.FaceDetection(faceDetected: true, confidence: 99),
        faceMatch: IdentityVerifyResult.FaceMatch(isMatch: true, confidence: 96, threshold: 80),
        overallConfidence: 94,
        documentFrontKey: "front", documentBackKey: nil, selfieKey: "selfie")
}

@Test func verificationResultPairsIdentityWithAntiCheat() {
    let antiCheat = AntiCheatResult(verdict: .unique, action: .allow)
    let result = DeepIDVVerificationResult(identity: makeIdentityResult(), antiCheat: antiCheat)

    #expect(result.identity.verified == true)
    #expect(result.antiCheat == antiCheat)
}

@Test func verificationResultDefaultsAntiCheatToNil() {
    // No igamingSessionID → antiCheat nil.
    let result = DeepIDVVerificationResult(identity: makeIdentityResult())
    #expect(result.antiCheat == nil)
}

@Test func verificationResultIsEquatable() {
    let a = DeepIDVVerificationResult(identity: makeIdentityResult())
    let b = DeepIDVVerificationResult(identity: makeIdentityResult())
    let c = DeepIDVVerificationResult(
        identity: makeIdentityResult(),
        antiCheat: AntiCheatResult(verdict: .duplicate, action: .flag))

    #expect(a == b)
    #expect(a != c)
}
