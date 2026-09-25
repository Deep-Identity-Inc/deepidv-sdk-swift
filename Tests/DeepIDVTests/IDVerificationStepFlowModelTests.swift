import Foundation
import Testing

@testable import DeepIDV

private func workflowIDRequirements(
    secondary: Bool = false,
    tertiary: Bool = false,
    validTypes: [String] = ["passport", "drivers-license", "national-id"]
) -> IDVerificationRequirements {
    IDVerificationRequirements(
        document: .init(
            requireFrontOnly: false,
            frontOnlyDocumentTypes: ["passport"],
            requireSecondaryID: secondary,
            requireTertiaryID: tertiary,
            validIDTypes: validTypes,
            validStates: []),
        face: .init(faceFrontPhotoOnly: true))
}

private func image(_ byte: UInt8) -> FileInput {
    .data(Data([0xFF, 0xD8, 0xFF, byte]))
}

private func idOutcome(
    status: WorkflowStepStatus,
    failureReason: String? = nil,
    currentStep: Int?,
    attemptsRemaining: Int?,
    sessionStatus: SessionStatus = .pending,
    sessionProgress: SessionProgress = .started,
    attempts: Int = 0
) -> WorkflowStepOutcome {
    WorkflowStepOutcome(
        stepID: .idVerification,
        stepStatus: status,
        failureReason: failureReason,
        currentStep: currentStep,
        attemptsRemaining: attemptsRemaining,
        sessionStatus: sessionStatus,
        sessionProgress: sessionProgress,
        attempts: attempts)
}

private final class IDStepSpy: @unchecked Sendable {
    var uploadCalls: [[SessionUploadSlot: FileInput]] = []
    var submissions: [IDVerificationSubmission] = []
    var outcomes: [WorkflowStepOutcome]
    var completed: [WorkflowStepOutcome] = []
    var failures: [DeepIDVError] = []

    init(outcomes: [WorkflowStepOutcome]) {
        self.outcomes = outcomes
    }

    func upload(
        _ files: [SessionUploadSlot: FileInput]
    ) async throws -> [SessionUploadSlot: String] {
        uploadCalls.append(files)
        return Dictionary(
            uniqueKeysWithValues: files.keys.map { ($0, "key-\($0.rawValue)") })
    }

    func submit(_ submission: IDVerificationSubmission) async throws
        -> WorkflowStepOutcome
    {
        submissions.append(submission)
        return outcomes.removeFirst()
    }
}

@MainActor
private func makeIDModel(
    requirements: IDVerificationRequirements,
    spy: IDStepSpy
) -> IDVerificationStepFlowModel {
    IDVerificationStepFlowModel(
        requirements: requirements,
        upload: { try await spy.upload($0) },
        submit: { try await spy.submit($0) },
        onStepCompleted: { spy.completed.append($0) },
        onStepFailed: { spy.failures.append($0) })
}

@MainActor @Test
func idStepBuildsEveryRequiredSlotCombination() {
    let terminal = idOutcome(
        status: .completed,
        currentStep: nil,
        attemptsRemaining: 1,
        sessionStatus: .submitted,
        sessionProgress: .completed,
        attempts: 1)

    #expect(
        makeIDModel(
            requirements: workflowIDRequirements(),
            spy: IDStepSpy(outcomes: [terminal])
        ).slots == [.primary])
    #expect(
        makeIDModel(
            requirements: workflowIDRequirements(secondary: true),
            spy: IDStepSpy(outcomes: [terminal])
        ).slots == [.primary, .secondary])
    #expect(
        makeIDModel(
            requirements: workflowIDRequirements(tertiary: true),
            spy: IDStepSpy(outcomes: [terminal])
        ).slots == [.primary, .tertiary])
    #expect(
        makeIDModel(
            requirements: workflowIDRequirements(secondary: true, tertiary: true),
            spy: IDStepSpy(outcomes: [terminal])
        ).slots == [.primary, .secondary, .tertiary])
}

@MainActor @Test
func regionSuffixedCatalogueMapsToFamilyOptions() {
    // Server workflow configs can carry the region-suffixed catalogue instead
    // of plain family values. Only the passport and driver's-license families
    // map; the submitted wire value is the family value the submission
    // contract (and the server's front-only registry) key on.
    let model = makeIDModel(
        requirements: workflowIDRequirements(validTypes: [
            "aadhaar-in",
            "driver-license-ca",
            "driver-license-us",
            "firearm-license-us",
            "national-id-eu",
            "passport-us",
            "pr-card-ca",
        ]),
        spy: IDStepSpy(outcomes: []))

    #expect(
        model.documentTypeOptions == [
            WorkflowDocumentTypeOption(
                documentType: .driversLicense, wireValue: "drivers-license"),
            WorkflowDocumentTypeOption(documentType: .passport, wireValue: "passport"),
        ])
}

@MainActor @Test
func plainWireValuesPassThroughUnchanged() {
    // Un-suffixed values keep their original wire value on submission —
    // suffix handling must not rewrite what already matched exactly.
    let model = makeIDModel(
        requirements: workflowIDRequirements(validTypes: [
            "passport", "driving-license", "national-id",
        ]),
        spy: IDStepSpy(outcomes: []))

    #expect(
        model.documentTypeOptions == [
            WorkflowDocumentTypeOption(documentType: .passport, wireValue: "passport"),
            WorkflowDocumentTypeOption(
                documentType: .driversLicense, wireValue: "driving-license"),
            WorkflowDocumentTypeOption(documentType: .idCard, wireValue: "national-id"),
        ])
}

@MainActor @Test
func suffixedPassportSubmitsFamilyValueAndSkipsBack() async throws {
    let terminal = idOutcome(
        status: .completed,
        currentStep: nil,
        attemptsRemaining: 1,
        sessionStatus: .submitted,
        sessionProgress: .completed,
        attempts: 1)
    let spy = IDStepSpy(outcomes: [terminal])
    let model = makeIDModel(
        requirements: workflowIDRequirements(validTypes: ["passport-us", "passport-eu"]),
        spy: spy)

    model.start()
    model.selectDocumentType(.passport)
    // The family value hits the front-only set; the raw "passport-us" never would.
    #expect(
        model.phase
            == .capturingDocument(
                slot: .primary,
                type: .passport,
                captureMode: .frontOnly))
    model.documentCaptured(front: image(1), back: nil)
    model.selfieCaptured(image(2))
    await model.awaitPendingWork()

    let submission = try #require(spy.submissions.first)
    #expect(submission.documentType == "passport")
    #expect(spy.completed == [terminal])
}

@MainActor @Test
func unsupportedOnlyCatalogueFailsBeforeAnyUI() {
    let spy = IDStepSpy(outcomes: [])
    let model = makeIDModel(
        requirements: workflowIDRequirements(validTypes: ["pr-card-ca", "medicare-card-au"]),
        spy: spy)

    model.start()

    #expect(model.phase == .finished)
    #expect(spy.failures.count == 1)
    #expect(spy.failures.first?.kind == .validation)
}

@MainActor @Test
func frontOnlyTypesSkipBackPerSelectedDocument() {
    let spy = IDStepSpy(
        outcomes: [
            idOutcome(
                status: .completed,
                currentStep: nil,
                attemptsRemaining: 1,
                sessionStatus: .submitted,
                sessionProgress: .completed)
        ])
    let model = makeIDModel(
        requirements: workflowIDRequirements(secondary: true),
        spy: spy)

    model.start()
    model.selectDocumentType(.passport)
    #expect(
        model.phase
            == .capturingDocument(
                slot: .primary,
                type: .passport,
                captureMode: .frontOnly))
    model.documentCaptured(front: image(1), back: nil)

    model.selectDocumentType(.driversLicense)
    #expect(
        model.phase
            == .capturingDocument(
                slot: .secondary,
                type: .driversLicense,
                captureMode: .frontAndBack))
}

@MainActor @Test
func idStepUploadsAllCapturesAndSubmitsDeclaredTypes() async throws {
    let terminal = idOutcome(
        status: .completed,
        currentStep: nil,
        attemptsRemaining: 1,
        sessionStatus: .submitted,
        sessionProgress: .completed,
        attempts: 1)
    let spy = IDStepSpy(outcomes: [terminal])
    let model = makeIDModel(
        requirements: workflowIDRequirements(secondary: true, tertiary: true),
        spy: spy)

    model.start()
    model.selectDocumentType(.passport)
    model.documentCaptured(front: image(1), back: nil)
    model.selectDocumentType(.driversLicense)
    model.documentCaptured(front: image(2), back: image(3))
    model.selectDocumentType(.idCard)
    model.documentCaptured(front: image(4), back: image(5))
    model.selfieCaptured(image(6))
    await model.awaitPendingWork()

    let uploadedSlots = Set(try #require(spy.uploadCalls.first).keys)
    #expect(
        uploadedSlots == [
            .idFront,
            .secondaryIDFront, .secondaryIDBack,
            .tertiaryIDFront, .tertiaryIDBack,
            .selfieFront,
        ])
    let submission = try #require(spy.submissions.first)
    #expect(submission.documentType == "passport")
    #expect(submission.secondaryDocumentType == "drivers-license")
    #expect(submission.tertiaryDocumentType == "national-id")
    #expect(submission.uploads[.selfieFront] == "key-selfie_front")
    #expect(spy.completed == [terminal])
    #expect(model.phase == .finished)
}

@MainActor @Test
func failedAttemptRetryRecapturesAndReuploads() async {
    let retryable = idOutcome(
        status: .inProgress,
        failureReason: "DOCUMENT_MISMATCH",
        currentStep: 0,
        attemptsRemaining: 1)
    let terminal = idOutcome(
        status: .completed,
        currentStep: nil,
        attemptsRemaining: 0,
        sessionStatus: .submitted,
        sessionProgress: .completed,
        attempts: 2)
    let spy = IDStepSpy(outcomes: [retryable, terminal])
    let model = makeIDModel(
        requirements: workflowIDRequirements(validTypes: ["drivers-license"]),
        spy: spy)

    model.start()
    model.selectDocumentType(.driversLicense)
    model.documentCaptured(front: image(1), back: image(2))
    model.selfieCaptured(image(3))
    await model.awaitPendingWork()
    #expect(
        model.phase
            == .retry(
                failureReason: "DOCUMENT_MISMATCH",
                attemptsRemaining: 1))

    model.retry()
    #expect(model.selectedWireType(for: .primary) == nil)
    model.selectDocumentType(.driversLicense)
    model.documentCaptured(front: image(4), back: image(5))
    model.selfieCaptured(image(6))
    await model.awaitPendingWork()

    #expect(spy.uploadCalls.count == 2)
    #expect(spy.submissions.count == 2)
    #expect(spy.completed == [terminal])
}

@MainActor @Test
func idStepDoesNotOfferRetryWhenBudgetIsExhausted() async {
    let exhausted = idOutcome(
        status: .inProgress,
        failureReason: "DOCUMENT_MISMATCH",
        currentStep: 0,
        attemptsRemaining: 0,
        attempts: 1)
    let spy = IDStepSpy(outcomes: [exhausted])
    let model = makeIDModel(
        requirements: workflowIDRequirements(validTypes: ["drivers-license"]),
        spy: spy)

    model.start()
    model.selectDocumentType(.driversLicense)
    model.documentCaptured(front: image(1), back: image(2))
    model.selfieCaptured(image(3))
    await model.awaitPendingWork()

    #expect(model.phase == .finished)
    #expect(spy.completed == [exhausted])
}

@MainActor @Test
func idStepOffersRetryForUnlimitedBudget() async {
    let retryable = idOutcome(
        status: .inProgress,
        failureReason: "DOCUMENT_MISMATCH",
        currentStep: 0,
        attemptsRemaining: nil)
    let spy = IDStepSpy(outcomes: [retryable])
    let model = makeIDModel(
        requirements: workflowIDRequirements(validTypes: ["drivers-license"]),
        spy: spy)

    model.start()
    model.selectDocumentType(.driversLicense)
    model.documentCaptured(front: image(1), back: image(2))
    model.selfieCaptured(image(3))
    await model.awaitPendingWork()

    #expect(
        model.phase
            == .retry(
                failureReason: "DOCUMENT_MISMATCH",
                attemptsRemaining: nil))
}
