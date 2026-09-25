// DeepIDV › IdentityVerify

import CoreVideo
import Foundation  // TimeInterval
import Vision

/// Per-frame face-framing metrics the selfie auto-capture gates read.
///
/// The selfie counterpart to ``CaptureQuality``: measuring these from a live frame
/// needs Vision and is iOS-only (``FaceFrameEvaluating``); the gating in
/// ``SelfieCaptureAnalyzer`` consumes only this plain struct, so it unit-tests
/// camera-free. Framing guidance **only** — there is no
/// liveness/blink/motion check here (that's out of scope for this file).
struct FaceQuality: Sendable, Equatable {
    /// How many faces were detected. Exactly one is required.
    var faceCount: Int
    /// Width of the (largest) face as a fraction of frame width — the "close
    /// enough" signal. Gated against ``SelfieCaptureTunables/minFaceWidthRatio``.
    var faceWidthRatio: Double
    /// Distance of the face centre from the frame centre, normalized (0 = dead
    /// centre). Gated against ``SelfieCaptureTunables/maxCenterOffset`` so the face
    /// sits inside the guide oval.
    var centerOffset: Double

    init(faceCount: Int, faceWidthRatio: Double = 0, centerOffset: Double = 1) {
        self.faceCount = faceCount
        self.faceWidthRatio = faceWidthRatio
        self.centerOffset = centerOffset
    }
}

/// The selfie auto-capture thresholds. Defaults are the spec's values.
struct SelfieCaptureTunables: Sendable, Equatable {
    /// Minimum face width as a fraction of frame width.
    var minFaceWidthRatio: Double = 0.26
    /// Maximum normalized centre offset that still counts as "in the oval".
    var maxCenterOffset: Double = 0.24
    /// Consecutive fully-passing frames required before auto-capture (hold steady).
    var stabilityFrameCount: Int = 6
    /// Seconds after capture starts before auto-capture may fire — gives the
    /// user time to settle into frame after the screen appears. Manual capture
    /// is not delayed. The analyzer is wall-clock-free; the model consumes this.
    var autoCaptureWarmup: TimeInterval = 2
    /// Seconds before the capture view reveals the manual shutter. The
    /// analyzer is wall-clock-free; the view consumes this.
    var autoCaptureTimeout: TimeInterval = 8

    // The compiler-synthesized memberwise initializer is used — every stored
    // property has a default, so `.init()` and `.init(stabilityFrameCount:)` both work.
}

/// The guidance to surface when a selfie frame isn't yet capturable. Maps to the
/// framing hints.
enum SelfieGuidance: Sendable, Equatable {
    /// No face detected — ask the user to look at the camera.
    case noFace
    /// More than one face — only the subject should be in frame.
    case multipleFaces
    /// Face too small — move the phone closer.
    case moveCloser
    /// Face off-centre — move it into the guide oval.
    case centerFace
    /// Settling — hold steady.
    case holdSteady
}

/// The analyzer's verdict for a selfie frame: capture, or show guidance.
enum SelfieCaptureDecision: Sendable, Equatable {
    case capture
    case guide(SelfieGuidance)
}

/// Decides *when* to auto-capture a selfie, from a stream of per-frame
/// ``FaceQuality`` metrics — the pure selfie gate.
///
/// Mirrors ``DocumentCaptureAnalyzer``: `assess(_:)` is the stateless per-frame
/// check, `evaluate(_:)` adds the N-consecutive-frame stability rule. Framing only
/// — no liveness.
struct SelfieCaptureAnalyzer: Sendable {
    let tunables: SelfieCaptureTunables
    private(set) var consecutiveGoodFrames = 0

    init(tunables: SelfieCaptureTunables = .init()) {
        self.tunables = tunables
    }

    /// Pure per-frame gate check, most-fundamental-first: returns `nil` when the
    /// frame passes every gate, or the first failing gate's guidance.
    func assess(_ quality: FaceQuality) -> SelfieGuidance? {
        if quality.faceCount == 0 { return .noFace }
        if quality.faceCount > 1 { return .multipleFaces }
        if quality.faceWidthRatio < tunables.minFaceWidthRatio { return .moveCloser }
        if quality.centerOffset > tunables.maxCenterOffset { return .centerFace }
        return nil
    }

    /// Feeds one frame through the gates and the stability counter.
    mutating func evaluate(_ quality: FaceQuality) -> SelfieCaptureDecision {
        if let failure = assess(quality) {
            consecutiveGoodFrames = 0
            return .guide(failure)
        }
        consecutiveGoodFrames += 1
        if consecutiveGoodFrames >= tunables.stabilityFrameCount {
            return .capture
        }
        return .guide(.holdSteady)
    }

    mutating func reset() {
        consecutiveGoodFrames = 0
    }
}

/// Turns a raw ``CameraFrame`` into ``FaceQuality`` — the impure-measurement seam
/// for selfies. The live implementation is iOS-only; tests inject a scripted
/// evaluator.
protocol FaceFrameEvaluating: Sendable {
    func quality(of frame: CameraFrame) -> FaceQuality
}

/// Measures ``FaceQuality`` from a live front-camera frame using
/// `VNDetectFaceRectanglesRequest` — framing guidance only, no liveness.
/// iOS-only.
struct VisionFaceFrameEvaluator: FaceFrameEvaluating {
    func quality(of frame: CameraFrame) -> FaceQuality {
        guard let pixelBuffer = frame.pixelBuffer else { return FaceQuality(faceCount: 0) }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? handler.perform([request])) != nil,
            let faces = request.results, !faces.isEmpty
        else {
            return FaceQuality(faceCount: 0)
        }

        // Frame against the largest face (the subject, if others stray in).
        let primary = faces.max { $0.boundingBox.width < $1.boundingBox.width }!
        let box = primary.boundingBox  // normalized, bottom-left origin
        let dx = Double(box.midX) - 0.5
        let dy = Double(box.midY) - 0.5
        return FaceQuality(
            faceCount: faces.count,
            faceWidthRatio: Double(box.width),
            centerOffset: (dx * dx + dy * dy).squareRoot())
    }
}
