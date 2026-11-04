import Foundation

// DeepIDVCore › Classifier

/// One frame kept while a card front is scanned, with its sharpness.
struct BufferedFrame<Frame> {
    /// When it was kept, in seconds on the capture's clock.
    var time: TimeInterval
    var frame: Frame
    /// Its sharpness score (higher is sharper), or `nil` when it couldn't be scored.
    var sharpness: Double?
}

extension BufferedFrame: Sendable where Frame: Sendable {}
extension BufferedFrame: Equatable where Frame: Equatable {}

/// Picks which recent frames go with a card-front photo.
///
/// While a front is scanned, the camera keeps its last few frames. When the photo
/// is taken, the sharpest of them stands in for a blurry still, and the next
/// sharpest, spaced apart, go with the photo as extra frames for the server to
/// read from if a field on the photo is unreadable.
enum CaptureFramePicker {
    /// How often a frame is kept.
    static let interval: TimeInterval = 0.25
    /// Frames kept, newest last: a little over the hold.
    static let capacity = 5
    /// Auto-capture looks back over the hold, the stretch the scan confirmed a good
    /// card in.
    static let captureWindow: TimeInterval = 1.2
    /// The manual shutter looks back only this far: the photo is the moment it was
    /// pressed.
    static let shutterWindow: TimeInterval = 0.5
    /// Extra frames sent with a photo.
    static let extraCount = 2
    /// Extras are at least this far from the photo and from each other: frames
    /// close together share the same motion blur.
    static let minimumGap: TimeInterval = 0.2
    /// JPEG quality for extra frames.
    static let extraJPEGQuality = 0.92
    /// A kept frame replaces the full-resolution still only when it is at least this
    /// many times sharper: the still's resolution is worth more for small print,
    /// unless it was taken mid-movement.
    static let stillReplacementFactor = 1.5

    /// The best frame and the extras among `candidates` for a photo taken at `now`.
    ///
    /// The best frame is the sharpest of the last `window` seconds (the newest on a
    /// tie, and the newest when none is scored); the extras are the next sharpest,
    /// each at least `gap` from the best frame and from each other.
    static func pick<Frame>(
        _ candidates: [BufferedFrame<Frame>], now: TimeInterval,
        window: TimeInterval = captureWindow, gap: TimeInterval = minimumGap,
        count: Int = extraCount
    ) -> (main: BufferedFrame<Frame>?, extras: [BufferedFrame<Frame>]) {
        let ranked =
            candidates
            .filter { now - $0.time <= window + 1e-9 }
            .sorted { a, b in
                let sa = a.sharpness ?? -1
                let sb = b.sharpness ?? -1
                return sa != sb ? sa > sb : a.time > b.time
            }
        guard let main = ranked.first else { return (nil, []) }
        var extras: [BufferedFrame<Frame>] = []
        for candidate in ranked.dropFirst() {
            guard extras.count < count else { break }
            let spaced = ([main] + extras).allSatisfy {
                abs($0.time - candidate.time) >= gap - 1e-9
            }
            if spaced { extras.append(candidate) }
        }
        return (main, extras)
    }

    /// Whether the sharpest kept frame should replace the still as the photo: only
    /// when both were scored and the frame is at least `stillReplacementFactor`
    /// times sharper.
    static func prefersKeptFrame(stillSharpness: Double?, keptSharpness: Double?) -> Bool {
        guard let stillSharpness, let keptSharpness, stillSharpness >= 0 else { return false }
        return keptSharpness >= stillSharpness * stillReplacementFactor
    }
}
