// DeepIDV › DocumentScanner › Capture

import CoreGraphics
import CoreImage
import DeepIDVCore
import UIKit

/// Turns a captured still into the compact JPEG ``FileInput`` the headless
/// `scanDocument` / `verifyIdentity` methods upload.
///
/// Split along the testability seam: the sizing arithmetic
/// (``scaledSize(for:maxDimension:)``) is pure, so the
/// "downscale to a sane upload size" rule is unit-tested; the actual
/// pixel work (perspective-correct to the document quad, render, JPEG-encode) is
/// iOS-only because it needs Core Image and the camera's `CVPixelBuffer`.
enum DocumentImageProcessor {
    /// Default longest-edge cap for an uploaded image. ~2000 px keeps OCR text
    /// legible while staying far under the 15 MiB presign limit.
    static let defaultMaxDimension: CGFloat = 2000

    /// Default JPEG quality — a good legibility/size trade-off for OCR.
    static let defaultJPEGQuality: CGFloat = 0.8

    /// The size that fits `size` within a `maxDimension`-sided square while
    /// preserving aspect ratio. Never upscales (a small capture is left as-is),
    /// and returns `.zero` for a degenerate input so callers don't divide by zero.
    ///
    /// Pure arithmetic — this is the piece the tests pin.
    static func scaledSize(for size: CGSize, maxDimension: CGFloat) -> CGSize {
        let longestEdge = max(size.width, size.height)
        guard longestEdge > 0, maxDimension > 0 else { return .zero }
        guard longestEdge > maxDimension else { return size }  // never upscale
        let scale = maxDimension / longestEdge
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Four corners of a detected document, in Vision's normalized space (0–1,
/// origin bottom-left). A small value type so the processor's perspective-correct
/// step doesn't depend on a Vision observation directly.
struct DocumentQuad: Sendable, Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomLeft: CGPoint
    var bottomRight: CGPoint
}

extension DocumentImageProcessor {
    /// Crops/deskews a still to `quad` (when supplied), downscales it under
    /// `maxDimension`, and JPEG-encodes it into a `FileInput` ready for upload.
    ///
    /// iOS-only — Core Image over the camera's pixel buffer. A failure to render
    /// or encode surfaces as a non-retryable `.captureFailed` ``DeepIDVError``.
    static func process(
        _ pixelBuffer: CVPixelBuffer,
        correctingTo quad: DocumentQuad? = nil,
        maxDimension: CGFloat = defaultMaxDimension,
        jpegQuality: CGFloat = defaultJPEGQuality
    ) throws -> FileInput {
        var image = CIImage(cvPixelBuffer: pixelBuffer)

        // 1. Perspective-correct to the document quad. Vision's normalized,
        //    bottom-left corners map into the image's pixel extent.
        if let quad {
            let extent = image.extent
            func denormalize(_ p: CGPoint) -> CGPoint {
                CGPoint(
                    x: extent.origin.x + p.x * extent.width,
                    y: extent.origin.y + p.y * extent.height)
            }
            let correction = CIFilter(name: "CIPerspectiveCorrection")
            correction?.setValue(image, forKey: kCIInputImageKey)
            correction?.setValue(
                CIVector(cgPoint: denormalize(quad.topLeft)), forKey: "inputTopLeft")
            correction?.setValue(
                CIVector(cgPoint: denormalize(quad.topRight)), forKey: "inputTopRight")
            correction?.setValue(
                CIVector(cgPoint: denormalize(quad.bottomLeft)), forKey: "inputBottomLeft")
            correction?.setValue(
                CIVector(cgPoint: denormalize(quad.bottomRight)), forKey: "inputBottomRight")
            if let corrected = correction?.outputImage {
                image = corrected
            }
        }

        // 2. Downscale under the max dimension (never upscales).
        let target = scaledSize(for: image.extent.size, maxDimension: maxDimension)
        if target != .zero, target != image.extent.size, image.extent.width > 0 {
            let scale = target.width / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        // 3. Render and JPEG-encode.
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw DeepIDVError.captureFailed("Unable to render the captured image.")
        }
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: jpegQuality)
        else {
            throw DeepIDVError.captureFailed("Unable to encode the captured image.")
        }
        return .data(data)
    }
}
