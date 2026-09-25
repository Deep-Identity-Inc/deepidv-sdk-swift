import Foundation
import Testing

@testable import DeepIDV

// The selfie coordinator driven headless via a fake controller + a
// scripted face evaluator ("view wiring with the fake CameraController").

private func goodFace() -> FaceQuality {
    FaceQuality(faceCount: 1, faceWidthRatio: 0.42, centerOffset: 0.05)
}

private func noFace() -> FaceQuality {
    FaceQuality(faceCount: 0)
}

/// Maps each emitted frame to a scripted ``FaceQuality`` by its index.
private struct ScriptedFaceEvaluator: FaceFrameEvaluating {
    let qualities: [FaceQuality]
    func quality(of frame: CameraFrame) -> FaceQuality {
        frame.index < qualities.count ? qualities[frame.index] : FaceQuality(faceCount: 0)
    }
}

private struct StubSelfieEncoder: SelfieStillEncoding {
    var error: DeepIDVError?
    func encode(_ frame: CameraFrame) throws -> FileInput {
        if let error { throw error }
        return .data(Data([0xFF, 0xD8, 0xFF, 0xE0]))
    }
}

private struct StubAuthorizer: CameraAuthorizing {
    var status: CameraAuthorizationStatus = .authorized
    var grant: Bool = true
    func authorizationStatus() -> CameraAuthorizationStatus { status }
    func requestAccess() async -> Bool { grant }
}

private final class ResultSpy: @unchecked Sendable {
    var result: Result<FileInput, DeepIDVError>?
    var isSuccess: Bool {
        if case .success = result { return true }
        return false
    }
    var failureKind: DeepIDVError.Kind? {
        if case .failure(let error) = result { return error.kind }
        return nil
    }
}

@MainActor
private func makeModel(
    faces: [FaceQuality],
    encoder: any SelfieStillEncoding = StubSelfieEncoder(),
    authorizer: any CameraAuthorizing = StubAuthorizer(),
    autoCaptureWarmup: TimeInterval = 0,
    resultSpy: ResultSpy
) -> SelfieCaptureModel {
    SelfieCaptureModel(
        controller: FakeCameraController(frameCount: faces.count),
        evaluator: ScriptedFaceEvaluator(qualities: faces),
        encoder: encoder,
        authorizer: authorizer,
        tunables: .init(stabilityFrameCount: 4, autoCaptureWarmup: autoCaptureWarmup),
        onResult: { resultSpy.result = $0 })
}

// MARK: - Happy paths

@MainActor @Test func aWellFramedFaceAutoCapturesAndReturnsAFileInput() async {
    let resultSpy = ResultSpy()
    let model = makeModel(faces: Array(repeating: goodFace(), count: 4), resultSpy: resultSpy)

    await model.run()

    #expect(resultSpy.isSuccess)
}

@MainActor @Test func manualShutterCapturesWhenFramingNeverLocks() async {
    let resultSpy = ResultSpy()
    // Never a usable face, so only a manual tap can capture.
    let model = makeModel(faces: Array(repeating: noFace(), count: 6), resultSpy: resultSpy)

    model.triggerManualCapture()
    await model.run()

    #expect(resultSpy.isSuccess)
}

@MainActor @Test func autoCaptureHoldsOffDuringTheWarmupPeriod() async {
    let resultSpy = ResultSpy()
    // Every frame is well framed, but the warm-up hasn't elapsed by the time
    // the stream ends — so no auto-capture may fire.
    let model = makeModel(
        faces: Array(repeating: goodFace(), count: 8),
        autoCaptureWarmup: 60,
        resultSpy: resultSpy)

    await model.run()

    #expect(resultSpy.failureKind == .captureFailed)
}

@MainActor @Test func manualCaptureIsNotDelayedByTheWarmupPeriod() async {
    let resultSpy = ResultSpy()
    let model = makeModel(
        faces: Array(repeating: goodFace(), count: 4),
        autoCaptureWarmup: 60,
        resultSpy: resultSpy)

    model.triggerManualCapture()
    await model.run()

    #expect(resultSpy.isSuccess)
}

// MARK: - Failure & control paths

@MainActor @Test func noFramingLockBeforeStreamEndsFailsAsCaptureFailed() async {
    let resultSpy = ResultSpy()
    let model = makeModel(faces: Array(repeating: noFace(), count: 6), resultSpy: resultSpy)

    await model.run()

    #expect(resultSpy.failureKind == .captureFailed)
}

@MainActor @Test func aFailedSelfieEncodeSurfacesCaptureFailed() async {
    let resultSpy = ResultSpy()
    let model = makeModel(
        faces: Array(repeating: goodFace(), count: 4),
        encoder: StubSelfieEncoder(error: .captureFailed("boom")),
        resultSpy: resultSpy)

    await model.run()

    #expect(resultSpy.failureKind == .captureFailed)
}

@MainActor @Test func deniedCameraPermissionSurfacesTypedError() async {
    let resultSpy = ResultSpy()
    let model = makeModel(
        faces: Array(repeating: goodFace(), count: 4),
        authorizer: StubAuthorizer(status: .denied), resultSpy: resultSpy)

    await model.run()

    #expect(resultSpy.failureKind == .cameraPermissionDenied)
    #expect(model.permissionDenied)
}

@MainActor @Test func cancelSurfacesCancelled() async {
    let resultSpy = ResultSpy()
    let model = makeModel(faces: Array(repeating: goodFace(), count: 4), resultSpy: resultSpy)

    model.cancel()

    #expect(resultSpy.failureKind == .cancelled)
}

// MARK: - Instantiation smoke

@MainActor @Test func selfieViewInstantiates() {
    _ = SelfieCaptureView { _ in }
    #expect(Bool(true))
}
