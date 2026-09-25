// DeepIDV › DocumentScanner

import AVFoundation
import Combine
import CoreGraphics
import DeepIDVCore
import Foundation
import OSLog

/// The guided document-capture coordinator — the testable brain behind
/// ``DocumentScannerView`` and the document step of the drop-in verify flow.
///
/// It owns the loop that drives a ``CameraController`` through a
/// ``DocumentCaptureAnalyzer``: per frame it measures quality (via the injected
/// ``DocumentFrameEvaluating``), decides whether to auto-capture, handles the
/// front→back sequence for two-sided documents, the manual-shutter fallback,
/// camera permission and cancellation, then hands the captured image(s)
/// to the injected `complete` operation and reports its result exactly once.
///
/// It's generic over `Output` so the *same* capture engine serves both callers:
/// the OCR scanner completes by calling `client.scanDocument` (`Output =
/// DocumentScanResult`), while the verify flow completes by simply returning the
/// captured ``FileInput``s for `verifyIdentity` to upload (`Output =
/// (FileInput, FileInput?)`). One capture code path, two terminals.
///
/// Every external dependency is a seam, so the whole flow runs headless in tests
/// with a fake controller/evaluator/encoder and no camera.
@MainActor
final class DocumentCaptureModel<Output>: ObservableObject {
    /// Which step of the capture flow is on screen.
    enum Phase: Sendable, Equatable {
        case capturingFront
        case capturingBack
        case processing
    }

    /// Turns the captured image(s) into the flow's `Output` — the model's one
    /// outward call. The scanner passes `client.scanDocument`; the verify flow
    /// passes a closure returning the raw images; tests pass a spy. Not
    /// `@Sendable`: it's stored and invoked only on the main actor.
    typealias CompleteOperation =
        (_ front: FileInput, _ back: FileInput?, _ type: DocumentType) async throws -> Output

    // MARK: - Published state (drives the overlay)

    @Published private(set) var phase: Phase = .capturingFront
    /// The live guidance hint for the current frame, or `nil` once a side locks.
    @Published private(set) var guidance: CaptureGuidance?
    /// Whether the manual shutter should be offered (auto-capture timed out).
    @Published private(set) var manualShutterVisible = false
    /// Set when camera access is denied — the view shows a Settings deep-link CTA.
    @Published private(set) var permissionDenied = false
    /// 0–1 progress of the hold-still dwell, for the overlay's capture ring.
    @Published private(set) var holdProgress: Double = 0
    /// Set briefly after a side locks so the overlay can flash a success
    /// checkmark before the flow advances (to the back, or to processing).
    @Published private(set) var showSideCaptured = false

    // MARK: - Dependencies

    let documentType: DocumentType
    private let captureMode: CaptureMode
    private let controller: any CameraController
    private let evaluator: any DocumentFrameEvaluating
    private let encoder: any DocumentStillEncoding
    private let authorizer: any CameraAuthorizing
    private let tunables: DocumentCaptureTunables
    private let complete: CompleteOperation
    private let onResult: (Result<Output, DeepIDVError>) -> Void

    // MARK: - Internal state

    private var analyzer: DocumentCaptureAnalyzer
    private var isCancelled = false
    private var hasFinished = false
    private var manualRequested = false
    private var manualShutterTask: Task<Void, Never>?
    /// Whether the back side is armed for auto-capture (after the flip grace).
    private var backArmed = false
    private var backArmTask: Task<Void, Never>?
    /// Most recent per-frame metrics, for the auto-capture-timeout diagnostic.
    private var lastQuality: CaptureQuality?
    /// When the document last became steady — the start of the hold-still dwell.
    private var steadyStartedAt: Date?

    /// Capture diagnostics. Filter the Xcode console / Console.app by this
    /// subsystem (`com.deepidv.sdk`) to see why auto-capture is or isn't locking.
    private let log = Logger(subsystem: "com.deepidv.sdk", category: "doc-capture")

    init(
        documentType: DocumentType,
        captureMode: CaptureMode? = nil,
        controller: any CameraController,
        evaluator: any DocumentFrameEvaluating,
        encoder: any DocumentStillEncoding,
        authorizer: any CameraAuthorizing = AlwaysAuthorizedCamera(),
        tunables: DocumentCaptureTunables = .init(),
        complete: @escaping CompleteOperation,
        onResult: @escaping (Result<Output, DeepIDVError>) -> Void
    ) {
        self.documentType = documentType
        self.captureMode = captureMode ?? documentType.captureMode
        self.controller = controller
        self.evaluator = evaluator
        self.encoder = encoder
        self.authorizer = authorizer
        self.tunables = tunables
        self.analyzer = DocumentCaptureAnalyzer(documentType: documentType, tunables: tunables)
        self.complete = complete
        self.onResult = onResult
    }

    // MARK: - Lifecycle

    /// Runs the whole capture flow to completion, firing `onResult` once. Safe to
    /// `await` directly (tests) or launch from `.task` (the view).
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
        finish(.failure(.cancelled("Document scanning was cancelled.")))
    }

    /// The live `AVCaptureSession` for the preview layer, when backed by the real
    /// controller. `nil` for the fake controller (tests/previews).
    var previewSession: AVCaptureSession? {
        (controller as? AVFoundationCameraController)?.session
    }

    /// The instruction banner for the current phase (front / flip-to-back / processing).
    var instructionText: String {
        switch phase {
        case .capturingFront:
            return captureMode == .frontOnly
                ? "Position your document in the frame"
                : "Scan the front of your document"
        case .capturingBack:
            return "Flip your document and scan the back"
        case .processing:
            return "Processing…"
        }
    }

    /// The short side label for the overlay pill — `nil` once processing, so
    /// the pill disappears when there's nothing left to position.
    var sideLabel: String? {
        switch phase {
        case .capturingFront: return "Front of your ID"
        case .capturingBack: return "Back of your ID"
        case .processing: return nil
        }
    }

    // MARK: - Capture loop

    /// A single pass over the frame stream that captures the front, then (for
    /// two-sided documents) the back, then submits. One iteration of `frames`
    /// across both sides — the live `AsyncStream` only supports one consumer.
    private func captureLoop() async {
        var capturingBack = false
        var frontInput: FileInput?
        startManualShutterTimer()

        for await frame in controller.frames {
            if isCancelled { return }  // `cancel()` already reported

            // After the front is captured, hold off on the back until the user has
            // had a chance to flip — otherwise the still-present front re-captures
            // instantly. Arm early if the document leaves the frame.
            if capturingBack, !backArmed {
                if !evaluator.quality(of: frame, for: documentType).documentDetected {
                    backArmed = true
                    backArmTask?.cancel()
                    log.debug("back armed: document left frame")
                }
                continue
            }

            if !shouldCapture(frame) { continue }

            // Lock acquired — grab a full-resolution still; fall back to the
            // streamed video frame if the photo capture fails (never a regression).
            let captured: CameraFrame
            do {
                captured = try await controller.captureStill()
            } catch {
                captured = frame
            }
            if isCancelled { return }

            let input: FileInput
            do {
                input = try encoder.encode(captured, documentType: documentType)
            } catch {
                finishCaptureFailed(error, fallback: "Unable to process the captured image.")
                return
            }

            // Two-sided document, front just captured → flash a confirmation,
            // then advance to the back.
            if !capturingBack, captureMode == .frontAndBack {
                frontInput = input
                await confirmSideCaptured()
                if isCancelled { return }
                capturingBack = true
                backArmed = false
                phase = .capturingBack
                guidance = nil
                manualRequested = false
                steadyStartedAt = nil
                holdProgress = 0
                analyzer.reset()
                startManualShutterTimer()
                startBackArmTimer()
                continue
            }

            // Final side captured (passport front, or a card's back).
            cancelManualShutterTimer()
            await confirmSideCaptured()
            if isCancelled { return }
            await submit(
                front: capturingBack ? (frontInput ?? input) : input,
                back: capturingBack ? input : nil)
            return
        }

        // Stream ended before a document was captured.
        if !hasFinished, !isCancelled {
            finish(
                .failure(
                    .captureFailed(
                        "The camera stopped before a document could be captured.")))
        }
    }

    /// Whether to capture this frame — an explicit manual request wins; otherwise
    /// the analyzer's gate decides, and any guidance is published for the overlay.
    private func shouldCapture(_ frame: CameraFrame) -> Bool {
        if manualRequested {
            manualRequested = false
            log.debug("manual capture requested")
            return true
        }
        let quality = evaluator.quality(of: frame, for: documentType)
        lastQuality = quality
        switch analyzer.evaluate(quality) {
        case .capture:
            // The document is well-positioned and still right now. Require the user
            // to hold it there for `holdStillDuration` before firing — the elapsed
            // time drives the overlay's progress ring (a deliberate "hold still").
            let start = steadyStartedAt ?? Date()
            steadyStartedAt = start
            let elapsed = Date().timeIntervalSince(start)
            holdProgress = min(1, elapsed / max(0.001, tunables.holdStillDuration))
            guidance = .holdSteady
            if elapsed >= tunables.holdStillDuration {
                log.debug("auto-capture after hold — \(Self.describe(quality), privacy: .public)")
                return true
            }
            return false
        case .guide(let hint):
            // Moved or a gate failed — reset the dwell and surface the hint.
            if steadyStartedAt != nil || guidance != hint {
                log.debug(
                    "not steady: \(String(describing: hint), privacy: .public) — \(Self.describe(quality), privacy: .public)"
                )
            }
            steadyStartedAt = nil
            holdProgress = 0
            guidance = hint
            return false
        }
    }

    /// Compact per-frame metrics for the capture diagnostics log.
    private static func describe(_ q: CaptureQuality) -> String {
        let center =
            q.center.map { String(format: "(%.2f,%.2f)", Double($0.x), Double($0.y)) } ?? "—"
        return "detected=\(q.documentDetected) fill=\(String(format: "%.2f", q.fillRatio)) "
            + "aspect=\(String(format: "%.2f", q.aspectRatio)) "
            + "sharp=\(String(format: "%.0f", q.sharpness)) "
            + "glare=\(String(format: "%.3f", q.glareRatio)) center=\(center)"
    }

    /// Hands the captured image(s) to `complete` and reports its result (or error).
    private func submit(front: FileInput, back: FileInput?) async {
        phase = .processing
        controller.stop()
        do {
            finish(.success(try await complete(front, back, documentType)))
        } catch let error as DeepIDVError {
            finish(.failure(error))
        } catch {
            finish(
                .failure(
                    .captureFailed(
                        "Document capture failed.", causeDescription: String(describing: error))))
        }
    }

    /// Flashes the captured-side checkmark for a beat so the user gets clear
    /// per-side feedback before the flow moves on. Clears the live guidance
    /// and dwell so nothing competes with the confirmation.
    private func confirmSideCaptured() async {
        guidance = nil
        holdProgress = 0
        steadyStartedAt = nil
        showSideCaptured = true
        try? await Task.sleep(nanoseconds: UInt64(tunables.sideCapturedDisplay * 1_000_000_000))
        showSideCaptured = false
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
                    .cameraPermissionDenied(
                        "Camera access is required to scan your document.")))
            return false
        }
    }

    // MARK: - Completion

    /// Fires `onResult` exactly once; all completion paths funnel through here.
    private func finish(_ result: Result<Output, DeepIDVError>) {
        guard !hasFinished else { return }
        hasFinished = true
        holdProgress = 0
        cancelManualShutterTimer()
        backArmTask?.cancel()
        onResult(result)
    }

    /// Reports a `DeepIDVError` as-is, or wraps any other error as `.captureFailed`.
    private func finishCaptureFailed(_ error: Error, fallback message: String) {
        if let error = error as? DeepIDVError {
            finish(.failure(error))
        } else {
            finish(
                .failure(
                    .captureFailed(
                        message, causeDescription: String(describing: error))))
        }
    }

    // MARK: - Manual-shutter timer

    /// (Re)starts the countdown that reveals the manual shutter after the
    /// auto-capture timeout. Kept off the analyzer so gating stays wall-clock-free.
    private func startManualShutterTimer() {
        manualShutterVisible = false
        manualShutterTask?.cancel()
        let timeout = tunables.autoCaptureTimeout
        manualShutterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.manualShutterVisible = true
            let last = self.lastQuality.map(Self.describe) ?? "no frames analyzed"
            self.log.info(
                "auto-capture timed out after \(timeout, privacy: .public)s — showing manual shutter. last: \(last, privacy: .public)"
            )
        }
    }

    private func cancelManualShutterTimer() {
        manualShutterTask?.cancel()
        manualShutterTask = nil
        manualShutterVisible = false
    }

    /// After the front of a two-sided document is captured, gives the user a grace
    /// period to flip before the back is armed for auto-capture. The capture
    /// loop also arms early if the document leaves the frame.
    private func startBackArmTimer() {
        backArmTask?.cancel()
        let grace = tunables.flipGracePeriod
        backArmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.backArmed = true
        }
    }
}
