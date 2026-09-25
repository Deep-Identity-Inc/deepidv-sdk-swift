import CoreVideo
import Testing

@testable import DeepIDV

private func blankPixelBuffer(width: Int = 320, height: Int = 240) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pb)
    return pb!
}

struct MovementReplayRecorderTests {
    @Test func recordsFramesIntoAnMp4() async {
        let recorder = MovementReplayRecorder()
        for _ in 0..<6 { recorder.append(blankPixelBuffer()) }
        let clip = await recorder.finish()
        #expect(clip != nil)
        #expect((clip?.count ?? 0) > 0)
    }

    @Test func finishWithNoFramesReturnsNil() async {
        let recorder = MovementReplayRecorder()
        let clip = await recorder.finish()
        #expect(clip == nil)
    }
}
