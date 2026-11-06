// DeepIDVTests › DocumentScanner

import CoreGraphics
import Foundation
import CoreVideo
import DeepIDVCore
import ImageIO
import Testing
import UIKit

@testable import DeepIDV

private let photo = CGRect(x: 0, y: 0, width: 2016, height: 1512)

/// The capture frame for an ID card, as the overlay reports it on a screen of `size`.
private func window(on size: CGSize, aspect: CGFloat = 1.586) -> CaptureWindow {
    let rect = CaptureLayout.window(in: size, aspect: aspect)
    return CaptureWindow(
        rect: CGRect(
            x: rect.minX / size.width, y: rect.minY / size.height,
            width: rect.width / size.width, height: rect.height / size.height),
        screenAspect: Double(size.width / size.height))
}

private func near(_ a: CGFloat, _ b: CGFloat, within tolerance: CGFloat = 2) -> Bool {
    abs(a - b) <= tolerance
}

@Test func onAScreenShapedLikeThePhotoTheCropIsTheFrameWithItsMargin() throws {
    // A 4:3 screen shows the 4:3 photo whole.
    let frame = CaptureWindow(rect: CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.4), screenAspect: 4.0 / 3)
    let crop = try #require(DocumentStillEncoder.cropRect(for: frame, in: photo))
    let m = DocumentStillEncoder.windowMargin
    #expect(near(crop.width, 2016 * 0.6 * (1 + 2 * m)))
    #expect(near(crop.height, 1512 * 0.4 * (1 + 2 * m)))
    #expect(near(crop.midX, 2016 * 0.5))
    // Core Image runs bottom-up: the frame's centre, 0.45 down the screen, is
    // 0.55 up the photo.
    #expect(near(crop.midY, 1512 * 0.55))
}

@Test func onAWiderScreenTheCropFollowsWhatThePreviewShowed() throws {
    // A landscape iPad (1194 x 834) is wider than the 4:3 photo, so the preview
    // shows the photo's full width and the middle of its height.
    let screen = CGSize(width: 1194, height: 834)
    let frame = window(on: screen)
    let crop = try #require(DocumentStillEncoder.cropRect(for: frame, in: photo))
    let visibleHeight = 2016 / (1194.0 / 834.0)
    let scale = 2016 / screen.width
    let m = DocumentStillEncoder.windowMargin
    let drawn = CaptureLayout.window(in: screen, aspect: 1.586)
    #expect(near(crop.width, drawn.width * scale * (1 + 2 * m)))
    #expect(near(crop.height, drawn.height * scale * (1 + 2 * m)))
    // Centred across, and the frame's height stays a card's shape.
    #expect(near(crop.midX, 1008))
    #expect(near(crop.width / crop.height, 1.586, within: 0.01))
    #expect(crop.height < visibleHeight)
    // Well short of the whole photo: what's around the frame is left out.
    #expect(crop.width < 2016 * 0.8)
}

@Test func onANarrowerScreenTheSidesOfThePhotoAreLeftOut() throws {
    // A 16:10 portrait-ish shape narrower than the photo: only the middle of
    // the photo's width was on screen.
    let frame = CaptureWindow(rect: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4), screenAspect: 1.2)
    let crop = try #require(DocumentStillEncoder.cropRect(for: frame, in: photo))
    let visibleWidth = 1512 * 1.2
    let m = DocumentStillEncoder.windowMargin
    #expect(near(crop.width, visibleWidth * 0.8 * (1 + 2 * m)))
    #expect(near(crop.height, 1512 * 0.4 * (1 + 2 * m)))
    #expect(near(crop.midX, 1008))
}

@Test func theCropStaysInsideThePhoto() throws {
    let frame = CaptureWindow(rect: CGRect(x: 0, y: 0, width: 1, height: 1), screenAspect: 4.0 / 3)
    #expect(try #require(DocumentStillEncoder.cropRect(for: frame, in: photo)) == photo)
}

@Test func aPhotoTurnedDifferentlyFromTheScreenIsNotCut() {
    let portraitScreen = CaptureWindow(rect: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.3), screenAspect: 0.7)
    #expect(DocumentStillEncoder.cropRect(for: portraitScreen, in: photo) == nil)
    let degenerate = CaptureWindow(rect: .zero, screenAspect: 4.0 / 3)
    #expect(DocumentStillEncoder.cropRect(for: degenerate, in: photo) == nil)
}

/// A camera photo: a light card in front of a dark room, with a "face" beside it.
private func syntheticPhoto() -> Data {
    let renderer = UIGraphicsImageRenderer(size: photo.size, format: {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return format
    }())
    return renderer.jpegData(withCompressionQuality: 0.9) { context in
        UIColor(white: 0.12, alpha: 1).setFill()
        context.fill(photo)
        UIColor(red: 0.8, green: 0.65, blue: 0.55, alpha: 1).setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 1790, y: 100, width: 220, height: 320))
        UIColor(white: 0.95, alpha: 1).setFill()
        UIBezierPath(roundedRect: CGRect(x: 500, y: 450, width: 1000, height: 630), cornerRadius: 30).fill()
    }
}

@Test func theUploadIsTheFrameTheRightWayUpWithoutTheFaceBesideIt() throws {
    let screen = CGSize(width: 1194, height: 834)
    let frame = window(on: screen)
    let input = try DocumentStillEncoder().encode(
        CameraFrame(index: 0, imageData: syntheticPhoto()), documentType: .idCard, window: frame)
    guard case .data(let data) = input else {
        Issue.record("expected JPEG data")
        return
    }
    let image = try #require(UIImage(data: data)?.cgImage)
    let crop = try #require(DocumentStillEncoder.cropRect(for: frame, in: photo))
    // The frame's own pixels: not enlarged, not turned.
    #expect(image.width == Int(crop.width) && image.height == Int(crop.height))
    #expect(image.width > image.height)
    // The "face" at the photo's right edge is outside the cut.
    #expect(crop.maxX < 1790)
}

@Test func withoutTheFrameThePhotoIsSentAsTaken() throws {
    let original = syntheticPhoto()
    let input = try DocumentStillEncoder().encode(
        CameraFrame(index: 0, imageData: original), documentType: .idCard, window: nil)
    guard case .data(let data) = input else {
        Issue.record("expected JPEG data")
        return
    }
    #expect(data == original)
}

/// A photo as the camera stores it on a portrait screen: landscape pixels
/// tagged to be turned 90° clockwise to stand upright.
private func sensorSidePhoto() throws -> Data {
    let pixels = try #require(
        UIGraphicsImageRenderer(size: photo.size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(photo)
        }.cgImage)
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(
        destination, pixels, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test func aPortraitScreensPhotoIsTurnedUprightBeforeTheCut() throws {
    let screen = CGSize(width: 834, height: 1194)
    let frame = window(on: screen)
    let input = try DocumentStillEncoder().encode(
        CameraFrame(index: 0, imageData: try sensorSidePhoto()), documentType: .idCard, window: frame)
    guard case .data(let data) = input else {
        Issue.record("expected JPEG data")
        return
    }
    let image = try #require(UIImage(data: data)?.cgImage)
    // Cut from the upright 1512 x 2016 photo, not sent whole, and a card's shape.
    let upright = CGRect(x: 0, y: 0, width: 1512, height: 2016)
    let crop = try #require(DocumentStillEncoder.cropRect(for: frame, in: upright))
    #expect(image.width == Int(crop.width) && image.height == Int(crop.height))
    #expect(image.width > image.height)
    #expect(image.width < 1512)
}

@Test func keptVideoFramesAreCutToTheSameFrame() throws {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 1440, 1920, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    let frame = window(on: CGSize(width: 834, height: 1194))
    let kept = try #require(
        CoreImageClassifierImaging().keptFrame(CameraFrame(index: 0, pixelBuffer: pixels), window: frame))
    guard case .data(let data) = kept else {
        Issue.record("expected JPEG data")
        return
    }
    let image = try #require(UIImage(data: data)?.cgImage)
    let crop = try #require(
        DocumentStillEncoder.cropRect(for: frame, in: CGRect(x: 0, y: 0, width: 1440, height: 1920)))
    #expect(image.width == Int(crop.width) && image.height == Int(crop.height))
    #expect(image.width > image.height)
}

// MARK: Scoring the photo against the video frames

private let videoSize = CGSize(width: 720, height: 960)

@Test func aPhotoCutToTheFrameIsScaledToTheFramesWidthInTheVideo() throws {
    let frame = window(on: CGSize(width: 393, height: 852))
    let crop = try #require(
        DocumentStillEncoder.cropRect(for: frame, in: CGRect(origin: .zero, size: videoSize)))
    let cutPhoto = CGSize(width: crop.width * 2.4, height: crop.height * 2.4)
    #expect(
        ClassifierImages.scoringWidth(photoSize: cutPhoto, frameSize: videoSize, window: frame)
            == crop.width)
    #expect(crop.width < videoSize.width * 0.75)
}

@Test func aPhotoSentWholeIsScaledToTheWholeVideoWidth() {
    let frame = window(on: CGSize(width: 393, height: 852))
    let wholePhoto = CGSize(width: 3024, height: 4032)
    #expect(
        ClassifierImages.scoringWidth(photoSize: wholePhoto, frameSize: videoSize, window: frame)
            == videoSize.width)
    #expect(
        ClassifierImages.scoringWidth(photoSize: wholePhoto, frameSize: videoSize, window: nil)
            == videoSize.width)
    #expect(
        ClassifierImages.scoringWidth(photoSize: wholePhoto, frameSize: .zero, window: frame) == 0)
}

/// The same printed-looking scene, drawn at any size: small dark marks on a
/// light page, placed the same way relative to the size.
private func drawScene(in context: CGContext, size: CGSize) {
    context.setFillColor(gray: 0.9, alpha: 1)
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(gray: 0.1, alpha: 1)
    var seed: UInt64 = 7
    func next() -> CGFloat {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31)
    }
    for _ in 0..<4000 {
        context.fill(
            CGRect(
                x: next() * size.width, y: next() * size.height,
                width: size.width * 0.008, height: size.width * 0.005))
    }
}

private func sceneVideoFrame(_ size: CGSize) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    #expect(
        CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
            attributes, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let context = try #require(
        CGContext(
            data: CVPixelBufferGetBaseAddress(pixels), width: Int(size.width),
            height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue))
    drawScene(in: context, size: size)
    return pixels
}

private func scenePhoto(_ size: CGSize) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    drawScene(in: context, size: size)
    let image = try #require(context.makeImage())
    return try #require(UIImage(cgImage: image).jpegData(compressionQuality: 0.95))
}

@Test func anEquallySharpPhotoIsNotSwappedForAVideoFrame() throws {
    // An iPhone in portrait, where the frame is about two thirds of the photo's
    // width: the photo, cut to the frame, must score like the video frame of
    // the same scene, not as if it were enlarged to the whole video width.
    let frame = window(on: CGSize(width: 393, height: 852))
    let video = try sceneVideoFrame(videoSize)
    let crop = try #require(
        DocumentStillEncoder.cropRect(for: frame, in: CGRect(origin: .zero, size: videoSize)))
    let cardBox = CGRect(
        x: crop.minX / videoSize.width, y: crop.minY / videoSize.height,
        width: crop.width / videoSize.width, height: crop.height / videoSize.height)
    let kept = VisionDocumentFrameEvaluator.sharpnessAndGlare(in: video, boundingBox: cardBox)
        .sharpness

    let photo = try DocumentStillEncoder().encode(
        CameraFrame(index: 0, imageData: try scenePhoto(CGSize(width: 1512, height: 2016))),
        documentType: .idCard, window: frame)
    let imaging = CoreImageClassifierImaging()
    let still = try #require(imaging.sharpness(of: photo, frameSize: videoSize, window: frame))
    // Scored as before, at the whole video width.
    let enlarged = try #require(imaging.sharpness(of: photo, frameSize: videoSize, window: nil))

    #expect(kept > 0)
    #expect(!CaptureFramePicker.prefersKeptFrame(stillSharpness: still, keptSharpness: kept))
    #expect(still > enlarged)
}
