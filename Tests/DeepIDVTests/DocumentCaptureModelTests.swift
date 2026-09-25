import Foundation
import Testing

@testable import DeepIDV

// The capture coordinator is driven entirely through its seams, so the whole
// flow — auto-capture, front/back sequencing, manual fallback, permission, cancel,
// upload — runs headless with a fake camera and no Vision. These are the
// "view wiring with the fake CameraController" tests.

// MARK: - Fixtures & doubles

private func good() -> CaptureQuality {
    CaptureQuality(
        documentDetected: true, fillRatio: 0.72, aspectRatio: 1.586,
        sharpness: 300, glareRatio: 0.0)
}

private func searching() -> CaptureQuality {
    CaptureQuality(documentDetected: false)
}

private func stubResult() -> DocumentScanResult {
    DocumentScanResult(
        documentType: "national_id", fullName: "Ada Lovelace", firstName: "Ada",
        lastName: "Lovelace", dateOfBirth: "1815-12-10", gender: "F", nationality: "GB",
        documentNumber: "X1", expirationDate: "2030-01-01", issuingCountry: "GB",
        address: nil, mrzData: nil, rawFields: [:], confidence: 0.9,
        frontImageKey: "front-key", backImageKey: nil)
}

/// Returns canned JPEG-magic bytes, or throws a scripted error.
private struct StubStillEncoder: DocumentStillEncoding {
    var error: DeepIDVError?
    func encode(_ frame: CameraFrame, documentType: DocumentType) throws -> FileInput {
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

// Spies are `@unchecked Sendable`: in these tests all access is serialized on the
// main actor (the model is `@MainActor`), so the unchecked storage is race-free.
private final class ScanSpy: @unchecked Sendable {
    var calls: [(front: FileInput, back: FileInput?, type: DocumentType)] = []
    var result: DocumentScanResult
    var error: DeepIDVError?
    init(result: DocumentScanResult) { self.result = result }
    func scan(_ front: FileInput, _ back: FileInput?, _ type: DocumentType) async throws
        -> DocumentScanResult
    {
        calls.append((front, back, type))
        if let error { throw error }
        return result
    }
}

private final class ResultSpy: @unchecked Sendable {
    var result: Result<DocumentScanResult, DeepIDVError>?
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
    type: DocumentType,
    captureMode: CaptureMode? = nil,
    qualities: [CaptureQuality],
    encoder: any DocumentStillEncoding = StubStillEncoder(),
    authorizer: any CameraAuthorizing = StubAuthorizer(),
    scanSpy: ScanSpy,
    resultSpy: ResultSpy
) -> DocumentCaptureModel<DocumentScanResult> {
    DocumentCaptureModel(
        documentType: type,
        captureMode: captureMode,
        controller: FakeCameraController(qualities: qualities),
        evaluator: PassthroughFrameEvaluator(),
        encoder: encoder,
        authorizer: authorizer,
        // holdStillDuration 0: the dwell completes immediately, so capture fires on
        // the analyzer's first `.capture` — keeps these frame-driven tests deterministic.
        // sideCapturedDisplay 0: skip the per-side confirmation flash so the flow
        // doesn't sleep between sides.
        tunables: .init(stabilityFrameCount: 4, holdStillDuration: 0, sideCapturedDisplay: 0),
        complete: { front, back, type in try await scanSpy.scan(front, back, type) },
        onResult: { resultSpy.result = $0 })
}

// MARK: - Happy paths

@MainActor @Test func passportScanUploadsFrontOnlyAndSucceeds() async {
    let scanSpy = ScanSpy(result: stubResult())
    let resultSpy = ResultSpy()
    let model = makeModel(
        type: .passport, qualities: Array(repeating: good(), count: 4),
        scanSpy: scanSpy, resultSpy: resultSpy)

    await model.run()

    #expect(scanSpy.calls.count == 1)
    #expect(scanSpy.calls.first?.type == .passport)
    #expect(scanSpy.calls.first?.back == nil)  // front-only
    #expect(resultSpy.isSuccess)
}

@MainActor @Test func cardScanCapturesFrontThenBackAndSucceeds() async {
    let scanSpy = ScanSpy(result: stubResult())
    let resultSpy = ResultSpy()
    // Four steady frames lock the front; a no-document frame (the flip) arms the
    // back; four more steady frames lock the back — all in one stream pass.
    let model = makeModel(
        type: .idCard,
        qualities: Array(repeating: good(), count: 4) + [searching()]
            + Array(repeating: good(), count: 4),
        scanSpy: scanSpy, resultSpy: resultSpy)

    await model.run()

    #expect(scanSpy.calls.count == 1)
    #expect(scanSpy.calls.first?.type == .idCard)
    #expect(scanSpy.calls.first?.back != nil)  // back captured for two-sided
    #expect(resultSpy.isSuccess)
}

@MainActor @Test func captureModeOverrideCanMakeCardFrontOnly() async {
    let scanSpy = ScanSpy(result: stubResult())
    let resultSpy = ResultSpy()
    let model = makeModel(
        type: .idCard,
        captureMode: .frontOnly,
        qualities: Array(repeating: good(), count: 4),
        scanSpy: scanSpy,
        resultSpy: resultSpy)

    await model.run()

    #expect(scanSpy.calls.count == 1)
    #expect(scanSpy.calls.first?.back == nil)
    #expect(resultSpy.isSuccess)
}

@MainActor @Test func captureModeOverrideCanRequirePassportBack() async {
    let scanSpy = ScanSpy(result: stubResult())
    let resultSpy = ResultSpy()
    let model = makeModel(
        type: .passport,
        captureMode: .frontAndBack,
        qualities: Array(repeating: good(), count: 4) + [searching()]
            + Array(repeating: good(), count: 4),
        scanSpy: scanSpy,
        resultSpy: resultSpy)

    await model.run()

    #expect(scanSpy.calls.count == 1)
    #expect(scanSpy.calls.first?.back != nil)
    #expect(resultSpy.isSuccess)
}

@MainActor @Test func manualShutterCapturesWhenAutoNeverLocks() async {
    let scanSpy = ScanSpy(result: stubResult())
    let resultSpy = ResultSpy()
    // Frames never pass the gates, so only a manual tap can capture.
    let model = makeModel(
        type: .passport, qualities: Array(repeating: searching(), count: 6),
        scanSpy: scanSpy, resultSpy: resultSpy)

    model.triggerManualCapture()
    await model.run()

    #expect(scanSpy.calls.count == 1)
    #expect(resultSpy.isSuccess)
}

// MARK: - Failure & control paths

@MainActor @Test func noLockBeforeTheStreamEndsFailsAsCaptureFailed() async {
    let scanSpy = ScanSpy(result: stubResult())
    let resultSpy = ResultSpy()
    let model = makeModel(
        type: .passport, qualities: Array(repeating: searching(), count: 6),
        scanSpy: scanSpy, resultSpy: resultSpy)

    await model.run()

    #expect(scanSpy.calls.isEmpty)
    #expect(resultSpy.failureKind == .captureFailed)
}

@MainActor @Test func aFailedEncodeSurfacesCaptureFailed() async {
    let scanSpy = ScanSpy(result: stubResult())
    let resultSpy = ResultSpy()
    let model = makeModel(
        type: .passport, qualities: Array(repeating: good(), count: 4),
        encoder: StubStillEncoder(error: .captureFailed("boom")),
        scanSpy: scanSpy, resultSpy: resultSpy)

    await model.run()

    #expect(scanSpy.calls.isEmpty)
    #expect(resultSpy.failureKind == .captureFailed)
}

@MainActor @Test func aScanErrorPropagatesUnchanged() async {
    let scanSpy = ScanSpy(result: stubResult())
    scanSpy.error = .rateLimit("slow down")
    let resultSpy = ResultSpy()
    let model = makeModel(
        type: .passport, qualities: Array(repeating: good(), count: 4),
        scanSpy: scanSpy, resultSpy: resultSpy)

    await model.run()

    #expect(scanSpy.calls.count == 1)  // the scan was attempted
    #expect(resultSpy.failureKind == .rateLimit)  // and its error surfaced as-is
}

@MainActor @Test func deniedCameraPermissionSurfacesTypedErrorWithoutScanning() async {
    let scanSpy = ScanSpy(result: stubResult())
    let resultSpy = ResultSpy()
    let model = makeModel(
        type: .passport, qualities: Array(repeating: good(), count: 4),
        authorizer: StubAuthorizer(status: .denied),
        scanSpy: scanSpy, resultSpy: resultSpy)

    await model.run()

    #expect(scanSpy.calls.isEmpty)
    #expect(resultSpy.failureKind == .cameraPermissionDenied)
    #expect(model.permissionDenied)  // drives the in-view Settings CTA
}

@MainActor @Test func declinedFirstRunPromptSurfacesPermissionDenied() async {
    let scanSpy = ScanSpy(result: stubResult())
    let resultSpy = ResultSpy()
    let model = makeModel(
        type: .passport, qualities: Array(repeating: good(), count: 4),
        authorizer: StubAuthorizer(status: .notDetermined, grant: false),
        scanSpy: scanSpy, resultSpy: resultSpy)

    await model.run()

    #expect(scanSpy.calls.isEmpty)
    #expect(resultSpy.failureKind == .cameraPermissionDenied)
}

@MainActor @Test func cancelSurfacesCancelledAndIsTerminal() async {
    let scanSpy = ScanSpy(result: stubResult())
    let resultSpy = ResultSpy()
    let model = makeModel(
        type: .passport, qualities: Array(repeating: good(), count: 4),
        scanSpy: scanSpy, resultSpy: resultSpy)

    model.cancel()
    #expect(resultSpy.failureKind == .cancelled)

    // A subsequent run is a no-op — the result fires exactly once.
    await model.run()
    #expect(scanSpy.calls.isEmpty)
    #expect(resultSpy.failureKind == .cancelled)
}

// MARK: - Presentation

@MainActor @Test func instructionTextReflectsTypeAndSide() {
    let card = makeModel(
        type: .idCard, qualities: [], scanSpy: ScanSpy(result: stubResult()),
        resultSpy: ResultSpy())
    #expect(card.instructionText == "Scan the front of your document")

    let passport = makeModel(
        type: .passport, qualities: [], scanSpy: ScanSpy(result: stubResult()),
        resultSpy: ResultSpy())
    #expect(passport.instructionText == "Position your document in the frame")
}
