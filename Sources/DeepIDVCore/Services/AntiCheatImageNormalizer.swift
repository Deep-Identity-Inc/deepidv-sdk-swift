// DeepIDVCore › Services

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fits an anti-cheat image under the endpoint's JSON body cap.
///
/// The capture layer can emit full-resolution stills (several MB), and
/// headless callers hand `checkAntiCheat` arbitrary photos — but the endpoint
/// takes inline base64 under a 5 MB body limit, and face dedup doesn't need
/// 12 MP. Images that already fit pass through **byte-identical** (no silent
/// re-encode); oversized ones are downscaled through a fixed rung ladder and
/// JPEG-re-encoded until they fit. Only data that is oversized *and* not a
/// decodable image — or that no rung can shrink enough — fails, as the same
/// `.validation` the pre-flight guard always threw.
enum AntiCheatImageNormalizer {
    /// Ceiling for the first downscale attempt; face matching is comfortable
    /// well below it.
    private static let firstRungCeiling = 2048
    /// Below this the image is useless for face matching — give up instead.
    private static let smallestRung = 64
    private static let jpegQuality: CGFloat = 0.8

    /// Returns `data` unchanged when its base64 form fits `maxBase64Bytes`;
    /// otherwise a downscaled JPEG re-encode that fits. Throws `.validation`
    /// when the data can't be decoded as an image or can't be shrunk enough.
    package static func normalize(_ data: Data, maxBase64Bytes: Int) throws -> Data {
        guard base64Size(of: data) > maxBase64Bytes else { return data }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else {
            throw DeepIDVError.validation(
                "Image is too large for the anti-cheat check and could not be "
                    + "decoded for downscaling — the base64 payload must stay under "
                    + "the API's 5 MB body limit.")
        }

        // Halving ladder from the source's own longest side (capped at the
        // ceiling), so any input — even an already-small one — keeps shrinking
        // until it fits or drops below the useful floor.
        var maxDimension = min(firstRungCeiling, longestSide(of: source) ?? firstRungCeiling)
        while maxDimension >= smallestRung {
            defer { maxDimension /= 2 }
            // `WithTransform` bakes in the EXIF orientation, so the re-encode
            // stays upright without carrying metadata.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            ]
            guard
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source, 0, options as CFDictionary),
                let encoded = encodeJPEG(thumbnail, quality: jpegQuality)
            else { continue }
            if base64Size(of: encoded) <= maxBase64Bytes { return encoded }
        }

        throw DeepIDVError.validation(
            "Image is too large for the anti-cheat check — downscaling could not "
                + "bring the base64 payload under the API's 5 MB body limit.")
    }

    /// JPEG-encodes a `CGImage` via ImageIO. Package-visible so tests build
    /// their fixtures through the same stack production encodes with.
    package static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Exact base64 length for `count` raw bytes (4 output bytes per 3 input,
    /// padded) — computed without materializing the encoding.
    private static func base64Size(of data: Data) -> Int {
        (data.count + 2) / 3 * 4
    }

    /// The source's longest pixel side, read from its properties without
    /// decoding the bitmap.
    private static func longestSide(of source: CGImageSource) -> Int? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return max(width, height)
    }
}
