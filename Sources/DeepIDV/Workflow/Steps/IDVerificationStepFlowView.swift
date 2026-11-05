// DeepIDV › Workflow › Steps

import DeepIDVCore
import SwiftUI
import UIKit

/// Captures every required document plus one selfie, then uploads and submits.
struct IDVerificationStepFlowView: View {
    @Environment(\.theme) private var theme
    @StateObject private var model: IDVerificationStepFlowModel
    private let registerCancellation: (@escaping () -> Void) -> Void
    private let documentCamera: DocumentCamera
    private let showsIntro: Bool

    init(
        context: WorkflowStepContext,
        requirements: IDVerificationRequirements
    ) {
        self.registerCancellation = context.registerCancellation
        self.documentCamera = context.client.config.documentCamera
        self.showsIntro = context.client.config.showsDocumentCaptureIntro
        let usesClassifier = context.client.config.usesDocumentClassifier
        _model = StateObject(
            wrappedValue: IDVerificationStepFlowModel(
                requirements: requirements,
                classifier: usesClassifier
                    ? IDVerificationStepFlowModel.ClassifierSetup(
                        availability: ClassifierAvailability(),
                        make: { type, availability in
                            DocumentClassifierScanner(
                                documentType: type,
                                sessionID: context.sessionID,
                                detector: context.client.makeDetectClient(
                                    sessionID: context.sessionID),
                                availability: availability)
                        }) : nil,
                upload: { files in
                    try await context.uploader.upload(
                        sessionID: context.sessionID,
                        files: files)
                },
                uploadExtraFrames: { files in
                    try await context.uploader.uploadExtraFrames(
                        sessionID: context.sessionID, files: files)
                },
                submit: { submission in
                    WorkflowStepOutcome(
                        try await context.service.submitIDVerification(
                            sessionID: context.sessionID,
                            submission: submission))
                },
                onStepCompleted: context.onStepCompleted,
                onStepFailed: context.onStepFailed))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.colors.grey.s50)
            .task { model.start() }
            .onAppear {
                let model = model
                registerCancellation { [weak model] in model?.cancel() }
            }
            .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .selectingType(let index):
            if model.slots.indices.contains(index) {
                let slot = model.slots[index]
                DocumentTypePicker(
                    availableTypes: model.documentTypeOptions.map(\.documentType),
                    heading: slot == .primary
                        ? "Which ID will you use?" : "Now choose your \(slot.title)",
                    onCancel: model.cancel,
                    onSelect: model.selectDocumentType
                )
                .id("picker-\(index)")
            } else {
                Color.clear
            }

        case .capturingDocument(let slot, let type, let captureMode):
            DocumentCaptureFlowView<(FileInput, FileInput?)>(
                documentType: type,
                captureMode: captureMode,
                cameraPosition: documentCamera.avPosition,
                showsIntro: showsIntro,
                makeClassifier: { model.classifier(for: type) },
                usesClassifierRules: model.usesClassifierRules,
                onFrontCaptured: { model.frontCaptured($0, slot: slot) },
                complete: { front, back, _ in (front, back) },
                onResult: { result in
                    switch result {
                    case .success(let capture):
                        model.documentCaptured(front: capture.0, back: capture.1)
                    case .failure(let error):
                        model.captureFailed(error)
                    }
                }
            )
            .id("capture-\(slot.title)-\(type.rawValue)")

        case .capturingSelfie:
            SelfieCaptureFlowView(
                faceFrontPhotoOnly: model.faceFrontPhotoOnly,
                onResult: { result in
                    switch result {
                    case .success(let image):
                        model.selfieCaptured(image)
                    case .failure(let error):
                        model.selfieFailed(error)
                    }
                })

        case .submitting:
            let photos = model.submittedPhotos
            SubmittingStep(document: photos.document, selfie: photos.selfie)

        case .retry(let failure, let attemptsRemaining):
            retryView(
                failure: failure,
                attemptsRemaining: attemptsRemaining)

        case .finished:
            Color.clear
        }
    }

    private func retryView(
        failure: WorkflowFailure?,
        attemptsRemaining: Int?
    ) -> some View {
        let copy = WorkflowFailureCopy.failure(failure, step: .idVerification)
        return Kit.StatusScreen(
            badge: .retry, title: copy.title, message: copy.body,
            note: attemptsRemaining.map { $0 == 1 ? "1 attempt left" : "\($0) attempts left" },
            primary: .init(title: "Try again", run: model.retry),
            secondary: .init(title: "Cancel", run: model.cancel))
    }
}

/// The submitting screen, with the photos decoded off the main thread.
private struct SubmittingStep: View {
    let document: FileInput?
    let selfie: FileInput?
    @State private var documentImage: UIImage?
    @State private var selfieImage: UIImage?

    var body: some View {
        SubmittingScreen(document: documentImage, selfie: selfieImage)
            .task {
                let document = self.document
                let selfie = self.selfie
                let images = await Task.detached {
                    (document.flatMap(Self.image), selfie.flatMap(Self.image))
                }.value
                documentImage = images.0
                selfieImage = images.1
            }
    }

    nonisolated private static func image(_ file: FileInput) -> UIImage? {
        ClassifierImages.data(of: file).flatMap(UIImage.init(data:))
    }
}
