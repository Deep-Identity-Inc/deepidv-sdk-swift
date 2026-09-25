import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import DeepIDVCore

// The anti-cheat image normalizer: images whose base64 form fits the cap pass
// through byte-identical; oversized ones are downscaled/re-encoded until they
// fit; oversized non-images still fail as `.validation`.

/// Renders a noise image (noise defeats JPEG compression, keeping files big)
/// and JPEG-encodes it via the same ImageIO stack production uses.
private func noiseJPEG(side: Int) -> Data {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    for i in pixels.indices {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        pixels[i] = UInt8(truncatingIfNeeded: seed >> 33)
    }
    let context = CGContext(
        data: &pixels, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let image = context.makeImage()!
    return AntiCheatImageNormalizer.encodeJPEG(image, quality: 0.9)!
}

private func base64Size(of data: Data) -> Int {
    (data.count + 2) / 3 * 4
}

@Test func passesSmallDataThroughByteIdentical() throws {
    let original = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])  // fits any cap
    let result = try AntiCheatImageNormalizer.normalize(original, maxBase64Bytes: 1_000)
    #expect(result == original)
}

@Test func downscalesOversizedImageUnderTheCap() throws {
    let original = noiseJPEG(side: 800)
    let cap = base64Size(of: original) / 4  // force at least one downscale rung

    let result = try AntiCheatImageNormalizer.normalize(original, maxBase64Bytes: cap)

    #expect(base64Size(of: result) <= cap)
    // Still a decodable image, and genuinely smaller than the original frame.
    let source = CGImageSourceCreateWithData(result as CFData, nil)
    let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    #expect(decoded != nil)
    #expect((decoded?.width ?? .max) < 800)
}

@Test func oversizedNonImageDataThrowsValidation() {
    let junk = Data(count: 100_000)  // zeros — not a decodable image
    do {
        _ = try AntiCheatImageNormalizer.normalize(junk, maxBase64Bytes: 1_000)
        Issue.record("expected .validation")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    } catch {
        Issue.record("expected DeepIDVError, got \(error)")
    }
}

@Test func impossibleCapThrowsValidation() {
    let original = noiseJPEG(side: 800)
    do {
        // No downscale rung can fit a real JPEG into 32 base64 bytes.
        _ = try AntiCheatImageNormalizer.normalize(original, maxBase64Bytes: 32)
        Issue.record("expected .validation")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    } catch {
        Issue.record("expected DeepIDVError, got \(error)")
    }
}
