// DeepIDV › DocumentScanner › Capture

import CoreGraphics
import CoreImage
import CoreVideo
import DeepIDVCore
import Vision

/// Turns a captured ``CameraFrame`` into the upload-ready ``FileInput`` the headless
/// `scanDocument` method consumes.
///
/// The seam that lets the capture coordinator be driven in tests: the live
/// implementation (``DocumentStillEncoder``) does Core Image work over the camera's
/// pixel buffer and is iOS-only, while tests inject a fake that returns canned
/// bytes. A failure surfaces as a non-retryable `.captureFailed` ``DeepIDVError``.
protocol DocumentStillEncoding: Sendable {
    func encode(_ frame: CameraFrame, documentType: DocumentType) throws -> FileInput
}

/// The live still encoder: re-detects the document quad on the captured frame,
/// then perspective-corrects, downscales, and JPEG-encodes via
/// ``DocumentImageProcessor`` (iOS-only).
///
/// The photo uploaded is the document, not the whole camera view. With the
/// front camera the person holding the card is often in view behind it, and a
/// face beside the card can be matched in place of the card's portrait by the
/// server's face checks. Only when no plausible document is found is the frame
/// sent whole.
struct DocumentStillEncoder: DocumentStillEncoding {
    var maxDimension: CGFloat = DocumentImageProcessor.defaultMaxDimension
    var jpegQuality: CGFloat = DocumentImageProcessor.defaultJPEGQuality

    func encode(_ frame: CameraFrame, documentType: DocumentType) throws -> FileInput {
        // High-res photo path: a full-resolution, upright JPEG, cropped to the
        // document found in it.
        if let data = frame.imageData {
            return Self.croppedToDocument(data, maxDimension: maxDimension, jpegQuality: jpegQuality)
                ?? .data(data)
        }

        // Fallback: process the streamed (upright) video pixel buffer. Re-run
        // detection so the crop matches what the user saw locked in the
        // viewfinder; `nil` simply skips perspective correction.
        guard let pixelBuffer = frame.pixelBuffer else {
            throw DeepIDVError.captureFailed("The captured frame held no image data.")
        }
        let quad = VisionDocumentFrameEvaluator.detectQuad(in: pixelBuffer)
        return try DocumentImageProcessor.process(
            pixelBuffer, correctingTo: quad,
            maxDimension: maxDimension, jpegQuality: jpegQuality)
    }
}

// MARK: - Cropping the full-resolution still

extension DocumentStillEncoder {
    /// Room left around the document, as a share of its size, so a corner
    /// detected a little inside the card never cuts text off.
    static let cropMargin: CGFloat = 0.04
    /// The least share of the photo a detected document must cover to be
    /// trusted as the card rather than something else in view.
    static let minimumCropArea: CGFloat = 0.12
    /// The widest long-side to short-side ratio taken as a document: an ID
    /// card is 1.59, an open passport about 1.1 to 1.45.
    static let maximumCropAspect: CGFloat = 2.2

    /// `data` cropped and straightened to the document in it, with
    /// ``cropMargin`` around it, or `nil` when no plausible document is found
    /// or the image can't be read, so the caller sends it whole.
    static func croppedToDocument(_ data: Data, maxDimension: CGFloat, jpegQuality: CGFloat) -> FileInput? {
        guard let image = CIImage(data: data) else { return nil }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard let observation = VisionDocumentFrameEvaluator.detectObservation(using: handler) else {
            return nil
        }
        let quad = DocumentQuad(
            topLeft: observation.topLeft, topRight: observation.topRight,
            bottomLeft: observation.bottomLeft, bottomRight: observation.bottomRight)
        let size = image.extent.size
        guard isPlausibleDocument(quad, in: size) else { return nil }
        return try? DocumentImageProcessor.process(
            image, correctingTo: expanded(quad, by: cropMargin),
            maxDimension: maxDimension, jpegQuality: jpegQuality)
    }

    /// Whether `quad` (normalized) is big enough and shaped like a document in
    /// an image of `size`.
    static func isPlausibleDocument(_ quad: DocumentQuad, in size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft].map {
            CGPoint(x: $0.x * size.width, y: $0.y * size.height)
        }
        // Shoelace area, as a share of the image.
        var twiceArea: CGFloat = 0
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            twiceArea += a.x * b.y - b.x * a.y
        }
        let share = abs(twiceArea) / 2 / (size.width * size.height)
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let horizontal = (length(points[0], points[1]) + length(points[3], points[2])) / 2
        let vertical = (length(points[0], points[3]) + length(points[1], points[2])) / 2
        guard horizontal > 0, vertical > 0 else { return false }
        let aspect = max(horizontal, vertical) / min(horizontal, vertical)
        return share >= minimumCropArea && aspect <= maximumCropAspect
    }

    /// `quad` grown away from its centre by `fraction` of its size on each
    /// axis, kept inside the image.
    static func expanded(_ quad: DocumentQuad, by fraction: CGFloat) -> DocumentQuad {
        let corners = [quad.topLeft, quad.topRight, quad.bottomLeft, quad.bottomRight]
        let centre = CGPoint(
            x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        func grow(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: min(1, max(0, centre.x + (p.x - centre.x) * (1 + fraction))),
                y: min(1, max(0, centre.y + (p.y - centre.y) * (1 + fraction))))
        }
        return DocumentQuad(
            topLeft: grow(quad.topLeft), topRight: grow(quad.topRight),
            bottomLeft: grow(quad.bottomLeft), bottomRight: grow(quad.bottomRight))
    }
}
