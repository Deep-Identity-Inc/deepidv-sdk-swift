import Foundation
import Testing

@testable import DeepIDV
@testable import DeepIDVCore

// How the capture model and the ID step use the classifier, with a fake one.

// MARK: - A scripted classifier

@MainActor
private final class FakeClassifier: DocumentClassifying {
    var verdict: ClassifierVerdict
    var replacementPhoto: FileInput?
    var classification: TierCaptureClassification?
    private(set) var observed = 0
    private(set) var captures: [Bool] = []
    private(set) var stopped = false
    var shown: ShownDocument?

    var shownDocument: ShownDocument? { shown }

    init(_ verdict: ClassifierVerdict) {
        self.verdict = verdict
    }

    func observe(
        _ frame: CameraFrame, quality: CaptureQuality, framed: Bool, visionReady: Bool,
        at now: TimeInterval
    ) { observed += 1 }

    func verdict(at now: TimeInterval) -> ClassifierVerdict { verdict }

    func frontCaptured(photo: FileInput, manual: Bool, at now: TimeInterval) async
        -> FrontCaptureReport
    {
        captures.append(manual)
        return FrontCaptureReport(
            photo: replacementPhoto ?? photo, classification: classification, extraFrames: [])
    }

    func stop() { stopped = true }
}

private struct StillEncoder: DocumentStillEncoding {
    func encode(_ frame: CameraFrame, documentType: DocumentType) throws -> FileInput {
        .data(Data([0xFF, 0xD8, 0xFF, UInt8(frame.index % 256)]))
    }
}

private struct Authorized: CameraAuthorizing {
    func authorizationStatus() -> CameraAuthorizationStatus { .authorized }
    func requestAccess() async -> Bool { true }
}

private let good = CaptureQuality(
    documentDetected: true, fillRatio: 0.72, aspectRatio: 1.586, sharpness: 300, glareRatio: 0)
private let noDocument = CaptureQuality(documentDetected: false)
/// An open passport booklet, as Vision measures it around the photo page.
private let page = CaptureQuality(
    documentDetected: true, fillRatio: 0.76, aspectRatio: 1.2, sharpness: 50, glareRatio: 0)
/// In position and steady, but under the blur bar, as a legible card scores on an
/// iPad front camera.
private let soft = CaptureQuality(
    documentDetected: true, fillRatio: 0.72, aspectRatio: 1.586, sharpness: 50, glareRatio: 0)

@MainActor
private final class CaptureSpy {
    var completed: [(front: FileInput, back: FileInput?)] = []
    var reports: [FrontCaptureReport] = []
    var failure: DeepIDVError?
}

private func bytes(_ input: FileInput?) -> Data? { input.flatMap(ClassifierImages.data(of:)) }

@MainActor
private func makeCapture(
    type: DocumentType, captureMode: CaptureMode? = nil, qualities: [CaptureQuality],
    classifier: FakeClassifier?, rules: Bool = false, sharpnessWaitLimit: TimeInterval = 0.8,
    sharpnessWindow: TimeInterval = 2, spy: CaptureSpy
) -> DocumentCaptureModel<Void> {
    DocumentCaptureModel(
        documentType: type,
        captureMode: captureMode,
        controller: FakeCameraController(qualities: qualities),
        evaluator: PassthroughFrameEvaluator(),
        encoder: StillEncoder(),
        authorizer: Authorized(),
        tunables: .init(
            stabilityFrameCount: 2, holdStillDuration: 0, sideCapturedDisplay: 0,
            doneDisplay: 0, classifierHoldDuration: 0, steadyCaptureDuration: 0,
            sharpnessWindow: sharpnessWindow, sharpnessWaitLimit: sharpnessWaitLimit),
        classifier: classifier,
        usesClassifierRules: rules,
        onFrontCaptured: { spy.reports.append($0) },
        complete: { front, back, _ in spy.completed.append((front, back)) },
        onResult: { if case .failure(let error) = $0 { spy.failure = error } })
}

// MARK: - The capture model

@MainActor @Test func withTheClassifierOffCaptureRunsOnTheOnDeviceChecksAlone() async {
    let spy = CaptureSpy()
    let classifier = FakeClassifier(.off)
    let model = makeCapture(
        type: .idCard, captureMode: .frontOnly, qualities: [good, good], classifier: classifier,
        spy: spy)
    await model.run()
    #expect(spy.completed.count == 1)
    #expect(classifier.observed == 2)
    #expect(spy.reports.count == 1)
}

@MainActor @Test func whileTheClassifierHoldsNothingIsCapturedAndItsGuidanceShows() async {
    let spy = CaptureSpy()
    let model = makeCapture(
        type: .idCard, captureMode: .frontOnly, qualities: Array(repeating: good, count: 6),
        classifier: FakeClassifier(.hold(.identifying)), spy: spy)
    await model.run()
    #expect(spy.completed.isEmpty)
    #expect(spy.failure?.kind == .captureFailed)
    #expect(model.guidance == .identifying)
}

@MainActor @Test func onDeviceHintsComeBeforeTheClassifiersOwn() async {
    let spy = CaptureSpy()
    let model = makeCapture(
        type: .idCard, captureMode: .frontOnly, qualities: [noDocument, noDocument],
        classifier: FakeClassifier(.hold(.identifying)), spy: spy)
    await model.run()
    #expect(model.guidance == .searching)
}

@MainActor @Test func aBlockedCardIsNeverAutoCapturedButTheShutterStillWorks() async {
    let spy = CaptureSpy()
    let blocked = makeCapture(
        type: .driversLicense, captureMode: .frontOnly, qualities: Array(repeating: good, count: 6),
        classifier: FakeClassifier(.block(.healthCard)), spy: spy)
    await blocked.run()
    #expect(spy.completed.isEmpty)
    #expect(blocked.guidance == .healthCard)

    let manualSpy = CaptureSpy()
    let classifier = FakeClassifier(.block(.healthCard))
    let manual = makeCapture(
        type: .driversLicense, captureMode: .frontOnly, qualities: [good, good],
        classifier: classifier, spy: manualSpy)
    manual.triggerManualCapture()
    await manual.run()
    #expect(manualSpy.completed.count == 1)
    #expect(classifier.captures == [true])
}

@MainActor @Test func whenTheClassifierSaysGoTheFrontIsCapturedWithItsReport() async throws {
    let spy = CaptureSpy()
    let classifier = FakeClassifier(.go)
    classifier.replacementPhoto = .data(Data([0x4B, 0x01]))
    let model = makeCapture(
        type: .idCard, captureMode: .frontOnly, qualities: [good, good], classifier: classifier,
        spy: spy)
    await model.run()
    let completed = try #require(spy.completed.first)
    #expect(bytes(completed.front) == Data([0x4B, 0x01]), "the report's photo is uploaded")
    #expect(classifier.captures == [false])
    #expect(classifier.stopped)
}

@MainActor @Test func withTheClassifierInPlayBlurDoesNotHoldCaptureBack() async {
    let spy = CaptureSpy()
    let model = makeCapture(
        type: .idCard, captureMode: .frontOnly, qualities: [soft, soft],
        classifier: FakeClassifier(.go), spy: spy)
    await model.run()
    #expect(spy.completed.count == 1)
}

@MainActor @Test func aSoftMomentAfterASharpOneWaitsForASharperFrame() async {
    let spy = CaptureSpy()
    let model = makeCapture(
        type: .idCard, captureMode: .frontOnly, qualities: [good, soft, soft, soft],
        classifier: FakeClassifier(.go), sharpnessWaitLimit: 100, sharpnessWindow: 100, spy: spy)
    await model.run()
    #expect(spy.completed.isEmpty)
    #expect(model.guidance == .holdSteady)
}

@MainActor @Test func theWaitEndsOnTheNextSharpFrame() async {
    let spy = CaptureSpy()
    let model = makeCapture(
        type: .idCard, captureMode: .frontOnly, qualities: [good, soft, soft, good],
        classifier: FakeClassifier(.go), sharpnessWaitLimit: 100, sharpnessWindow: 100, spy: spy)
    await model.run()
    #expect(spy.completed.count == 1)
}

@MainActor @Test func theWaitForASharperFrameIsCapped() async {
    let spy = CaptureSpy()
    let model = makeCapture(
        type: .idCard, captureMode: .frontOnly, qualities: [good, soft, soft],
        classifier: FakeClassifier(.go), sharpnessWaitLimit: 0, sharpnessWindow: 100, spy: spy)
    await model.run()
    #expect(spy.completed.count == 1)
}

@MainActor @Test func withoutTheClassifierRulesTheBlurGateStands() async {
    let spy = CaptureSpy()
    let model = makeCapture(
        type: .idCard, captureMode: .frontOnly, qualities: Array(repeating: soft, count: 6),
        classifier: nil, spy: spy)
    await model.run()
    #expect(spy.completed.isEmpty)
    #expect(model.guidance == .holdSteady)
}

@MainActor @Test func underTheClassifierRulesASoftBackIsCapturedOnceSteady() async throws {
    let spy = CaptureSpy()
    let model = makeCapture(
        type: .idCard, qualities: [soft, soft, noDocument, soft, soft, soft],
        classifier: FakeClassifier(.go), spy: spy)
    await model.run()
    let completed = try #require(spy.completed.first)
    #expect(completed.1 != nil, "the back was captured")
}

@MainActor @Test func underTheClassifierRulesASoftPassportPageIsCapturedOnceSteady() async {
    let spy = CaptureSpy()
    let model = makeCapture(
        type: .passport, qualities: [soft, soft], classifier: nil, rules: true, spy: spy)
    await model.run()
    #expect(spy.completed.count == 1)

    let legacySpy = CaptureSpy()
    let legacy = makeCapture(
        type: .passport, qualities: Array(repeating: soft, count: 6), classifier: nil,
        spy: legacySpy)
    await legacy.run()
    #expect(legacySpy.completed.isEmpty)
}

@MainActor @Test func theRulesFollowTheSessionsClassifier() async {
    #expect(!makeStep(availability: nil, spy: StepSpy()).usesClassifierRules)
    let availability = ClassifierAvailability()
    #expect(makeStep(availability: availability, spy: StepSpy()).usesClassifierRules)
    availability.record(.failure(DetectFailure(status: 403, reason: .unavailable)))
    #expect(!makeStep(availability: availability, spy: StepSpy()).usesClassifierRules)
}

@MainActor @Test func cardBacksNeverReachTheClassifierButPassportPagesDo() async {
    let spy = CaptureSpy()
    let classifier = FakeClassifier(.go)
    let card = makeCapture(
        type: .idCard, qualities: [good, good, noDocument, good, good, good],
        classifier: classifier,
        spy: spy)
    await card.run()
    #expect(spy.completed.count == 1)
    #expect(classifier.observed == 2, "front frames only")

    let passportSpy = CaptureSpy()
    let passportClassifier = FakeClassifier(.hold(.identifying))
    let passport = makeCapture(
        type: .passport, qualities: [page, page, page], classifier: passportClassifier,
        spy: passportSpy)
    await passport.run()
    #expect(passportSpy.completed.isEmpty, "the classifier holds the page until it is steady")
    #expect(passportClassifier.observed == 3)
    #expect(passportSpy.failure?.kind == .captureFailed)
}

@MainActor @Test func aPassportPageTheClassifierPassesIsCapturedAndReported() async {
    let spy = CaptureSpy()
    let classifier = FakeClassifier(.go)
    let model = makeCapture(
        type: .passport, qualities: [page, page], classifier: classifier, spy: spy)
    await model.run()
    #expect(spy.completed.count == 1)
    #expect(spy.completed.first?.back == nil)
    #expect(classifier.captures == [false])
    #expect(spy.reports.count == 1)
}

@MainActor @Test func theRecognisedDocumentAndThePhotoReachTheScreen() async {
    let spy = CaptureSpy()
    let classifier = FakeClassifier(.go)
    classifier.shown = ShownDocument(id: "ca_on_dl", confirmed: true)
    let model = makeCapture(
        type: .driversLicense, captureMode: .frontOnly, qualities: [good, good],
        classifier: classifier, spy: spy)
    #expect(model.isFinalSide)
    await model.run()
    #expect(model.shownDocument?.label == "Ontario Driver's Licence")
    #expect(spy.completed.count == 1)
}

@MainActor @Test func aTwoSidedCardIsOnlyFinalOnItsBack() {
    let model = makeCapture(
        type: .driversLicense, qualities: [], classifier: nil, spy: CaptureSpy())
    #expect(model.hasBack)
    #expect(!model.isFinalSide)
}

@MainActor @Test func theScreenEndsOnTheProcessingStage() async {
    let spy = CaptureSpy()
    let model = makeCapture(
        type: .passport, qualities: [page, page], classifier: FakeClassifier(.go), spy: spy)
    #expect(model.stage == .findDocument)
    await model.run()
    #expect(model.stage == .processing)
}

@MainActor @Test func anOpenBookletIsFramedForAPassport() async {
    // The shape Vision measured around an open booklet on the iPad front camera.
    for aspect in [1.11, 1.19, 1.24] {
        var booklet = page
        booklet.aspectRatio = aspect
        let spy = CaptureSpy()
        let model = makeCapture(
            type: .passport, qualities: [booklet, booklet], classifier: FakeClassifier(.go),
            spy: spy)
        await model.run()
        #expect(spy.completed.count == 1, "aspect \(aspect)")
    }
}

@MainActor @Test func cancellingStopsTheClassifier() async {
    let spy = CaptureSpy()
    let classifier = FakeClassifier(.hold(.identifying))
    let model = makeCapture(
        type: .idCard, qualities: [good], classifier: classifier, spy: spy)
    model.cancel()
    #expect(classifier.stopped)
}

// MARK: - The ID step

private func requirements(secondary: Bool = false) -> IDVerificationRequirements {
    IDVerificationRequirements(
        document: .init(
            requireFrontOnly: false, frontOnlyDocumentTypes: ["passport"],
            requireSecondaryID: secondary, requireTertiaryID: false,
            validIDTypes: ["passport", "drivers-license", "national-id"], validStates: []),
        face: .init(faceFrontPhotoOnly: true))
}

private func completedOutcome() -> WorkflowStepOutcome {
    WorkflowStepOutcome(
        stepID: .idVerification, stepStatus: .completed, failure: nil, currentStep: nil,
        attemptsRemaining: 1, sessionStatus: .submitted, sessionProgress: .completed, attempts: 1)
}

@MainActor
private final class StepSpy {
    var submissions: [IDVerificationSubmission] = []
    var extraUploads: [[ExtraFrameSlot: FileInput]] = []
    var rejectFieldsOnce = false
    var failures: [DeepIDVError] = []
}

private func tier(_ id: String = "gb_dvla_dl") -> TierCaptureClassification {
    TierCaptureClassification(
        ClassifierScanPolicy.Confirmed(
            id: id, confidence: 0.9, kind: .driversLicence, group: .driversLicence, source: .api,
            strength: .strong, top3: [.init(id: id, confidence: 0.9)], votes: 3,
            modelVersion: "m-test", captureRotation: 0),
        captureMode: .auto)
}

private func photo(_ byte: UInt8) -> FileInput { .data(Data([0xFF, 0xD8, 0xFF, byte])) }

@MainActor
private func makeStep(
    availability: ClassifierAvailability?, spy: StepSpy, secondary: Bool = false
) -> IDVerificationStepFlowModel {
    IDVerificationStepFlowModel(
        requirements: requirements(secondary: secondary),
        classifier: availability.map { availability in
            .init(availability: availability, make: { _, _ in FakeClassifier(.off) })
        },
        upload: { files in
            Dictionary(uniqueKeysWithValues: files.keys.map { ($0, "key-\($0.rawValue)") })
        },
        uploadExtraFrames: { files in
            await MainActor.run { spy.extraUploads.append(files) }
            return Dictionary(uniqueKeysWithValues: files.keys.map { ($0, "x-\($0.rawValue)") })
        },
        submit: { submission in
            try await MainActor.run {
                spy.submissions.append(submission)
                if spy.rejectFieldsOnce, submission.hasClassifierFields {
                    spy.rejectFieldsOnce = false
                    throw DeepIDVError.validation("Unrecognized key: capture_classification")
                }
            }
            return completedOutcome()
        },
        onStepCompleted: { _ in },
        onStepFailed: { error in spy.failures.append(error) })
}

/// Picks a licence, photographs it with `report`, then the selfie.
@MainActor
private func completeLicence(
    _ model: IDVerificationStepFlowModel, report: FrontCaptureReport?
) async {
    model.start()
    model.selectDocumentType(.driversLicense)
    if let report { model.frontCaptured(report, slot: .primary) }
    model.documentCaptured(front: report?.photo ?? photo(1), back: photo(2))
    model.selfieCaptured(photo(3))
    await model.awaitPendingWork()
}

private func available(sendsExtraFrames: Bool = false) async -> ClassifierAvailability {
    await MainActor.run {
        let availability = ClassifierAvailability(sendsExtraFrames: sendsExtraFrames)
        availability.record(.answer(DetectAnswer(present: false)))
        return availability
    }
}

@MainActor @Test func theClassificationIsSentOnceTheClassifierHasAnswered() async throws {
    let spy = StepSpy()
    let model = makeStep(availability: await available(), spy: spy)
    await completeLicence(
        model, report: FrontCaptureReport(photo: photo(1), classification: tier(), extraFrames: []))
    let submission = try #require(spy.submissions.first)
    #expect(submission.captureClassification?.tiers[.primary]?.documentType == "gb_dvla_dl")
    #expect(submission.extraFrameUploads.isEmpty)
}

@MainActor @Test func noFieldsAreSentWhileTheClassifierHasNeverAnswered() async throws {
    for availability in [ClassifierAvailability(), nil] {
        let spy = StepSpy()
        let model = makeStep(availability: availability, spy: spy)
        await completeLicence(
            model,
            report: FrontCaptureReport(photo: photo(1), classification: tier(), extraFrames: []))
        let submission = try #require(spy.submissions.first)
        #expect(!submission.hasClassifierFields)
    }
}

@MainActor @Test func aServerThatRejectsTheFieldsGetsOneSubmissionWithoutThem() async {
    let spy = StepSpy()
    spy.rejectFieldsOnce = true
    let model = makeStep(availability: await available(), spy: spy)
    await completeLicence(
        model, report: FrontCaptureReport(photo: photo(1), classification: tier(), extraFrames: []))
    #expect(spy.submissions.count == 2)
    #expect(spy.submissions[0].hasClassifierFields)
    #expect(!spy.submissions[1].hasClassifierFields)
    #expect(spy.submissions[1].uploads == spy.submissions[0].uploads, "same upload keys")
    #expect(spy.failures.isEmpty)
}

@MainActor @Test func anUnconfirmedFrontSendsNoTier() async throws {
    let spy = StepSpy()
    let model = makeStep(availability: await available(), spy: spy)
    await completeLicence(
        model, report: FrontCaptureReport(photo: photo(1), classification: nil, extraFrames: []))
    let submission = try #require(spy.submissions.first)
    #expect(submission.captureClassification == nil)
}

@MainActor @Test func extraFramesAreUploadedAndSentOnlyWhenEnabled() async throws {
    let frames = [photo(7), photo(8)]
    let spy = StepSpy()
    let model = makeStep(availability: await available(sendsExtraFrames: true), spy: spy)
    await completeLicence(
        model,
        report: FrontCaptureReport(photo: photo(1), classification: tier(), extraFrames: frames))
    #expect(spy.extraUploads.first.map { Set($0.keys) } == [.idFront1, .idFront2])
    let submission = try #require(spy.submissions.first)
    #expect(
        submission.extraFrameUploads == [
            .idFront1: "x-id_front_extra_1", .idFront2: "x-id_front_extra_2",
        ])

    let offSpy = StepSpy()
    let off = makeStep(availability: await available(), spy: offSpy)
    await completeLicence(
        off,
        report: FrontCaptureReport(photo: photo(1), classification: tier(), extraFrames: frames))
    #expect(offSpy.extraUploads.isEmpty)
    #expect(offSpy.submissions.first?.extraFrameUploads.isEmpty == true)
}

@MainActor @Test func passportsGetAScannerAndAnUnavailableClassifierNone() async {
    let availability = ClassifierAvailability()
    let model = makeStep(availability: availability, spy: StepSpy())
    #expect(model.classifier(for: .driversLicense) != nil)
    #expect(model.classifier(for: .passport) != nil)
    availability.record(.failure(DetectFailure(status: 403, reason: .unavailable)))
    #expect(model.classifier(for: .driversLicense) == nil)
    #expect(makeStep(availability: nil, spy: StepSpy()).classifier(for: .idCard) == nil)
}

@Test func theClassifierIsOnByDefaultAndCanBeTurnedOff() {
    #expect(DeepIDVConfig(apiKey: "sk_test").usesDocumentClassifier)
    #expect(!DeepIDVConfig(apiKey: "sk_test", usesDocumentClassifier: false).usesDocumentClassifier)
}
