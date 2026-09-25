import CoreGraphics
import Testing

@testable import DeepIDV

// The post-processor's sizing rule is pure arithmetic, so it's pinned in a plain
// unit test; the Core Image crop/encode it feeds is exercised on-device.

@Test func downscalesALargeLandscapeImageUnderTheCap() {
    let scaled = DocumentImageProcessor.scaledSize(
        for: CGSize(width: 4000, height: 3000), maxDimension: 2000)
    #expect(scaled == CGSize(width: 2000, height: 1500))
}

@Test func downscalesALargePortraitImageUnderTheCap() {
    let scaled = DocumentImageProcessor.scaledSize(
        for: CGSize(width: 3000, height: 4000), maxDimension: 2000)
    #expect(scaled == CGSize(width: 1500, height: 2000))
}

@Test func downscalesASquareImageOnBothEdges() {
    let scaled = DocumentImageProcessor.scaledSize(
        for: CGSize(width: 4000, height: 4000), maxDimension: 2000)
    #expect(scaled == CGSize(width: 2000, height: 2000))
}

@Test func neverUpscalesASmallImage() {
    let size = CGSize(width: 1000, height: 800)
    let scaled = DocumentImageProcessor.scaledSize(for: size, maxDimension: 2000)
    #expect(scaled == size)
}

@Test func aSizeExactlyAtTheCapIsUnchanged() {
    let size = CGSize(width: 2000, height: 1200)
    let scaled = DocumentImageProcessor.scaledSize(for: size, maxDimension: 2000)
    #expect(scaled == size)
}

@Test func degenerateInputsReturnZeroRatherThanDividingByZero() {
    #expect(DocumentImageProcessor.scaledSize(for: .zero, maxDimension: 2000) == .zero)
    #expect(
        DocumentImageProcessor.scaledSize(
            for: CGSize(width: 100, height: 100), maxDimension: 0) == .zero)
}
