import Foundation
import Testing

@testable import DeepIDVCore

// Shared result of the VPN-detection and IP-jurisdiction checks. `verdict`
// decodes tolerantly; `action` stays a raw string (the schema doesn't
// enum-constrain it on these endpoints); `evidence` is free-form JSON whose
// scalar values are stringified so an unexpected shape never fails the decode.

private func decode(_ json: String) throws -> IPCheckResult {
    try JSONDecoder().decode(IPCheckResult.self, from: Data(json.utf8))
}

@Test func decodesVerdictActionAndNullEscalation() throws {
    let result = try decode(
        #"{"verdict":"CLEAR","action":"allow","evidence":{"country":"CA"},"escalation":null}"#)
    #expect(result.verdict == .clear)
    #expect(result.action == "allow")
    #expect(result.evidence == ["country": "CA"])
    #expect(result.escalation == nil)
}

@Test func decodesAllVerdictsIncludingUnknown() throws {
    #expect(try decode(#"{"verdict":"HIT","action":"block","evidence":{}}"#).verdict == .hit)
    #expect(
        try decode(#"{"verdict":"UNAVAILABLE","action":"allow","evidence":{}}"#).verdict
            == .unavailable)
    #expect(
        try decode(#"{"verdict":"MAYBE","action":"allow","evidence":{}}"#).verdict
            == .unknown("MAYBE"))
}

@Test func stringifiesNonStringEvidenceValues() throws {
    let result = try decode(
        #"{"verdict":"HIT","action":"block","evidence":{"vpn":true,"score":87,"latency":1.5,"note":null,"nested":{"a":1}}}"#
    )
    #expect(result.evidence["vpn"] == "true")
    #expect(result.evidence["score"] == "87")
    #expect(result.evidence["latency"] == "1.5")
    #expect(result.evidence["note"] == "null")
    #expect(result.evidence["nested"] == "<unsupported>")
}

@Test func decodesEscalationWhenPresent() throws {
    let result = try decode(
        #"{"verdict":"HIT","action":"manual-review","evidence":{},"escalation":{"decision":"ESCALATE","type":"vpn","reason":"datacenter ip"}}"#
    )
    #expect(result.escalation?.decision == "ESCALATE")
    #expect(result.escalation?.type == "vpn")
    #expect(result.escalation?.reason == "datacenter ip")
}

@Test func toleratesAbsentEvidenceKey() throws {
    // The step-not-configured short-circuit always sends evidence, but decode
    // must not hard-require it.
    let result = try decode(#"{"verdict":"UNAVAILABLE","action":"allow"}"#)
    #expect(result.evidence.isEmpty)
}
