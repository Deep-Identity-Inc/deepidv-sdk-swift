// DeepIDV › FaceLiveness

import DeepIDVCore
import SwiftUI
import UIKit

/// Public entry point for the native custom liveness flow, run against a
/// verification session your backend creates.
public struct CustomFaceLivenessView: View {
    private let client: DeepIDVClient
    private let sessionID: String
    private let onResult: (Result<FaceLivenessResult, DeepIDVError>) -> Void

    public init(
        client: DeepIDVClient,
        sessionID: String,
        onResult: @escaping (Result<FaceLivenessResult, DeepIDVError>) -> Void
    ) {
        self.client = client
        self.sessionID = sessionID
        self.onResult = onResult
    }

    public var body: some View {
        CustomFaceLivenessFlowView(client: client, sessionID: sessionID, onResult: onResult)
    }
}

/// Permission pre-check → session create → native capture (proximity / light) →
/// upload → result.
struct CustomFaceLivenessFlowView: View {
    @Environment(\.theme) private var theme
    @StateObject private var model: CustomFaceLivenessModel
    private let onResult: (Result<FaceLivenessResult, DeepIDVError>) -> Void
    private let authorizer: any CameraAuthorizing
    @State private var permissionDenied = false
    @State private var didBegin = false

    init(
        client: DeepIDVClient,
        sessionID: String,
        onResult: @escaping (Result<FaceLivenessResult, DeepIDVError>) -> Void
    ) {
        _model = StateObject(
            wrappedValue: CustomFaceLivenessModel(
                service: client.makeCustomFaceLivenessService(),
                sessionID: sessionID,
                onResult: onResult))
        self.onResult = onResult
        self.authorizer = SystemCameraAuthorizer()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.colors.grey.s50)
            .task { await begin() }
    }

    @ViewBuilder
    private var content: some View {
        if permissionDenied {
            permissionDeniedView
        } else {
            switch model.state {
            case .idle, .creating, .uploading, .fetching:
                loadingView
            case .capturing(let script):
                CaptureRunView(
                    script: script,
                    onCaptured: { result in
                        let timeline = (try? JSONEncoder().encode(result.timeline)) ?? Data("[]".utf8)
                        model.submit(frames: result.frames, timeline: timeline, clip: result.clip)
                    },
                    onError: { model.captureFailed($0) })
            case .finished(let result):
                resultView(result)
            case .failed(let error):
                errorView(error)
            }
        }
    }

    // MARK: - Themed chrome

    private var loadingView: some View {
        VStack(spacing: theme.spacing.md) {
            ProgressView()
            Text("Preparing your liveness check…")
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s600)
        }
        .padding(theme.spacing.lg)
    }

    private func resultView(_ result: FaceLivenessResult) -> some View {
        VStack(spacing: theme.spacing.md) {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(result.passed ? theme.colors.success : theme.colors.error)
            Text(result.passed ? "Liveness confirmed" : "We couldn't verify you")
                .font(theme.typography.heading())
                .foregroundStyle(theme.colors.grey.s900)
                .multilineTextAlignment(.center)
            if !result.passed {
                primaryButton("Try again", action: model.retry)
            }
        }
        .padding(theme.spacing.lg)
    }

    private func errorView(_ error: DeepIDVError) -> some View {
        VStack(spacing: theme.spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(theme.colors.warning)
            Text(error.message)
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s700)
                .multilineTextAlignment(.center)
            primaryButton("Try again", action: model.retry)
        }
        .padding(theme.spacing.lg)
    }

    private var permissionDeniedView: some View {
        VStack(spacing: theme.spacing.md) {
            Text("Camera access needed")
                .font(theme.typography.heading())
                .foregroundStyle(theme.colors.grey.s900)
            Text("Enable camera access in Settings to run the liveness check.")
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s600)
                .multilineTextAlignment(.center)
            primaryButton("Open Settings", action: openSettings)
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
                .clipShape(RoundedRectangle(cornerRadius: theme.spacing.sm, style: .continuous))
        }
    }

    // MARK: - Permission pre-check + start

    private func begin() async {
        guard !didBegin else { return }
        didBegin = true
        switch authorizer.authorizationStatus() {
        case .authorized:
            model.start()
        case .notDetermined where await authorizer.requestAccess():
            model.start()
        case .notDetermined, .denied:
            permissionDenied = true
            onResult(.failure(.cameraPermissionDenied("Camera access is required for the liveness check.")))
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
