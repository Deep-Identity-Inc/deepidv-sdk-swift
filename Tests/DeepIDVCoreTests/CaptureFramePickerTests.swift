import Foundation
import Testing

@testable import DeepIDVCore

private func kept(_ time: TimeInterval, _ sharpness: Double?) -> BufferedFrame<String> {
    BufferedFrame(time: time, frame: "f\(time)", sharpness: sharpness)
}

@Suite struct CaptureFramePickerTests {
    @Test func theConstantsMatchTheWebCapture() {
        #expect(CaptureFramePicker.capacity == 5)
        #expect(CaptureFramePicker.interval == 0.25)
        #expect(CaptureFramePicker.captureWindow == 1.2)
        #expect(CaptureFramePicker.shutterWindow == 0.5)
        #expect(CaptureFramePicker.extraCount == 2)
        #expect(CaptureFramePicker.minimumGap == 0.2)
        #expect(CaptureFramePicker.extraJPEGQuality == 0.92)
    }

    @Test func aCardPulledAwayAtTheEndOfTheHoldKeepsTheSharpEarlyFrame() {
        // The hold runs 8.15–9.35 s; sharpness falls as the device moves.
        let ring = [kept(8.25, 820), kept(8.5, 790), kept(8.75, 610), kept(9, 240), kept(9.25, 150)]
        let (main, extras) = CaptureFramePicker.pick(ring + [kept(9.35, 120)], now: 9.35)
        #expect(main?.time == 8.25)
        #expect(extras.map(\.time) == [8.5, 8.75])
    }

    @Test func aSteadyCardUsuallyPicksTheNewest() {
        let ring = [kept(8.25, 800), kept(8.5, 805), kept(8.75, 810), kept(9, 812), kept(9.25, 815)]
        #expect(CaptureFramePicker.pick(ring + [kept(9.35, 818)], now: 9.35).main?.time == 9.35)
    }

    @Test func theShutterLooksBackHalfASecondOnly() {
        let ring = [kept(8.25, 999), kept(9, 300), kept(9.25, 310)]
        let picked = CaptureFramePicker.pick(
            ring + [kept(9.35, 305)], now: 9.35, window: CaptureFramePicker.shutterWindow)
        #expect(picked.main?.time == 9.25)
    }

    @Test func aTieOrUnscoredFramesPickTheNewest() {
        #expect(CaptureFramePicker.pick([kept(0.1, 500), kept(0.3, 500)], now: 0.4).main?.time == 0.3)
        #expect(CaptureFramePicker.pick([kept(0.1, nil), kept(0.3, nil)], now: 0.4).main?.time == 0.3)
        // A scored frame beats an unscored one.
        #expect(CaptureFramePicker.pick([kept(0.1, 1), kept(0.3, nil)], now: 0.4).main?.time == 0.1)
    }

    @Test func extrasAreNeverWithinTheGapOfThePhotoOrEachOther() {
        let all = [kept(1, 10), kept(1.1, 9), kept(1.2, 8), kept(1.3, 7), kept(1.5, 6), kept(1.7, 5)]
        let (main, extras) = CaptureFramePicker.pick(all, now: 1.8)
        let picked = [main!] + extras
        for (i, a) in picked.enumerated() {
            for b in picked[(i + 1)...] {
                #expect(abs(a.time - b.time) >= CaptureFramePicker.minimumGap - 1e-9)
            }
        }
        #expect(extras.count == 2)
    }

    @Test func fewerCandidatesThanExtrasGiveFewerExtras() {
        let (main, extras) = CaptureFramePicker.pick([kept(1, 10), kept(1.1, 9)], now: 1.2)
        #expect(main?.time == 1)
        #expect(extras.isEmpty, "the only other frame is too close")
    }

    @Test func nothingInTheWindowPicksNothing() {
        #expect(CaptureFramePicker.pick([kept(0.1, 5)], now: 5).main == nil)
        #expect(CaptureFramePicker.pick([BufferedFrame<String>](), now: 5).extras.isEmpty)
    }

    @Test func aKeptFrameReplacesTheStillOnlyWhenItIsHalfAgainAsSharp() {
        #expect(CaptureFramePicker.stillReplacementFactor == 1.5)
        #expect(CaptureFramePicker.prefersKeptFrame(stillSharpness: 100, keptSharpness: 150))
        #expect(!CaptureFramePicker.prefersKeptFrame(stillSharpness: 100, keptSharpness: 149))
        // Keep the still unless both were scored.
        #expect(!CaptureFramePicker.prefersKeptFrame(stillSharpness: nil, keptSharpness: 900))
        #expect(!CaptureFramePicker.prefersKeptFrame(stillSharpness: 100, keptSharpness: nil))
    }
}
