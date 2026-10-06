// DeepIDV › Workflow

import DeepIDVCore
import SwiftUI

/// Runs a server-defined verification workflow from one SwiftUI entry point.
///
/// UIKit hosts can present this view with `UIHostingController`.
public struct DeepIDVWorkflowView: View {
    /// Where the run comes from: a session this view creates, one the host's
    /// backend already created and identified by id, or an existing session
    /// continued from its current step.
    private enum Source {
        case workflow(id: String, user: WorkflowUser)
        case session(id: String)
        case resume(id: String)
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

    /// Resumes an existing headless session from its current step — the UI
    /// counterpart of ``DeepIDVClient/resumeWorkflowSession(sessionID:)``. Unlike
    /// ``init(client:sessionID:onResult:)``, which only runs sessions that have
    /// never been submitted to, this continues a session that was already started.
    /// A terminal session shows the entry error screen and reports
    /// ``DeepIDVError/Kind/conflict`` through `onResult` when dismissed.
    public init(
        client: DeepIDVClient,
        resumingSessionID sessionID: String,
        onResult: @escaping (Result<WorkflowRunResult, DeepIDVError>) -> Void
    ) {
        self.client = client
        self.source = .resume(id: sessionID)
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
        case .resume(let id):
            WorkflowFlowView(
                client: client,
                resumingSessionID: id,
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

    init(
        client: DeepIDVClient,
        resumingSessionID sessionID: String,
        onResult: @escaping (Result<WorkflowRunResult, DeepIDVError>) -> Void
    ) {
        let service = client.makeWorkflowService()
        self.client = client
        self.service = service
        self.uploader = client.makeSessionUploader()
        _model = StateObject(
            wrappedValue: WorkflowFlowModel(
                resume: {
                    try await service.resumeRun(sessionID: sessionID)
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
        case .stepError(let error):
            stepErrorView(error)
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
        // A conflict means the session is already started or terminal —
        // retrying can only fail the same way, so close is the only exit.
        let retry: (() -> Void)? = model.canRetryEntry ? { model.retryEntry() } : nil
        return WorkflowErrorView(
            title: "We couldn't start verification",
            message: WorkflowFailureCopy.error(error).body,
            onRetry: retry,
            onClose: { model.dismissFailure() })
    }

    private func stepErrorView(_ error: DeepIDVError) -> some View {
        let copy = WorkflowFailureCopy.error(error)
        let retry: (() -> Void)? =
            model.canRetryStepError ? { model.retryAfterStepError() } : nil
        return WorkflowErrorView(
            title: copy.title,
            message: copy.body,
            onRetry: retry,
            onClose: { model.dismissStepError() })
    }

    private var cancelButton: some View {
        Button("Cancel", action: model.cancel)
            .font(theme.typography.button(size: 16))
            .foregroundStyle(theme.colors.grey.s600)
            .padding(theme.spacing.sm)
    }
}

/// The error screen for a run that could not start or could not continue.
/// Shows applicant copy only; "Try again" appears when a retry is offered.
private struct WorkflowErrorView: View {
    @Environment(\.theme) private var theme

    let title: String
    let message: String
    let onRetry: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: theme.spacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(theme.colors.warning)
            Text(title)
                .font(theme.typography.heading())
                .foregroundStyle(theme.colors.grey.s900)
                .multilineTextAlignment(.center)
            Text(message)
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s700)
                .multilineTextAlignment(.center)
            Spacer()
            if let onRetry {
                primaryButton("Try again", action: onRetry)
                Button("Close", action: onClose)
                    .font(theme.typography.button(size: 16))
                    .foregroundStyle(theme.colors.grey.s600)
                    .padding(theme.spacing.sm)
            } else {
                primaryButton("Close", action: onClose)
            }
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
