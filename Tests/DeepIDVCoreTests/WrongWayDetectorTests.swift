import Foundation
import Testing

@testable import DeepIDVCore

/// A 200 with a card box (or not) and a best guess `top` at `confidence`.
private func frame(
    _ confidence: Double, box: Bool = true, id: String? = nil, top: String = "ca_on_dl"
) -> DetectOutcome {
    .answer(
        DetectAnswer(
            present: box, box: box ? .init(xyxy: [10, 10, 200, 300]) : nil,
            documentType: .init(
                id: id, confidence: confidence, top3: [.init(id: top, confidence: confidence)])))
}

private let failed = DetectOutcome.failure(status: 0)

/// Normal frames every 0.5 s from t = 0, all at `confidence`.
private func stuck(_ n: Int, _ confidence: Double = 0.08) -> WrongWayDetector {
    var detector = WrongWayDetector()
    for i in 0..<n { detector.recordFrame(frame(confidence), at: Double(i) * 0.5) }
    return detector
}

private func probed(
    _ detector: WrongWayDetector, _ outcome: DetectOutcome, at now: TimeInterval = 4
) -> WrongWayDetector {
    var detector = detector
    detector.recordProbe(outcome, at: now)
    return detector
}

@Suite struct WrongWayDetectorTests {
    @Test func probesTurnTheFrameAHalfTurn() {
        #expect(WrongWayDetector.probeRotation == 180)
    }

    @Test func noProbeBeforeACardHasBeenInFrameUnconfirmedForASecond() {
        #expect(WrongWayDetector.stuckDelay == 1)
        let s = stuck(2)
        #expect(s.stuckSince == 0)
        #expect(!s.probeDue(at: 0.999))
        #expect(s.probeDue(at: 1))
    }

    @Test func afterThatAtMostOneProbeASecond() {
        #expect(WrongWayDetector.probeInterval == 1)
        let s = probed(stuck(8), frame(0.1), at: 3)
        #expect(!s.probeDue(at: 3.5))
        #expect(!s.probeDue(at: 3.999))
        #expect(s.probeDue(at: 4))
        // A failed probe counts for the schedule too.
        #expect(!probed(stuck(8), failed, at: 3).probeDue(at: 3.5))
    }

    @Test(arguments: [0.5, 1.0])
    func probesGoOnceASecondWhateverTheAnswerRate(every: Double) {
        var s = WrongWayDetector()
        var at: [Double] = []
        var t = 0.0
        while t <= 5 + 1e-9 {
            s.recordFrame(frame(0.08), at: t)
            if s.probeDue(at: t) {
                at.append(t)
                s.recordProbe(frame(0.1), at: t)
            }
            t += every
        }
        #expect(at == [1, 2, 3, 4, 5])
    }

    @Test func noCardOrAConfirmedTypeEndsTheRun() {
        var gone = stuck(8)
        gone.recordFrame(frame(0.05, box: false), at: 4)
        #expect(gone.stuckSince == nil)
        #expect(!gone.probeDue(at: 4))
        var recognised = stuck(8)
        recognised.recordFrame(frame(ClassifierVotes.namedFloor), at: 4)
        #expect(!recognised.probeDue(at: 4))
        // A licence under the named floor isn't recognised: the run goes on.
        var low = stuck(8)
        low.recordFrame(frame(0.45, top: "us_tx_dl"), at: 4)
        #expect(low.probeDue(at: 4))
        // A health card keeps its lower floor.
        var health = stuck(8)
        health.recordFrame(frame(ClassifierVotes.healthFloor, top: "ca_on_hc"), at: 4)
        #expect(!health.probeDue(at: 4))
        // Never without a card at all.
        var none = WrongWayDetector()
        for t in [0, 0.5, 1, 3.5, 5] { none.recordFrame(frame(0, box: false), at: t) }
        #expect(!none.probeDue(at: 5))
    }

    @Test func aFailedCallSaysNothing() {
        let s = stuck(8)
        var after = s
        after.recordFrame(failed, at: 4)
        #expect(after == s)
        let probe = probed(s, failed)
        #expect(probe.lastProbeAt == 4)
        #expect(probe.pending == nil && !probe.shown && !probe.flip)
        #expect(probe.recent == s.recent)
    }

    @Test func theRecentMeanCoversOnlyTheLastThreeSeconds() {
        var s = stuck(4, 0.02)  // t = 0 … 1.5 at 0.02
        for t in [2, 2.5, 3, 3.5, 4, 4.5] { s.recordFrame(frame(0.14), at: t) }
        // From t = 1.5 on: one at 0.02 and six at 0.14.
        #expect(abs(s.recentMean - (0.02 + 6 * 0.14) / 7) < 1e-9)
    }

    @Test func aProbeShowsTheNoteOnlyWhenItClearlyBeatsTheNormalFrames() {
        #expect(WrongWayDetector.probeMinConfidence == 0.5)
        let s = stuck(8, 0.08)
        #expect(probed(s, frame(0.6)).shown)
        #expect(probed(s, frame(0.5)).shown)
        #expect(!probed(s, frame(0.45)).shown)
        var high = s
        high.recent = [.init(time: 3, confidence: 0.55)]
        #expect(!probed(high, frame(0.52)).shown)
    }

    @Test func theNoteHidesWhenAProbeNoLongerBeatsThemOrAFrameIsRecognised() {
        let shown = probed(stuck(8), frame(0.5))
        #expect(shown.shown)
        #expect(shown.holdsCapture)
        #expect(!probed(shown, frame(0.06)).shown)
        var recognised = shown
        recognised.recordFrame(frame(0.6), at: 4)
        #expect(!recognised.shown)
    }

    @Test func twoStrongProbesInARowForTheSameClassFlipTheScan() {
        #expect(WrongWayDetector.flipMinConfidence == 0.75)
        #expect(WrongWayDetector.flipProbes == 2)
        let first = probed(stuck(8), frame(0.86, id: "ca_on_dl"))
        #expect(!first.flip)
        #expect(!first.shown)
        #expect(first.pending == .init(id: "ca_on_dl", probes: 1))
        // While it waits for its second probe, capture waits, and that probe goes at once.
        #expect(first.holdsCapture)
        #expect(first.probeDue(at: 4.1))
        let second = probed(first, frame(0.89, id: "ca_on_dl"))
        #expect(second.flip)
        #expect(!second.shown)
        #expect(!second.holdsCapture)
        #expect(second.recent == stuck(8).recent)
    }

    @Test func aFlipNeedsTheSameClassTwice() {
        let first = probed(stuck(8), frame(0.86, id: "ca_on_dl"))
        let other = probed(first, frame(0.8, top: "ca_ab_dl"))
        #expect(!other.flip)
        #expect(other.pending == .init(id: "ca_ab_dl", probes: 1))
        let weaker = probed(first, frame(0.6))
        #expect(!weaker.flip)
        #expect(weaker.pending == nil)
        #expect(weaker.shown, "still beats the normal frames")
        let none = probed(first, frame(0.1))
        #expect(none.pending == nil)
        #expect(!none.holdsCapture)
    }

    @Test func aRecognisedNormalFrameDropsAPendingFlip() {
        var first = probed(stuck(8), frame(0.86, id: "ca_on_dl"))
        first.recordFrame(frame(0.8), at: 4.5)
        #expect(first.pending == nil)
    }

    @Test(arguments: ["no_id", "xx_unknown_dl"])
    func onlyAKnownDocumentFlipsTheScan(id: String) {
        let s = probed(probed(stuck(8), frame(0.9, top: id)), frame(0.9, top: id))
        #expect(!s.flip)
        #expect(s.pending == nil)
    }

    @Test func aStrongProbeThatDoesNotBeatTheNormalFramesNeverFlips() {
        var s = stuck(8)
        s.recent = [.init(time: 3, confidence: 0.9)]
        #expect(!probed(probed(s, frame(0.8)), frame(0.8)).flip)
    }

    @Test func aCardTheRightWayUpThatScoresAsWellTurnedOverIsLeftAlone() {
        // A card out of position: its frames name it at about 0.88 but never confirm,
        // and turned over it scores about the same.
        #expect(WrongWayDetector.sameClassMargin == 0.15)
        var s = WrongWayDetector()
        for (n, score) in [0.87, 0.88, 0.88, 0.87].enumerated() {
            s.recordFrame(frame(score, top: "gb_dvla_dl"), at: Double(n) * 0.5, confirmed: false)
        }
        let probe = frame(0.89, id: "gb_dvla_dl", top: "gb_dvla_dl")
        let twice = probed(probed(s, probe, at: 2), probe, at: 3)
        #expect(!twice.flip)
        #expect(twice.pending == nil)
        #expect(!twice.shown, "no turn-the-card note either")
        #expect(!twice.holdsCapture)
    }

    @Test func aProbeNamingTheSameClassFlipsWhenItClearlyBeatsTheFrames() {
        var s = WrongWayDetector()
        for (n, score) in [0.65, 0.7, 0.68, 0.69].enumerated() {
            s.recordFrame(frame(score, top: "ca_on_dl"), at: Double(n) * 0.5, confirmed: false)
        }
        let probe = frame(0.9, id: "ca_on_dl")
        #expect(probed(probed(s, probe, at: 2), probe, at: 3).flip)
        // Under the margin over the frames' mean (0.68): no flip.
        let close = frame(0.8, id: "ca_on_dl")
        #expect(!probed(probed(s, close, at: 2), close, at: 3).flip)
    }

    @Test func anUpsideDownCardReadAsAnotherClassStillFlips() {
        // An upside-down Ontario licence read as a UK one at a good score.
        var s = WrongWayDetector()
        for (n, score) in [0.82, 0.61, 0.7, 0.66].enumerated() {
            s.recordFrame(frame(score, top: "gb_dvla_dl"), at: Double(n) * 0.5, confirmed: false)
        }
        let probe = frame(0.9, id: "ca_on_dl")
        #expect(probed(probed(s, probe, at: 2), probe, at: 3).flip)
    }

    @Test func anUpsideDownLicenceFlipsBeforeTheUntypedCapture() {
        // Made-up scores in the range an upside-down card gets for a wrong class,
        // with probes scoring as a known card the right way up.
        let scores = [0.385, 0.205, 0.336, 0.418, 0.508, 0.336, 0.418, 0.385, 0.336, 0.418]
        var memo = ScanMemo()
        var s = WrongWayDetector()
        var flippedAt: TimeInterval?
        for (n, score) in scores.enumerated() where flippedAt == nil {
            let t = Double(n) * 0.5
            let got = frame(score, id: score >= 0.502 ? "us_tx_dl" : nil, top: "us_tx_dl")
            let d = ClassifierVotes.decide(got, frameGood: true, memo: &memo) {
                $0.hasSuffix("_dl")
            }
            #expect(d.key != .classified, "frame \(n) confirmed the wrong class")
            s.recordFrame(got, at: t, confirmed: false)
            if s.probeDue(at: t) {
                s.recordProbe(frame(0.87, id: "ca_on_dl"), at: t)
                if s.flip { flippedAt = t }
            }
        }
        #expect(flippedAt != nil)
        #expect((flippedAt ?? .infinity) < ClassifierScanPolicy.untypedCaptureDelay)
    }

    @Test func answersAboutASecondApartStillFlipWellBeforeTheUntypedHold() {
        let answers: [(TimeInterval, Double)] = [
            (4.017, 0.25), (4.832, 0.222), (5.831, 0.232), (7.266, 0.214), (8.29, 0.151),
            (10.136, 0.327),
        ]
        var s = WrongWayDetector()
        var flippedAt: TimeInterval?
        for (t, score) in answers {
            s.recordFrame(frame(score, top: "us_ga_dl"), at: t, confirmed: false)
            if flippedAt == nil, s.probeDue(at: t) {
                s.recordProbe(frame(0.9, id: "ca_on_dl"), at: t)
                if s.flip { flippedAt = t }
            }
        }
        #expect(flippedAt == 7.266)
        #expect((flippedAt ?? .infinity) < 4.017 + ClassifierScanPolicy.untypedCaptureDelay)
    }
}
