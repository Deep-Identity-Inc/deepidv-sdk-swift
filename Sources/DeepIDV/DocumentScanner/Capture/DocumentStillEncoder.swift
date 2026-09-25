// DeepIDV › DocumentScanner › Capture

import CoreGraphics
import CoreVideo
import DeepIDVCore

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
struct DocumentStillEncoder: DocumentStillEncoding {
    var maxDimension: CGFloat = DocumentImageProcessor.defaultMaxDimension
    var jpegQuality: CGFloat = DocumentImageProcessor.defaultJPEGQuality

    func encode(_ frame: CameraFrame, documentType: DocumentType) throws -> FileInput {
        // High-res photo path: a full-resolution, already-upright JPEG — upload
        // as-is (no downscale/crop needed; OCR benefits from the full image).
        if let data = frame.imageData { return .data(data) }

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
