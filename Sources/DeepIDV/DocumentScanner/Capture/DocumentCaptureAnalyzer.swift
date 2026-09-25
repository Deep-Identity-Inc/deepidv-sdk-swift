// DeepIDV › DocumentScanner › Capture

import CoreGraphics
import CoreVideo
import DeepIDVCore
import Vision

/// Decides *when* to auto-capture a document, from a stream of per-frame
/// ``CaptureQuality`` metrics.
///
/// This is the pure heart of the capture pipeline.
/// It holds no camera, no Vision, no pixels — only the gating thresholds and a
/// small amount of stability state — so the whole "is this frame good enough"
/// decision unit-tests without a device. The impure half (turning a
/// live frame into ``CaptureQuality``) lives behind ``DocumentFrameEvaluating``
/// and is iOS-only.
///
/// `assess(_:)` is the stateless per-frame gate check; `evaluate(_:)` layers the
/// N-consecutive-frame stability rule on top and is what the capture loop calls.
/// It's a `struct` with `mutating` state (the streak counter) rather than a class
/// so a test can replay a scripted sequence deterministically and inspect it.
struct DocumentCaptureAnalyzer: Sendable {
    /// The document type being captured — selects the target aspect-ratio band.
    let documentType: DocumentType
    /// The gating thresholds.
    let tunables: DocumentCaptureTunables

    /// Consecutive fully-passing frames seen so far. Exposed read-only for tests
    /// and overlay debugging; reset to zero whenever a gate fails.
    private(set) var consecutiveGoodFrames = 0

    /// The previous frame's document centre, for inter-frame motion (jitter) detection.
    private var previousCenter: CGPoint?

    init(documentType: DocumentType, tunables: DocumentCaptureTunables = .init()) {
        self.documentType = documentType
        self.tunables = tunables
    }

    /// Pure per-frame gate check. Returns `nil` when every gate passes for this
    /// frame, or the first failing gate's guidance otherwise.
    ///
    /// Gates are checked most-fundamental-first so the returned hint is the one
    /// worth showing: there's no point telling the user to "hold steady" when we
    /// can't even see a document, or to "reduce glare" on a frame that's the wrong
    /// shape entirely. Carries no state, so it's trivially testable in isolation.
    func assess(_ quality: CaptureQuality) -> CaptureGuidance? {
        guard quality.documentDetected else { return .searching }
        if quality.fillRatio < tunables.minFillRatio { return .moveCloser }
        if !aspectMatches(quality.aspectRatio) { return .fitDocumentInFrame }
        if quality.glareRatio > tunables.maxGlareRatio { return .reduceGlare }
        if quality.sharpness < tunables.minSharpness { return .holdSteady }
        return nil
    }

    /// Feeds one frame's metrics through the gates and the stability counter,
    /// returning whether to capture now or what guidance to show.
    ///
    /// A passing frame increments the streak; reaching `stabilityFrameCount`
    /// returns `.capture`. Any failing frame resets the streak to zero (so a lone
    /// good frame in the middle of camera shake never trips the shutter) and
    /// returns that gate's guidance. A passing-but-not-yet-stable frame asks the
    /// user to hold steady.
    mutating func evaluate(_ quality: CaptureQuality) -> CaptureDecision {
        if let failure = assess(quality) {
            consecutiveGoodFrames = 0
            previousCenter = quality.center
            return .guide(failure)
        }
        // Every per-frame gate passes — but also require the document to be holding
        // still between frames. A slow pan while aligning keeps each frame "good"
        // yet drifts; without this the count-only streak would lock mid-movement
        // (blurry / off-centre). A `nil` centre (tests/previews) skips the check.
        if let previous = previousCenter, let current = quality.center,
            Self.distance(previous, current) > tunables.maxCenterJitter
        {
            consecutiveGoodFrames = 0
            previousCenter = current
            return .guide(.holdSteady)
        }
        previousCenter = quality.center
        consecutiveGoodFrames += 1
        if consecutiveGoodFrames >= tunables.stabilityFrameCount {
            return .capture
        }
        return .guide(.holdSteady)
    }

    /// Euclidean distance between two normalized points.
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Resets the stability streak — call when restarting capture (e.g. after the
    /// "Flip your card" transition between the front and back of a two-sided doc).
    mutating func reset() {
        consecutiveGoodFrames = 0
        previousCenter = nil
    }

    // MARK: - Aspect-ratio band

    /// Whether `ratio` (longer ÷ shorter side, ≥ 1) is within tolerance of the
    /// target shape for the selected document type.
    private func aspectMatches(_ ratio: Double) -> Bool {
        Self.aspectTargets(for: documentType)
            .contains { abs(ratio - $0) <= tunables.aspectTolerance }
    }

    /// Target long/short aspect ratio(s) per type. `.auto` accepts either shape
    /// since the side count is unknown — but note the picker never offers `.auto`
    /// to a capture flow, so in practice this is passport-or-card.
    /// - ID-1 (card / driver's licence / most national IDs): 85.6 × 53.98 mm ≈ 1.586
    /// - ID-3 (passport data page): 125 × 88 mm ≈ 1.42
    static func aspectTargets(for type: DocumentType) -> [Double] {
        switch type {
        case .passport: return [1.42]
        case .idCard, .driversLicense: return [1.586]
        case .auto: return [1.42, 1.586]
        }
    }
}

// MARK: - Frame → quality seam

/// Turns a raw ``CameraFrame`` into ``CaptureQuality`` metrics.
///
/// The boundary between impure measurement and pure gating. The live
/// implementation (``VisionDocumentFrameEvaluator``) runs Vision over the pixel
/// buffer and is iOS-only; ``PassthroughFrameEvaluator`` reads a frame's scripted
/// quality so tests and SwiftUI previews drive the analyzer with no camera.
protocol DocumentFrameEvaluating: Sendable {
    func quality(of frame: CameraFrame, for type: DocumentType) -> CaptureQuality
}

/// Reads ``CameraFrame/syntheticQuality`` straight through — the no-camera path
/// for tests and previews. Falls back to "no document detected" for a frame that
/// carries no scripted quality, which is the safe default (asks the user to bring
/// a document into view rather than spuriously capturing).
struct PassthroughFrameEvaluator: DocumentFrameEvaluating {
    func quality(of frame: CameraFrame, for type: DocumentType) -> CaptureQuality {
        frame.syntheticQuality ?? CaptureQuality(documentDetected: false)
    }
}

/// Measures ``CaptureQuality`` from a live camera frame using Vision plus a light
/// pixel pass. iOS-only: it needs `CVPixelBuffer` access and the Vision
/// document detectors, none of which are exercised by the test suite.
///
/// - Document quad: `VNDetectDocumentSegmentationRequest` (iOS 15+), falling back
///   to `VNDetectRectanglesRequest` when segmentation finds nothing. Both yield a
///   `VNRectangleObservation`, so fill (bounding-box width) and aspect (edge
///   lengths) are computed the same way for either.
/// - Sharpness/glare: a strided pass over the BGRA buffer within the document's
///   bounding box — a 3×3 Laplacian variance for sharpness, and the fraction of
///   near-white pixels for glare. Strided (not every pixel) to stay real-time and
///   dependency-free.
struct VisionDocumentFrameEvaluator: DocumentFrameEvaluating {
    func quality(of frame: CameraFrame, for type: DocumentType) -> CaptureQuality {
        guard let pixelBuffer = frame.pixelBuffer else {
            return CaptureQuality(documentDetected: false)
        }

        guard let observation = Self.detectObservation(in: pixelBuffer) else {
            return CaptureQuality(documentDetected: false)
        }

        let box = observation.boundingBox  // normalized, origin bottom-left
        let fillRatio = Double(box.width)

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let aspectRatio = Self.aspectRatio(
            of: observation, pixelWidth: width, pixelHeight: height)

        let (sharpness, glareRatio) = Self.sharpnessAndGlare(
            in: pixelBuffer, boundingBox: box)

        return CaptureQuality(
            documentDetected: true,
            fillRatio: fillRatio,
            aspectRatio: aspectRatio,
            sharpness: sharpness,
            glareRatio: glareRatio,
            center: CGPoint(x: box.midX, y: box.midY))
    }

    /// Runs segmentation, falling back to rectangle detection. Shared by the
    /// per-frame metric pass and the still-capture quad lookup
    /// (``DocumentStillEncoder``), so both see the same document the same way.
    static func detectObservation(in pixelBuffer: CVPixelBuffer) -> VNRectangleObservation? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        let segmentation = VNDetectDocumentSegmentationRequest()
        if (try? handler.perform([segmentation])) != nil,
            let result = segmentation.results?.first
        {
            return result
        }

        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumConfidence = 0.6
        rectangles.maximumObservations = 1
        if (try? handler.perform([rectangles])) != nil {
            return rectangles.results?.first
        }
        return nil
    }

    /// The detected document corners as a plain ``DocumentQuad`` (Vision's
    /// normalized, bottom-left-origin space), for the still post-processor's
    /// perspective correction. `nil` when no document is found.
    static func detectQuad(in pixelBuffer: CVPixelBuffer) -> DocumentQuad? {
        guard let o = detectObservation(in: pixelBuffer) else { return nil }
        return DocumentQuad(
            topLeft: o.topLeft, topRight: o.topRight,
            bottomLeft: o.bottomLeft, bottomRight: o.bottomRight)
    }

    /// Long-side ÷ short-side of the observed quad, in pixel space (normalized
    /// corners scaled by the buffer dimensions so the ratio isn't distorted by a
    /// non-square frame).
    private static func aspectRatio(
        of observation: VNRectangleObservation, pixelWidth: Int, pixelHeight: Int
    ) -> Double {
        let w = Double(pixelWidth)
        let h = Double(pixelHeight)
        func point(_ p: CGPoint) -> (Double, Double) { (Double(p.x) * w, Double(p.y) * h) }
        func distance(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
            ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)).squareRoot()
        }
        let tl = point(observation.topLeft)
        let tr = point(observation.topRight)
        let bl = point(observation.bottomLeft)
        let br = point(observation.bottomRight)

        let topEdge = distance(tl, tr)
        let bottomEdge = distance(bl, br)
        let leftEdge = distance(tl, bl)
        let rightEdge = distance(tr, br)

        let horizontal = (topEdge + bottomEdge) / 2
        let vertical = (leftEdge + rightEdge) / 2
        guard horizontal > 0, vertical > 0 else { return 0 }
        return max(horizontal, vertical) / min(horizontal, vertical)
    }

    /// Strided BGRA pass over the document's bounding box: Laplacian-variance
    /// sharpness and near-white glare fraction. Assumes a 32-bit BGRA buffer
    /// (the format the live ``AVFoundationCameraController`` requests); other
    /// formats yield zeroed metrics, which simply keep auto-capture from firing.
    private static func sharpnessAndGlare(
        in pixelBuffer: CVPixelBuffer, boundingBox: CGRect
    ) -> (sharpness: Double, glareRatio: Double) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return (0, 0)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return (0, 0) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // Vision's bounding box is normalized with a bottom-left origin; flip Y
        // into the buffer's top-left pixel space and clamp to a safe interior.
        let minX = max(1, Int(boundingBox.minX * CGFloat(width)))
        let maxX = min(width - 2, Int(boundingBox.maxX * CGFloat(width)))
        let minY = max(1, Int((1 - boundingBox.maxY) * CGFloat(height)))
        let maxY = min(height - 2, Int((1 - boundingBox.minY) * CGFloat(height)))
        guard maxX > minX, maxY > minY else { return (0, 0) }

        // Sample on a grid so the cost is bounded regardless of resolution.
        let stride = max(2, (maxX - minX) / 160)

        func luma(_ x: Int, _ y: Int) -> Double {
            let offset = y * bytesPerRow + x * 4
            let b = Double(ptr[offset])
            let g = Double(ptr[offset + 1])
            let r = Double(ptr[offset + 2])
            return 0.299 * r + 0.587 * g + 0.114 * b
        }

        var laplacians: [Double] = []
        var brightCount = 0
        var sampleCount = 0
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let center = luma(x, y)
                // 4-neighbour Laplacian: high magnitude at sharp edges.
                let lap =
                    luma(x - 1, y) + luma(x + 1, y) + luma(x, y - 1) + luma(x, y + 1)
                    - 4 * center
                laplacians.append(lap)
                if center >= 245 { brightCount += 1 }
                sampleCount += 1
                x += stride
            }
            y += stride
        }
        guard sampleCount > 0 else { return (0, 0) }

        let mean = laplacians.reduce(0, +) / Double(laplacians.count)
        let variance =
            laplacians.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(laplacians.count)
        let glareRatio = Double(brightCount) / Double(sampleCount)
        return (variance, glareRatio)
    }
}
