// Plain `import` (not @testable): this target deliberately tests only the
// PUBLIC surface — the way a real client app sees the SDK. Reserve `@testable`
// for when you need to reach `internal` symbols, as DeepIDVCoreTests does.
import DeepIDV
import Foundation
import Testing

// MARK: - Headless client method wiring

// The two headless methods are thin pass-throughs to `DocumentScanService` /
// `IdentityVerifyService`, whose request shape, decoding, and error mapping are
// covered end-to-end against the transport stub in `DeepIDVCoreTests`. These
// smoke the *client* layer — that each public method is actually wired to the
// real orchestration. `FileInput` normalization runs before any network I/O, so a
// bad image fails fast with `.validation`: a hermetic way to prove the delegation
// without a live request (a stubbed pass-through wouldn't throw here).

@Test func scanDocumentRejectsInvalidImageBeforeNetwork() async {
    let client = DeepIDVClient(apiKey: "sk_test_key")
    do {
        _ = try await client.scanDocument(front: .base64("not-valid-base64!!!"), type: .passport)
        Issue.record("expected a validation error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func verifyIdentityRejectsInvalidImageBeforeNetwork() async {
    let client = DeepIDVClient(apiKey: "sk_test_key")
    do {
        _ = try await client.verifyIdentity(
            documentFront: .base64("not-valid-base64!!!"),
            selfie: .data(Data()),
            type: .idCard)
        Issue.record("expected a validation error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}
