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
    /// Replaces the fixed not-passed copy when the host flow knows why the
    /// attempt failed. `nil` outside a workflow run.
    private let retryCopy: (title: String, body: String)?
    /// Shows a close button; `nil` outside a workflow run.
    private let onCancel: (() -> Void)?
    @State private var permissionDenied = false
    @State private var didBegin = false

    init(
        client: DeepIDVClient,
        sessionID: String,
        retryCopy: (title: String, body: String)? = nil,
        onCancel: (() -> Void)? = nil,
        onResult: @escaping (Result<FaceLivenessResult, DeepIDVError>) -> Void
    ) {
        _model = StateObject(
            wrappedValue: CustomFaceLivenessModel(
                service: client.makeCustomFaceLivenessService(),
                sessionID: sessionID,
                onResult: onResult))
        self.onResult = onResult
        self.retryCopy = retryCopy
        self.onCancel = onCancel
        self.authorizer = SystemCameraAuthorizer()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    onCancel: onCancel,
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

    // MARK: - Status screens

    private var loadingView: some View {
        Kit.StatusScreen(
            badge: .working(symbol: "faceid"), title: L("Getting ready"),
            message: L("Next, a quick check that it's really you"), onClose: onCancel)
    }

    @ViewBuilder
    private func resultView(_ result: FaceLivenessResult) -> some View {
        if result.passed {
            Kit.StatusScreen(
                badge: .success, title: L("Liveness confirmed"),
                message: L("Thanks, that's everything we need"))
        } else {
            Kit.StatusScreen(
                badge: .retry, title: retryCopy?.title ?? L("We couldn't verify you"),
                message: retryCopy?.body
                    ?? L("Make sure your face is well lit and fills the oval, then try again."),
                primary: .init(title: L("Try again"), run: model.retry),
                secondary: onCancel.map { .init(title: L("Cancel"), run: $0) })
        }
    }

    private func errorView(_ error: DeepIDVError) -> some View {
        let copy = WorkflowFailureCopy.error(error)
        return Kit.StatusScreen(
            badge: .warning, title: copy.title, message: copy.body,
            primary: .init(title: L("Try again"), run: model.retry),
            secondary: onCancel.map { .init(title: L("Cancel"), run: $0) })
    }

    private var permissionDeniedView: some View {
        CaptureScreens.Permission(
            purpose: L("check that it's really you"), onOpenSettings: openSettings)
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
