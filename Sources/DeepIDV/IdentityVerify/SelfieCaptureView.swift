// DeepIDV › IdentityVerify (UI)

import AVFoundation
import DeepIDVCore
import SwiftUI
import UIKit

/// Composable selfie-capture step: a plain front-camera capture (no
/// liveness) that returns the captured ``FileInput`` to its caller.
///
/// For hosts assembling their own verify flow — capture a selfie here, then pass
/// the `FileInput` to ``DeepIDVClient/verifyIdentity(documentFront:documentBack:selfie:type:)``.
/// It needs no client (it only captures); failures and cancellation surface as a
/// ``DeepIDVError`` through `onResult`. The camera surface is iOS-only. UIKit hosts
/// wrap it in a `UIHostingController`.
public struct SelfieCaptureView: View {
    private let onResult: (Result<FileInput, DeepIDVError>) -> Void

    public init(onResult: @escaping (Result<FileInput, DeepIDVError>) -> Void) {
        self.onResult = onResult
    }

    public var body: some View {
        SelfieCaptureFlowView(onResult: onResult)
    }
}

/// The live iOS selfie surface: front-camera preview with the oval guide
/// overlay, driven by a ``SelfieCaptureModel``. Reuses the document flow's
/// ``CameraPreviewView``. Internal — hosts use ``SelfieCaptureView``.
struct SelfieCaptureFlowView: View {
    @Environment(\.theme) private var theme
    @StateObject private var model: SelfieCaptureModel
    private let faceFrontPhotoOnly: Bool?

    init(
        faceFrontPhotoOnly: Bool? = nil,
        onResult: @escaping (Result<FileInput, DeepIDVError>) -> Void
    ) {
        self.faceFrontPhotoOnly = faceFrontPhotoOnly
        _model = StateObject(
            wrappedValue: SelfieCaptureModel(
                controller: AVFoundationCameraController(position: .front),
                evaluator: VisionFaceFrameEvaluator(),
                encoder: SelfieStillEncoder(),
                authorizer: SystemCameraAuthorizer(),
                onResult: onResult))
    }

    var body: some View {
        ZStack {
            CameraPreviewView(session: model.previewSession)
                .ignoresSafeArea()
            SelfieCaptureOverlayView(
                instruction: faceFrontPhotoOnly == true
                    ? "Look straight at the camera"
                    : model.instructionText,
                guidance: model.guidance,
                manualShutterVisible: model.manualShutterVisible,
                permissionDenied: model.permissionDenied,
                onManualCapture: { model.triggerManualCapture() },
                onCancel: { model.cancel() },
                onOpenSettings: openSettings)
        }
        .background(theme.colors.grey.s900)
        .task { await model.run() }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    SelfieCaptureView { result in
        switch result {
        case .success: print("selfie captured")
        case .failure(let error): print("selfie failed: \(error)")
        }
    }
}
