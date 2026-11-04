// DeepIDV › DocumentScanner › Classifier

import CoreGraphics
import CoreImage
import CoreVideo
import DeepIDVCore
import Foundation
import ImageIO

/// A frame cut out and copied for the classifier, so the camera's buffer goes
/// straight back to its pool. `@unchecked Sendable`: a `CGImage` is immutable.
struct PreparedFrame: @unchecked Sendable {
    let image: CGImage?
    /// Lets test doubles tell frames apart without pixels.
    let tag: Int
}

/// The image work behind the classifier: all of it runs off the main actor.
protocol ClassifierImaging: Sendable {
    /// Cuts the card out of `frame` and copies it, at most `ClassifierImages.detectSide`
    /// pixels on the longest side. `box` is Vision's normalized box; without one the
    /// middle of the frame is used.
    func prepare(_ frame: CameraFrame, box: CGRect?) -> PreparedFrame?
    /// The prepared frame turned by `rotation` degrees (0 or 180), as base64 JPEG.
    func detectImage(_ frame: PreparedFrame, rotation: Int) -> String?
    /// A frame kept as a candidate photo: perspective-corrected, at most 2000 px.
    func keptFrame(_ frame: CameraFrame) -> FileInput?
    /// The photo's sharpness on the same scale as the video frames, which are
    /// `frameWidth` pixels wide. `nil` when it can't be measured.
    func sharpness(of photo: FileInput, frameWidth: Int) -> Double?
    /// The photo turned 180°.
    func turnedOver(_ photo: FileInput) -> FileInput?
}

enum ClassifierImages {
    /// Longest side of a frame sent to the classifier. Never upscaled.
    static let detectSide: CGFloat = 1280
    /// JPEG quality of a frame sent to the classifier.
    static let detectQuality: CGFloat = 0.8
    /// The margin added around Vision's box, as a share of the box on each side.
    static let detectMargin: CGFloat = 0.25
    /// Longest side of a kept frame.
    static let keptSide: CGFloat = DocumentImageProcessor.defaultMaxDimension

    /// The crop for the classifier, in normalized bottom-left coordinates: the box
    /// grown by the margin and clamped, or a card-shaped area in the middle.
    static func cropRect(box: CGRect?, frameAspect: CGFloat) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let box, box.width > 0, box.height > 0 else {
            // A card across 90% of the width, in a frame `frameAspect` (w/h) wide.
            let width: CGFloat = 0.9
            let height = min(1, width * frameAspect / 1.586)
            return CGRect(x: 0.05, y: (1 - height) / 2, width: width, height: height)
        }
        return box.insetBy(dx: -box.width * detectMargin, dy: -box.height * detectMargin)
            .intersection(unit)
    }

    /// The bytes of a photo.
    static func data(of input: FileInput) -> Data? {
        switch input {
        case .data(let data): return data
        case .fileURL(let url): return try? Data(contentsOf: url)
        case .base64(let string): return Data(base64Encoded: string)
        @unknown default: return nil
        }
    }
}

/// The live image work, with Core Image.
struct CoreImageClassifierImaging: ClassifierImaging {
    private static let context = CIContext()

    func prepare(_ frame: CameraFrame, box: CGRect?) -> PreparedFrame? {
        guard let pixelBuffer = frame.pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let unit = ClassifierImages.cropRect(box: box, frameAspect: extent.width / extent.height)
        let crop = CGRect(
            x: extent.minX + unit.minX * extent.width, y: extent.minY + unit.minY * extent.height,
            width: unit.width * extent.width, height: unit.height * extent.height
        ).integral
        var cut = image.cropped(to: crop)
        let target = DocumentImageProcessor.scaledSize(
            for: cut.extent.size, maxDimension: ClassifierImages.detectSide)
        if target != .zero, target.width < cut.extent.width {
            let scale = target.width / cut.extent.width
            cut = cut.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        // Rendering copies the pixels, so the camera buffer is released here.
        guard let cgImage = Self.context.createCGImage(cut, from: cut.extent) else { return nil }
        return PreparedFrame(image: cgImage, tag: frame.index)
    }

    func detectImage(_ frame: PreparedFrame, rotation: Int) -> String? {
        guard let cgImage = frame.image else { return nil }
        var image = CIImage(cgImage: cgImage)
        if rotation == 180 { image = image.oriented(.down) }
        return jpeg(image, quality: ClassifierImages.detectQuality)?.base64EncodedString()
    }

    func keptFrame(_ frame: CameraFrame) -> FileInput? {
        guard let pixelBuffer = frame.pixelBuffer else { return nil }
        let quad = VisionDocumentFrameEvaluator.detectQuad(in: pixelBuffer)
        return try? DocumentImageProcessor.process(
            pixelBuffer, correctingTo: quad, maxDimension: ClassifierImages.keptSide,
            jpegQuality: CaptureFramePicker.extraJPEGQuality)
    }

    func sharpness(of photo: FileInput, frameWidth: Int) -> Double? {
        guard frameWidth > 0, let data = ClassifierImages.data(of: photo),
            var image = CIImage(data: data, options: [.applyOrientationProperty: true])
        else { return nil }
        // Scale to the video frames' width, so both are scored on the same grid.
        let scale = CGFloat(frameWidth) / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = Int(image.extent.width.rounded())
        let height = Int(image.extent.height.rounded())
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes,
                &buffer) == kCVReturnSuccess, let buffer
        else { return nil }
        Self.context.render(
            image.transformed(
                by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)),
            to: buffer)
        let box =
            VisionDocumentFrameEvaluator.detectObservation(in: buffer)?.boundingBox
            ?? CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        let score = VisionDocumentFrameEvaluator.sharpnessAndGlare(in: buffer, boundingBox: box)
            .sharpness
        return score > 0 ? score : nil
    }

    func turnedOver(_ photo: FileInput) -> FileInput? {
        guard let data = ClassifierImages.data(of: photo),
            let image = CIImage(data: data, options: [.applyOrientationProperty: true])
        else { return nil }
        let turned = image.oriented(.down)
        return jpeg(turned, quality: CaptureFramePicker.extraJPEGQuality).map(FileInput.data)
    }

    private func jpeg(_ image: CIImage, quality: CGFloat) -> Data? {
        let moved = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let options = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality
        ]
        return Self.context.jpegRepresentation(
            of: moved, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: options)
    }
}
