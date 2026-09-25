import Testing

@testable import DeepIDV

// Selfie framing gates, tested cross-platform on synthetic ``FaceQuality`` (no
// Vision, no camera). Framing only; there is no liveness check here.

private func goodFace() -> FaceQuality {
    FaceQuality(faceCount: 1, faceWidthRatio: 0.42, centerOffset: 0.05)
}

// MARK: - Per-frame gates

@Test func oneCenteredCloseFacePassesEveryGate() {
    let analyzer = SelfieCaptureAnalyzer()
    #expect(analyzer.assess(goodFace()) == nil)
}

@Test func noFaceAsksToLookAtCamera() {
    let analyzer = SelfieCaptureAnalyzer()
    #expect(analyzer.assess(FaceQuality(faceCount: 0)) == .noFace)
}

@Test func multipleFacesIsRejected() {
    let analyzer = SelfieCaptureAnalyzer()
    var quality = goodFace()
    quality.faceCount = 2
    #expect(analyzer.assess(quality) == .multipleFaces)
}

@Test func aSmallFaceAsksToMoveCloser() {
    let analyzer = SelfieCaptureAnalyzer()
    var quality = goodFace()
    quality.faceWidthRatio = 0.20  // below the 0.30 default
    #expect(analyzer.assess(quality) == .moveCloser)
}

@Test func anOffCentreFaceAsksToCenter() {
    let analyzer = SelfieCaptureAnalyzer()
    var quality = goodFace()
    quality.centerOffset = 0.40  // beyond the 0.18 default
    #expect(analyzer.assess(quality) == .centerFace)
}

@Test func selfieGatesAreCheckedMostFundamentalFirst() {
    // No face beats every other complaint.
    let analyzer = SelfieCaptureAnalyzer()
    let quality = FaceQuality(faceCount: 0, faceWidthRatio: 0.05, centerOffset: 0.9)
    #expect(analyzer.assess(quality) == .noFace)
}

// MARK: - Stability

@Test func selfieAutoCapturesAfterEnoughConsecutiveGoodFrames() {
    var analyzer = SelfieCaptureAnalyzer(tunables: .init(stabilityFrameCount: 4))
    let good = goodFace()
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .capture)
    #expect(analyzer.consecutiveGoodFrames == 4)
}

@Test func aFailingFrameResetsTheSelfieStabilityStreak() {
    var analyzer = SelfieCaptureAnalyzer(tunables: .init(stabilityFrameCount: 3))
    let good = goodFace()
    _ = analyzer.evaluate(good)
    _ = analyzer.evaluate(good)
    #expect(analyzer.evaluate(FaceQuality(faceCount: 0)) == .guide(.noFace))
    #expect(analyzer.consecutiveGoodFrames == 0)
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .guide(.holdSteady))
    #expect(analyzer.evaluate(good) == .capture)
}
