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
            Kit.StatusScreen(
                badge: .working(symbol: "person.crop.square"), title: "Checking your photo",
                message: "This only takes a moment")

        case .finished(let result):
            if result.isDuplicate {
                Kit.StatusScreen(badge: .warning, title: "This face is already registered")
            } else {
                Kit.StatusScreen(badge: .success, title: "Check complete")
            }

        case .failed(let error):
            if error.kind == .cameraPermissionDenied {
                // Retrying re-arms the same capture surface, which will
                // immediately deny again — offer the Settings deep-link first
                // so the host isn't stuck in a loop with no way out.
                Kit.StatusScreen(
                    badge: .camera, title: "Camera access is off", message: error.message,
                    primary: .init(title: "Open Settings", run: openSettings),
                    secondary: .init(title: "Try again", run: model.retry))
            } else {
                Kit.StatusScreen(
                    badge: .warning, title: "Something went wrong", message: error.message,
                    primary: .init(title: "Try again", run: model.retry))
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

}

#Preview {
    AntiCheatCheckView(
        client: DeepIDVClient(apiKey: "sk_test"), sessionID: "sess-demo"
    ) { result in
        print("anti-cheat: \(result)")
    }
}
