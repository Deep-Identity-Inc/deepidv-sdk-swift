import CoreGraphics
import Testing

// `@testable` (not plain `import DeepIDV`): the capture seam is `internal` SDK
// machinery, not public surface, since no views are wired to it yet, so reaching it
// requires testability — same pattern as the theming tests.
@testable import DeepIDV

// The whole point of the ``CaptureQuality`` seam: these gating tests run headless
// with no camera and no Vision. We feed synthetic per-frame metrics straight in
// and assert the decision — deterministic, and far more controllable than driving
// real photographs through Vision (which needs a device).

// MARK: - Fixtures

/// A frame that passes every gate for the given type — sharp, filled, well-shaped.
private func passingQuality(for type: DocumentType = .idCard) -> CaptureQuality {
    CaptureQuality(
        documentDetected: true,
        fillRatio: 0.72,
        aspectRatio: DocumentCaptureAnalyzer.aspectTargets(for: type).first!,
        sharpness: 300,
        glareRatio: 0.0)
}

/// A passing frame with the document centred at `center` (for jitter tests).
private func passingQuality(at center: CGPoint) -> CaptureQuality {
    CaptureQuality(
        documentDetected: true, fillRatio: 0.72, aspectRatio: 1.586,
        sharpness: 300, glareRatio: 0.0, center: center)
}

// MARK: - Per-frame gates (stateless `assess`)

@Test func sharpFilledStableFramePassesEveryGate() {
    let analyzer = DocumentCaptureAnalyzer(documentType: .idCard)
    #expect(analyzer.assess(passingQuality()) == nil)
}

@Test func noDocumentDetectedAsksToSearch() {
    let analyzer = DocumentCaptureAnalyzer(documentType: .idCard)
    #expect(analyzer.assess(CaptureQuality(documentDetected: false)) == .searching)
}

@Test func documentTooSmallAsksToMoveCloser() {
    let analyzer = DocumentCaptureAnalyzer(documentType: .idCard)
    var quality = passingQuality()
    quality.fillRatio = 0.40  // below the 0.60 default
    #expect(analyzer.assess(quality) == .moveCloser)
}

@Test func wrongAspectAsksToFitInFrame() {
    let analyzer = DocumentCaptureAnalyzer(documentType: .idCard)
    var quality = passingQuality()
    quality.aspectRatio = 1.0  // square — far outside the card band
    #expect(analyzer.assess(quality) == .fitDocumentInFrame)
}

@Test func glareAsksToReduceGlare() {
    let analyzer = DocumentCaptureAnalyzer(documentType: .idCard)
    var quality = passingQuality()
    quality.glareRatio = 0.20  // above the 0.035 default
    #expect(analyzer.assess(quality) == .reduceGlare)
}

@Test func blurryFrameAsksToHoldSteady() {
    let analyzer = DocumentCaptureAnalyzer(documentType: .idCard)
    var quality = passingQuality()
    quality.sharpness = 10  // below the 150 default
    #expect(analyzer.assess(quality) == .holdSteady)
}

@Test func gatesAreCheckedMostFundamentalFirst() {
    // A frame failing several gates surfaces the earliest one: aspect (shape) is
    // reported before glare or blur, so the hint is the one worth acting on.
    let analyzer = DocumentCaptureAnalyzer(documentType: .idCard)
    let quality = CaptureQuality(
        documentDetected: true, fillRatio: 0.72, aspectRatio: 1.0,
        sharpness: 5, glareRatio: 0.9)
    #expect(analyzer.assess(quality) == .fitDocumentInFrame)
}

// MARK: - Per-type aspect band

@Test func passportAspectPassesForPassportType() {
    let analyzer = DocumentCaptureAnalyzer(documentType: .passport)
    #expect(analyzer.assess(passingQuality(for: .passport)) == nil)
}

@Test func autoTypeAcceptsBothPassportAndCardShapes() {
    let analyzer = DocumentCaptureAnalyzer(documentType: .auto)
    var passportShaped = passingQuality()
    passportShaped.aspectRatio = 1.42
    var cardShaped = passingQuality()
    cardShaped.aspectRatio = 1.586
    #expect(analyzer.assess(passportShaped) == nil)
    #expect(analyzer.assess(cardShaped) == nil)
}

// MARK: - Stability (stateful `evaluate`)

@Test func autoCapturesOnlyAfterEnoughConsecutiveGoodFrames() {
    var analyzer = DocumentCaptureAnalyzer(
        documentType: .idCard, tunables: .init(stabilityFrameCount: 4))
    let good = passingQuality()

    // The first three good frames are "hold steady"; the fourth trips capture.
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .capture)
    #expect(analyzer.consecutiveGoodFrames == 4)
}

@Test func aFailingFrameResetsTheStabilityStreak() {
    var analyzer = DocumentCaptureAnalyzer(
        documentType: .idCard, tunables: .init(stabilityFrameCount: 4))
    let good = passingQuality()
    var blurry = good
    blurry.sharpness = 10

    _ = analyzer.evaluate(good)
    _ = analyzer.evaluate(good)
    #expect(analyzer.consecutiveGoodFrames == 2)

    // One bad frame zeroes the streak — a brief good frame mid-wobble can't capture.
    #expect(analyzer.evaluate(blurry) == .guide(.holdSteady))
    #expect(analyzer.consecutiveGoodFrames == 0)

    // It now takes a full fresh run of good frames to lock.
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .capture)
}

@Test func resetClearsTheStreakForTheNextSide() {
    var analyzer = DocumentCaptureAnalyzer(
        documentType: .idCard, tunables: .init(stabilityFrameCount: 3))
    let good = passingQuality()
    _ = analyzer.evaluate(good)
    _ = analyzer.evaluate(good)
    analyzer.reset()  // e.g. "Flip your card" between front and back
    #expect(analyzer.consecutiveGoodFrames == 0)
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
}

// MARK: - Inter-frame motion (jitter)

@Test func aDriftingDocumentResetsStabilityUntilItHoldsStill() {
    var analyzer = DocumentCaptureAnalyzer(
        documentType: .idCard, tunables: .init(stabilityFrameCount: 3, maxCenterJitter: 0.02))

    // Each frame is sharp/filled/well-shaped, but the centre drifts past the jitter
    // threshold each step (a slow pan while aligning) → the streak never builds.
    _ = analyzer.evaluate(passingQuality(at: CGPoint(x: 0.50, y: 0.5)))
    _ = analyzer.evaluate(passingQuality(at: CGPoint(x: 0.56, y: 0.5)))
    _ = analyzer.evaluate(passingQuality(at: CGPoint(x: 0.62, y: 0.5)))
    #expect(analyzer.consecutiveGoodFrames == 0)

    // Held still at one spot → the streak accumulates and locks.
    let still = CGPoint(x: 0.62, y: 0.5)
    #expect(analyzer.evaluate(passingQuality(at: still)) == .guide(.holdSteady))
    #expect(analyzer.evaluate(passingQuality(at: still)) == .guide(.holdSteady))
    #expect(analyzer.evaluate(passingQuality(at: still)) == .capture)
}

@Test func smallCenterJitterStillAllowsCapture() {
    // Tiny hand tremor (under the threshold) must not block a steady capture.
    var analyzer = DocumentCaptureAnalyzer(
        documentType: .idCard, tunables: .init(stabilityFrameCount: 3, maxCenterJitter: 0.02))
    #expect(analyzer.evaluate(passingQuality(at: CGPoint(x: 0.500, y: 0.5))) == .guide(.holdSteady))
    #expect(analyzer.evaluate(passingQuality(at: CGPoint(x: 0.505, y: 0.5))) == .guide(.holdSteady))
    #expect(analyzer.evaluate(passingQuality(at: CGPoint(x: 0.508, y: 0.5))) == .capture)
}
