import Foundation
import Testing

@testable import DeepIDVCore

// The anti-cheat result decodes tolerantly: known verdict/action strings map to
// typed cases, anything new from the server folds into `.unknown(raw)` instead
// of failing the decode (the endpoint is fail-soft — see spec).

private func decode(_ json: String) throws -> AntiCheatResult {
    try JSONDecoder().decode(AntiCheatResult.self, from: Data(json.utf8))
}

@Test func decodesKnownVerdictsAndActions() throws {
    let result = try decode(#"{"verdict":"DUPLICATE","action":"manual-review"}"#)
    #expect(result.verdict == .duplicate)
    #expect(result.action == .manualReview)

    #expect(try decode(#"{"verdict":"UNIQUE","action":"allow"}"#).verdict == .unique)
    #expect(try decode(#"{"verdict":"UNAVAILABLE","action":"allow"}"#).verdict == .unavailable)
    #expect(
        try decode(#"{"verdict":"SELF_EXCLUSION","action":"block"}"#).verdict == .selfExclusion)
    #expect(try decode(#"{"verdict":"UNIQUE","action":"flag"}"#).action == .flag)
    #expect(try decode(#"{"verdict":"UNIQUE","action":"block"}"#).action == .block)
}

@Test func unknownWireValuesFoldIntoUnknownCases() throws {
    let result = try decode(#"{"verdict":"NEW_VERDICT","action":"quarantine"}"#)
    #expect(result.verdict == .unknown("NEW_VERDICT"))
    #expect(result.action == .unknown("quarantine"))
}

@Test func isDuplicateCoversDuplicateAndSelfExclusion() throws {
    #expect(try decode(#"{"verdict":"DUPLICATE","action":"flag"}"#).isDuplicate)
    #expect(try decode(#"{"verdict":"SELF_EXCLUSION","action":"block"}"#).isDuplicate)
    #expect(!(try decode(#"{"verdict":"UNIQUE","action":"allow"}"#).isDuplicate))
    #expect(!(try decode(#"{"verdict":"UNAVAILABLE","action":"allow"}"#).isDuplicate))
}

@Test func isBlockedOnlyForBlockAction() throws {
    #expect(try decode(#"{"verdict":"DUPLICATE","action":"block"}"#).isBlocked)
    #expect(!(try decode(#"{"verdict":"DUPLICATE","action":"manual-review"}"#).isBlocked))
}
