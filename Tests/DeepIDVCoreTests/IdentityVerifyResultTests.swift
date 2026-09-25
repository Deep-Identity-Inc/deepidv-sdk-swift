import Foundation
import Testing

@testable import DeepIDVCore

private let verifyBody = """
    {
      "verified": true,
      "document": {
        "documentType": "passport",
        "fullName": "Ada Lovelace",
        "firstName": "Ada",
        "lastName": "Lovelace",
        "dateOfBirth": "1815-12-10",
        "gender": "F",
        "nationality": "GB",
        "documentNumber": "P1234567",
        "expirationDate": "2030-01-01",
        "issuingCountry": "GB",
        "address": "12 Analytical Engine Way",
        "confidence": 88.5
      },
      "faceDetection": { "faceDetected": true, "confidence": 99.1 },
      "faceMatch": { "isMatch": true, "confidence": 96.0, "threshold": 80.0 },
      "overallConfidence": 94.2
    }
    """

@Test func identityVerifyWireResponseDecodesNestedBody() throws {
    let wire = try JSONDecoder().decode(
        IdentityVerifyWireResponse.self, from: Data(verifyBody.utf8))

    #expect(wire.verified == true)
    #expect(wire.document.fullName == "Ada Lovelace")
    #expect(wire.document.address == "12 Analytical Engine Way")
    #expect(wire.document.confidence == 88.5)  // 0–100 scale
    #expect(wire.faceDetection.faceDetected == true)
    #expect(wire.faceDetection.confidence == 99.1)
    #expect(wire.faceMatch.isMatch == true)
    #expect(wire.faceMatch.confidence == 96.0)
    #expect(wire.faceMatch.threshold == 80.0)
    #expect(wire.overallConfidence == 94.2)
}

@Test func identityVerifyDocumentDecodesWithAddressAbsent() throws {
    let json = """
        {
          "verified": false,
          "document": {
            "documentType": "national_id", "fullName": "Grace Hopper",
            "firstName": "Grace", "lastName": "Hopper", "dateOfBirth": "1906-12-09",
            "gender": "F", "nationality": "US", "documentNumber": "ID7",
            "expirationDate": "2028-01-01", "issuingCountry": "US", "confidence": 70.0
          },
          "faceDetection": { "faceDetected": false, "confidence": 12.0 },
          "faceMatch": { "isMatch": false, "confidence": 20.0, "threshold": 80.0 },
          "overallConfidence": 30.0
        }
        """
    let wire = try JSONDecoder().decode(
        IdentityVerifyWireResponse.self, from: Data(json.utf8))

    #expect(wire.verified == false)
    #expect(wire.document.address == nil)
    #expect(wire.faceMatch.isMatch == false)
}

@Test func resultFromWireInjectsAllThreeImageKeys() throws {
    let wire = try JSONDecoder().decode(
        IdentityVerifyWireResponse.self, from: Data(verifyBody.utf8))

    let result = IdentityVerifyResult(
        wire: wire,
        documentFrontKey: "doc-front",
        documentBackKey: "doc-back",
        selfieKey: "selfie")

    #expect(result.verified == true)
    #expect(result.document.confidence == 88.5)
    #expect(result.faceMatch.threshold == 80.0)
    #expect(result.documentFrontKey == "doc-front")
    #expect(result.documentBackKey == "doc-back")
    #expect(result.selfieKey == "selfie")
}

@Test func resultFromWireLeavesBackKeyNilWhenNoBackCaptured() throws {
    let wire = try JSONDecoder().decode(
        IdentityVerifyWireResponse.self, from: Data(verifyBody.utf8))

    let result = IdentityVerifyResult(
        wire: wire, documentFrontKey: "doc-front", documentBackKey: nil, selfieKey: "selfie")

    #expect(result.documentBackKey == nil)
}
