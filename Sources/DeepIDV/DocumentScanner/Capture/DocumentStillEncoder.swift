// DeepIDV › DocumentScanner › Capture

import CoreGraphics
import CoreImage
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
    /// `window` is the capture frame drawn on screen when the photo was taken,
    /// `nil` when it isn't known.
    func encode(_ frame: CameraFrame, documentType: DocumentType, window: CaptureWindow?) throws
        -> FileInput
}

/// The capture frame drawn over the camera preview: its rectangle in the
/// screen's normalized space (0–1, origin top-left), and the screen's
/// width ÷ height. The preview fills the screen, cropping the camera's view to
/// the screen's shape.
struct CaptureWindow: Sendable, Equatable {
    var rect: CGRect
    var screenAspect: Double
}

/// The live still encoder: crops the captured photo to the capture frame the
/// user lined the document up in, and JPEG-encodes it via
/// ``DocumentImageProcessor`` (iOS-only).
///
/// The photo uploaded is what was inside the frame on screen, not the whole
/// camera view. With the front camera the person holding the card is often in
/// view behind it, and a face beside the card can be matched in place of the
/// card's portrait by the server's face checks. The crop is a plain cut of the
/// camera's pixels: nothing is straightened, rotated or enlarged. Only when the
/// frame isn't known is the photo sent whole.
struct DocumentStillEncoder: DocumentStillEncoding {
    /// The longest side uploaded: a 12 MP photo's (``PhotoSize/maxPixels``),
    /// so a cut of the photo keeps every pixel the camera took.
    static let stillMaxDimension: CGFloat = 4032
    var maxDimension: CGFloat = stillMaxDimension
    /// The full-resolution photo is re-encoded close to the camera's own quality.
    var stillJPEGQuality: CGFloat = 0.92
    var jpegQuality: CGFloat = DocumentImageProcessor.defaultJPEGQuality

    func encode(_ frame: CameraFrame, documentType: DocumentType, window: CaptureWindow?) throws
        -> FileInput
    {
        // High-res photo path: a full-resolution JPEG, cut to the frame. The
        // camera stores it sensor-side up with an orientation tag (a portrait
        // screen's photo is landscape pixels tagged "turn 90°"), so it is turned
        // upright first, as the screen showed it.
        if let data = frame.imageData {
            guard let window,
                let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
                let crop = Self.cropRect(for: window, in: image.extent)
            else { return .data(data) }
            return try DocumentImageProcessor.process(
                image.cropped(to: crop), maxDimension: maxDimension, jpegQuality: stillJPEGQuality)
        }

        // Fallback: the streamed (upright) video pixel buffer, cut to the frame
        // too, or straightened to the document detected in it when the frame
        // isn't known.
        guard let pixelBuffer = frame.pixelBuffer else {
            throw DeepIDVError.captureFailed("The captured frame held no image data.")
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        if let window, let crop = Self.cropRect(for: window, in: image.extent) {
            return try DocumentImageProcessor.process(
                image.cropped(to: crop), maxDimension: maxDimension, jpegQuality: jpegQuality)
        }
        let quad = VisionDocumentFrameEvaluator.detectQuad(in: pixelBuffer)
        return try DocumentImageProcessor.process(
            pixelBuffer, correctingTo: quad,
            maxDimension: maxDimension, jpegQuality: jpegQuality)
    }
}

// MARK: - Cutting the photo to the frame

extension DocumentStillEncoder {
    /// Room kept around the frame on each side, as a share of its size, so a
    /// card held a little larger than the frame keeps its edges.
    static let windowMargin: CGFloat = 0.08

    /// The part of an image with `extent` (Core Image space, origin
    /// bottom-left) that was inside `window` on screen, grown by
    /// ``windowMargin`` and kept inside the image. `nil` when the image and the
    /// screen are turned differently (one landscape, one portrait), as then the
    /// screen didn't show this image the way it is stored.
    static func cropRect(for window: CaptureWindow, in extent: CGRect) -> CGRect? {
        guard extent.width > 0, extent.height > 0, window.screenAspect > 0,
            window.rect.width > 0, window.rect.height > 0
        else { return nil }
        let imageAspect = Double(extent.width / extent.height)
        guard (imageAspect >= 1) == (window.screenAspect >= 1) else { return nil }

        let r = window.rect.insetBy(
            dx: -window.rect.width * windowMargin, dy: -window.rect.height * windowMargin)
        // Aspect-fill: the screen shows the image's full height and the middle of
        // its width when the image is wider than the screen, and the reverse.
        var x = r.minX, y = r.minY, width = r.width, height = r.height
        if imageAspect > window.screenAspect {
            let visible = CGFloat(window.screenAspect / imageAspect)
            x = 0.5 + (x - 0.5) * visible
            width *= visible
        } else {
            let visible = CGFloat(imageAspect / window.screenAspect)
            y = 0.5 + (y - 0.5) * visible
            height *= visible
        }
        // Screen space runs top-down, Core Image bottom-up.
        let pixels = CGRect(
            x: extent.minX + x * extent.width,
            y: extent.minY + (1 - y - height) * extent.height,
            width: width * extent.width, height: height * extent.height
        ).integral.intersection(extent)
        return pixels.isEmpty ? nil : pixels
    }
}
