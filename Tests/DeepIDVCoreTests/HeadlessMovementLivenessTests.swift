import Foundation
import Testing

@testable import DeepIDVCore

/// Records every call so tests can assert the orchestration's sequence + args.
private final class RecordingLivenessService: CustomFaceLivenessServicing, @unchecked Sendable {
    var createdSessionID: String?
    var uploadURLSessionID: String?
    var uploadURLFrameCount: Int?
    var uploadURLClipMime: String?
    var uploadedFrameCount: Int?
    var uploadedFrames: [Data]?
    var uploadedClip: Data?
    var fetchSessionID: String?
    let script: ChallengeScript
    let result: FaceLivenessResult

    init(
        script: ChallengeScript = ChallengeScript(challengeType: .faceMovement, durationMs: 2000, steps: []),
        result: FaceLivenessResult = .init(status: .succeeded, confidence: 90, passed: true)
    ) {
        self.script = script
        self.result = result
    }

    func createSession(sessionID: String) async throws -> CustomLivenessSession {
        createdSessionID = sessionID
        return CustomLivenessSession(livenessSessionID: "lv-1", script: script)
    }
    func requestUploadURLs(
        sessionID: String, frameCount: Int, clipMimeType: String?
    ) async throws -> LivenessUploadURLs {
        uploadURLSessionID = sessionID
        uploadURLFrameCount = frameCount
        uploadURLClipMime = clipMimeType
        return LivenessUploadURLs(
            frameUploadURLs: (0..<frameCount).map { URL(string: "https://s3/f\($0)")! },
            frameKeys: (0..<frameCount).map { "k\($0)" },
            timelineUploadURL: URL(string: "https://s3/t")!, timelineKey: "kt")
    }
    func uploadFrames(_ frames: [Data], timeline: Data, clip: Data?, to urls: LivenessUploadURLs) async throws {
        uploadedFrameCount = frames.count
        uploadedFrames = frames
        uploadedClip = clip
    }
    func fetchResult(sessionID: String) async throws -> FaceLivenessResult {
        fetchSessionID = sessionID
        return result
    }
}

private func frame(_ byte: UInt8) -> FileInput { .data(Data([byte])) }

struct HeadlessMovementLivenessTests {
    @Test func sequencesCreateUploadResultForMovement() async throws {
        let svc = RecordingLivenessService()
        let result = try await runMovementLiveness(
            sessionID: "sess-1", frames: [frame(1), frame(2), frame(3)], service: svc)

        #expect(svc.createdSessionID == "sess-1")
        #expect(svc.uploadURLSessionID == "sess-1")
        #expect(svc.uploadURLFrameCount == 3)
        #expect(svc.uploadURLClipMime == nil)   // no clip in headless
        #expect(svc.uploadedFrameCount == 3)
        #expect(svc.uploadedClip == nil)
        #expect(svc.fetchSessionID == "sess-1")
        #expect(result.passed == true)
    }

    @Test func throwsValidationBelowThreeFrames() async {
        let svc = RecordingLivenessService()
        do {
            _ = try await runMovementLiveness(sessionID: "sess-1", frames: [frame(1), frame(2)], service: svc)
            Issue.record("expected a validation error")
        } catch let error as DeepIDVError {
            #expect(error.kind == .validation)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
        #expect(svc.createdSessionID == nil)  // threw before any network
    }

    @Test func throwsWhenStepReturnsNonMovementScript() async {
        let svc = RecordingLivenessService(
            script: ChallengeScript(challengeType: .faceMovementAndLight, durationMs: 2000, steps: []))
        do {
            _ = try await runMovementLiveness(
                sessionID: "sess-1", frames: [frame(1), frame(2), frame(3)], service: svc)
            Issue.record("expected a validation error")
        } catch let error as DeepIDVError {
            #expect(error.kind == .validation)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
        #expect(svc.uploadURLSessionID == nil)  // threw before upload
    }

    @Test func samplesDownToEightFrames() async throws {
        let svc = RecordingLivenessService()
        let twenty = (0..<20).map { frame(UInt8($0)) }
        _ = try await runMovementLiveness(sessionID: "sess-1", frames: twenty, service: svc)
        #expect(svc.uploadURLFrameCount == 8)
        #expect(svc.uploadedFrameCount == 8)
    }

    @Test func samplesNineFramesKeepingFirstAndLast() async throws {
        let svc = RecordingLivenessService()
        let nine = (0..<9).map { frame(UInt8($0)) }   // .data(Data([0]))...([8])
        _ = try await runMovementLiveness(sessionID: "sess-1", frames: nine, service: svc)
        #expect(svc.uploadedFrameCount == 8)
        #expect(svc.uploadedFrames?.first == Data([0]))   // first input kept
        #expect(svc.uploadedFrames?.last == Data([8]))    // last (closest) input kept
    }

    @Test func uploadsReplayClipWhenProvided() async throws {
        let svc = RecordingLivenessService()
        let clip = Data([0xAA, 0xBB, 0xCC])
        _ = try await runMovementLiveness(
            sessionID: "sess-1", frames: [frame(1), frame(2), frame(3)], clip: clip, service: svc)
        #expect(svc.uploadURLClipMime == "video/mp4")   // clip present → mp4 mime requested
        #expect(svc.uploadedClip == clip)               // exact bytes forwarded
    }

    @Test func noClipMimeWhenClipAbsent() async throws {
        let svc = RecordingLivenessService()
        _ = try await runMovementLiveness(sessionID: "sess-1", frames: [frame(1), frame(2), frame(3)], service: svc)
        #expect(svc.uploadURLClipMime == nil)
        #expect(svc.uploadedClip == nil)
    }
}
