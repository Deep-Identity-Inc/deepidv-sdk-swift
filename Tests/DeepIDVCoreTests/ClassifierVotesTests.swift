import Testing

@testable import DeepIDVCore

/// A classifier answer for a card in frame whose best guess is `id` at
/// `confidence`. The classifier names the type itself only at 0.502 or more.
func detectFrame(
    _ id: String, _ confidence: Double, present: Bool = true,
    second: (String, Double) = ("ca_ab_id", 0.04)
) -> DetectOutcome {
    .answer(
        DetectAnswer(
            present: present,
            box: present ? .init(xyxy: [1, 2, 3, 4], score: 0.96) : nil,
            documentType: .init(
                id: confidence >= 0.502 ? id : nil, confidence: confidence,
                top3: [
                    .init(id: id, confidence: confidence),
                    .init(id: second.0, confidence: second.1),
                    .init(id: "us_ga_dl", confidence: 0.03),
                ]),
            modelVersion: "m1"))
}

@Suite struct ClassifierVotesTests {
    private func run(
        _ frames: [DetectOutcome], good: [Bool]? = nil,
        allow: @escaping (String) -> Bool = { _ in true }
    ) -> [ScanDecision] {
        var memo = ScanMemo()
        return frames.enumerated().map { i, frame in
            ClassifierVotes.decide(frame, frameGood: good?[i] ?? true, memo: &memo, allow: allow)
        }
    }

    @Test func threeOfFiveHealthCardFramesUnderTheNamedFloorConfirmByVote() {
        let out = run([
            detectFrame("ca_on_hc", 0.44), detectFrame("ca_on_hc", 0.46),
            detectFrame("ca_on_hc", 0.15), detectFrame("ca_on_hc", 0.45),
        ])
        #expect(out.map(\.key) == [.identifying, .identifying, .identifying, .classified])
        #expect(out[3].doc == ScanDoc(id: "ca_on_hc", confidence: 0.45, votes: 3))
        #expect(out[3].source == .vote)
    }

    @Test func aFrameUnderTheHealthFloorDoesNotVote() {
        let low = ClassifierVotes.healthFloor - 0.01
        let out = run([
            detectFrame("ca_on_hc", 0.4), detectFrame("ca_on_hc", low),
            detectFrame("ca_on_hc", low), detectFrame("ca_on_hc", 0.4),
        ])
        #expect(out.allSatisfy { $0.key == .identifying })
    }

    @Test func aTypeTheVoteMayNotConfirmNeverConfirmsByVotes() {
        let out = run(
            [
                detectFrame("us_ga_dl", 0.4), detectFrame("us_ga_dl", 0.42),
                detectFrame("us_ga_dl", 0.41),
            ],
            allow: { $0 != "us_ga_dl" })
        #expect(out.allSatisfy { $0.key == .identifying })
    }

    @Test func theClassifierNamingATypeOnTwoFramesInARowConfirmsItAsAPI() {
        let out = run(
            [detectFrame("ca_on_dl", 0.7), detectFrame("ca_on_dl", 0.7)], allow: { _ in false })
        #expect(out.map(\.key) == [.identifying, .classified])
        #expect(out[1].source == .api)
        #expect(out[1].strength == .strong)
        #expect(out[1].doc?.votes == nil)
    }

    @Test func framesTheStreakMissesStillConfirmAsVotes() {
        let out = run(
            [
                detectFrame("ca_on_dl", 0.56), detectFrame("us_ga_dl", 0.6),
                detectFrame("ca_on_dl", 0.58),
                detectFrame("us_ga_dl", 0.6), detectFrame("ca_on_dl", 0.57),
            ],
            allow: { $0 == "ca_on_dl" })
        #expect(
            out.map(\.key) == [.identifying, .identifying, .identifying, .identifying, .classified])
        #expect(out[4].source == .vote)
    }

    @Test func theCardLeavingTheFrameClearsTheVotes() {
        var memo = ScanMemo()
        _ = ClassifierVotes.decide(detectFrame("ca_on_hc", 0.44), frameGood: true, memo: &memo) {
            _ in true
        }
        _ = ClassifierVotes.decide(detectFrame("ca_on_hc", 0.45), frameGood: true, memo: &memo) {
            _ in true
        }
        let gone = ClassifierVotes.decide(
            detectFrame("ca_on_hc", 0.2, present: false), frameGood: true, memo: &memo
        ) { _ in true }
        #expect(gone.key == .noID)
        #expect(memo.votes.isEmpty)
        let back = ClassifierVotes.decide(
            detectFrame("ca_on_hc", 0.46), frameGood: true, memo: &memo
        ) { _ in true }
        #expect(back.key == .identifying)
    }

    @Test func onlyTheLastFiveGoodFramesCount() {
        let out = run(
            [
                detectFrame("ca_on_hc", 0.44), detectFrame("ca_on_hc", 0.45),
                detectFrame("us_ga_dl", 0.4),
                detectFrame("us_ga_dl", 0.4), detectFrame("us_ga_dl", 0.4),
                detectFrame("ca_on_hc", 0.46),
                detectFrame("ca_on_hc", 0.46),
            ],
            allow: { $0 == "ca_on_hc" })
        #expect(out[5].key == .identifying)
        #expect(out[6].key == .identifying)
    }

    @Test func tallyIgnoresUnknownFramesAndReturnsNilBelowTheBar() {
        let three = [VoteEntry("a", 0.5), VoteEntry("a", 0.5), VoteEntry("a", 0.5)]
        #expect(
            ClassifierVotes.tally([VoteEntry(nil, 0), VoteEntry("a", 0.5), VoteEntry("a", 0.5)]) {
                _ in true
            } == nil)
        #expect(ClassifierVotes.tally(three) { _ in false } == nil)
        #expect(ClassifierVotes.tally(three) { _ in true }?.id == "a")
    }

    @Test func aFrameThatFailedTheOnDeviceCheckNeitherExtendsAStreakNorVotes() {
        let out = run(
            Array(repeating: detectFrame("ca_on_dl", 0.7), count: 6),
            good: [true, false, true, false, true, false])
        #expect(
            out.map(\.key) == [
                .identifying, .quality, .identifying, .quality, .classified, .quality,
            ])
        #expect(out[4].source == .vote)
    }

    @Test func failedCallsCountInARowAndAnAnswerResetsThem() {
        var memo = ScanMemo()
        _ = ClassifierVotes.decide(.failure(status: 503), frameGood: true, memo: &memo) { _ in true
        }
        let second = ClassifierVotes.decide(.failure(status: 0), frameGood: true, memo: &memo) {
            _ in true
        }
        #expect(second.key == .error)
        #expect(memo.errors == 2)
        _ = ClassifierVotes.decide(detectFrame("ca_on_dl", 0.7), frameGood: true, memo: &memo) {
            _ in true
        }
        #expect(memo.errors == 0)
    }

    @Test func theNamedFloorIsHalfAndTheHealthFloorStaysLower() {
        #expect(ClassifierVotes.namedFloor == 0.5)
        #expect(ClassifierVotes.healthFloor == 0.2)
        #expect(ClassifierVotes.floor(for: "ca_on_dl") == 0.5)
        #expect(ClassifierVotes.floor(for: "ca_on_hc") == 0.2)
        // Low licence scores don't confirm a licence...
        let low = run([
            detectFrame("ca_on_dl", 0.21), detectFrame("ca_on_dl", 0.24),
            detectFrame("us_ga_dl", 0.3), detectFrame("ca_on_dl", 0.2),
        ])
        #expect(low.allSatisfy { $0.key == .identifying })
        // ...three at the floor do, as a vote...
        let out = run([
            detectFrame("ca_on_dl", 0.5), detectFrame("ca_on_dl", 0.501),
            detectFrame("us_ga_dl", 0.3), detectFrame("ca_on_dl", 0.5),
        ])
        #expect(out[3].source == .vote)
        #expect(out[3].doc == ScanDoc(id: "ca_on_dl", confidence: 0.5, votes: 3))
        // ...and a health card still confirms at its own floor.
        let hc = run([
            detectFrame("ca_on_hc", 0.21), detectFrame("ca_on_hc", 0.24),
            detectFrame("ca_on_hc", 0.2),
        ])
        #expect(hc[2].doc == ScanDoc(id: "ca_on_hc", confidence: 0.2, votes: 3))
    }

    @Test func anUpsideDownCardScoringLowForAWrongClassNeverConfirmsIt() {
        let out = run([0.385, 0.205, 0.336, 0.418, 0.508].map { detectFrame("us_tx_dl", $0) })
        #expect(out.allSatisfy { $0.key == .identifying })
    }

    @Test func theStrongVoteNeedsFourOfFiveWithMeanConfidenceAndMargin() {
        #expect(ClassifierVotes.strongVotes == 4)
        #expect(ClassifierVotes.strongMeanConfidence == 0.25)
        #expect(ClassifierVotes.strongMeanMargin == 0.15)
        func w(_ c: Double, _ m: Double) -> VoteEntry { VoteEntry("ca_on_dl", c, margin: m) }
        let other = VoteEntry("us_ga_dl", 0.2, margin: 0.05)
        #expect(
            ClassifierVotes.strength(
                [w(0.3, 0.2), w(0.25, 0.2), w(0.22, 0.15), w(0.28, 0.18), other], id: "ca_on_dl")
                == .strong)
        // Only 3 of 5 agree.
        #expect(
            ClassifierVotes.strength(
                [w(0.6, 0.5), w(0.6, 0.5), w(0.6, 0.5), other, other], id: "ca_on_dl") == .weak)
        // Mean confidence under 0.25 but a clear margin at 0.20+: a margin vote.
        #expect(
            ClassifierVotes.strength(
                [w(0.22, 0.2), w(0.23, 0.2), w(0.24, 0.2), w(0.24, 0.2)], id: "ca_on_dl") == .margin
        )
        #expect(
            ClassifierVotes.strength(
                [w(0.18, 0.2), w(0.19, 0.2), w(0.19, 0.2), w(0.19, 0.2)], id: "ca_on_dl") == .weak)
        // A close second guess.
        #expect(
            ClassifierVotes.strength(
                [w(0.3, 0.1), w(0.3, 0.12), w(0.3, 0.14), w(0.3, 0.14)], id: "ca_on_dl") == .weak)
    }

    @Test func aMarginVoteIsNeverAHealthCardOrAnUnknownClass() {
        func w(_ id: String) -> VoteEntry { VoteEntry(id, 0.22, margin: 0.2) }
        #expect(
            ClassifierVotes.strength(Array(repeating: w("ca_on_hc"), count: 4), id: "ca_on_hc")
                == .weak)
        #expect(
            ClassifierVotes.strength(Array(repeating: w("xx_new_dl"), count: 4), id: "xx_new_dl")
                == .weak)
    }

    @Test func aVoteTurnsStrongOnceTheWindowSupportsIt() {
        // The second guess is 0.04, so each frame's margin is its confidence minus 0.04.
        let out = run([
            detectFrame("ca_on_dl", 0.5), detectFrame("ca_on_dl", 0.501),
            detectFrame("ca_on_dl", 0.5), detectFrame("ca_on_dl", 0.501),
        ])
        #expect(out[2].key == .classified)
        #expect(out[2].strength == .weak)
        #expect(out[3].strength == .strong)
    }

    @Test func anAnswerWithNoTypeKeepsTheBestGuess() {
        let out = run([detectFrame("ca_on_dl", 0.3)])
        #expect(out[0].key == .identifying)
        #expect(out[0].top == .init(id: "ca_on_dl", confidence: 0.3))
        #expect(out[0].doc == nil)
    }
}
