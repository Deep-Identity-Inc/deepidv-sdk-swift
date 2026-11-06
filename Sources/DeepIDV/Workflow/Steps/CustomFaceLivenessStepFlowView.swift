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
                retryCopy: model.retryCopy,
                onCancel: model.cancel,
                onResult: { model.attemptFinished($0) })

            if model.state == .syncing {
                Kit.StatusScreen(
                    badge: .working(symbol: "checkmark.shield.fill"),
                    title: L("Checking your result"), message: L("This only takes a moment"))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.state == .syncing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let model = model
            registerCancellation { [weak model] in model?.cancel() }
        }
        .onDisappear { model.cancel() }
    }
}
