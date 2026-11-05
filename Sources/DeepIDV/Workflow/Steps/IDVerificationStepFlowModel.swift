// DeepIDV › Workflow › Steps

import Combine
import DeepIDVCore
import Foundation

enum IDVerificationDocumentSlot: Sendable, Equatable, Hashable {
    case primary
    case secondary
    case tertiary

    var title: String {
        switch self {
        case .primary: return "primary ID"
        case .secondary: return "secondary ID"
        case .tertiary: return "tertiary ID"
        }
    }

    var frontUploadSlot: SessionUploadSlot {
        switch self {
        case .primary: return .idFront
        case .secondary: return .secondaryIDFront
        case .tertiary: return .tertiaryIDFront
        }
    }

    /// The tier the classifier reports this document under.
    var tier: DocumentTier {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        case .tertiary: return .tertiary
        }
    }

    var backUploadSlot: SessionUploadSlot {
        switch self {
        case .primary: return .idBack
        case .secondary: return .secondaryIDBack
        case .tertiary: return .tertiaryIDBack
        }
    }
}

struct WorkflowDocumentTypeOption: Sendable, Equatable {
    let documentType: DocumentType
    let wireValue: String

    static func options(from wireValues: [String]) -> [WorkflowDocumentTypeOption] {
        var seen: Set<DocumentType> = []
        return wireValues.compactMap { wireValue in
            guard let option = option(for: wireValue),
                seen.insert(option.documentType).inserted
            else {
                return nil
            }
            return option
        }
    }

    private static func option(for wireValue: String) -> WorkflowDocumentTypeOption? {
        let normalized = normalized(wireValue)
        if let type = documentType(for: normalized) {
            return WorkflowDocumentTypeOption(documentType: type, wireValue: wireValue)
        }

        // Region-suffixed catalogue value (e.g. "passport-us",
        // "driver-license-eu"): match on the family, submit the family value
        // the submission contract and the server's front-only registry key on.
        // Only the passport and driver's-license families are supported for
        // now; other suffixed families (pr-card, firearm-license, …) have no
        // capture flow yet and are dropped.
        switch documentType(for: strippingRegionSuffix(from: normalized)) {
        case .passport:
            return WorkflowDocumentTypeOption(documentType: .passport, wireValue: "passport")
        case .driversLicense:
            return WorkflowDocumentTypeOption(
                documentType: .driversLicense, wireValue: "drivers-license")
        default:
            return nil
        }
    }

    private static func documentType(for normalizedValue: String) -> DocumentType? {
        switch normalizedValue {
        case "passport":
            return .passport
        case "drivers-license", "driver-license", "driving-license":
            return .driversLicense
        case "id-card", "identity-card", "identification-card", "national-id":
            return .idCard
        default:
            return nil
        }
    }

    /// Drops a trailing two-letter region component ("passport-us" →
    /// "passport"). Anything longer or non-alphabetic is part of the family
    /// name ("id-card", "pr-card") and stays.
    private static func strippingRegionSuffix(from normalizedValue: String) -> String {
        guard let separator = normalizedValue.lastIndex(of: "-") else { return normalizedValue }
        let suffix = normalizedValue[normalizedValue.index(after: separator)...]
        guard suffix.count == 2, suffix.allSatisfy(\.isLetter) else { return normalizedValue }
        return String(normalizedValue[..<separator])
    }

    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}

/// Requirements-driven capture, upload, and submission state machine.
@MainActor
final class IDVerificationStepFlowModel: ObservableObject {
    enum Phase: Equatable {
        case selectingType(index: Int)
        case capturingDocument(
            slot: IDVerificationDocumentSlot,
            type: DocumentType,
            captureMode: CaptureMode)
        case capturingSelfie
        case submitting
        case retry(failure: WorkflowFailure?, attemptsRemaining: Int?)
        case finished
    }

    typealias UploadOperation =
        (_ files: [SessionUploadSlot: FileInput]) async throws -> [SessionUploadSlot: String]
    typealias SubmitOperation =
        (_ submission: IDVerificationSubmission) async throws -> WorkflowStepOutcome
    typealias ExtraFrameUploadOperation =
        (_ files: [ExtraFrameSlot: FileInput]) async throws -> [ExtraFrameSlot: String]

    /// The document classifier for this step: whether it works in this session,
    /// and how to build one for a card front.
    struct ClassifierSetup {
        let availability: ClassifierAvailability
        let make: @MainActor (DocumentType, ClassifierAvailability) -> any DocumentClassifying
    }

    @Published private(set) var phase: Phase = .selectingType(index: 0)

    let slots: [IDVerificationDocumentSlot]
    let documentTypeOptions: [WorkflowDocumentTypeOption]
    let faceFrontPhotoOnly: Bool

    private let frontOnlyDocumentTypes: Set<String>
    private let upload: UploadOperation
    private let uploadExtraFrames: ExtraFrameUploadOperation
    private let submit: SubmitOperation
    private let classifierSetup: ClassifierSetup?
    private let onStepCompleted: (WorkflowStepOutcome) -> Void
    private let onStepFailed: (DeepIDVError) -> Void

    private struct Capture {
        let documentType: DocumentType
        let wireType: String
        let front: FileInput
        let back: FileInput?
        /// What the classifier confirmed on the front, if anything.
        let classification: TierCaptureClassification?
        let extraFrames: [FileInput]
    }

    /// The report of the front just photographed, until its capture completes.
    private var frontReports: [IDVerificationDocumentSlot: FrontCaptureReport] = [:]
    /// Extra-frame upload keys, kept with the document keys for a selfie-only retry.
    private var extraFrameKeys: [ExtraFrameSlot: String] = [:]

    private var selections: [IDVerificationDocumentSlot: WorkflowDocumentTypeOption] = [:]
    private var captures: [IDVerificationDocumentSlot: Capture] = [:]
    private var selfie: FileInput?
    /// Document upload keys from the last upload, kept so a selfie-only retry
    /// can resubmit them without uploading the documents again.
    private var documentUploadKeys: [SessionUploadSlot: String] = [:]
    private var reusesDocumentUploads = false
    private var task: Task<Void, Never>?
    private var hasCompleted = false
    private var hasStarted = false
    private var submissionAttempts = 0

    init(
        requirements: IDVerificationRequirements,
        classifier: ClassifierSetup? = nil,
        upload: @escaping UploadOperation,
        uploadExtraFrames: @escaping ExtraFrameUploadOperation = { _ in [:] },
        submit: @escaping SubmitOperation,
        onStepCompleted: @escaping (WorkflowStepOutcome) -> Void,
        onStepFailed: @escaping (DeepIDVError) -> Void
    ) {
        var slots: [IDVerificationDocumentSlot] = [.primary]
        if requirements.document.requireSecondaryID { slots.append(.secondary) }
        if requirements.document.requireTertiaryID { slots.append(.tertiary) }
        self.slots = slots
        self.documentTypeOptions = WorkflowDocumentTypeOption.options(
            from: requirements.document.validIDTypes)
        self.frontOnlyDocumentTypes = Set(
            requirements.document.frontOnlyDocumentTypes.map(
                WorkflowDocumentTypeOption.normalized))
        self.faceFrontPhotoOnly = requirements.face.faceFrontPhotoOnly
        self.upload = upload
        self.uploadExtraFrames = uploadExtraFrames
        self.submit = submit
        self.classifierSetup = classifier
        self.onStepCompleted = onStepCompleted
        self.onStepFailed = onStepFailed
    }

    func start() {
        guard !hasStarted, !hasCompleted else { return }
        hasStarted = true
        guard !documentTypeOptions.isEmpty else {
            fail(
                .validation(
                    "This workflow does not provide a supported document type."))
            return
        }
        beginSelection(at: 0)
    }

    func selectDocumentType(_ documentType: DocumentType) {
        guard !hasCompleted, case .selectingType(let index) = phase,
            slots.indices.contains(index),
            let option = documentTypeOptions.first(where: {
                $0.documentType == documentType
            })
        else { return }

        let slot = slots[index]
        selections[slot] = option
        phase = capturePhase(slot: slot, option: option)
    }

    /// Whether captures follow the classifier's rules (blur never holds a frame
    /// back; a back or a passport page is taken once steady): the classifier is
    /// set up and not ruled out for this session.
    var usesClassifierRules: Bool {
        classifierSetup.map { $0.availability.state != .unavailable } ?? false
    }

    /// A classifier for the front or passport page of `type`, or `nil` when the
    /// classifier is off or unavailable for this session.
    func classifier(for type: DocumentType) -> (any DocumentClassifying)? {
        guard let classifierSetup,
            classifierSetup.availability.state != .unavailable
        else { return nil }
        return classifierSetup.make(type, classifierSetup.availability)
    }

    /// The front of the document being captured was photographed.
    func frontCaptured(_ report: FrontCaptureReport, slot: IDVerificationDocumentSlot) {
        frontReports[slot] = report
    }

    func documentCaptured(front: FileInput, back: FileInput?) {
        guard !hasCompleted,
            case .capturingDocument(let slot, _, let captureMode) = phase,
            let option = selections[slot]
        else { return }

        guard captureMode == .frontAndBack ? back != nil : back == nil else {
            fail(.validation("The captured document sides do not match its requirements."))
            return
        }

        let report = frontReports.removeValue(forKey: slot)
        captures[slot] = Capture(
            documentType: option.documentType,
            wireType: option.wireValue,
            front: front,
            back: back,
            classification: report?.classification,
            extraFrames: report?.extraFrames ?? [])

        guard let index = slots.firstIndex(of: slot) else { return }
        let nextIndex = index + 1
        guard slots.indices.contains(nextIndex) else {
            phase = .capturingSelfie
            return
        }
        // A document retake keeps the later slots' type selections, so those
        // go straight back to capture.
        let nextSlot = slots[nextIndex]
        if let kept = selections[nextSlot] {
            phase = capturePhase(slot: nextSlot, option: kept)
        } else {
            beginSelection(at: nextIndex)
        }
    }

    func captureFailed(_ error: DeepIDVError) {
        guard !hasCompleted else { return }
        fail(error)
    }

    func selfieCaptured(_ image: FileInput) {
        guard !hasCompleted, phase == .capturingSelfie else { return }
        selfie = image
        submitAttempt()
    }

    func selfieFailed(_ error: DeepIDVError) {
        guard !hasCompleted else { return }
        fail(error)
    }

    func cancel() {
        guard !hasCompleted else { return }
        fail(.cancelled("Identity verification was cancelled."))
    }

    /// Starts the next attempt from the point the failure's suggested action
    /// calls for, so the applicant only redoes what failed. Anything without a
    /// targeted remedy clears every capture and starts over.
    func retry() {
        guard !hasCompleted, case .retry(let failure, _) = phase else { return }
        task?.cancel()
        selfie = nil
        reusesDocumentUploads = false

        switch failure?.userAction {
        case .retakeSelfie where !documentUploadKeys.isEmpty:
            // Only the selfie is captured and uploaded again; the documents
            // are resubmitted with the keys they already have.
            reusesDocumentUploads = true
            phase = .capturingSelfie

        case .useDifferentDocument:
            let index = slotIndex(for: failure?.slot)
            for slot in slots[index...] {
                selections[slot] = nil
                captures[slot] = nil
            }
            documentUploadKeys.removeAll()
            extraFrameKeys.removeAll()
            beginSelection(at: index)

        case .retakeDocument:
            let index = slotIndex(for: failure?.slot)
            guard let option = selections[slots[index]] else {
                restart()
                return
            }
            for slot in slots[index...] {
                captures[slot] = nil
            }
            documentUploadKeys.removeAll()
            extraFrameKeys.removeAll()
            phase = capturePhase(slot: slots[index], option: option)

        default:
            restart()
        }
    }

    func selectedWireType(for slot: IDVerificationDocumentSlot) -> String? {
        selections[slot]?.wireValue
    }

    func awaitPendingWork() async {
        await task?.value
    }

    /// Clears every capture and returns to the first type selection.
    private func restart() {
        selections.removeAll()
        captures.removeAll()
        frontReports.removeAll()
        documentUploadKeys.removeAll()
        extraFrameKeys.removeAll()
        beginSelection(at: 0)
    }

    /// Asks for the document type of the slot at `index`, or, when the workflow
    /// allows only one type, picks it without asking.
    private func beginSelection(at index: Int) {
        phase = .selectingType(index: index)
        if documentTypeOptions.count == 1, let only = documentTypeOptions.first {
            selectDocumentType(only.documentType)
        }
    }

    /// The position of the document a failure is attributed to. A failure
    /// without a slot, or one naming a document this step does not collect, is
    /// treated as the primary document.
    private func slotIndex(for slot: WorkflowDocumentSlot?) -> Int {
        let target: IDVerificationDocumentSlot
        switch slot {
        case .secondary: target = .secondary
        case .tertiary: target = .tertiary
        case .primary, nil: target = .primary
        }
        return slots.firstIndex(of: target) ?? 0
    }

    private func capturePhase(
        slot: IDVerificationDocumentSlot,
        option: WorkflowDocumentTypeOption
    ) -> Phase {
        let isFrontOnly = frontOnlyDocumentTypes.contains(
            WorkflowDocumentTypeOption.normalized(option.wireValue))
        return .capturingDocument(
            slot: slot,
            type: option.documentType,
            captureMode: isFrontOnly ? .frontOnly : .frontAndBack)
    }

    private func submitAttempt() {
        guard let selfie, captures.count == slots.count else {
            fail(.validation("Required identity captures are missing."))
            return
        }

        let reusedKeys = reusesDocumentUploads ? documentUploadKeys : [:]
        let reusedExtraKeys = reusesDocumentUploads ? extraFrameKeys : [:]
        var extraFiles: [ExtraFrameSlot: FileInput] = [:]
        if reusedKeys.isEmpty, sendsClassifierFields,
            classifierSetup?.availability.sendsExtraFrames == true
        {
            for slot in slots {
                for (offset, frame) in (captures[slot]?.extraFrames ?? []).enumerated() {
                    if let key = ExtraFrameSlot(tier: slot.tier, number: offset + 1) {
                        extraFiles[key] = frame
                    }
                }
            }
        }
        var files: [SessionUploadSlot: FileInput] = [.selfieFront: selfie]
        if reusedKeys.isEmpty {
            for slot in slots {
                guard let capture = captures[slot] else {
                    fail(.validation("A required document capture is missing."))
                    return
                }
                files[slot.frontUploadSlot] = capture.front
                if let back = capture.back {
                    files[slot.backUploadSlot] = back
                }
            }
        }

        phase = .submitting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let uploaded = try await self.upload(files)
                guard !Task.isCancelled, !self.hasCompleted else { return }
                let keys = reusedKeys.merging(uploaded) { _, new in new }
                self.documentUploadKeys = keys.filter { $0.key != .selfieFront }
                // Extra frames are a bonus: failing to upload them never fails the step.
                var extraKeys = reusedExtraKeys
                if !extraFiles.isEmpty, let uploaded = try? await self.uploadExtraFrames(extraFiles)
                {
                    extraKeys = uploaded
                }
                guard !Task.isCancelled, !self.hasCompleted else { return }
                self.extraFrameKeys = extraKeys
                let submission = try self.makeSubmission(uploadKeys: keys, extraKeys: extraKeys)
                let outcome = try await self.submitOnce(submission)
                guard !Task.isCancelled, !self.hasCompleted else { return }
                self.submissionAttempts += 1
                self.handle(outcome.recordingAttempts(self.submissionAttempts))
            } catch let error as DeepIDVError {
                guard !Task.isCancelled, !self.hasCompleted else { return }
                self.fail(error)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !self.hasCompleted else { return }
                self.fail(
                    .network(
                        "Identity verification failed unexpectedly.",
                        causeDescription: String(describing: error)))
            }
        }
    }

    /// Whether the classifier's fields go with the submission: only once a call
    /// succeeded in this session, because a server that answers the classifier
    /// route also accepts its fields.
    private var sendsClassifierFields: Bool {
        classifierSetup?.availability.state == .available
    }

    private func makeSubmission(
        uploadKeys: [SessionUploadSlot: String],
        extraKeys: [ExtraFrameSlot: String] = [:]
    ) throws -> IDVerificationSubmission {
        guard let primary = captures[.primary]?.wireType else {
            throw DeepIDVError.validation("The primary document type is missing.")
        }
        let submission = IDVerificationSubmission(
            documentType: primary,
            secondaryDocumentType: captures[.secondary]?.wireType,
            tertiaryDocumentType: captures[.tertiary]?.wireType,
            uploads: uploadKeys)
        guard sendsClassifierFields else { return submission }
        var classification = CaptureClassificationPayload()
        for slot in slots {
            classification.recordFront(slot.tier, captures[slot]?.classification)
        }
        return submission.withClassifierFields(classification, extraFrames: extraKeys)
    }

    /// Submits, and if a server that doesn't know the classifier's fields
    /// rejects them, submits once more without them.
    private func submitOnce(
        _ submission: IDVerificationSubmission
    ) async throws -> WorkflowStepOutcome {
        do {
            return try await submit(submission)
        } catch let error as DeepIDVError
            where error.kind == .validation && submission.hasClassifierFields
        {
            return try await submit(submission.withoutClassifierFields)
        }
    }

    private func handle(_ outcome: WorkflowStepOutcome) {
        if outcome.stepStatus == .completed || outcome.isTerminalRun {
            complete(outcome)
            return
        }

        if outcome.canRetry {
            phase = .retry(
                failure: outcome.failure,
                attemptsRemaining: outcome.attemptsRemaining)
        } else {
            complete(outcome)
        }
    }

    private func complete(_ outcome: WorkflowStepOutcome) {
        guard !hasCompleted else { return }
        hasCompleted = true
        phase = .finished
        onStepCompleted(outcome)
    }

    private func fail(_ error: DeepIDVError) {
        guard !hasCompleted else { return }
        hasCompleted = true
        task?.cancel()
        phase = .finished
        onStepFailed(error)
    }
}
