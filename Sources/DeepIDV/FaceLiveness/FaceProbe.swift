// DeepIDV › FaceLiveness

import CoreVideo

/// A single face-geometry reading for one camera frame — enough to drive a
/// "center your face → now move closer" UI without any Vision code. Produced by
/// ``DeepIDVClient/faceProbe(_:)``.
public struct FaceProbe: Sendable, Equatable {
    /// Faces detected in the frame. Want exactly 1 before capturing.
    public let faceCount: Int
    /// Face width ÷ frame width, 0–1. The proximity signal: larger = closer.
    public let widthRatio: Double
    /// Distance of the face center from the frame center, 0–1. 0 = centered.
    public let centerOffset: Double

    /// `centerOffset ≤ this` counts as centered (matches the SDK's own flow).
    public static let centeredMaxOffset = 0.20
    /// `widthRatio ≥ this` is close enough to start the move-closer capture.
    public static let centeredMinWidth = 0.25
    /// `widthRatio` at "fully close" — the top of the move-closer range.
    public static let closeTargetWidth = 0.55

    init(faceCount: Int, widthRatio: Double, centerOffset: Double) {
        self.faceCount = faceCount
        self.widthRatio = widthRatio
        self.centerOffset = centerOffset
    }

    init(_ quality: FaceQuality) {
        self.init(
            faceCount: quality.faceCount,
            widthRatio: quality.faceWidthRatio,
            centerOffset: quality.centerOffset)
    }
}
