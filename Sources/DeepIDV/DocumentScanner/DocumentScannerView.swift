// DeepIDV › DocumentScanner (UI)

import AVFoundation
import DeepIDVCore
import SwiftUI
import UIKit

/// Composable per-step view that runs the OCR-only document-scan flow, for a host
/// assembling its own verification flow.
///
/// The caller fixes the ``DocumentType`` up front: the front-only vs.
/// front+back capture rule must be known before capture, so this step takes an
/// explicit `documentType` rather than showing a picker. It drives guided
/// auto-capture (with a manual-shutter fallback), uploads via
/// ``DeepIDVClient/scanDocument(front:back:type:)``, and reports a
/// ``DocumentScanResult`` (or a ``DeepIDVError``) through `onResult`.
///
/// The camera surface is iOS-only; on other platforms the body is a themed
/// notice so the package still builds and previews. UIKit hosts wrap it in a
/// `UIHostingController`.
public struct DocumentScannerView: View {
    private let client: DeepIDVClient
    private let documentType: DocumentType
    private let onResult: (Result<DocumentScanResult, DeepIDVError>) -> Void

    public init(
        client: DeepIDVClient,
        documentType: DocumentType,
        onResult: @escaping (Result<DocumentScanResult, DeepIDVError>) -> Void
    ) {
        self.client = client
        self.documentType = documentType
        self.onResult = onResult
    }

    public var body: some View {
        // Capture the document, then OCR it server-side via `scanDocument`.
        DocumentCaptureFlowView(
            documentType: documentType,
            cameraPosition: client.config.documentCamera.avPosition,
            showsIntro: client.config.showsDocumentCaptureIntro,
            complete: { front, back, type in
                try await client.scanDocument(front: front, back: back, type: type)
            },
            onResult: onResult)
    }
}

/// The live iOS capture surface: the camera preview with the guide overlay on
/// top, driven by a ``DocumentCaptureModel``. Generic over the capture
/// `Output` so it serves both the OCR scanner and the verify flow's document
/// step (which completes with the raw ``FileInput``s). Internal — hosts use the
/// public ``DocumentScannerView`` or ``DeepIDVVerificationView``.
struct DocumentCaptureFlowView<Output>: View {
    @Environment(\.theme) private var theme
    @StateObject private var model: DocumentCaptureModel<Output>
    /// Gates the camera behind the intro screen — `run()` (and the camera
    /// session) only start once the user taps Continue / Skip.
    @State private var started: Bool
    private let cameraPosition: AVCaptureDevice.Position

    init(
        documentType: DocumentType,
        captureMode: CaptureMode? = nil,
        cameraPosition: AVCaptureDevice.Position = .back,
        showsIntro: Bool = true,
        complete: @escaping DocumentCaptureModel<Output>.CompleteOperation,
        onResult: @escaping (Result<Output, DeepIDVError>) -> Void
    ) {
        self.cameraPosition = cameraPosition
        // No intro → the camera starts as soon as the view appears.
        _started = State(initialValue: !showsIntro)
        _model = StateObject(
            wrappedValue: DocumentCaptureModel(
                documentType: documentType,
                captureMode: captureMode,
                controller: AVFoundationCameraController(position: cameraPosition),
                evaluator: VisionDocumentFrameEvaluator(),
                encoder: DocumentStillEncoder(),
                authorizer: SystemCameraAuthorizer(),
                complete: complete,
                onResult: onResult))
    }

    var body: some View {
        if started {
            ZStack {
                // A front-camera document preview must not be mirrored: the
                // user reads the ID on screen, and the still is un-mirrored too.
                CameraPreviewView(
                    session: model.previewSession,
                    mirrored: cameraPosition == .front ? false : nil
                )
                .ignoresSafeArea()
                CaptureOverlayView(
                    instruction: model.instructionText,
                    guidance: model.guidance,
                    manualShutterVisible: model.manualShutterVisible,
                    isProcessing: model.phase == .processing,
                    permissionDenied: model.permissionDenied,
                    sideLabel: model.sideLabel,
                    sideCaptured: model.showSideCaptured,
                    holdProgress: model.holdProgress,
                    onManualCapture: { model.triggerManualCapture() },
                    onCancel: { model.cancel() },
                    onOpenSettings: openSettings)
            }
            .background(theme.colors.grey.s900)
            .task { await model.run() }
        } else {
            DocumentScanStartView { started = true }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

extension DocumentCamera {
    /// The AVFoundation device position for this setting.
    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .back: return .back
        case .front: return .front
        }
    }
}

/// Hosts an `AVCaptureVideoPreviewLayer` bound to the capture session.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession?
    /// `nil` keeps AVFoundation's default (front camera mirrored, like a
    /// mirror — right for selfies). `false` forces an un-mirrored preview so a
    /// document held up to the front camera reads correctly on screen.
    var mirrored: Bool? = nil

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        configure(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        configure(uiView.previewLayer)
    }

    /// Mirroring first (it is part of what the rotation coordinator accounts
    /// for), then the upright angle for whichever camera feeds the session.
    private func configure(_ layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection else { return }
        if let mirrored, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        if let device = (session?.inputs.first as? AVCaptureDeviceInput)?.device {
            AVFoundationCameraController.applyUprightRotation(
                to: [connection], device: device, previewLayer: layer)
        } else {
            AVFoundationCameraController.applyPortraitRotation(to: connection)
        }
    }

    /// A `UIView` whose backing layer *is* the preview layer, so it resizes
    /// with the view automatically.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

#Preview {
    let client = DeepIDVClient(apiKey: "sk_test")

    DocumentScannerView(client: client, documentType: .idCard) { result in
        switch result {
        case .success(let scanResult):
            print("scan confidence: \(scanResult.confidence)")
        case .failure(let error):
            print("scan failed: \(error)")
        }
    }
}
