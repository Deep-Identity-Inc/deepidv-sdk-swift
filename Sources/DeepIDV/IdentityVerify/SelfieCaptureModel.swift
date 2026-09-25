// DeepIDV › IdentityVerify

import AVFoundation
import Combine
import DeepIDVCore
import Foundation

/// The selfie-capture coordinator behind ``SelfieCaptureView`` — the testable
/// brain of the plain front-camera capture (no liveness).
///
/// A single-shot sibling of ``DocumentCaptureModel``: it drives a
/// ``CameraController`` through a ``SelfieCaptureAnalyzer`` (face framing only),
/// supports the manual-shutter fallback, permission and cancellation,
/// then encodes the captured frame to a ``FileInput`` and reports it once. Every
/// dependency is a seam, so it runs headless in tests.
///
/// (The capture lifecycle deliberately parallels ``DocumentCaptureModel`` rather
/// than sharing a base class — `ObservableObject` inheritance with `@Published` is
/// fragile, and the two differ in metric type and single-vs-two-sided capture.)
@MainActor
final class SelfieCaptureModel: ObservableObject {
    // MARK: - Published state (drives the overlay)

    /// The live framing hint, or `nil` once the face locks.
    @Published private(set) var guidance: SelfieGuidance?
    /// Whether the manual shutter should be offered (auto-capture timed out).
    @Published private(set) var manualShutterVisible = false
    /// Set when camera access is denied — the view shows a Settings deep-link CTA.
    @Published private(set) var permissionDenied = false

    // MARK: - Dependencies

    private let controller: any CameraController
    private let evaluator: any FaceFrameEvaluating
    private let encoder: any SelfieStillEncoding
    private let authorizer: any CameraAuthorizing
    private let tunables: SelfieCaptureTunables
    private let onResult: (Result<FileInput, DeepIDVError>) -> Void

    // MARK: - Internal state

    private var analyzer: SelfieCaptureAnalyzer
    private var autoCaptureAllowedAt: DispatchTime = .now()
    private var isCancelled = false
    private var hasFinished = false
    private var manualRequested = false
    private var manualShutterTask: Task<Void, Never>?

    init(
        controller: any CameraController,
        evaluator: any FaceFrameEvaluating,
        encoder: any SelfieStillEncoding,
        authorizer: any CameraAuthorizing = AlwaysAuthorizedCamera(),
        tunables: SelfieCaptureTunables = .init(),
        onResult: @escaping (Result<FileInput, DeepIDVError>) -> Void
    ) {
        self.controller = controller
        self.evaluator = evaluator
        self.encoder = encoder
        self.authorizer = authorizer
        self.tunables = tunables
        self.analyzer = SelfieCaptureAnalyzer(tunables: tunables)
        self.onResult = onResult
    }

    // MARK: - Lifecycle

    /// Runs the capture to completion, firing `onResult` once.
    func run() async {
        guard !hasFinished, !isCancelled else { return }
        guard await ensureAuthorized() else { return }

        do {
            try await controller.start()
        } catch {
            finishCaptureFailed(error, fallback: "Unable to start the camera.")
            return
        }

        await captureLoop()
    }

    /// Requests a manual capture of the next frame — the shutter-button action.
    func triggerManualCapture() {
        manualRequested = true
    }

    /// User backed out: reports `.cancelled` and tears the session down.
    func cancel() {
        guard !hasFinished else { return }
        isCancelled = true
        cancelManualShutterTimer()
        controller.stop()
        finish(.failure(.cancelled("Selfie capture was cancelled.")))
    }

    /// The live `AVCaptureSession` for the preview layer, when backed by the real
    /// controller. `nil` for the fake controller (tests/previews).
    var previewSession: AVCaptureSession? {
        (controller as? AVFoundationCameraController)?.session
    }

    /// The framing instruction shown above the guide oval.
    var instructionText: String { "Center your face in the circle" }

    // MARK: - Capture loop

    private func captureLoop() async {
        autoCaptureAllowedAt = .now() + tunables.autoCaptureWarmup
        startManualShutterTimer()

        for await frame in controller.frames {
            if isCancelled { return }  // `cancel()` already reported
            guard shouldCapture(frame) else { continue }

            cancelManualShutterTimer()
            // Grab a full-resolution still; fall back to the streamed video frame.
            let captured: CameraFrame
            do { captured = try await controller.captureStill() } catch { captured = frame }
            if isCancelled { return }
            controller.stop()
            do {
                finish(.success(try encoder.encode(captured)))
            } catch {
                finishCaptureFailed(error, fallback: "Unable to process the selfie.")
            }
            return
        }

        // Stream ended before a selfie was captured.
        if !hasFinished, !isCancelled {
            finish(
                .failure(
                    .captureFailed("The camera stopped before a selfie could be captured.")))
        }
    }

    /// Whether to capture this frame — a manual request wins; otherwise the
    /// analyzer's framing gate decides, publishing any guidance. Auto-capture
    /// is additionally held back until the warm-up period elapses so the first
    /// well-framed frames after the screen appears aren't shot immediately.
    private func shouldCapture(_ frame: CameraFrame) -> Bool {
        if manualRequested {
            manualRequested = false
            return true
        }
        switch analyzer.evaluate(evaluator.quality(of: frame)) {
        case .capture:
            guard DispatchTime.now() >= autoCaptureAllowedAt else {
                guidance = .holdSteady
                return false
            }
            return true
        case .guide(let hint):
            guidance = hint
            return false
        }
    }

    // MARK: - Permission

    private func ensureAuthorized() async -> Bool {
        switch authorizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined where await authorizer.requestAccess():
            return true
        case .notDetermined, .denied:
            permissionDenied = true
            finish(
                .failure(
                    .cameraPermissionDenied("Camera access is required to take a selfie.")))
            return false
        }
    }

    // MARK: - Completion

    private func finish(_ result: Result<FileInput, DeepIDVError>) {
        guard !hasFinished else { return }
        hasFinished = true
        cancelManualShutterTimer()
        onResult(result)
    }

    private func finishCaptureFailed(_ error: Error, fallback message: String) {
        if let error = error as? DeepIDVError {
            finish(.failure(error))
        } else {
            finish(
                .failure(
                    .captureFailed(message, causeDescription: String(describing: error))))
        }
    }

    // MARK: - Manual-shutter timer

    private func startManualShutterTimer() {
        manualShutterVisible = false
        manualShutterTask?.cancel()
        let timeout = tunables.autoCaptureTimeout
        manualShutterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.manualShutterVisible = true
        }
    }

    private func cancelManualShutterTimer() {
        manualShutterTask?.cancel()
        manualShutterTask = nil
        manualShutterVisible = false
    }
}
