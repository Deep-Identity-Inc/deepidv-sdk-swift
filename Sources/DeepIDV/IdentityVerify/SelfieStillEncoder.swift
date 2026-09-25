// DeepIDV › IdentityVerify

import CoreGraphics
import CoreVideo
import DeepIDVCore

/// Turns a captured selfie ``CameraFrame`` into the upload-ready ``FileInput``.
///
/// The selfie counterpart to ``DocumentStillEncoding``: the live
/// implementation is iOS-only Core Image work; tests inject a fake returning
/// canned bytes. Unlike the document encoder there's no quad to crop to — a selfie
/// is just downscaled and JPEG-encoded.
protocol SelfieStillEncoding: Sendable {
    func encode(_ frame: CameraFrame) throws -> FileInput
}

/// The live selfie encoder: downscales and JPEG-encodes the captured frame via
/// ``DocumentImageProcessor`` with no perspective correction (iOS-only).
struct SelfieStillEncoder: SelfieStillEncoding {
    var maxDimension: CGFloat = DocumentImageProcessor.defaultMaxDimension
    var jpegQuality: CGFloat = DocumentImageProcessor.defaultJPEGQuality

    func encode(_ frame: CameraFrame) throws -> FileInput {
        // High-res photo path: a full-resolution, already-upright JPEG.
        if let data = frame.imageData { return .data(data) }

        // Fallback: downscale/encode the streamed (upright) video pixel buffer.
        guard let pixelBuffer = frame.pixelBuffer else {
            throw DeepIDVError.captureFailed("The captured frame held no image data.")
        }
        return try DocumentImageProcessor.process(
            pixelBuffer, correctingTo: nil,
            maxDimension: maxDimension, jpegQuality: jpegQuality)
    }
}
