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

@Test func theFlipStaysUpLongEnoughToSeeItTurn() {
    var presenter = CaptureStagePresenter(.captured)
    #expect(presenter.update(.flip, at: 10) == .flip)
    // The card left the frame at once and the back is in view: still the flip.
    presenter.update(.findDocument, at: 10.1)
    #expect(presenter.update(.findDocument, at: 11.5) == .flip)
    #expect(presenter.update(.findDocument, at: 11.6) == .findDocument)
}

// MARK: - Copy

@Test func theWordsFollowTheDocumentAndSide() {
    let licence = CaptureCopy.Context(documentType: .driversLicense, isFinalSide: false)
    #expect(CaptureCopy.lines(for: .findDocument, in: licence).title == "Fill the frame with your licence")
    #expect(CaptureCopy.lines(for: .findDocument, in: licence).subtitle == CaptureCopy.automatic)
    let back = CaptureCopy.Context(documentType: .driversLicense, isBack: true, isFinalSide: true)
    #expect(
        CaptureCopy.lines(for: .findDocument, in: back).title
            == "Fill the frame with the back of your licence")
    let passport = CaptureCopy.Context(documentType: .passport)
    #expect(
        CaptureCopy.lines(for: .findDocument, in: passport).title
            == "Fill the frame with your passport photo page")
    #expect(CaptureCopy.lines(for: .captured, in: licence).title == "Front captured")
    #expect(CaptureCopy.lines(for: .captured, in: back).title == "All done!")
    #expect(CaptureCopy.lines(for: .flip, in: licence).title == "Now show the back of your licence")
}

@Test func everyStageHasATitle() {
    let stages: [CaptureStage] = [
        .findDocument, .adjust(.turnToLandscape), .adjust(.moveCloser), .adjust(.fitInFrame),
        .adjust(.reduceGlare), .checking, .turnOver, .wrongDocument(.passport), .healthCard,
        .holdStill, .captured, .flip, .processing,
    ]
    for type in [DocumentType.driversLicense, .idCard, .passport] {
        for stage in stages {
            let title = CaptureCopy.lines(for: stage, in: .init(documentType: type)).title
            #expect(!title.isEmpty, "\(stage) \(type)")
        }
    }
    #expect(CaptureCopy.encryption == "Protected by TripleLock® Encryption System")
}

@Test func theRecognisedDocumentIsNamed() {
    #expect(ShownDocument(id: "ca_on_dl", confirmed: true).label == "Ontario Driver's Licence")
    #expect(ShownDocument(id: "nope", confirmed: false).label == nil)
}

// MARK: - Layout

@Test func theWindowFitsTheScreenAndKeepsTheDocumentShape() {
    for size in [CGSize(width: 1366, height: 1024), CGSize(width: 1024, height: 1366),
                 CGSize(width: 393, height: 852), CGSize(width: 852, height: 393)] {
        for aspect in [1.586, 1.42] as [CGFloat] {
            let window = CaptureLayout.window(in: size, aspect: aspect)
            #expect(abs(window.width / window.height - aspect) < 0.001)
            #expect(window.width <= size.width * CaptureLayout.maxWindowWidth + 0.001)
            #expect(window.height <= size.height * CaptureLayout.maxWindowHeight + 0.001)
            #expect(window.minX >= 0 && window.maxX <= size.width)
            #expect(abs(window.midX - size.width / 2) < 0.001)
        }
    }
}

// MARK: - "Close enough" follows the drawn frame

@Test func aCardThatFillsTheDrawnFrameIsCloseEnough() {
    // iPad landscape: the window is drawn on 1366×1024, over a 4∶3 camera frame.
    let size = CGSize(width: 1366, height: 1024)
    let window = CaptureLayout.window(in: size, aspect: 1.586)
    let share = Double(window.width / size.width)
    let fill = DocumentCaptureAnalyzer.guideFill(
        widthShare: share, screenAspect: Double(size.width / size.height),
        frameAspect: 4.0 / 3.0, share: DocumentCaptureTunables().guideFillShare)
    var analyzer = DocumentCaptureAnalyzer(documentType: .driversLicense)
    analyzer.guideFill = fill
    // A card across 90% of the drawn window passes the distance check …
    let filling = CaptureQuality(
        documentDetected: true, fillRatio: share * 0.9,
        aspectRatio: 1.586, sharpness: 300, glareRatio: 0)
    #expect(analyzer.assess(filling) == nil)
    // … one across half of it is still asked to come closer.
    var far = filling
    far.fillRatio = share * 0.5
    #expect(analyzer.assess(far) == .moveCloser)
}

@Test func theDrawnFrameNeverAsksForMoreThanTheDefault() {
    var analyzer = DocumentCaptureAnalyzer(documentType: .driversLicense)
    #expect(analyzer.minFill == DocumentCaptureTunables().minFillRatio)
    analyzer.guideFill = 0.9
    #expect(analyzer.minFill == DocumentCaptureTunables().minFillRatio)
    analyzer.guideFill = 0.4
    #expect(analyzer.minFill == 0.4)
}

@Test func aNarrowScreenSeesLessOfTheCameraFrame() {
    // A phone in portrait shows the middle of a 3∶4 frame: the window's share of
    // the screen is a smaller share of the frame.
    let fill = DocumentCaptureAnalyzer.guideFill(
        widthShare: 0.8, screenAspect: 393.0 / 852.0, frameAspect: 3.0 / 4.0, share: 1)
    #expect(abs(fill - 0.8 * (393.0 / 852.0) / 0.75) < 1e-9)
}
