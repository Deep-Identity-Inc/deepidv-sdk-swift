import Foundation
import Testing

@testable import DeepIDV

struct CheckMovementLivenessTests {
    // Fewer than 3 frames fails as `.validation` before any network call, so this
    // exercises the client → orchestration wiring with no transport needed.
    @Test func throwsValidationWhenTooFewFrames() async {
        let client = DeepIDVClient(apiKey: "k")
        do {
            _ = try await client.checkMovementLiveness(sessionID: "sess-1", frames: [.data(Data([0xFF]))])
            Issue.record("expected a validation error")
        } catch let error as DeepIDVError {
            #expect(error.kind == .validation)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}
