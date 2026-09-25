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
        case retry(failureReason: String?, attemptsRemaining: Int?)
        case finished
    }

    typealias UploadOperation =
        (_ files: [SessionUploadSlot: FileInput]) async throws -> [SessionUploadSlot: String]
    typealias SubmitOperation =
        (_ submission: IDVerificationSubmission) async throws -> WorkflowStepOutcome

    @Published private(set) var phase: Phase = .selectingType(index: 0)

    let slots: [IDVerificationDocumentSlot]
    let documentTypeOptions: [WorkflowDocumentTypeOption]
    let faceFrontPhotoOnly: Bool

    private let frontOnlyDocumentTypes: Set<String>
    private let upload: UploadOperation
    private let submit: SubmitOperation
    private let onStepCompleted: (WorkflowStepOutcome) -> Void
    private let onStepFailed: (DeepIDVError) -> Void

    private struct Capture {
        let documentType: DocumentType
        let wireType: String
        let front: FileInput
        let back: FileInput?
    }

    private var selections: [IDVerificationDocumentSlot: WorkflowDocumentTypeOption] = [:]
    private var captures: [IDVerificationDocumentSlot: Capture] = [:]
    private var selfie: FileInput?
    private var task: Task<Void, Never>?
    private var hasCompleted = false
    private var hasStarted = false
    private var submissionAttempts = 0

    init(
        requirements: IDVerificationRequirements,
        upload: @escaping UploadOperation,
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
        self.submit = submit
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
        phase = .selectingType(index: 0)
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
        let isFrontOnly = frontOnlyDocumentTypes.contains(
            WorkflowDocumentTypeOption.normalized(option.wireValue))
        phase = .capturingDocument(
            slot: slot,
            type: documentType,
            captureMode: isFrontOnly ? .frontOnly : .frontAndBack)
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

        captures[slot] = Capture(
            documentType: option.documentType,
            wireType: option.wireValue,
            front: front,
            back: back)

        guard let index = slots.firstIndex(of: slot) else { return }
        let nextIndex = index + 1
        phase =
            slots.indices.contains(nextIndex)
            ? .selectingType(index: nextIndex)
            : .capturingSelfie
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

    /// Clears all captures so a retry always uses fresh uploads.
    func retry() {
        guard !hasCompleted, case .retry = phase else { return }
        task?.cancel()
        selections.removeAll()
        captures.removeAll()
        selfie = nil
        phase = .selectingType(index: 0)
    }

    func selectedWireType(for slot: IDVerificationDocumentSlot) -> String? {
        selections[slot]?.wireValue
    }

    func awaitPendingWork() async {
        await task?.value
    }

    private func submitAttempt() {
        guard let selfie, captures.count == slots.count else {
            fail(.validation("Required identity captures are missing."))
            return
        }

        var files: [SessionUploadSlot: FileInput] = [.selfieFront: selfie]
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

        phase = .submitting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let keys = try await self.upload(files)
                guard !Task.isCancelled, !self.hasCompleted else { return }
                let submission = try self.makeSubmission(uploadKeys: keys)
                let outcome = try await self.submit(submission)
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

    private func makeSubmission(
        uploadKeys: [SessionUploadSlot: String]
    ) throws -> IDVerificationSubmission {
        guard let primary = captures[.primary]?.wireType else {
            throw DeepIDVError.validation("The primary document type is missing.")
        }
        return IDVerificationSubmission(
            documentType: primary,
            secondaryDocumentType: captures[.secondary]?.wireType,
            tertiaryDocumentType: captures[.tertiary]?.wireType,
            uploads: uploadKeys)
    }

    private func handle(_ outcome: WorkflowStepOutcome) {
        if outcome.stepStatus == .completed || outcome.isTerminalRun {
            complete(outcome)
            return
        }

        if outcome.canRetry {
            phase = .retry(
                failureReason: outcome.failureReason,
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
