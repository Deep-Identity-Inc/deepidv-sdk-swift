// DeepIDV › ReVerify

import DeepIDVCore
import SwiftUI

/// Renders the flow model's phase through the native custom capture.
struct ReVerifyFlowView: View {
    @Environment(\.theme) private var theme
    @StateObject private var model: ReVerifyFlowModel

    /// Keeps text and buttons readable on iPad and in landscape.
    private static let maxContentWidth: CGFloat = 520

    init(
        client: DeepIDVClient,
        workflowID: String,
        onResult: @escaping (Result<ReVerifyResult, DeepIDVError>) -> Void
    ) {
        _model = StateObject(
            wrappedValue: ReVerifyFlowModel(
                client: client, workflowID: workflowID, onResult: onResult))
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
        case .checking:
            progressView("Preparing your liveness check…")
        case .liveness(let session, let attemptsRemaining, let guidance):
            livenessView(session, attemptsRemaining: attemptsRemaining, guidance: guidance)
        case .uploading:
            progressView("Uploading your capture…")
        case .deciding:
            progressView("Checking your identity… this can take a few seconds")
        case .failed(let error):
            failureView(error)
        case .outcome:
            Color.clear
        }
    }

    // MARK: - Capture

    /// Keyed on `livenessSessionID`: every attempt mounts a fresh capture
    /// controller, even though the phase goes straight back to `.liveness`.
    private func livenessView(
        _ session: CustomLivenessSession,
        attemptsRemaining: Int?,
        guidance: ReVerifyGuidance
    ) -> some View {
        let livenessSessionID = session.livenessSessionID
        return CaptureRunView(
            script: session.script,
            onCaptured: { model.captured($0, livenessSessionID: livenessSessionID) },
            onError: { model.captureFailed($0, livenessSessionID: livenessSessionID) }
        )
        .id(livenessSessionID)
        .overlay(alignment: .top) {
            attemptBanner(attemptsRemaining: attemptsRemaining, guidance: guidance)
        }
    }

    @ViewBuilder
    private func attemptBanner(attemptsRemaining: Int?, guidance: ReVerifyGuidance) -> some View {
        let message = Self.guidanceText(guidance)
        if message != nil || attemptsRemaining != nil {
            VStack(spacing: theme.spacing.xs) {
                if let message {
                    Text(message)
                        .font(theme.typography.body())
                        .foregroundStyle(theme.colors.grey.s900)
                }
                if let attemptsRemaining {
                    Text(Self.attemptsText(attemptsRemaining))
                        .font(theme.typography.body(size: 14))
                        .foregroundStyle(theme.colors.grey.s700)
                }
            }
            .multilineTextAlignment(.center)
            .padding(theme.spacing.md)
            .frame(maxWidth: Self.maxContentWidth)
            .background(theme.colors.grey.s50.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: theme.spacing.sm, style: .continuous))
            .padding(theme.spacing.md)
        }
    }

    private static func guidanceText(_ guidance: ReVerifyGuidance) -> String? {
        switch guidance {
        case .initial:
            nil
        case .retryMismatch:
            "We couldn't match your face — try again in good lighting, facing the camera"
        case .retryLiveness:
            "The liveness check didn't pass — hold still and follow the prompts"
        }
    }

    private static func attemptsText(_ count: Int) -> String {
        count == 1 ? "1 attempt remaining" : "\(count) attempts remaining"
    }

    // MARK: - Themed chrome

    private func progressView(_ title: String) -> some View {
        VStack(spacing: theme.spacing.lg) {
            ProgressView()
            Text(title)
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s700)
                .multilineTextAlignment(.center)
        }
        .padding(theme.spacing.lg)
        .frame(maxWidth: Self.maxContentWidth)
    }

    /// Text comes only from ``ReVerifyCopy`` — never `error.message`. Scrolls
    /// when the height is compact (landscape phone) so the buttons stay
    /// reachable.
    private func failureView(_ error: DeepIDVError) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: theme.spacing.lg) {
                    Spacer(minLength: 0)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(theme.colors.warning)
                    Text(ReVerifyCopy.message(for: error))
                        .font(theme.typography.body())
                        .foregroundStyle(theme.colors.grey.s900)
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                    if model.canRetry {
                        primaryButton("Try again", action: model.retry)
                        Button("Close", action: model.dismissFailure)
                            .font(theme.typography.button(size: 16))
                            .foregroundStyle(theme.colors.grey.s600)
                            .padding(theme.spacing.sm)
                    } else {
                        primaryButton("Close", action: model.dismissFailure)
                    }
                }
                .padding(theme.spacing.lg)
                .frame(maxWidth: Self.maxContentWidth)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
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
