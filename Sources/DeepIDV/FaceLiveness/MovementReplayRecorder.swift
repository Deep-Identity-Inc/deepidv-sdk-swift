// DeepIDV › FaceLiveness

import AVFoundation   // CMTime / CVPixelBuffer
import QuartzCore     // CACurrentMediaTime

/// Records a headless movement-liveness attempt into an `.mp4` replay clip.
///
/// In the SDK's own UI flow the recorder taps the camera directly. Headless
/// integrators own the camera, so they feed this recorder the same
/// `CVPixelBuffer`s they hand to ``DeepIDVClient/faceProbe(_:)``, then pass the
/// finished bytes to
/// ``DeepIDVClient/checkMovementLiveness(frames:clip:confidenceThreshold:)``.
/// The heavy lifting — frame copy, H.264 encode, gap-capped real-time playback —
/// is the SDK's; the integrator's job is one `append` per frame plus `finish`.
///
/// Thread-safe: `append` may be called from any queue (e.g. the camera delegate
/// queue). Timestamps come from the host clock, so the clip plays at real speed
/// no matter how evenly frames arrive.
public final class MovementReplayRecorder: @unchecked Sendable {
    private let recorder = LivenessClipRecorder()

    public init() {}

    /// Feed one camera frame — call this for every frame you receive, alongside
    /// `faceProbe`.
    public func append(_ pixelBuffer: CVPixelBuffer) {
        recorder.append(
            pixelBuffer, at: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600))
    }

    /// Finalizes the clip and returns the mp4 bytes — `nil` if nothing usable was
    /// recorded. Pass the result as `clip:` to `checkMovementLiveness`.
    public func finish() async -> Data? {
        await recorder.finish()
    }
}
