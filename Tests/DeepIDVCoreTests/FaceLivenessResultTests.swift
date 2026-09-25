import Foundation
import Testing

@testable import DeepIDVCore

@Test func faceLivenessResultDecodesSucceededAndPassed() throws {
    let json = """
        { "status": "SUCCEEDED", "confidence": 92.5, "passed": true }
        """
    let result = try JSONDecoder().decode(FaceLivenessResult.self, from: Data(json.utf8))

    #expect(result.status == .succeeded)
    #expect(result.confidence == 92.5)  // 0–100 scale
    #expect(result.passed == true)
}

@Test func faceLivenessResultDecodesNotLiveAsPassedFalse() throws {
    // A resolved-but-not-live check still decodes cleanly — it's a success at the
    // result layer, surfaced as `passed == false` rather than an error.
    let json = """
        { "status": "SUCCEEDED", "confidence": 40.0, "passed": false }
        """
    let result = try JSONDecoder().decode(FaceLivenessResult.self, from: Data(json.utf8))

    #expect(result.status == .succeeded)
    #expect(result.confidence == 40.0)
    #expect(result.passed == false)
}

@Test func faceLivenessResultDecodesWithConfidenceAbsent() throws {
    // `confidence` is absent until the session resolves; a missing key
    // decodes to nil via the synthesized `decodeIfPresent`.
    let json = """
        { "status": "IN_PROGRESS", "passed": false }
        """
    let result = try JSONDecoder().decode(FaceLivenessResult.self, from: Data(json.utf8))

    #expect(result.status == .inProgress)
    #expect(result.confidence == nil)
    #expect(result.passed == false)
}

@Test func faceLivenessResultDecodesFailedStatus() throws {
    let json = """
        { "status": "FAILED", "passed": false }
        """
    let result = try JSONDecoder().decode(FaceLivenessResult.self, from: Data(json.utf8))

    #expect(result.status == .failed)
    #expect(result.confidence == nil)
    #expect(result.passed == false)
}

@Test func faceLivenessStatusRawValuesMatchWire() {
    // Wire raw values are the uppercase server statuses.
    #expect(FaceLivenessResult.Status.succeeded.rawValue == "SUCCEEDED")
    #expect(FaceLivenessResult.Status.inProgress.rawValue == "IN_PROGRESS")
    #expect(FaceLivenessResult.Status.failed.rawValue == "FAILED")
    #expect(FaceLivenessResult.Status(rawValue: "SUCCEEDED") == .succeeded)
    #expect(FaceLivenessResult.Status(rawValue: "nope") == nil)
}
