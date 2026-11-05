import Foundation
import Testing

@testable import DeepIDV
@testable import DeepIDVCore

// The one instruction on the capture screen, and when it changes.

private let settle = CaptureStagePresenter.settle

@Test func everyGuidanceHasOneStageWithText() {
    let all: [CaptureGuidance] = [
        .searching, .turnToLandscape, .moveCloser, .fitDocumentInFrame, .reduceGlare,
        .holdSteady, .identifying, .connecting, .wrongWay, .healthCard,
        .otherDocument(.passport),
    ]
    for guidance in all {
        let text = CaptureStage(guidance).defaultText
        #expect(text?.isEmpty == false, "\(guidance)")
    }
    #expect(CaptureStage(.identifying) == CaptureStage(.connecting))
    #expect(CaptureStage(.otherDocument(.driversLicence)) == .wrongDocument(.driversLicence))
}

@Test func aNewStageShowsOnlyOnceItHasHeld() {
    #expect(settle == 0.5)
    var presenter = CaptureStagePresenter()
    #expect(presenter.update(.adjust(.moveCloser), at: 0) == .findDocument)
    #expect(presenter.update(.adjust(.moveCloser), at: 0.49) == .findDocument)
    #expect(presenter.update(.adjust(.moveCloser), at: 0.5) == .adjust(.moveCloser))
}

@Test func aReadingThatChangesFrameToFrameNeverFlashes() {
    // A passport held up for a licence: the readings jump around every frame.
    let readings: [CaptureStage] = [
        .checking, .turnOver, .holdStill, .wrongDocument(.driversLicence), .adjust(.moveCloser),
    ]
    var presenter = CaptureStagePresenter(.checking)
    var shown: Set<String> = []
    for i in 0..<60 {
        let now = Double(i) / 30
        shown.insert("\(presenter.update(readings[i % readings.count], at: now))")
    }
    #expect(shown == ["checking"])
}

@Test func aBriefOtherReadingDoesNotResetTheShownStage() {
    var presenter = CaptureStagePresenter(.holdStill)
    presenter.update(.checking, at: 0)
    presenter.update(.holdStill, at: 0.2)
    // The checking reading started again: it has to hold afresh.
    presenter.update(.checking, at: 0.3)
    #expect(presenter.update(.checking, at: 0.7) == .holdStill)
    #expect(presenter.update(.checking, at: 0.8) == .checking)
}

@Test func whatFollowsAnEventShowsAtOnce() {
    for stage in [CaptureStage.captured, .flip, .processing] {
        var presenter = CaptureStagePresenter(.holdStill)
        #expect(presenter.update(stage, at: 0) == stage)
    }
}

@Test func onlyTheWrongDocumentStagesAreProblems() {
    #expect(CaptureStage.wrongDocument(.passport).isProblem)
    #expect(CaptureStage.healthCard.isProblem)
    #expect(!CaptureStage.turnOver.isProblem)
    #expect(!CaptureStage.adjust(.moveCloser).isProblem)
}

@Test func theCapturedTickAndTheProcessingScreenHaveNoInstruction() {
    #expect(CaptureStage.captured.defaultText == nil)
    #expect(CaptureStage.processing.defaultText == nil)
    #expect(CaptureStage.flip.defaultText == "Now turn it over to scan the back")
}
