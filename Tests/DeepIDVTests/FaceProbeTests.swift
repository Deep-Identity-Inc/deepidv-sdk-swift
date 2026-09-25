import CoreVideo
import Testing

@testable import DeepIDV

private func blankPixelBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pb)
    return pb!
}

struct FaceProbeTests {
    @Test func mapsFaceQualityFields() {
        let probe = FaceProbe(FaceQuality(faceCount: 2, faceWidthRatio: 0.5, centerOffset: 0.1))
        #expect(probe.faceCount == 2)
        #expect(probe.widthRatio == 0.5)
        #expect(probe.centerOffset == 0.1)
    }

    @Test func thresholdsMatchTheMovementChoreography() {
        #expect(FaceProbe.centeredMaxOffset == LivenessChoreography.maxCenterOffset)
        #expect(FaceProbe.centeredMinWidth == LivenessChoreography.minFaceWidthRatio)
        #expect(FaceProbe.closeTargetWidth == LivenessChoreography.targetFaceWidthRatio)
    }

    @Test func facelessBufferReportsNoFace() {
        let client = DeepIDVClient(apiKey: "k")
        let probe = client.faceProbe(blankPixelBuffer())
        #expect(probe.faceCount == 0)
    }
}
