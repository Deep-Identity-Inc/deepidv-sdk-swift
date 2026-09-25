// DeepIDV › Workflow › Steps

import DeepIDVCore
import SwiftUI

/// Runs the workflow `FACE_LIVENESS` step through the native custom liveness
/// flow. The capture UI, permission chrome, and per-attempt retry are
/// ``CustomFaceLivenessFlowView``'s; this view only reconciles each attempt
/// with the workflow state and reports the step outcome.
struct CustomFaceLivenessStepFlowView: View {
    @Environment(\.theme) private var theme
    @StateObject private var model: CustomFaceLivenessStepFlowModel

    private let client: DeepIDVClient
    private let sessionID: String
    private let registerCancellation: (@escaping () -> Void) -> Void

    init(
        context: WorkflowStepContext,
        requirements: FaceLivenessRequirements
    ) {
        self.client = context.client
        self.sessionID = context.sessionID
        self.registerCancellation = context.registerCancellation
        _model = StateObject(
            wrappedValue: CustomFaceLivenessStepFlowModel(
                stepID: context.stepID,
                attemptsRemaining: context.attemptsRemaining,
                fetchState: {
                    try await context.service.fetchState(sessionID: context.sessionID)
                },
                onStepCompleted: context.onStepCompleted,
                onStepFailed: context.onStepFailed))
    }

    var body: some View {
        ZStack {
            CustomFaceLivenessFlowView(
                client: client,
                sessionID: sessionID,
                onResult: { model.attemptFinished($0) })

            if model.state == .syncing {
                syncingOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.grey.s50)
        .overlay(alignment: .topTrailing) { cancelButton }
        .onAppear {
            let model = model
            registerCancellation { [weak model] in model?.cancel() }
        }
        .onDisappear { model.cancel() }
    }

    private var syncingOverlay: some View {
        VStack(spacing: theme.spacing.md) {
            ProgressView()
            Text("Checking your liveness result…")
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s700)
        }
        .padding(theme.spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.grey.s50.opacity(0.92))
    }

    private var cancelButton: some View {
        Button("Cancel", action: model.cancel)
            .font(theme.typography.button(size: 16))
            .foregroundStyle(theme.colors.grey.s600)
            .padding(theme.spacing.md)
    }
}
