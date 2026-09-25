// DeepIDV › DocumentScanner › Capture

import CoreGraphics  // CGPoint
import Foundation  // TimeInterval

/// The per-frame quality metrics the auto-capture gates are evaluated against.
///
/// This is the seam that keeps the capture stack testable without a camera.
/// Measuring these numbers from a live frame needs Vision/pixel access and is
/// therefore iOS-only (see ``DocumentFrameEvaluating``); the *gating logic* in
/// ``DocumentCaptureAnalyzer`` consumes only this plain struct, so it runs —
/// and unit-tests — no camera needed. Think of it like separating
/// a pure reducer from the impure I/O that feeds it: the reducer is what we test.
///
/// All values describe a single frame. `Equatable`/`Sendable` so tests can assert
/// on them and they can cross the camera-thread → analyzer boundary freely.
struct CaptureQuality: Sendable, Equatable {
    /// Whether a document quad was detected in the frame at all. When `false`
    /// the remaining metrics are meaningless and the analyzer asks the user to
    /// bring a document into view before checking anything else.
    var documentDetected: Bool

    /// Fraction (0–1) of the frame's width the detected document spans — the
    /// "is it close enough" signal. Gated against ``DocumentCaptureTunables/minFillRatio``.
    var fillRatio: Double

    /// Longer-side ÷ shorter-side of the detected quad (always ≥ 1, orientation
    /// independent). Compared against the target band for the selected
    /// ``DocumentType`` (ID-1 card ≈ 1.586 vs. passport data page ≈ 1.42).
    var aspectRatio: Double

    /// Sharpness score — the variance of a Laplacian over the document region.
    /// Higher means crisper; motion blur and poor focus drive it down. Gated
    /// against ``DocumentCaptureTunables/minSharpness``. The absolute scale is a
    /// device-calibrated tunable, not a physical unit.
    var sharpness: Double

    /// Fraction (0–1) of the document region that is blown-out/over-exposed —
    /// the glare signal. Gated against ``DocumentCaptureTunables/maxGlareRatio``.
    var glareRatio: Double

    /// Centre of the detected document, normalized (0–1). The analyzer compares it
    /// across frames to reject a document that's still being moved/aligned — one
    /// that passes the per-frame gates but is drifting (see
    /// ``DocumentCaptureTunables/maxCenterJitter``). `nil` when not measured (the
    /// no-camera test/preview path), which disables the jitter check.
    var center: CGPoint?

    init(
        documentDetected: Bool,
        fillRatio: Double = 0,
        aspectRatio: Double = 0,
        sharpness: Double = 0,
        glareRatio: Double = 0,
        center: CGPoint? = nil
    ) {
        self.documentDetected = documentDetected
        self.fillRatio = fillRatio
        self.aspectRatio = aspectRatio
        self.sharpness = sharpness
        self.glareRatio = glareRatio
        self.center = center
    }
}

/// The auto-capture thresholds. Every gate is a named, overridable knob
/// rather than a magic number buried in the analyzer, so they can be tuned per
/// device and pinned in tests. Defaults are the spec's starting values.
struct DocumentCaptureTunables: Sendable, Equatable {
    /// Minimum fraction of frame width the document must fill — high enough that
    /// the user has framed it close and roughly centered, not caught it drifting.
    var minFillRatio: Double = 0.55

    /// Absolute tolerance on the per-type target aspect ratio. Tight enough to
    /// reject a steeply-angled or mis-shaped frame, loose enough for normal
    /// perspective.
    var aspectTolerance: Double = 0.22

    /// Minimum Laplacian-variance sharpness — the key anti-motion gate: a frame
    /// captured while the phone is moving is blurry and fails here, resetting the
    /// stability streak. The absolute scale is device-dependent, so tune it from
    /// the values the capture diagnostics log on your target hardware.
    var minSharpness: Double = 150

    /// Maximum fraction of the document allowed to be glared/over-exposed. Lenient
    /// enough for a glossy laminated ID, strict enough to reject a blown-out frame.
    var maxGlareRatio: Double = 0.08

    /// Consecutive fully-passing frames that confirm the document is steady before
    /// the hold-still dwell begins — a short debounce so a single fluke frame
    /// doesn't start the timer. The dwell (`holdStillDuration`) is the real hold.
    var stabilityFrameCount: Int = 3

    /// How long the document must stay steady (the "hold still" dwell) before
    /// auto-capture fires — this drives the on-screen progress ring. The model owns
    /// this timing; the analyzer stays wall-clock-free for deterministic tests.
    var holdStillDuration: TimeInterval = 2

    /// Maximum normalized distance the document centre may move *between* frames
    /// while still counting toward the stability streak. A slow pan to fine-align
    /// keeps each frame "good" but drifts past this, resetting the streak — so it
    /// won't lock until you actually hold still (~2% of the frame).
    var maxCenterJitter: Double = 0.02

    /// Grace period after the front is captured before the back is armed for
    /// auto-capture, giving the user time to flip a two-sided document. Armed
    /// early if the document leaves the frame.
    var flipGracePeriod: TimeInterval = 2

    /// Seconds of trying-to-lock after which the capture *view* reveals the manual
    /// shutter. The analyzer itself is wall-clock-free for deterministic tests;
    /// this value is carried here for the view to consume.
    var autoCaptureTimeout: TimeInterval = 8

    /// How long the per-side success checkmark stays on screen after a side locks,
    /// before the flow advances to the back (or to processing). Purely a display
    /// beat — kept here so tests can zero it out and not wait on it.
    var sideCapturedDisplay: TimeInterval = 0.9

    // The compiler-synthesized memberwise initializer is used — every stored
    // property has a default, so `.init()` and `.init(stabilityFrameCount:)` both work.
}

/// The single piece of guidance to surface when a frame is *not* yet capturable.
///
/// One value per failing gate, in the order the analyzer checks them, so the
/// overlay shows the most fundamental problem first ("I can't even see
/// a document" before "hold steady"). Maps to the live hints.
enum CaptureGuidance: Sendable, Equatable {
    /// No document detected — ask the user to bring one into view.
    case searching
    /// Document detected but too small — move the camera closer.
    case moveCloser
    /// Wrong shape for the selected type — fit the whole document squarely in frame.
    case fitDocumentInFrame
    /// Glare/reflection on the document — tilt away from the light.
    case reduceGlare
    /// Blurry or still settling — hold steady. Covers both motion blur and the
    /// not-yet-stable window after all other gates pass.
    case holdSteady
}

/// The analyzer's verdict for a frame: either take the shot, or show guidance.
enum CaptureDecision: Sendable, Equatable {
    /// All gates have held for the required number of consecutive frames — capture now.
    case capture
    /// Not capturable yet; show this guidance to the user.
    case guide(CaptureGuidance)
}
