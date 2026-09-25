import Testing

@testable import DeepIDV

// Proves the capture pipeline is drivable end-to-end with no camera: a fake
// controller emits a scripted frame sequence, the passthrough evaluator turns each
// frame back into its scripted ``CaptureQuality``, and the analyzer reaches a
// deterministic capture decision. This is the seam the view wiring rides on.

// MARK: - Fixtures

private func good() -> CaptureQuality {
    CaptureQuality(
        documentDetected: true, fillRatio: 0.72, aspectRatio: 1.586,
        sharpness: 300, glareRatio: 0.0)
}

private func searching() -> CaptureQuality {
    CaptureQuality(documentDetected: false)
}

/// Drives every frame from `controller` through the evaluator + analyzer and
/// returns the decision per frame, in order.
private func runPipeline(
    _ controller: FakeCameraController, type: DocumentType,
    tunables: DocumentCaptureTunables
) async -> [CaptureDecision] {
    var analyzer = DocumentCaptureAnalyzer(documentType: type, tunables: tunables)
    let evaluator = PassthroughFrameEvaluator()
    var decisions: [CaptureDecision] = []
    for await frame in controller.frames {
        let quality = evaluator.quality(of: frame, for: type)
        decisions.append(analyzer.evaluate(quality))
    }
    return decisions
}

// MARK: - Tests

@Test func scriptedFramesDriveTheAnalyzerToCapture() async {
    // Two settling frames, then four steady ones (stability = 4) → capture on the last.
    let qualities = [searching(), good(), good(), good(), good()]
    let controller = FakeCameraController(qualities: qualities)

    let decisions = await runPipeline(
        controller, type: .idCard, tunables: .init(stabilityFrameCount: 4))

    #expect(decisions.count == 5)
    #expect(decisions[0] == .guide(.searching))
    #expect(decisions.last == .capture)
    // Capture fires exactly once, on the 4th consecutive good frame (index 4).
    #expect(decisions.firstIndex(of: .capture) == 4)
}

@Test func aStreamThatNeverStabilizesNeverCaptures() async {
    let qualities = [searching(), good(), searching(), good(), searching()]
    let controller = FakeCameraController(qualities: qualities)

    let decisions = await runPipeline(
        controller, type: .idCard, tunables: .init(stabilityFrameCount: 4))

    #expect(!decisions.contains(.capture))
}

@Test func captureStillReturnsTheRequestedFrame() async throws {
    let controller = FakeCameraController(
        qualities: [searching(), good(), good()], stillIndex: 2)
    let still = try await controller.captureStill()
    #expect(still.index == 2)
    #expect(still.syntheticQuality == good())
}

@Test func captureStillDefaultsToTheLastFrame() async throws {
    let controller = FakeCameraController(qualities: [searching(), good(), good()])
    let still = try await controller.captureStill()
    #expect(still.index == 2)  // last frame by default
}

@Test func framesStreamEmitsEveryScriptedFrameInOrder() async {
    let controller = FakeCameraController(qualities: [searching(), good(), good()])
    var indices: [Int] = []
    for await frame in controller.frames { indices.append(frame.index) }
    #expect(indices == [0, 1, 2])
}
