// DeepIDV › Workflow

import DeepIDVCore
import SwiftUI

/// Runs a server-defined verification workflow from one SwiftUI entry point.
///
/// UIKit hosts can present this view with `UIHostingController`.
public struct DeepIDVWorkflowView: View {
    /// Where the run comes from: a session this view creates, or one the
    /// host's backend already created and identified by id.
    private enum Source {
        case workflow(id: String, user: WorkflowUser)
        case session(id: String)
    }

    private let client: DeepIDVClient
    private let source: Source
    private let onResult: (Result<WorkflowRunResult, DeepIDVError>) -> Void

    /// Creates a session for `workflowID` and runs it.
    public init(
        client: DeepIDVClient,
        workflowID: String,
        user: WorkflowUser,
        onResult: @escaping (Result<WorkflowRunResult, DeepIDVError>) -> Void
    ) {
        self.client = client
        self.source = .workflow(id: workflowID, user: user)
        self.onResult = onResult
    }

    /// Runs an existing headless session that has not started yet — for hosts
    /// whose backend creates the session and passes the app only its id. The
    /// end-user identity fields were supplied at creation, so none are needed
    /// here. A session that has already started, or is terminal, fails with
    /// ``DeepIDVError/Kind/conflict``.
    public init(
        client: DeepIDVClient,
        sessionID: String,
        onResult: @escaping (Result<WorkflowRunResult, DeepIDVError>) -> Void
    ) {
        self.client = client
        self.source = .session(id: sessionID)
        self.onResult = onResult
    }

    public var body: some View {
        switch source {
        case .workflow(let id, let user):
            WorkflowFlowView(
                client: client,
                workflowID: id,
                user: user,
                onResult: onResult)
        case .session(let id):
            WorkflowFlowView(
                client: client,
                sessionID: id,
                onResult: onResult)
        }
    }
}

/// Renders the current server-selected step through the UI registry.
struct WorkflowFlowView: View {
    @Environment(\.theme) private var theme
    @StateObject private var model: WorkflowFlowModel

    private let client: DeepIDVClient
    private let service: WorkflowService
    private let uploader: SessionUploader

    init(
        client: DeepIDVClient,
        workflowID: String,
        user: WorkflowUser,
        onResult: @escaping (Result<WorkflowRunResult, DeepIDVError>) -> Void
    ) {
        let service = client.makeWorkflowService()
        self.client = client
        self.service = service
        self.uploader = client.makeSessionUploader()
        _model = StateObject(
            wrappedValue: WorkflowFlowModel(
                create: {
                    try await service.createSession(
                        workflowID: workflowID,
                        user: user)
                },
                fetchState: { sessionID in
                    try await service.fetchState(sessionID: sessionID)
                },
                supportsStep: WorkflowStepUIRegistry.supports,
                onResult: onResult))
    }

    init(
        client: DeepIDVClient,
        sessionID: String,
        onResult: @escaping (Result<WorkflowRunResult, DeepIDVError>) -> Void
    ) {
        let service = client.makeWorkflowService()
        self.client = client
        self.service = service
        self.uploader = client.makeSessionUploader()
        _model = StateObject(
            wrappedValue: WorkflowFlowModel(
                start: {
                    try await service.startRun(sessionID: sessionID)
                },
                fetchState: { sessionID in
                    try await service.fetchState(sessionID: sessionID)
                },
                supportsStep: WorkflowStepUIRegistry.supports,
                onResult: onResult))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.colors.grey.s50)
            .task { model.start() }
            .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .creating:
            progressView("Preparing your verification…")
        case .runningStep(let index):
            stepView(index: index)
        case .resyncing:
            progressView("Refreshing your verification…")
        case .finishing:
            progressView("Finishing your verification…")
        case .failed(let error):
            entryErrorView(error)
        case .finished:
            Color.clear
        }
    }

    @ViewBuilder
    private func stepView(index: Int) -> some View {
        if let sessionID = model.sessionID,
            model.steps.indices.contains(index)
        {
            let plan = model.steps[index]
            let context = WorkflowStepContext(
                client: client,
                sessionID: sessionID,
                stepID: plan.stepID,
                requirements: plan.requirements,
                service: service,
                uploader: uploader,
                attemptsRemaining: model.attemptsRemaining,
                registerCancellation: model.registerActiveStepCancellation,
                onStepCompleted: { model.stepCompleted($0) },
                onStepFailed: { model.stepFailed($0) })

            if let view = WorkflowStepUIRegistry.makeFlowView(
                for: plan.stepID,
                context: context)
            {
                view.id("\(sessionID)-\(index)-\(model.renderGeneration)")
            } else {
                Color.clear.task {
                    model.stepFailed(
                        .validation(
                            "This SDK cannot render workflow step "
                                + "'\(plan.stepID.rawValue)'."))
                }
            }
        } else {
            Color.clear.task {
                model.stepFailed(.validation("Workflow step state is unavailable."))
            }
        }
    }

    private func progressView(_ title: String) -> some View {
        VStack(spacing: theme.spacing.lg) {
            Spacer()
            ProgressView()
            Text(title)
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s700)
            Spacer()
            cancelButton
        }
        .padding(theme.spacing.lg)
    }

    private func entryErrorView(_ error: DeepIDVError) -> some View {
        VStack(spacing: theme.spacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(theme.colors.warning)
            Text("We couldn't start verification")
                .font(theme.typography.heading())
                .foregroundStyle(theme.colors.grey.s900)
                .multilineTextAlignment(.center)
            Text(error.message)
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s700)
                .multilineTextAlignment(.center)
            Spacer()
            // A conflict means the session is already started or terminal —
            // retrying can only fail the same way, so close is the only exit.
            if model.canRetryEntry {
                primaryButton("Try again", action: model.retryEntry)
                Button("Close", action: model.dismissFailure)
                    .font(theme.typography.button(size: 16))
                    .foregroundStyle(theme.colors.grey.s600)
                    .padding(theme.spacing.sm)
            } else {
                primaryButton("Close", action: model.dismissFailure)
            }
        }
        .padding(theme.spacing.lg)
    }

    private var cancelButton: some View {
        Button("Cancel", action: model.cancel)
            .font(theme.typography.button(size: 16))
            .foregroundStyle(theme.colors.grey.s600)
            .padding(theme.spacing.sm)
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
