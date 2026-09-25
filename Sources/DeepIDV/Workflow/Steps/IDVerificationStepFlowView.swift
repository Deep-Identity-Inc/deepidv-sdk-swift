// DeepIDV › Workflow › Steps

import DeepIDVCore
import SwiftUI

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
        _model = StateObject(
            wrappedValue: IDVerificationStepFlowModel(
                requirements: requirements,
                upload: { files in
                    try await context.uploader.upload(
                        sessionID: context.sessionID,
                        files: files)
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
                    heading: "Select your \(slot.title)",
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
            progressView

        case .retry(let failureReason, let attemptsRemaining):
            retryView(
                failureReason: failureReason,
                attemptsRemaining: attemptsRemaining)

        case .finished:
            Color.clear
        }
    }

    private var progressView: some View {
        VStack(spacing: theme.spacing.lg) {
            Spacer()
            ProgressView()
            Text("Submitting your identity verification…")
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s700)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Cancel", action: model.cancel)
                .font(theme.typography.button(size: 16))
                .foregroundStyle(theme.colors.grey.s600)
        }
        .padding(theme.spacing.lg)
    }

    private func retryView(
        failureReason: String?,
        attemptsRemaining: Int?
    ) -> some View {
        VStack(spacing: theme.spacing.lg) {
            Spacer()
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(theme.colors.warning)
            Text("Let's try that again")
                .font(theme.typography.heading())
                .foregroundStyle(theme.colors.grey.s900)
            Text(failureReason ?? "We couldn't complete the identity check.")
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s700)
                .multilineTextAlignment(.center)
            if let attemptsRemaining {
                Text("\(attemptsRemaining) attempts remaining")
                    .font(theme.typography.body(size: 14))
                    .foregroundStyle(theme.colors.grey.s600)
            }
            Spacer()
            primaryButton("Try again", action: model.retry)
            Button("Cancel", action: model.cancel)
                .font(theme.typography.button(size: 16))
                .foregroundStyle(theme.colors.grey.s600)
        }
        .padding(theme.spacing.lg)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.typography.button(size: 16))
                .foregroundStyle(theme.colors.grey.s50)
                .padding(theme.spacing.md)
                .frame(maxWidth: .infinity)
                .background(theme.colors.primary)
                .clipShape(
                    RoundedRectangle(cornerRadius: theme.spacing.sm, style: .continuous))
        }
    }
}
