import Foundation
import Testing

@testable import DeepIDVCore

private typealias Policy = ClassifierScanPolicy

private let ok = DetectOutcome.answer(DetectAnswer(present: true))
private let hold = Policy.holdDuration
private let untyped = Policy.untypedCaptureDelay

private func context(
    picked: DocumentGroup? = .driversLicence, health: HealthPolicy = .strict, now: TimeInterval = 0,
    votes: [VoteEntry] = [], wrongWay: Bool = false
) -> Policy.Context {
    Policy.Context(picked: picked, health: health, now: now, votes: votes, wrongWay: wrongWay)
}

/// A decision confirming `id`: by the classifier, or by vote when `voted`.
private func classified(_ id: String, voted: Bool = false, strength: TypeStrength? = nil)
    -> ScanDecision
{
    ScanDecision(
        .classified, source: voted ? .vote : .api, strength: strength ?? (voted ? .weak : .strong),
        answer: DetectAnswer(
            present: true,
            documentType: .init(id: id, confidence: 0.8, top3: [.init(id: id, confidence: 0.8)]),
            modelVersion: "m1"),
        doc: ScanDoc(id: id, confidence: 0.8, votes: voted ? 3 : nil))
}

private let steady = ScanDecision(.identifying)
private let noID = ScanDecision(.noID)
private let quality = ScanDecision(.quality)
private let error = ScanDecision(.error)
/// The vote window while the licence still leads.
private let licenceVotes = Array(repeating: VoteEntry("ca_on_dl", 0.6, margin: 0.5), count: 3)

private func step(
    _ state: Policy.State, _ decision: ScanDecision, _ context: Policy.Context,
    outcome: DetectOutcome = ok
) -> Policy.Step {
    Policy.step(state, decision: decision, outcome: outcome, context: context)
}

@Suite struct ClassifierScanPolicyTests {
    // MARK: Fail-over

    @Test func theClassifierGivesUpAfterThreeFailedCallsInARow() {
        #expect(Policy.fallbackAfter == 3)
        var state = Policy.State()
        var reasons: [String?] = []
        for status in [500, 0, 503] {
            let s = step(state, error, context(), outcome: .failure(status: status))
            state = s.state
            reasons.append(s.fallback)
        }
        #expect(reasons[0] == nil && reasons[1] == nil)
        #expect(reasons[2]?.contains("failed 3 times in a row (last: HTTP 503)") == true)
    }

    @Test func aNetworkErrorIsNamedAsOne() {
        var state = Policy.State()
        var last: String?
        for _ in 0..<3 {
            let s = step(state, error, context(), outcome: .failure(status: 0))
            state = s.state
            last = s.fallback
        }
        #expect(last?.contains("network error") == true)
    }

    @Test func anAnswerInBetweenResetsTheCount() {
        var state = Policy.State()
        state = step(state, error, context(), outcome: .failure(status: 0)).state
        state = step(state, error, context(), outcome: .failure(status: 0)).state
        state = step(state, noID, context()).state
        #expect(state.failures == 0)
        #expect(step(state, error, context(), outcome: .failure(status: 0)).fallback == nil)
    }

    // MARK: Capture and the hold

    @Test func aConfirmedTypeOfThePickedDocumentIsCapturedAfterTheHold() {
        for (decision, reason) in [
            (classified("ca_on_dl"), Policy.CaptureReason.typed),
            (classified("ca_on_dl", voted: true), .voted),
        ] {
            let first = step(Policy.State(), decision, context())
            #expect(first.capture == nil)
            #expect(step(first.state, decision, context(now: hold)).capture == reason)
        }
    }

    @Test func aVoteStartsTheHoldInsteadOfCapturingOnThatFrame() {
        let s = step(Policy.State(), classified("ca_on_dl", voted: true), context(now: 0.3))
        #expect(s.shown == .classified)
        #expect(s.capture == nil)
        #expect(s.state.hold == Policy.Hold(key: "ca_on_dl", reason: .voted, since: 0.3))
    }

    @Test func theHoldCompletesOnAStillGoodCardAndNotBefore() {
        let start = step(Policy.State(), classified("ca_on_dl"), context(now: 1))
        #expect(Policy.holdDue(start.state, now: 1 + hold - 0.001) == nil)
        #expect(Policy.holdDue(start.state, now: 1 + hold) == .typed)
        // A good answer during the hold keeps it unchanged.
        let mid = step(start.state, steady, context(now: 1.6, votes: licenceVotes))
        #expect(mid.capture == nil)
        #expect(mid.state.hold == start.state.hold)
        // An answer after the hold has run out takes the photo itself.
        #expect(step(mid.state, steady, context(now: 2.3, votes: licenceVotes)).capture == .typed)
    }

    @Test(arguments: [noID, quality])
    func aBadAnswerDuringTheHoldCancelsIt(decision: ScanDecision) {
        let start = step(Policy.State(), classified("ca_on_dl"), context())
        let cancelled = step(start.state, decision, context(now: 0.6, votes: licenceVotes))
        #expect(cancelled.state.hold == nil)
        #expect(cancelled.capture == nil)
        #expect(Policy.holdDue(cancelled.state, now: hold) == nil)
    }

    @Test func aFailedCallDuringTheHoldCancelsIt() {
        let start = step(Policy.State(), classified("ca_on_dl"), context())
        let failed = step(start.state, error, context(now: 0.6), outcome: .failure(status: 503))
        #expect(failed.state.hold == nil)
    }

    @Test func anotherLeadingTypeDuringTheHoldStartsItsOwn() {
        let start = step(Policy.State(), classified("ca_on_dl", voted: true), context())
        let other = step(start.state, classified("ca_ab_dl", voted: true), context(now: 0.6))
        #expect(other.capture == nil)
        #expect(other.state.hold == Policy.Hold(key: "ca_ab_dl", reason: .voted, since: 0.6))
        #expect(Policy.holdDue(other.state, now: hold) == nil)
        // The leading type dropping out of the vote window cancels it too.
        let dropped = step(
            start.state, steady, context(now: 0.6, votes: [VoteEntry("us_ga_dl", 0.3, margin: 0.2)])
        )
        #expect(dropped.state.hold == nil)
    }

    @Test func aHealthCardDuringTheHoldCancelsIt() {
        let start = step(Policy.State(), classified("ca_on_dl"), context())
        let health = step(start.state, classified("ca_on_hc"), context(now: 0.6))
        #expect(health.shown == .healthCard)
        #expect(health.state.hold == nil)
        #expect(step(health.state, classified("ca_on_hc"), context(now: 1.8)).capture == nil)
    }

    @Test func anUntypedHoldCarriesOnWhenTheCardIsTypedDuringIt() {
        let first = step(Policy.State(), steady, context())
        let held = step(first.state, steady, context(now: untyped))
        let typed = step(held.state, classified("ca_on_dl"), context(now: untyped + 0.5))
        #expect(typed.state.hold == Policy.Hold(key: "ca_on_dl", reason: .typed, since: untyped))
    }

    @Test func anUntypedGoodCardStartsItsHoldAfterFiveSeconds() {
        #expect(untyped == 5)
        let first = step(Policy.State(), steady, context(now: 1))
        #expect(first.capture == nil)
        let early = step(first.state, steady, context(now: 1 + untyped - 0.001))
        #expect(early.state.hold == nil)
        let held = step(early.state, steady, context(now: 1 + untyped))
        #expect(held.capture == nil)
        #expect(held.state.hold == Policy.Hold(key: nil, reason: .untyped, since: 1 + untyped))
        #expect(Policy.holdDue(held.state, now: 1 + untyped + hold) == .untyped)
    }

    @Test func aPassportPageIsCapturedOnceGoodForASecondAndAHalfWithNoHold() {
        #expect(Policy.passportCaptureDelay == 1.5)
        let page = context(picked: .passport, health: .apiOnly, now: 1)
        let first = step(Policy.State(), steady, page)
        #expect(first.capture == nil)
        var at = page
        at.now = 2.499
        let early = step(first.state, steady, at)
        #expect(early.capture == nil)
        at.now = 2.5
        let due = step(early.state, steady, at)
        #expect(due.capture == .passport, "no hold on top")
        #expect(due.shown == .identifying)
    }

    @Test func aPassportPageThatLeavesStartsItsSteadyTimeAgain() {
        let page = context(picked: .passport, health: .apiOnly, now: 0)
        var at = page
        let first = step(Policy.State(), steady, at)
        at.now = 1
        let gone = step(first.state, noID, at)
        at.now = 1.5
        let back = step(gone.state, steady, at)
        at.now = 2.9
        #expect(step(back.state, steady, at).capture == nil)
        at.now = 3
        #expect(step(back.state, steady, at).capture == .passport)
    }

    @Test func aLicenceHeldUpForAPassportIsNamedAndNeverAutoCaptured() {
        var state = Policy.State()
        var steps: [Policy.Step] = []
        for i in 0...10 {
            let s = step(
                state, classified("ca_on_dl"),
                context(picked: .passport, health: .apiOnly, now: Double(i) * 0.5))
            steps.append(s)
            state = s.state
        }
        #expect(steps.allSatisfy { $0.shown == .mismatch && $0.mismatch?.id == "ca_on_dl" })
        #expect(steps.allSatisfy { $0.capture == nil && $0.state.hold == nil })
    }

    @Test func theCardWarningInThePassportStepStaysUntilTheCardLeaves() {
        let page = { (now: TimeInterval) in context(picked: .passport, health: .apiOnly, now: now) }
        let named = step(Policy.State(), classified("gb_dvla_dl"), page(0))
        // The classifier stops naming it, or the frame is soft: still the warning,
        // and no capture however long it stays.
        var state = named.state
        for (i, decision) in [steady, quality, error, steady, steady, steady].enumerated() {
            let s = step(state, decision, page(Double(i + 1)))
            #expect(s.mismatch?.id == "gb_dvla_dl")
            #expect(s.capture == nil)
            state = s.state
        }
        // Once it leaves the frame, a page held up afterwards captures as usual.
        let gone = step(state, noID, page(8))
        #expect(gone.state.cardInPassport == nil)
        let back = step(gone.state, steady, page(9))
        #expect(back.shown == .identifying)
        #expect(step(back.state, steady, page(10.5)).capture == .passport)
    }

    @Test func aWeakCardGuessOnAPassportPageNeverBlocksIt() {
        // Passport pages sometimes get one card guess the classifier doesn't stand
        // by: only a type it confirms counts.
        let page = { (now: TimeInterval) in context(picked: .passport, health: .apiOnly, now: now) }
        let guess = ScanDecision(
            .identifying, source: .api, doc: ScanDoc(id: "gb_dvla_dl", confidence: 0.62))
        let first = step(Policy.State(), guess, page(0))
        #expect(first.state.cardInPassport == nil)
        #expect(step(first.state, steady, page(1.5)).capture == .passport)
    }

    @Test func theUpsideDownCheckHoldsEveryCapture() {
        let start = step(Policy.State(), classified("ca_on_dl"), context(wrongWay: true))
        #expect(start.state.hold == nil)
        let later = step(start.state, classified("ca_on_dl"), context(now: 3, wrongWay: true))
        #expect(later.capture == nil)
        #expect(later.state.hold == nil)
        // Once it clears, the hold starts afresh.
        let cleared = step(later.state, classified("ca_on_dl"), context(now: 4))
        #expect(cleared.state.hold?.since == 4)
    }

    // MARK: Another document

    @Test func anotherKindOfDocumentIsNamedAndItsTypeIsNeverTaken() {
        let s = step(Policy.State(), classified("ca_on_dl"), context(picked: .passport))
        #expect(s.shown == .mismatch)
        #expect(s.mismatch == Policy.Mismatch(id: "ca_on_dl", group: .driversLicence))
        #expect(s.capture == nil)
        #expect(s.state.doc == nil)
        #expect(s.state.hold == nil)
    }

    @Test func theMismatchIsAdvisoryAndTheUntypedCaptureStillRuns() {
        for (picked, id) in [
            (DocumentGroup.driversLicence, "us_passport_book"), (.permanentResident, "ca_on_dl"),
        ] {
            var state = Policy.State()
            var steps: [Policy.Step] = []
            for i in 0...14 {
                let s = step(state, classified(id), context(picked: picked, now: Double(i) * 0.6))
                steps.append(s)
                state = s.state
            }
            #expect(steps.allSatisfy { $0.shown == .mismatch && $0.mismatch?.id == id })
            #expect(steps.first { $0.state.hold != nil }?.state.hold?.reason == .untyped)
            #expect(steps.contains { $0.capture == .untyped })
        }
    }

    @Test func theIDCardLicenceConfusionShowsNoMismatchEitherWay() {
        for (picked, id) in [
            (DocumentGroup.driversLicence, "ca_ab_id"), (.driversLicence, "ca_mb_id"),
            (.national, "ca_on_dl"), (.national, "us_ga_dl"),
        ] {
            var state = Policy.State()
            var steps: [Policy.Step] = []
            for i in 0...14 {
                let s = step(state, classified(id), context(picked: picked, now: Double(i) * 0.6))
                steps.append(s)
                state = s.state
            }
            #expect(
                steps.allSatisfy { $0.mismatch == nil && $0.shown == .identifying },
                "\(picked) / \(id)")
            #expect(steps.contains { $0.capture == .untyped }, "\(picked) / \(id)")
        }
        // Any other pair still gets the note.
        #expect(
            step(Policy.State(), classified("ca_ab_id"), context(picked: .passport)).shown
                == .mismatch)
    }

    @Test func aTypeConfirmedOnlyByVoteNeverClaimsAnotherDocument() {
        let s = step(
            Policy.State(), classified("ca_on_dl", voted: true), context(picked: .passport))
        #expect(s.mismatch == nil)
        #expect(s.shown == .classified)
        #expect(
            s.chip
                == Policy.Chip(
                    doc: .init(id: "ca_on_dl", source: .vote, strength: .weak), pending: false))
    }

    // MARK: The sticky document

    @Test func theDocumentStaysWhileThreeOfTheLastFiveStillPutItFirst() {
        let first = step(Policy.State(), classified("ca_on_dl", voted: true), context())
        let held = step(
            first.state, steady,
            context(votes: [
                VoteEntry("ca_on_dl", 0.6, margin: 0.5), VoteEntry("ca_on_dl", 0.55, margin: 0.5),
                VoteEntry("us_ga_dl", 0.5, margin: 0.05), VoteEntry("ca_on_dl", 0.52, margin: 0.1),
            ]))
        #expect(
            held.chip
                == Policy.Chip(
                    doc: .init(id: "ca_on_dl", source: .vote, strength: .weak), pending: false))
        let dropped = step(
            held.state, steady,
            context(votes: [
                VoteEntry("ca_on_dl", 0.55, margin: 0.2), VoteEntry("us_ga_dl", 0.5, margin: 0.05),
                VoteEntry("us_ga_dl", 0.51, margin: 0.05), VoteEntry("ca_on_dl", 0.52, margin: 0.1),
            ]))
        #expect(dropped.chip == nil)
        // Frames under the named floor don't keep a licence, however many put it first.
        let low = step(
            held.state, steady,
            context(votes: Array(repeating: VoteEntry("ca_on_dl", 0.45, margin: 0.4), count: 3)))
        #expect(low.chip == nil)
    }

    @Test func theDocumentGoesWhenTheCardLeavesAndSurvivesAFailedCall() {
        let first = step(Policy.State(), classified("ca_on_dl", voted: true), context())
        #expect(
            step(first.state, error, context(), outcome: .failure(status: 503)).chip?.doc.id
                == "ca_on_dl")
        #expect(step(first.state, noID, context()).chip == nil)
    }

    @Test func forTheSameTypeTrustMovesUpButNeverDown() {
        let weak = step(Policy.State(), classified("ca_on_dl", voted: true), context())
        let up = step(weak.state, classified("ca_on_dl", voted: true, strength: .strong), context())
        #expect(up.chip?.doc.strength == .strong)
        let again = step(up.state, classified("ca_on_dl", voted: true), context())
        #expect(again.chip?.doc.strength == .strong)
        let api = step(again.state, classified("ca_on_dl"), context())
        #expect(api.chip?.doc.source == .api)
        #expect(
            step(api.state, classified("ca_on_dl", voted: true), context()).chip?.doc.source == .api
        )
    }

    @Test func aFirstGuessShowsAsAPendingChip() {
        let guess = ScanDecision(
            .identifying, source: .api, doc: ScanDoc(id: "ca_on_dl", confidence: 0.6))
        let s = step(Policy.State(), guess, context())
        #expect(
            s.chip
                == Policy.Chip(
                    doc: .init(id: "ca_on_dl", source: .api, strength: .weak), pending: true))
    }

    // MARK: What is sent with the photo

    @Test func theConfirmedClassificationCarriesKindGroupSourceVotesTop3AndModel() {
        var memo = ScanMemo()
        memo.votes = [
            VoteEntry("ca_on_dl", 0.8), VoteEntry("ca_on_dl", 0.6), VoteEntry("us_ga_dl", 0.4),
            VoteEntry("ca_on_dl", 0.1),
        ]
        let confirmed = Policy.confirmed(classified("ca_on_dl"), memo: memo, shown: nil)
        #expect(
            confirmed
                == Policy.Confirmed(
                    id: "ca_on_dl", confidence: 0.8, kind: .driversLicence, group: .driversLicence,
                    source: .api,
                    strength: .strong, top3: [.init(id: "ca_on_dl", confidence: 0.8)], votes: 2,
                    modelVersion: "m1", captureRotation: 0))
        #expect(
            Policy.confirmed(classified("ca_on_dl", voted: true), memo: memo, shown: nil)?.source
                == .vote)
        #expect(
            Policy.confirmed(classified("ca_on_dl"), memo: memo, shown: nil, captureRotation: 180)?
                .captureRotation == 180)
        #expect(Policy.confirmed(steady, memo: memo, shown: nil) == nil)
    }

    @Test func whatIsReportedCarriesTheShownTrustForThatType() {
        let c = Policy.confirmed(
            classified("ca_on_dl", voted: true), memo: ScanMemo(),
            shown: .init(id: "ca_on_dl", source: .vote, strength: .strong))
        #expect(c?.strength == .strong)
        #expect(c?.source == .vote)
    }

    // MARK: Running the scan end to end

    @Test func theRunningPolicyDecidesAndStepsInOne() {
        var policy = Policy(documentType: .driversLicense)
        #expect(policy.picked == .driversLicence)
        #expect(policy.health == .strict)
        let first = policy.step(detectFrame("ca_on_dl", 0.8), frameGood: true, now: 0)
        #expect(first.shown == .identifying)
        let second = policy.step(detectFrame("ca_on_dl", 0.8), frameGood: true, now: 0.5)
        #expect(second.shown == .classified)
        #expect(policy.state.hold?.reason == .typed)
        #expect(policy.captureDue(at: 0.5 + hold) == .typed)
    }
}

// MARK: - Health cards

/// The scan without the camera: each answer decided with the vote rule and
/// stepped through the policy, 0.5 s apart.
private struct Scan {
    var policy: Policy
    var steps: [Policy.Step] = []

    init(_ documentType: DocumentType?) {
        policy =
            documentType.map { Policy(documentType: $0) } ?? Policy(picked: nil, health: .strict)
    }

    @discardableResult
    mutating func run(_ answers: [DetectOutcome], start: TimeInterval = 0) -> Self {
        steps = answers.enumerated().map { i, outcome in
            policy.step(outcome, frameGood: true, now: start + Double(i) * 0.5)
        }
        return self
    }

    var last: Policy.Step { steps[steps.count - 1] }
}

private func card(_ top3: [(String, Double)], id: String? = nil) -> DetectOutcome {
    .answer(
        DetectAnswer(
            present: true, box: .init(xyxy: [0, 0, 1, 1]),
            documentType: .init(
                id: id, confidence: top3.first?.1 ?? 0,
                top3: top3.map { .init(id: $0.0, confidence: $0.1) }),
            modelVersion: "m1"))
}

/// A health card the classifier names itself.
private let apiHealth = card([("ca_on_hc", 0.9), ("ca_on_dl", 0.05)], id: "ca_on_hc")
/// Below the classifier's own threshold, but a clear leader: a strong vote after 4 frames.
private let strongHealth = card([("ca_on_hc", 0.4), ("ca_on_dl", 0.1)])
/// Leads, but too close to the second guess to be strong.
private let weakHealth = card([("ca_on_hc", 0.3), ("ca_mb_id", 0.25)])
/// Leads, but under the vote floor: only first in the window.
private let faintHealth = card([("ca_on_hc", 0.15), ("ca_on_dl", 0.1)])
/// A card the classifier can't type, its faint first guess a licence.
private let faintLicence = card([("ca_on_dl", 0.1), ("ca_on_hc", 0.05)])

private func times(_ n: Int, _ outcome: DetectOutcome) -> [DetectOutcome] {
    Array(repeating: outcome, count: n)
}

@Suite struct ClassifierHealthCardTests {
    @Test func healthCardVotesCountOnlyUnderTheStrictPolicy() {
        #expect(Policy.voteAllows("ca_on_hc", health: .strict, picked: .national))
        #expect(Policy.voteAllows("ca_on_hc", health: .strict, picked: nil))
        #expect(Policy.voteAllows("ca_on_hc", health: .strict, picked: .driversLicence))
        #expect(!Policy.voteAllows("ca_on_hc", health: .apiOnly, picked: .national))
        #expect(Policy.voteAllows("ca_on_dl", health: .apiOnly, picked: .driversLicence))
        #expect(!Policy.voteAllows("ca_on_dl", health: .strict, picked: nil))
    }

    @Test(arguments: [DocumentType.driversLicense, .idCard])
    func aHealthCardTheClassifierNamesIsBlockedAndNeverCaptured(type: DocumentType) {
        var scan = Scan(type)
        scan.run(times(20, apiHealth))
        #expect(scan.steps[0].shown == .identifying)
        for s in scan.steps.dropFirst() {
            #expect(s.shown == .healthCard)
            #expect(s.capture == nil)
            #expect(s.mismatch == nil)
            #expect(s.state.hold == nil)
            #expect(s.state.doc == Policy.ShownDoc(id: "ca_on_hc", source: .api, strength: .strong))
        }
    }

    @Test func aHealthCardTheClassifierNamesIsBlockedEvenUnderTheAPIOnlyPolicy() {
        var scan = Scan(nil)
        scan.policy = Policy(picked: .permanentResident, health: .apiOnly)
        scan.run(times(12, apiHealth))
        #expect(scan.steps.dropFirst().allSatisfy { $0.shown == .healthCard && $0.capture == nil })
    }

    @Test func underTheAPIOnlyPolicyAStrongHealthCardVoteIsNotBlocked() {
        var scan = Scan(nil)
        scan.policy = Policy(picked: .permanentResident, health: .apiOnly)
        scan.run(times(8, strongHealth))
        #expect(scan.steps.allSatisfy { $0.shown != .healthCard && $0.state.doc == nil })
    }

    @Test(arguments: [DocumentType.driversLicense, .idCard])
    func aStrongHealthCardVoteIsBlocked(type: DocumentType) {
        var scan = Scan(type)
        scan.run(times(12, strongHealth))
        #expect(scan.last.shown == .healthCard)
        #expect(
            scan.last.state.doc == Policy.ShownDoc(id: "ca_on_hc", source: .vote, strength: .strong)
        )
        #expect(scan.steps.allSatisfy { $0.capture == nil })
    }

    @Test(arguments: [DocumentType.driversLicense, .idCard])
    func aWeakHealthCardVoteHoldsAutoCapture(type: DocumentType) {
        var scan = Scan(type)
        scan.run(times(12, weakHealth))
        #expect(12 * 0.5 > untyped)
        #expect(scan.steps.allSatisfy { $0.capture == nil })
        #expect(scan.last.shown == .identifying)
        #expect(scan.last.chip == nil)
        #expect(
            scan.last.state.doc == Policy.ShownDoc(id: "ca_on_hc", source: .vote, strength: .weak))
    }

    @Test(arguments: [DocumentType.driversLicense, .idCard])
    func aHealthCardLeadingBelowTheFloorHoldsTheUntypedCapture(type: DocumentType) {
        var scan = Scan(type)
        scan.run(times(18, faintHealth))
        #expect(scan.steps.allSatisfy { $0.capture == nil && $0.state.hold == nil })
        #expect(scan.steps.allSatisfy { $0.shown == .identifying })
    }

    @Test(arguments: [DocumentType.driversLicense, .idCard])
    func onceAnotherTypeLeadsTheUntypedCaptureGoesAhead(type: DocumentType) {
        var scan = Scan(type)
        scan.run(times(10, faintHealth))
        #expect(scan.steps.allSatisfy { $0.capture == nil })
        scan.run(times(6, faintLicence), start: 5)
        #expect(scan.steps[0].state.hold == nil, "the health card still leads 4 of 5")
        #expect(scan.steps[2].state.hold?.reason == .untyped, "the licence now leads 3 of 5")
        #expect(scan.steps.prefix(5).allSatisfy { $0.capture == nil })
        #expect(scan.steps[5].capture == .untyped)
    }

    @Test func aServicesCardTheClassifierNamesIsBlockedAsAHealthCard() {
        var scan = Scan(.driversLicense)
        scan.run(times(12, card([("ca_bc_id", 0.9), ("ca_bc_dl_bcsc", 0.05)], id: "ca_bc_id")))
        #expect(scan.steps.dropFirst().allSatisfy { $0.shown == .healthCard && $0.capture == nil })
    }

    @Test func theCombinedLicenceClassIsNotAHealthCardAndIsCaptured() {
        var scan = Scan(.driversLicense)
        scan.run(
            times(12, card([("ca_bc_dl_bcsc", 0.9), ("ca_bc_id", 0.05)], id: "ca_bc_dl_bcsc")))
        #expect(scan.steps.allSatisfy { $0.shown != .healthCard })
        #expect(scan.steps.contains { $0.capture != nil })
    }

    @Test func noPickAStrongHealthCardVoteIsBlockedToo() {
        var scan = Scan(nil)
        #expect(scan.run(times(8, strongHealth)).last.shown == .healthCard)
    }

    @Test func aWeakHealthCardVoteThatTurnsStrongIsBlocked() {
        var scan = Scan(.idCard)
        scan.run(times(4, weakHealth))
        #expect(scan.steps.allSatisfy { $0.capture == nil })
        scan.run(times(5, strongHealth), start: 2)
        #expect(scan.last.shown == .healthCard)
        #expect(scan.steps.allSatisfy { $0.capture == nil })
    }

    @Test func aWeakHealthCardVoteGivesWayWhenAnotherTypeWins() {
        var scan = Scan(.idCard)
        scan.run(times(4, weakHealth))
        scan.run(times(5, card([("ca_mb_id", 0.9)], id: "ca_mb_id")), start: 2)
        #expect(scan.last.shown == .classified)
        #expect(scan.last.capture == .typed)
        #expect(scan.last.state.doc?.id == "ca_mb_id")
    }

    @Test func aHealthCardLeadsTheWindowWhenNoOtherIDLeadsMoreTiesIncluded() {
        func v(_ id: String?) -> VoteEntry { VoteEntry(id, 0.1) }
        #expect(Policy.healthLeads([v("ca_on_hc"), v("ca_on_dl"), v("us_ga_dl"), v(nil)]))
        #expect(!Policy.healthLeads([v("ca_on_hc"), v("ca_on_dl"), v("ca_on_dl")]))
        #expect(
            !Policy.healthLeads([v("ca_on_hc"), v("ca_qc_hc"), v("ca_on_dl"), v("ca_on_dl")]),
            "the best single id, not the kind's total")
        #expect(!Policy.healthLeads([v(nil)]))
        #expect(!Policy.healthLeads([]))
    }

    @Test func apiOnlyPicksIgnoreAWeakOrFaintHealthCardLead() {
        for answer in [weakHealth, faintHealth] {
            var scan = Scan(nil)
            scan.policy = Policy(picked: .military, health: .apiOnly)
            scan.run(times(14, answer))
            #expect(scan.steps.contains { $0.capture == .untyped })
        }
    }

    @Test func aBlockedHealthCardKeepsItsWarningOverQualityGuidanceUntilItLeaves() {
        var scan = Scan(.driversLicense)
        scan.run(times(3, apiHealth))
        // The window still puts the card first, but this answer confirms nothing.
        let fuzzy = card([("ca_on_hc", 0.3), ("ca_on_dl", 0.1)])
        scan.run([fuzzy], start: 1.5)
        #expect(scan.last.shown == .healthCard)
        #expect(scan.last.capture == nil)
        let blurred = scan.policy.step(fuzzy, frameGood: false, now: 4)
        #expect(blurred.shown == .healthCard)
        #expect(blurred.capture == nil)
        let gone = scan.policy.step(
            .answer(DetectAnswer(present: false)), frameGood: true, now: 4.5)
        #expect(gone.shown == .noID)
        #expect(gone.state.doc == nil)
    }

    @Test func aHealthCardNeverGetsTheDocumentChip() {
        var scan = Scan(.driversLicense)
        scan.run(times(3, apiHealth))
        #expect(scan.last.shown == .healthCard)
        #expect(scan.last.chip == nil)
    }
}
