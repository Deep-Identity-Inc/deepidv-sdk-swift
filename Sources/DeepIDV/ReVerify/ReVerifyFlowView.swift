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
        email: String,
        onResult: @escaping (Result<ReVerifyResult, DeepIDVError>) -> Void
    ) {
        _model = StateObject(
            wrappedValue: ReVerifyFlowModel(
                client: client, workflowID: workflowID, email: email, onResult: onResult))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { model.start() }
            .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            progressView(L("Getting ready"), symbol: "faceid", message: L("Next, a quick check that it's really you"))
        case .liveness(let session, let attemptsRemaining, let guidance):
            livenessView(session, attemptsRemaining: attemptsRemaining, guidance: guidance)
        case .uploading:
            progressView(L("Sending your check"), symbol: "arrow.up", message: L("This only takes a moment"))
        case .deciding:
            progressView(L("Checking it's you"), symbol: "checkmark.shield.fill", message: L("This can take a few seconds"))
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
            HStack(alignment: .top, spacing: theme.spacing.sm) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.colors.warning)
                    .opacity(message == nil ? 0 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    if let message {
                        Text(message)
                            .font(theme.typography.body(size: 15).weight(.medium))
                            .foregroundStyle(theme.colors.grey.s50)
                    }
                    if let attemptsRemaining {
                        Text(Self.attemptsText(attemptsRemaining))
                            .font(theme.typography.body(size: 13))
                            .foregroundStyle(theme.colors.grey.s50.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, theme.spacing.md)
            .padding(.vertical, 12)
            .frame(maxWidth: Self.maxContentWidth)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.35))))
            .padding(theme.spacing.md)
            .accessibilityElement(children: .combine)
        }
    }

    private static func guidanceText(_ guidance: ReVerifyGuidance) -> String? {
        switch guidance {
        case .initial:
            nil
        case .retryMismatch:
            L("We couldn't match your face — try again in good lighting, facing the camera")
        case .retryLiveness:
            L("The liveness check didn't pass — hold still and follow the prompts")
        }
    }

    private static func attemptsText(_ count: Int) -> String {
        count == 1 ? L("1 attempt remaining") : L("%d attempts remaining", count)
    }

    // MARK: - Status screens

    private func progressView(_ title: String, symbol: String, message: String) -> some View {
        Kit.StatusScreen(badge: .working(symbol: symbol), title: title, message: message)
    }

    /// Text comes only from ``ReVerifyCopy`` — never `error.message`. Scrolls
    /// when the height is compact (landscape phone) so the buttons stay
    /// reachable.
    private func failureView(_ error: DeepIDVError) -> some View {
        GeometryReader { proxy in
            ScrollView {
                Group {
                    if model.canRetry {
                        Kit.StatusScreen(
                            badge: .warning, title: L("That didn't work"),
                            message: ReVerifyCopy.message(for: error),
                            primary: .init(title: L("Try again"), run: model.retry),
                            secondary: .init(title: L("Close"), run: model.dismissFailure))
                    } else {
                        Kit.StatusScreen(
                            badge: .warning, title: L("We couldn't continue"),
                            message: ReVerifyCopy.message(for: error),
                            primary: .init(title: L("Close"), run: model.dismissFailure))
                    }
                }
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
    }
}
