import Foundation
import Testing

@testable import DeepIDVCore

@Test func documentScanWireResponseDecodesFullBody() throws {
    let json = """
        {
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
          "mrzData": "P<GBRLOVELACE<<ADA<<<<<<<<<<<<<<<<<<<<<<<<<<",
          "rawFields": { "documentNumber": "P1234567", "gender": "F" },
          "confidence": 0.92
        }
        """
    let wire = try JSONDecoder().decode(
        DocumentScanWireResponse.self, from: Data(json.utf8))

    #expect(wire.documentType == "passport")
    #expect(wire.fullName == "Ada Lovelace")
    #expect(wire.firstName == "Ada")
    #expect(wire.lastName == "Lovelace")
    #expect(wire.dateOfBirth == "1815-12-10")
    #expect(wire.gender == "F")
    #expect(wire.nationality == "GB")
    #expect(wire.documentNumber == "P1234567")
    #expect(wire.expirationDate == "2030-01-01")
    #expect(wire.issuingCountry == "GB")
    #expect(wire.address == "12 Analytical Engine Way")
    #expect(wire.mrzData?.hasPrefix("P<GBR") == true)
    #expect(wire.rawFields["documentNumber"] == "P1234567")
    #expect(wire.rawFields["gender"] == "F")
    #expect(wire.confidence == 0.92)  // 0–1 scale
}

@Test func documentScanWireResponseDecodesWithOptionalFieldsAbsent() throws {
    // `address` and `mrzData` are optional in the contract; absent → nil.
    let json = """
        {
          "documentType": "drivers_license",
          "fullName": "Grace Hopper",
          "firstName": "Grace",
          "lastName": "Hopper",
          "dateOfBirth": "1906-12-09",
          "gender": "F",
          "nationality": "US",
          "documentNumber": "DL987",
          "expirationDate": "2028-06-01",
          "issuingCountry": "US",
          "rawFields": {},
          "confidence": 0.5
        }
        """
    let wire = try JSONDecoder().decode(
        DocumentScanWireResponse.self, from: Data(json.utf8))

    #expect(wire.address == nil)
    #expect(wire.mrzData == nil)
    #expect(wire.rawFields.isEmpty)
}

@Test func resultFromWireInjectsBothImageKeys() throws {
    let json = """
        {
          "documentType": "national_id",
          "fullName": "Alan Turing", "firstName": "Alan", "lastName": "Turing",
          "dateOfBirth": "1912-06-23", "gender": "M", "nationality": "GB",
          "documentNumber": "ID42", "expirationDate": "2029-01-01",
          "issuingCountry": "GB", "rawFields": {}, "confidence": 0.8
        }
        """
    let wire = try JSONDecoder().decode(
        DocumentScanWireResponse.self, from: Data(json.utf8))

    let result = DocumentScanResult(
        wire: wire, frontImageKey: "front-key", backImageKey: "back-key")

    #expect(result.documentNumber == "ID42")
    #expect(result.frontImageKey == "front-key")
    #expect(result.backImageKey == "back-key")
}

@Test func resultFromWireLeavesBackKeyNilForFrontOnly() throws {
    let json = """
        {
          "documentType": "passport",
          "fullName": "Katherine Johnson", "firstName": "Katherine", "lastName": "Johnson",
          "dateOfBirth": "1918-08-26", "gender": "F", "nationality": "US",
          "documentNumber": "P9", "expirationDate": "2031-01-01",
          "issuingCountry": "US", "rawFields": {}, "confidence": 1.0
        }
        """
    let wire = try JSONDecoder().decode(
        DocumentScanWireResponse.self, from: Data(json.utf8))

    let result = DocumentScanResult(
        wire: wire, frontImageKey: "only-front", backImageKey: nil)

    #expect(result.frontImageKey == "only-front")
    #expect(result.backImageKey == nil)
}
