import Foundation
import Testing

@testable import DeepIDV
@testable import DeepIDVCore

// MARK: - Test fixtures / stub

extension ChallengeScript {
    static let movement = ChallengeScript(
        challengeType: .faceMovement, durationMs: 2000,
        steps: [ChallengeStep(kind: "move-closer", atMs: 0)])
}

/// A canned ``CustomFaceLivenessServicing`` with spy flags. `@unchecked Sendable`
/// (test-only; access is serialized through the model's awaited tasks).
final class StubCustomService: CustomFaceLivenessServicing, @unchecked Sendable {
    let script: ChallengeScript
    let result: FaceLivenessResult
    var uploadCalled = false

    init(script: ChallengeScript, result: FaceLivenessResult = .init(status: .succeeded, confidence: 90, passed: true)) {
        self.script = script
        self.result = result
    }

    func createSession(sessionID: String) async throws -> CustomLivenessSession {
        CustomLivenessSession(livenessSessionID: "lv-1", script: script)
    }
    func requestUploadURLs(sessionID: String, frameCount: Int, clipMimeType: String?) async throws -> LivenessUploadURLs {
        LivenessUploadURLs(
            frameUploadURLs: [URL(string: "https://s3/0")!], frameKeys: ["k0"],
            timelineUploadURL: URL(string: "https://s3/t")!, timelineKey: "kt")
    }
    func uploadFrames(_ frames: [Data], timeline: Data, clip: Data?, to urls: LivenessUploadURLs) async throws {
        uploadCalled = true
    }
    func fetchResult(sessionID: String) async throws -> FaceLivenessResult {
        result
    }
}

// MARK: - Tests

@MainActor
struct CustomFaceLivenessModelTests {
    @Test func startCreatesAndPublishesScript() async {
        let svc = StubCustomService(script: .movement)
        let model = CustomFaceLivenessModel(service: svc, sessionID: "sess-1") { _ in }
        model.start()
        await model.awaitPendingWork()
        guard case .capturing(let script) = model.state else {
            Issue.record("expected .capturing, got \(model.state)")
            return
        }
        #expect(script.challengeType == .faceMovement)
    }

    @Test func submitUploadsFetchesAndEmitsPassedOnce() async {
        let svc = StubCustomService(
            script: .movement, result: .init(status: .succeeded, confidence: 90, passed: true))
        var emitted: [Result<FaceLivenessResult, DeepIDVError>] = []
        let model = CustomFaceLivenessModel(service: svc, sessionID: "sess-1") { emitted.append($0) }
        model.start()
        await model.awaitPendingWork()
        model.submit(frames: [Data([1])], timeline: Data("[]".utf8))
        await model.awaitPendingWork()
        #expect(emitted.count == 1)
        #expect((try? emitted.first?.get())?.passed == true)
        #expect(svc.uploadCalled == true)
    }

    @Test func cancelEmitsCancelledOnce() async {
        let svc = StubCustomService(script: .movement)
        var emitted: [Result<FaceLivenessResult, DeepIDVError>] = []
        let model = CustomFaceLivenessModel(service: svc, sessionID: "sess-1") { emitted.append($0) }
        model.start()
        await model.awaitPendingWork()
        model.cancel()
        #expect(emitted.count == 1)
        if case .failure(let error) = emitted[0], error.kind == .cancelled {
            // ok
        } else {
            Issue.record("expected .cancelled failure, got \(emitted)")
        }
    }
}
