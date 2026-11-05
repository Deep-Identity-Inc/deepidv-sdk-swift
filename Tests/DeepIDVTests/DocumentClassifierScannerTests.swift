import Foundation
import Testing

@testable import DeepIDV
@testable import DeepIDVCore

// The classifier scanner, driven with scripted classifier answers, fake image
// work and a manual clock: no camera, no network.

// MARK: - Doubles

/// Answers each request with `answer(request)`, recording every request.
private final class ScriptedDetector: DetectSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [DetectRequest] = []
    private let answer: @Sendable (DetectRequest, Int) -> DetectResponse

    init(_ answer: @escaping @Sendable (DetectRequest, Int) -> DetectResponse) {
        self.answer = answer
    }

    var requests: [DetectRequest] { lock.withLock { _requests } }

    func detect(_ request: DetectRequest) async throws -> DetectResponse {
        let index = lock.withLock {
            _requests.append(request)
            return _requests.count - 1
        }
        return answer(request, index)
    }
}

/// Never answers, until cancelled.
private struct SilentDetector: DetectSending {
    func detect(_ request: DetectRequest) async throws -> DetectResponse {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
        return .failure(DetectFailure(status: 0, reason: .failed))
    }
}

/// Image work without pixels: frames are told apart by index.
private struct FakeImaging: ClassifierImaging {
    var stillSharpness: Double? = 250

    func prepare(_ frame: CameraFrame, box: CGRect?) -> PreparedFrame? {
        PreparedFrame(image: nil, tag: frame.index)
    }
    func detectImage(_ frame: PreparedFrame, rotation: Int) -> String? {
        "img-\(frame.tag)-\(rotation)"
    }
    func keptFrame(_ frame: CameraFrame) -> FileInput? {
        .data(Data([0x4B, UInt8(frame.index % 256)]))
    }
    func sharpness(of photo: FileInput, frameWidth: Int) -> Double? { stillSharpness }
    func turnedOver(_ photo: FileInput) -> FileInput? {
        guard case .data(let data) = photo else { return nil }
        return .data(data + [0xEE])
    }
}

@MainActor
private final class ManualClock {
    var now: TimeInterval = 0
}

// MARK: - Fixtures

private let good = CaptureQuality(
    documentDetected: true, fillRatio: 0.7, aspectRatio: 1.586, sharpness: 300, glareRatio: 0,
    boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4))

private func card(_ id: String, _ confidence: Double, named: Bool? = nil) -> DetectResponse {
    .answer(
        DetectAnswer(
            present: true, box: .init(xyxy: [1, 2, 3, 4]),
            documentType: .init(
                id: (named ?? (confidence >= 0.502)) ? id : nil, confidence: confidence,
                top3: [
                    .init(id: id, confidence: confidence), .init(id: "ca_ab_id", confidence: 0.04),
                ]),
            modelVersion: "m-test"))
}

private let still = FileInput.data(Data([0xFF, 0xD8, 0x01]))

private func bytes(_ input: FileInput) -> Data? { ClassifierImages.data(of: input) }

@MainActor
private func makeScanner(
    _ detector: any DetectSending, type: DocumentType = .driversLicense,
    imaging: FakeImaging = FakeImaging(),
    availability: ClassifierAvailability = ClassifierAvailability(),
    clock: ManualClock
) -> DocumentClassifierScanner {
    DocumentClassifierScanner(
        documentType: type, sessionID: "sess-test-1", detector: detector, imaging: imaging,
        availability: availability, clock: { clock.now })
}

/// Offers one good frame every `step` seconds from the clock's time, letting each
/// call finish before the next frame.
@MainActor
private func run(
    _ scanner: DocumentClassifierScanner, clock: ManualClock, frames: Int, step: TimeInterval = 0.5,
    quality: CaptureQuality = good, framed: Bool? = nil, visionReady: Bool = true
) async {
    for i in 0..<frames {
        scanner.observe(
            CameraFrame(index: i, syntheticQuality: quality), quality: quality,
            framed: framed ?? visionReady, visionReady: visionReady, at: clock.now)
        await scanner.settle()
        clock.now += step
    }
}

// MARK: - Calls and verdicts

@MainActor @Test func theFirstFrameIsSentAndTheVerdictWaitsForAnAnswer() async throws {
    let clock = ManualClock()
    let detector = ScriptedDetector { _, _ in card("ca_on_dl", 0.8) }
    let scanner = makeScanner(detector, clock: clock)
    #expect(scanner.verdict(at: 0) == .hold(.connecting))

    await run(scanner, clock: clock, frames: 1)
    let request = try #require(detector.requests.first)
    #expect(request.imageB64 == "img-0-0")
    #expect(request.frame == 1)
    #expect(request.method == "dl")
    #expect(request.scanID.hasPrefix("sess-test-1-"))
    #expect(scanner.verdict(at: clock.now) == .hold(.identifying))
}

@MainActor @Test func callsGoOneAtATimeAtMostTwiceASecond() async {
    let clock = ManualClock()
    let detector = ScriptedDetector { _, _ in card("ca_on_dl", 0.3) }
    let scanner = makeScanner(detector, clock: clock)
    // Frames every 0.125 s for 1 s: a call at 0, then one at 0.5, then at 1.0.
    await run(scanner, clock: clock, frames: 9, step: 0.125)
    #expect(detector.requests.filter { $0.frame != nil }.count == 3)
}

@MainActor @Test func aCardNamedTwiceIsTypedAndTheVerdictIsGo() async throws {
    let clock = ManualClock()
    let availability = ClassifierAvailability()
    let scanner = makeScanner(
        ScriptedDetector { _, _ in card("ca_on_dl", 0.8) }, availability: availability, clock: clock
    )
    await run(scanner, clock: clock, frames: 2)
    #expect(scanner.verdict(at: clock.now) == .go)
    #expect(availability.state == .available)

    let report = await scanner.frontCaptured(photo: still, manual: false, at: clock.now)
    let classification = try #require(report.classification)
    #expect(classification.documentType == "ca_on_dl")
    #expect(classification.trust == .api)
    #expect(classification.captureMode == .auto)
    #expect(classification.captureRotation == 0)
    #expect(classification.frames.count == 2)
    #expect(report.extraFrames.isEmpty, "extra frames are off by default")
}

@MainActor @Test func answersOnAFramedButUnsteadyCardStillVote() async {
    // A handheld card is rarely steady or crisp when a frame goes out: the answer
    // still counts when the card is in position, as on the web.
    let clock = ManualClock()
    let scanner = makeScanner(ScriptedDetector { _, _ in card("ca_on_dl", 0.8) }, clock: clock)
    await run(scanner, clock: clock, frames: 2, framed: true, visionReady: false)
    #expect(scanner.verdict(at: clock.now) == .go)
}

@MainActor @Test func answersOnACardOutOfPositionDoNotVote() async {
    let clock = ManualClock()
    let scanner = makeScanner(ScriptedDetector { _, _ in card("ca_on_dl", 0.8) }, clock: clock)
    await run(scanner, clock: clock, frames: 2, framed: false, visionReady: false)
    #expect(scanner.verdict(at: clock.now) != .go)
}

@MainActor @Test func aManualPhotoIsReportedAsManual() async {
    let clock = ManualClock()
    let scanner = makeScanner(ScriptedDetector { _, _ in card("ca_on_dl", 0.8) }, clock: clock)
    await run(scanner, clock: clock, frames: 2)
    let report = await scanner.frontCaptured(photo: still, manual: true, at: clock.now)
    #expect(report.classification?.captureMode == .manual)
}

@MainActor @Test func nothingConfirmedReportsNoClassification() async {
    let clock = ManualClock()
    let scanner = makeScanner(ScriptedDetector { _, _ in card("ca_on_dl", 0.3) }, clock: clock)
    await run(scanner, clock: clock, frames: 2)
    let report = await scanner.frontCaptured(photo: still, manual: false, at: clock.now)
    #expect(report.classification == nil)
    #expect(bytes(report.photo) == bytes(still))
}

@MainActor @Test func aSessionWithoutTheClassifierSwitchesItOffForGood() async {
    let clock = ManualClock()
    let availability = ClassifierAvailability()
    let detector = ScriptedDetector { _, _ in
        .failure(DetectFailure(status: 403, reason: .unavailable))
    }
    let scanner = makeScanner(detector, availability: availability, clock: clock)
    await run(scanner, clock: clock, frames: 4)
    #expect(availability.state == .unavailable)
    #expect(scanner.verdict(at: clock.now) == .off)
    #expect(detector.requests.count == 1, "no calls after the first refusal")

    // A later front in the same session doesn't even try.
    let next = makeScanner(detector, availability: availability, clock: clock)
    await run(next, clock: clock, frames: 2)
    #expect(next.verdict(at: clock.now) == .off)
    #expect(detector.requests.count == 1)
}

@MainActor @Test func threeFailedCallsInARowSwitchTheSideOff() async {
    let clock = ManualClock()
    let detector = ScriptedDetector { _, _ in .failure(DetectFailure(status: 500, reason: .failed))
    }
    let scanner = makeScanner(detector, clock: clock)
    await run(scanner, clock: clock, frames: 3)
    #expect(scanner.verdict(at: clock.now) == .off)
    await run(scanner, clock: clock, frames: 3)
    #expect(detector.requests.count == 3)
}

@MainActor @Test func aRateLimitBacksOffBeforeTheNextCall() async {
    let clock = ManualClock()
    let detector = ScriptedDetector { _, index in
        index == 0
            ? .failure(DetectFailure(status: 429, reason: .rateLimited(retryAfter: nil)))
            : card("ca_on_dl", 0.3)
    }
    let scanner = makeScanner(detector, clock: clock)
    // Frames every 0.25 s: after the 429 at 0, nothing until 1 s.
    await run(scanner, clock: clock, frames: 4, step: 0.25)
    #expect(detector.requests.count == 1)
    await run(scanner, clock: clock, frames: 1)
    #expect(detector.requests.count == 2)
}

@MainActor @Test func noAnswerWithinTheWaitLimitFallsBackToOnDevice() async {
    let clock = ManualClock()
    let scanner = makeScanner(SilentDetector(), clock: clock)
    for i in 0...9 {
        scanner.observe(
            CameraFrame(index: i, syntheticQuality: good), quality: good, framed: true, visionReady: true,
            at: clock.now)
        clock.now += 0.5
    }
    #expect(scanner.verdict(at: clock.now) == .off)
    scanner.stop()
}

@MainActor @Test func theWaitLimitOnlyCountsWhileTheOnDeviceChecksPass() async {
    let clock = ManualClock()
    let scanner = makeScanner(SilentDetector(), clock: clock)
    for i in 0...9 {
        scanner.observe(
            CameraFrame(index: i, syntheticQuality: good), quality: good, framed: i % 3 != 0, visionReady: i % 3 != 0,
            at: clock.now)
        clock.now += 0.5
    }
    #expect(scanner.verdict(at: clock.now) == .hold(.connecting))
    scanner.stop()
}

// MARK: - Health cards, other documents, upside down

@MainActor @Test func aHealthCardBlocksCapture() async {
    let clock = ManualClock()
    let scanner = makeScanner(ScriptedDetector { _, _ in card("ca_on_hc", 0.9) }, clock: clock)
    await run(scanner, clock: clock, frames: 3)
    #expect(scanner.verdict(at: clock.now) == .block(.healthCard))
}

@MainActor @Test func anotherKindOfDocumentIsNamedThenCapturedUntyped() async {
    let clock = ManualClock()
    let scanner = makeScanner(
        ScriptedDetector { _, _ in card("us_passport_book", 0.9) }, type: .idCard, clock: clock)
    await run(scanner, clock: clock, frames: 2)
    #expect(scanner.verdict(at: clock.now) == .hold(.otherDocument(.passport)))
    // After the untyped wait the classifier lets it through.
    await run(scanner, clock: clock, frames: 10)
    #expect(scanner.verdict(at: clock.now) == .go)
    let report = await scanner.frontCaptured(photo: still, manual: false, at: clock.now)
    #expect(report.classification == nil, "another document's type is never reported")
}

@MainActor @Test func aCardHeldUpsideDownIsTurnedAndSoIsThePhoto() async throws {
    let clock = ManualClock()
    // Upright frames score low for a wrong class; probes (no frame number) score
    // high for the real card the right way up.
    let detector = ScriptedDetector { request, _ in
        if request.frame == nil { return card("ca_on_dl", 0.9) }
        return request.imageB64.hasSuffix("-180") ? card("ca_on_dl", 0.85) : card("us_tx_dl", 0.3)
    }
    let scanner = makeScanner(detector, clock: clock)
    await run(scanner, clock: clock, frames: 4)
    #expect(scanner.rotation == 180)
    let probes = detector.requests.filter { $0.frame == nil }
    #expect(probes.count == 2)
    #expect(probes.allSatisfy { $0.imageB64.hasSuffix("-180") })

    // From the flip on, frames go turned, and the card is typed.
    await run(scanner, clock: clock, frames: 2)
    #expect(detector.requests.last?.imageB64.hasSuffix("-180") == true)
    #expect(scanner.verdict(at: clock.now) == .go)

    let report = await scanner.frontCaptured(photo: still, manual: false, at: clock.now)
    #expect(report.classification?.captureRotation == 180)
    #expect(
        bytes(report.photo) == Data([0xFF, 0xD8, 0x01, 0xEE]), "the photo is turned right way up")
    let frames = try #require(report.classification?.frames)
    #expect(frames.contains { $0.decision == FrameDiagnostic.probeDecision })
}

@MainActor @Test func whileAProbeBeatsTheFramesTheUserIsAskedToTurnTheCard() async {
    let clock = ManualClock()
    // Probes beat the frames but aren't strong enough to flip.
    let detector = ScriptedDetector { request, _ in
        request.frame == nil ? card("ca_on_dl", 0.6, named: false) : card("us_tx_dl", 0.2)
    }
    let scanner = makeScanner(detector, clock: clock)
    await run(scanner, clock: clock, frames: 3)
    #expect(scanner.verdict(at: clock.now) == .hold(.wrongWay))
}

// MARK: - The photo and extra frames

@MainActor @Test func aMuchSharperKeptFrameReplacesABlurryStill() async {
    let clock = ManualClock()
    let scanner = makeScanner(
        ScriptedDetector { _, _ in card("ca_on_dl", 0.8) },
        imaging: FakeImaging(stillSharpness: 100), clock: clock)
    await run(scanner, clock: clock, frames: 3, step: 0.25)  // kept frames at sharpness 300
    let report = await scanner.frontCaptured(photo: still, manual: false, at: clock.now - 0.25)
    #expect(bytes(report.photo) != bytes(still))
}

@MainActor @Test func aSharpStillIsKept() async {
    let clock = ManualClock()
    let scanner = makeScanner(
        ScriptedDetector { _, _ in card("ca_on_dl", 0.8) },
        imaging: FakeImaging(stillSharpness: 250), clock: clock)
    await run(scanner, clock: clock, frames: 3, step: 0.25)
    let report = await scanner.frontCaptured(photo: still, manual: false, at: clock.now - 0.25)
    #expect(bytes(report.photo) == bytes(still))
}

@MainActor @Test func extraFramesGoWithThePhotoOnlyWhenEnabled() async {
    let clock = ManualClock()
    let scanner = makeScanner(
        ScriptedDetector { _, _ in card("ca_on_dl", 0.8) },
        imaging: FakeImaging(stillSharpness: 250),
        availability: ClassifierAvailability(sendsExtraFrames: true), clock: clock)
    await run(scanner, clock: clock, frames: 5, step: 0.25)
    let report = await scanner.frontCaptured(photo: still, manual: false, at: clock.now - 0.25)
    #expect(bytes(report.photo) == bytes(still))
    #expect(report.extraFrames.count == 2)
}

@MainActor @Test func afterThePhotoTheScannerStops() async {
    let clock = ManualClock()
    let detector = ScriptedDetector { _, _ in card("ca_on_dl", 0.8) }
    let scanner = makeScanner(detector, clock: clock)
    await run(scanner, clock: clock, frames: 1)
    _ = await scanner.frontCaptured(photo: still, manual: false, at: clock.now)
    await run(scanner, clock: clock, frames: 3)
    #expect(detector.requests.count == 1)
    #expect(scanner.verdict(at: clock.now) == .off)
}

// MARK: - Copy

@Test func everyClassifierGuidanceHasCopy() {
    #expect(CaptureOverlayView.hintText(for: .identifying) == "Checking your ID…")
    #expect(CaptureOverlayView.hintText(for: .wrongWay) == "Turn your card the right way up")
    #expect(
        CaptureOverlayView.hintText(for: .healthCard)
            == "Health cards can't be used. Please use a different ID.")
    #expect(
        CaptureOverlayView.hintText(for: .otherDocument(.idCard))
            == "This looks like an ID card. Is this the right document?")
    #expect(CaptureOverlayView.hintText(for: .connecting) == "Getting ready…")
}

@Test func theClassifierCropGrowsTheBoxAndFallsBackToTheMiddle() {
    let crop = ClassifierImages.cropRect(
        box: CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.2), frameAspect: 0.75)
    #expect(abs(crop.minX - 0.1) < 1e-9 && abs(crop.width - 0.6) < 1e-9)
    #expect(abs(crop.minY - 0.35) < 1e-9 && abs(crop.height - 0.3) < 1e-9)
    let clamped = ClassifierImages.cropRect(
        box: CGRect(x: 0, y: 0, width: 0.9, height: 0.9), frameAspect: 0.75)
    #expect(clamped == CGRect(x: 0, y: 0, width: 1, height: 1))
    let middle = ClassifierImages.cropRect(box: nil, frameAspect: 0.75)
    #expect(abs(middle.midX - 0.5) < 1e-9 && abs(middle.midY - 0.5) < 1e-9)
}
