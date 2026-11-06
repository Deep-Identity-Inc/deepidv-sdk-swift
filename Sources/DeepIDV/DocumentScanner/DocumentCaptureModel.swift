// DeepIDV › DocumentScanner

import AVFoundation
import Combine
import CoreGraphics
import DeepIDVCore
import Foundation
import OSLog
import UIKit

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

    @Published private(set) var phase: Phase = .capturingFront {
        didSet { refreshStage() }
    }
    /// The live guidance hint for the current frame, or `nil` once a side locks.
    @Published private(set) var guidance: CaptureGuidance? {
        didSet { refreshStage() }
    }
    /// The one instruction on screen. It follows `guidance` and the phase, but a
    /// new stage only replaces the shown one once it has held for a moment, so a
    /// reading that changes frame to frame doesn't flash (``CaptureStagePresenter``).
    @Published private(set) var stage: CaptureStage = .findDocument
    /// Whether the manual shutter should be offered (auto-capture timed out).
    @Published private(set) var manualShutterVisible = false
    /// Set when camera access is denied — the view shows a Settings deep-link CTA.
    @Published private(set) var permissionDenied = false
    /// 0–1 progress of the hold-still dwell, for the overlay's capture ring.
    @Published private(set) var holdProgress: Double = 0
    /// Set briefly after a side locks so the overlay can flash a success
    /// checkmark before the flow advances (to the back, or to processing).
    @Published private(set) var showSideCaptured = false {
        didSet { refreshStage() }
    }
    /// The document the classifier names on the front, for the screen's label.
    @Published private(set) var shownDocument: ShownDocument?
    /// The photo just taken, shown in the frame while the side is confirmed.
    @Published private(set) var capturedImage: UIImage?

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
    /// The document classifier for card fronts and passport pages, or `nil` for
    /// on-device checks only.
    private let classifier: (any DocumentClassifying)?
    /// The session captures by the classifier's rules (ID capture v2): blur never
    /// holds a frame back on any side, and a back or a passport page is captured
    /// once steady for `steadyCaptureDuration`.
    private let usesClassifierRules: Bool
    /// Told about every front photo, with what the classifier made of it.
    private let onFrontCaptured: ((FrontCaptureReport) -> Void)?
    /// The classifier's clock (seconds, monotonic).
    private let clock: () -> TimeInterval

    // MARK: - Internal state

    private var analyzer: DocumentCaptureAnalyzer
    private var isCancelled = false
    private var hasFinished = false
    private var manualRequested = false
    /// Whether the side just captured was taken with the manual shutter.
    private var lastCaptureWasManual = false
    private var manualShutterTask: Task<Void, Never>?
    /// Whether the back side is armed for auto-capture (after the flip grace).
    private var backArmed = false
    private var backArmTask: Task<Void, Never>?
    /// Most recent per-frame metrics, for the auto-capture-timeout diagnostic.
    private var lastQuality: CaptureQuality?
    /// When the document last became steady — the start of the hold-still dwell.
    private var steadyStartedAt: Date?
    /// Recent sharpness scores of frames with a document on this side, on `clock`.
    private var recentSharpness: [(time: TimeInterval, value: Double)] = []
    /// When capture, otherwise ready, began waiting for a sharper frame.
    private var sharpnessWaitSince: TimeInterval?
    /// Whether a document has been in view on this side yet.
    private var documentSeenOnSide = false
    /// When the manual shutter is due to show.
    private var shutterDeadline: Date?
    private var stagePresenter = CaptureStagePresenter()
    /// The capture frame drawn on screen. `nil` until the screen reports it.
    private var guide: CaptureWindow?

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
        classifier: (any DocumentClassifying)? = nil,
        usesClassifierRules: Bool = false,
        onFrontCaptured: ((FrontCaptureReport) -> Void)? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
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
        self.classifier = classifier
        self.usesClassifierRules = usesClassifierRules || classifier != nil
        self.onFrontCaptured = onFrontCaptured
        self.clock = clock
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
    /// Where the frame is drawn, so "close enough" means filling it. The
    /// preview fills the screen, cropping the camera's view to the screen's
    /// shape, so the frame's share of the camera frame follows from both.
    /// The photo uploaded is cut to the same frame.
    func guideChanged(_ window: CaptureWindow) {
        guard window.rect.width > 0, window.screenAspect > 0 else { return }
        guide = window
    }

    func triggerManualCapture() {
        manualRequested = true
    }

    /// User backed out: reports `.cancelled` and tears the session down.
    func cancel() {
        guard !hasFinished else { return }
        isCancelled = true
        cancelManualShutterTimer()
        classifier?.stop()
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
                ? L("Position your document in the frame")
                : L("Scan the front of your document")
        case .capturingBack:
            return L("Flip your document and scan the back")
        case .processing:
            return L("Processing…")
        }
    }

    /// The short side label for the overlay pill — `nil` once processing, so
    /// the pill disappears when there's nothing left to position.
    var sideLabel: String? {
        switch phase {
        case .capturingFront: return L("Front of your ID")
        case .capturingBack: return L("Back of your ID")
        case .processing: return nil
        }
    }

    /// The document has a back to capture after the front.
    var hasBack: Bool { captureMode == .frontAndBack }

    /// The side being captured is the last one.
    var isFinalSide: Bool { phase == .capturingBack || !hasBack }

    // MARK: - Stage

    /// The stage the capture is in right now, before settling.
    private var currentStage: CaptureStage {
        if phase == .processing { return .processing }
        if showSideCaptured { return .captured }
        if phase == .capturingBack, !backArmed { return .flip }
        return guidance.map(CaptureStage.init) ?? .findDocument
    }

    private func refreshStage() {
        let next = stagePresenter.update(currentStage, at: clock())
        if next != stage { stage = next }
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

            // The classifier looks at card fronts and passport pages: backs skip it.
            let sideClassifier = capturingBack ? nil : classifier
            if !shouldCapture(frame, classifier: sideClassifier) { continue }

            // Lock acquired — grab a full-resolution still; fall back to the
            // streamed video frame if the photo capture fails (never a regression).
            let captured: CameraFrame
            do {
                captured = try await controller.captureStill()
            } catch {
                captured = frame
            }
            if isCancelled { return }

            // Cutting and re-encoding a full-size photo takes a while: off the
            // main actor, so the screen doesn't freeze while it runs.
            var input: FileInput
            do {
                let encoder = self.encoder
                let documentType = self.documentType
                let window = guide
                input = try await Task.detached {
                    try encoder.encode(captured, documentType: documentType, window: window)
                }.value
            } catch {
                if isCancelled { return }
                finishCaptureFailed(error, fallback: "Unable to process the captured image.")
                return
            }
            if isCancelled { return }

            if !capturingBack {
                let report =
                    await sideClassifier?.frontCaptured(
                        photo: input, manual: lastCaptureWasManual, at: clock())
                    ?? FrontCaptureReport(photo: input, classification: nil, extraFrames: [])
                if isCancelled { return }
                input = report.photo
                onFrontCaptured?(report)
            }

            capturedImage = ClassifierImages.data(of: input).flatMap(UIImage.init(data:))

            // Two-sided document, front just captured → flash a confirmation,
            // then advance to the back.
            if !capturingBack, captureMode == .frontAndBack {
                frontInput = input
                await confirmSideCaptured(for: tunables.sideCapturedDisplay)
                if isCancelled { return }
                capturingBack = true
                backArmed = false
                phase = .capturingBack
                guidance = nil
                shownDocument = nil
                capturedImage = nil
                manualRequested = false
                steadyStartedAt = nil
                sharpnessWaitSince = nil
                recentSharpness.removeAll()
                holdProgress = 0
                analyzer.reset()
                startManualShutterTimer()
                startBackArmTimer()
                continue
            }

            // Final side captured (passport front, or a card's back).
            cancelManualShutterTimer()
            await confirmSideCaptured(for: tunables.doneDisplay)
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
    ///
    /// With a classifier in play, both must agree: the classifier's verdict holds
    /// capture back (or blocks it, for a health card) until it is satisfied, and
    /// the on-device gates must then pass on every frame for the classifier hold.
    /// When the classifier is off, the on-device logic runs exactly as without it.
    private func shouldCapture(
        _ frame: CameraFrame, classifier: (any DocumentClassifying)?
    ) -> Bool {
        if manualRequested {
            manualRequested = false
            lastCaptureWasManual = true
            log.debug("manual capture requested")
            return true
        }
        lastCaptureWasManual = false
        if let guide, let buffer = frame.pixelBuffer {
            let height = Double(CVPixelBufferGetHeight(buffer))
            let aspect = height > 0 ? Double(CVPixelBufferGetWidth(buffer)) / height : 0
            analyzer.guideFill = DocumentCaptureAnalyzer.guideFill(
                widthShare: Double(guide.rect.width), screenAspect: guide.screenAspect,
                frameAspect: aspect, share: tunables.guideFillShare)
        }
        let quality = evaluator.quality(of: frame, for: documentType)
        lastQuality = quality
        let now = clock()
        if quality.documentDetected {
            recentSharpness.append((now, quality.sharpness))
            recentSharpness.removeAll { now - $0.time > tunables.sharpnessWindow + 1e-9 }
            if !documentSeenOnSide {
                documentSeenOnSide = true
                scheduleManualShutter(in: tunables.autoCaptureTimeout)
            }
        }
        // With the classifier's rules, blur only shapes which frame becomes the
        // photo; without them, the blur gate stands as before.
        let decision = analyzer.evaluate(quality, checksSharpness: !usesClassifierRules)
        if let classifier {
            if let guide { classifier.windowChanged(guide) }
            classifier.observe(
                frame, quality: quality, framed: analyzer.isFramed(quality),
                visionReady: decision == .capture, at: now)
            let named = classifier.shownDocument
            if named != shownDocument { shownDocument = named }
            switch classifier.verdict(at: now) {
            case .off:
                break
            case .block(let blocking):
                resetDwell()
                guidance = blocking
                return false
            case .hold(let waiting):
                resetDwell()
                // The on-device hints come first: they're the ones the user can act on.
                if case .guide(let hint) = decision {
                    guidance = hint
                } else {
                    guidance = waiting
                }
                return false
            case .go:
                // A passport page has already been good for its steady time.
                let hold = documentType == .passport ? 0 : tunables.classifierHoldDuration
                return dwell(decision, quality, duration: hold)
            }
        }
        // A back or a passport page under the classifier's rules: once steady.
        let steadyOnly = usesClassifierRules && (classifier == nil || documentType == .passport)
        return dwell(
            decision, quality,
            duration: steadyOnly ? tunables.steadyCaptureDuration : tunables.holdStillDuration)
    }

    private func resetDwell() {
        steadyStartedAt = nil
        sharpnessWaitSince = nil
        holdProgress = 0
    }

    /// Under the classifier's rules, whether this frame is sharp enough to be the
    /// moment of capture: at least `relativeSharpnessFloor` of the sharpest recent
    /// frame, or once capture has waited `sharpnessWaitLimit` for one.
    private func sharpEnough(_ quality: CaptureQuality) -> Bool {
        guard usesClassifierRules else { return true }
        let now = clock()
        let peak = recentSharpness.map(\.value).max() ?? 0
        if quality.sharpness >= peak * tunables.relativeSharpnessFloor {
            sharpnessWaitSince = nil
            return true
        }
        let since = sharpnessWaitSince ?? now
        sharpnessWaitSince = since
        guard now - since >= tunables.sharpnessWaitLimit else { return false }
        log.debug(
            "no sharper frame after \(self.tunables.sharpnessWaitLimit, privacy: .public)s; capturing anyway"
        )
        sharpnessWaitSince = nil
        return true
    }

    /// The hold-still dwell: capture once the gates have passed on every frame for
    /// `duration`.
    private func dwell(
        _ decision: CaptureDecision, _ quality: CaptureQuality, duration: TimeInterval
    ) -> Bool {
        switch decision {
        case .capture:
            // The document is well-positioned and still right now. Require the user
            // to hold it there for `duration` before firing — the elapsed
            // time drives the overlay's progress ring (a deliberate "hold still").
            let start = steadyStartedAt ?? Date()
            steadyStartedAt = start
            let elapsed = Date().timeIntervalSince(start)
            holdProgress = min(1, elapsed / max(0.001, duration))
            guidance = .holdSteady
            if elapsed >= duration, sharpEnough(quality) {
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
            sharpnessWaitSince = nil
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
    private func confirmSideCaptured(for duration: TimeInterval) async {
        guidance = nil
        holdProgress = 0
        steadyStartedAt = nil
        showSideCaptured = true
        try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
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
        classifier?.stop()
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

    /// (Re)starts a side's countdown to the manual shutter: `manualShutterCeiling`
    /// at the latest, brought forward to `autoCaptureTimeout` after the document
    /// first comes into view. Kept off the analyzer so gating stays wall-clock-free.
    private func startManualShutterTimer() {
        cancelManualShutterTimer()
        documentSeenOnSide = false
        scheduleManualShutter(in: tunables.manualShutterCeiling)
    }

    /// Shows the manual shutter after `delay`, unless it's already due sooner.
    private func scheduleManualShutter(in delay: TimeInterval) {
        guard !manualShutterVisible, !hasFinished else { return }
        let deadline = Date().addingTimeInterval(delay)
        if let shutterDeadline, shutterDeadline <= deadline { return }
        shutterDeadline = deadline
        manualShutterTask?.cancel()
        manualShutterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.manualShutterVisible = true
            let last = self.lastQuality.map(Self.describe) ?? "no frames analyzed"
            self.log.info(
                "no auto-capture after \(delay, privacy: .public)s — showing manual shutter. last: \(last, privacy: .public)"
            )
        }
    }

    private func cancelManualShutterTimer() {
        manualShutterTask?.cancel()
        manualShutterTask = nil
        shutterDeadline = nil
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
