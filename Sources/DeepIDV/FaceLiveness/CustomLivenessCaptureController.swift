// DeepIDV › FaceLiveness

import AVFoundation
import DeepIDVCore
import Foundation

/// One captured frame's metadata, uploaded as `timeline.json` alongside the JPEGs.
struct TimelineEntry: Encodable, Sendable, Equatable {
    let index: Int
    let atMs: Int
    let kind: String   // "checkpoint" | "color"
    let value: String  // checkpoint fraction, or the hex color
}

/// The output of a capture run: the JPEG frames, their timeline, and an
/// optional full-attempt replay clip (mp4). `clip` is `nil` when recording
/// isn't available (e.g. the non-AVFoundation test/preview camera).
struct CaptureResult: Sendable, Equatable {
    let frames: [Data]
    let timeline: [TimelineEntry]
    let clip: Data?
}

/// The **pure** challenge choreography — no camera, no UI, so it is unit-tested.
/// Fed a stream of ``FaceQuality`` samples, it decides when centering is done and
/// (for the movement challenge) which proximity checkpoints have been reached.
/// Ported from the web `CustomLivenessCapture`.
struct LivenessChoreography {
    static let minFaceWidthRatio = 0.25
    static let maxCenterOffset = 0.20
    static let holdCenteredFrames = 20            // ≈1s at ~20fps
    static let targetFaceWidthRatio = 0.55
    static let movementCheckpoints: [Double] = [0, 0.33, 0.66, 1.0]
    /// The widest face the movement challenge may start from. The server
    /// passes the attempt only when the face box in the last two frames is at
    /// least 1.15× the first two, and the checkpoints span start → target, so a
    /// start at 0.40 gives ≈1.23×. A start near or past the target fires every
    /// checkpoint at once (≈1.0×) and always fails — which is exactly where a
    /// retry begins, since the previous attempt ended at the target.
    static let maxStartFaceWidthRatio = 0.40

    struct Tick: Equatable {
        var centeringDone: Bool
        var progress: Double
        var checkpointsToCapture: [Double]
        /// Centering is waiting for the face to move back (movement challenge only).
        var tooClose = false
    }

    private let script: ChallengeScript
    private var centeredFrames = 0
    private(set) var centeringDone = false
    private var startRatio: Double?
    private var firedCheckpoints: Set<Int> = []

    init(script: ChallengeScript) { self.script = script }

    mutating func ingest(_ q: FaceQuality) -> Tick {
        if !centeringDone {
            // Only the movement challenge needs room to approach; the light
            // challenge is time-driven and can start at any distance.
            let tooClose = script.challengeType == .faceMovement
                && q.faceCount == 1
                && q.faceWidthRatio > Self.maxStartFaceWidthRatio
            let ok = q.faceCount == 1
                && q.faceWidthRatio >= Self.minFaceWidthRatio
                && !tooClose
                && q.centerOffset <= Self.maxCenterOffset
            centeredFrames = ok ? centeredFrames + 1 : 0
            if centeredFrames >= Self.holdCenteredFrames { centeringDone = true }
            return Tick(
                centeringDone: centeringDone, progress: 0, checkpointsToCapture: [],
                tooClose: tooClose)
        }
        // Movement proximity progress (the light challenge is time-driven and
        // ignores this — see the controller).
        if startRatio == nil { startRatio = q.faceWidthRatio }
        let start = startRatio ?? q.faceWidthRatio
        let denom = Self.targetFaceWidthRatio - start
        let clamped = denom > 0 ? min(1, max(0, (q.faceWidthRatio - start) / denom)) : 1
        var toCapture: [Double] = []
        for (i, cp) in Self.movementCheckpoints.enumerated()
        where clamped >= cp && !firedCheckpoints.contains(i) {
            firedCheckpoints.insert(i)
            toCapture.append(cp)
        }
        return Tick(centeringDone: true, progress: clamped, checkpointsToCapture: toCapture)
    }

    var movementComplete: Bool { firedCheckpoints.count == Self.movementCheckpoints.count }
}

/// Device capture engine: runs the ``LivenessChoreography`` against a live
/// ``CameraController`` + Vision evaluator, capturing JPEG stills at movement
/// checkpoints or after each flashed color, and returns a ``CaptureResult``.
///
/// Publishes `centeringDone` / `tooClose` / `progress` / `activeColor` for
/// ``CaptureRunView`` to render the oval, the "move back" / "move closer"
/// prompts, and the full-screen color overlay.
@MainActor
final class CustomLivenessCaptureController: ObservableObject {
    @Published private(set) var centeringDone = false
    /// The face is too close to start the movement challenge ("Move back").
    @Published private(set) var tooClose = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var activeColor: String?

    private let controller: any CameraController
    private let evaluator: any FaceFrameEvaluating
    private let encoder: any SelfieStillEncoding
    private let script: ChallengeScript

    /// The live `AVCaptureSession` for `CameraPreviewView`, when the controller is
    /// the AVFoundation-backed one (mirrors `SelfieCaptureModel.previewSession`).
    var previewSession: AVCaptureSession? { (controller as? AVFoundationCameraController)?.session }

    private static let framingTimeout: TimeInterval = 20
    private static let movementTimeout: TimeInterval = 10
    private static let lightCaptureLagMs: UInt64 = 200

    init(
        controller: any CameraController,
        evaluator: any FaceFrameEvaluating = VisionFaceFrameEvaluator(),
        encoder: any SelfieStillEncoding = SelfieStillEncoder(),
        script: ChallengeScript
    ) {
        self.controller = controller
        self.evaluator = evaluator
        self.encoder = encoder
        self.script = script
    }

    /// Runs the full challenge and returns the captured frames + timeline.
    /// Throws `DeepIDVError` on camera/timeout failure.
    func run() async throws -> CaptureResult {
        try await controller.start()
        defer { controller.stop() }

        // The operator replay clip records only the challenge (the actual scan),
        // not the centering/framing phase — during framing the face isn't yet in
        // position and frames barely flow, which would leave a long frozen gap at
        // the head of the clip. No-op on the non-AVFoundation test/preview camera.
        let recorder = controller as? AVFoundationCameraController

        var choreo = LivenessChoreography(script: script)
        var frames: [Data] = []
        var timeline: [TimelineEntry] = []
        let startedAt = Date()

        // 1. Frame loop until centered (or framing timeout).
        centerLoop: for await frame in controller.frames {
            if Date().timeIntervalSince(startedAt) > Self.framingTimeout {
                throw DeepIDVError.captureFailed("We couldn't detect your face. Please try again.")
            }
            let tick = choreo.ingest(evaluator.quality(of: frame))
            centeringDone = tick.centeringDone
            tooClose = tick.tooClose
            if tick.centeringDone { break centerLoop }
        }
        guard centeringDone else {
            throw DeepIDVError.captureFailed("We couldn't detect your face. Please try again.")
        }

        // Start recording now that the face is centered — the clip covers the
        // scan from here.
        recorder?.startRecording()

        // 2. Run the challenge.
        switch script.challengeType {
        case .faceMovement:
            try await runMovement(&choreo, frames: &frames, timeline: &timeline, startedAt: startedAt)
        case .faceMovementAndLight:
            try await runLight(frames: &frames, timeline: &timeline, startedAt: startedAt)
        }

        // Finalize the replay clip before the deferred `stop()` tears the
        // session down. Best-effort — a nil clip never blocks the result.
        let clip = await recorder?.stopRecording()
        return CaptureResult(frames: frames, timeline: timeline, clip: clip)
    }

    private func runMovement(
        _ choreo: inout LivenessChoreography, frames: inout [Data],
        timeline: inout [TimelineEntry], startedAt: Date
    ) async throws {
        let phaseStart = Date()
        for await frame in controller.frames {
            if Date().timeIntervalSince(phaseStart) > Self.movementTimeout {
                throw DeepIDVError.captureFailed("Liveness check timed out. Please try again.")
            }
            let tick = choreo.ingest(evaluator.quality(of: frame))
            progress = tick.progress
            for cp in tick.checkpointsToCapture {
                if let data = try await captureStillData(fallback: frame) {
                    timeline.append(TimelineEntry(
                        index: frames.count, atMs: msSince(startedAt), kind: "checkpoint", value: String(cp)))
                    frames.append(data)
                }
            }
            if choreo.movementComplete { break }
        }
    }

    private func runLight(
        frames: inout [Data], timeline: inout [TimelineEntry], startedAt: Date
    ) async throws {
        let phaseStart = Date()
        for step in script.steps where step.kind == "color" {
            guard let color = step.color else { continue }
            // Wait until this color's scheduled offset, then show it.
            let target = phaseStart.addingTimeInterval(Double(step.atMs) / 1000)
            let wait = target.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            activeColor = color
            try await Task.sleep(nanoseconds: Self.lightCaptureLagMs * 1_000_000)
            if let data = try await captureStillData(fallback: nil) {
                timeline.append(TimelineEntry(
                    index: frames.count, atMs: msSince(startedAt), kind: "color", value: color))
                frames.append(data)
            }
        }
        activeColor = nil
    }

    /// Captures a dedicated high-res still (falling back to the streamed frame),
    /// JPEG-encodes it, and returns the bytes.
    private func captureStillData(fallback: CameraFrame?) async throws -> Data? {
        let still: CameraFrame
        if let captured = try? await controller.captureStill() {
            still = captured
        } else if let fallback {
            still = fallback
        } else {
            return nil
        }
        let file: FileInput
        do { file = try encoder.encode(still) } catch { return nil }
        switch file {
        case .data(let d): return d
        case .base64(let s): return Data(base64Encoded: s)
        case .fileURL(let u): return try? Data(contentsOf: u)
        }
    }

    private func msSince(_ date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }
}
