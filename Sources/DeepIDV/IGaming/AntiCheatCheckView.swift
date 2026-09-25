// DeepIDV › IGaming (UI)

import DeepIDVCore
import SwiftUI
import UIKit

/// Composable anti-cheat face-check step: captures a face photo (reusing the
/// selfie-capture surface) and runs the iGaming anti-cheat check — face dedup
/// ("has this face already signed up?") plus self-exclusion. A denied camera
/// permission ends the capture and surfaces its own Settings deep-link in the
/// failed-state chrome rather than looping on "Try again".
///
/// `sessionID` references an existing verification session created by your
/// backend via `POST /v1/sessions` (the SDK never creates sessions). The
/// verdict is reported through `onResult` for the host to act on — a
/// duplicate is a `.success`, not an error; the endpoint is fail-soft (see
/// ``AntiCheatResult``). The camera surface is iOS-only. UIKit hosts wrap it
/// in a `UIHostingController`.
public struct AntiCheatCheckView: View {
    private let client: DeepIDVClient
    private let sessionID: String
    private let deviceFingerprint: String?
    private let onResult: (Result<AntiCheatResult, DeepIDVError>) -> Void

    public init(
        client: DeepIDVClient,
        sessionID: String,
        deviceFingerprint: String? = nil,
        onResult: @escaping (Result<AntiCheatResult, DeepIDVError>) -> Void
    ) {
        self.client = client
        self.sessionID = sessionID
        self.deviceFingerprint = deviceFingerprint
        self.onResult = onResult
    }

    public var body: some View {
        AntiCheatFlowView(
            service: client.makeIGamingService(),
            sessionID: sessionID,
            deviceFingerprint: deviceFingerprint,
            onResult: onResult)
    }
}

/// The live anti-cheat surface: the selfie capture step while capturing, then
/// themed checking/result/error chrome driven by an ``AntiCheatModel``.
/// Internal — hosts use ``AntiCheatCheckView``.
struct AntiCheatFlowView: View {
    @Environment(\.theme) private var theme
    @StateObject private var model: AntiCheatModel

    init(
        service: IGamingService,
        sessionID: String,
        deviceFingerprint: String?,
        onResult: @escaping (Result<AntiCheatResult, DeepIDVError>) -> Void
    ) {
        _model = StateObject(
            wrappedValue: AntiCheatModel(
                service: service, sessionID: sessionID, deviceFingerprint: deviceFingerprint,
                onResult: onResult))
    }

    var body: some View {
        content
            .onAppear { model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .capturing:
            // The capture surface owns cancellation and the initial permission
            // check; a denial (or cancel) arrives here as the failure branch,
            // which the `.failed` case below re-surfaces with its own
            // Settings deep-link.
            SelfieCaptureView { result in
                switch result {
                case .success(let image):
                    model.imageCaptured(image)
                case .failure(let error):
                    model.captureFailed(error)
                }
            }

        case .checking:
            statusChrome {
                ProgressView()
                Text("Checking your photo…")
                    .font(theme.typography.body())
                    .foregroundStyle(theme.colors.grey.s700)
            }

        case .finished(let result):
            statusChrome {
                Text(result.isDuplicate ? "This face is already registered" : "Check complete")
                    .font(theme.typography.body())
                    .foregroundStyle(theme.colors.grey.s700)
            }

        case .failed(let error):
            statusChrome {
                Text(error.message)
                    .font(theme.typography.body())
                    .foregroundStyle(theme.colors.grey.s700)
                    .multilineTextAlignment(.center)
                if error.kind == .cameraPermissionDenied {
                    // Retrying re-arms the same capture surface, which will
                    // immediately deny again — offer the Settings deep-link
                    // instead of (or in addition to) "Try again" so the host
                    // isn't stuck in a loop with no way out.
                    Button("Open Settings", action: openSettings)
                        .font(theme.typography.body())
                }
                Button("Try again") { model.retry() }
                    .font(theme.typography.body())
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Shared full-screen themed container for the non-capture states.
    private func statusChrome(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: theme.spacing.md) {
            content()
        }
        .padding(theme.spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.grey.s50)
    }
}

#Preview {
    AntiCheatCheckView(
        client: DeepIDVClient(apiKey: "sk_test"), sessionID: "sess-demo"
    ) { result in
        print("anti-cheat: \(result)")
    }
}
