// DeepIDVTests › DocumentScanner

import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import DeepIDV

private let photo = CGSize(width: 2016, height: 1512)

/// A quad from pixel corners (top-left origin) to Vision's normalized,
/// bottom-left-origin space.
private func quad(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, in size: CGSize = photo)
    -> DocumentQuad
{
    func n(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
        CGPoint(x: px / size.width, y: 1 - py / size.height)
    }
    return DocumentQuad(
        topLeft: n(x, y), topRight: n(x + width, y),
        bottomLeft: n(x, y + height), bottomRight: n(x + width, y + height))
}

@Test func aCardFillingPartOfThePhotoIsADocument() {
    // A licence across half the width: about 19% of the photo, 1.59 to 1.
    #expect(DocumentStillEncoder.isPlausibleDocument(quad(x: 500, y: 450, width: 1000, height: 630), in: photo))
    // An open passport, 1.4 to 1.
    #expect(DocumentStillEncoder.isPlausibleDocument(quad(x: 400, y: 300, width: 1100, height: 785), in: photo))
    // Held upright: the aspect counts either way round.
    #expect(DocumentStillEncoder.isPlausibleDocument(quad(x: 700, y: 200, width: 630, height: 1000), in: photo))
}

@Test func somethingSmallOrLongIsNotTakenForTheDocument() {
    // A light switch: far under 12% of the photo.
    #expect(!DocumentStillEncoder.isPlausibleDocument(quad(x: 100, y: 100, width: 200, height: 300), in: photo))
    // A door frame: tall and narrow.
    #expect(!DocumentStillEncoder.isPlausibleDocument(quad(x: 800, y: 0, width: 500, height: 1500), in: photo))
    #expect(!DocumentStillEncoder.isPlausibleDocument(quad(x: 0, y: 0, width: 0, height: 0), in: photo))
}

@Test func theCropGrowsEvenlyAroundTheCardAndStaysInThePhoto() {
    let card = quad(x: 500, y: 450, width: 1000, height: 630)
    let grown = DocumentStillEncoder.expanded(card, by: 0.04)
    // 4% wider and taller, about the same centre.
    #expect(abs((grown.topRight.x - grown.topLeft.x) - (card.topRight.x - card.topLeft.x) * 1.04) < 1e-9)
    #expect(abs((grown.topLeft.y - grown.bottomLeft.y) - (card.topLeft.y - card.bottomLeft.y) * 1.04) < 1e-9)
    // A card at the edge is kept inside the photo.
    let edge = DocumentStillEncoder.expanded(quad(x: 0, y: 0, width: 1200, height: 756), by: 0.04)
    #expect(edge.topLeft.x == 0 && edge.topLeft.y == 1)
}

/// A camera photo: a light card in front of a dark room, with a "face" beside it.
private func syntheticPhoto(card: CGRect) -> Data {
    let renderer = UIGraphicsImageRenderer(size: photo, format: {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return format
    }())
    return renderer.jpegData(withCompressionQuality: 0.9) { context in
        UIColor(white: 0.12, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: photo))
        // The person behind, partly beside the card.
        UIColor(red: 0.8, green: 0.65, blue: 0.55, alpha: 1).setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 1550, y: 150, width: 420, height: 560))
        UIColor(white: 0.95, alpha: 1).setFill()
        UIBezierPath(roundedRect: card, cornerRadius: 30).fill()
        UIColor(white: 0.4, alpha: 1).setFill()
        context.fill(CGRect(x: card.minX + 60, y: card.minY + 120, width: 220, height: 280))
    }
}

@Test func theUploadIsTheCardNotTheWholeView() throws {
    let card = CGRect(x: 380, y: 420, width: 1100, height: 694)
    let cropped = try #require(
        DocumentStillEncoder.croppedToDocument(syntheticPhoto(card: card), maxDimension: 2000, jpegQuality: 0.8))
    guard case .data(let data) = cropped else {
        Issue.record("expected JPEG data")
        return
    }
    let image = try #require(UIImage(data: data))
    let size = image.size
    // About the card plus its margin, not the 2016 x 1512 photo.
    #expect(size.width < 1400 && size.width > 1000)
    #expect(abs(size.width / size.height - card.width / card.height) < 0.12)
}

@Test func aPhotoWithNoDocumentIsSentWhole() {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600))
    let blank = renderer.jpegData(withCompressionQuality: 0.9) { context in
        UIColor(white: 0.5, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    // Vision may call the whole view the document: then the crop is the whole
    // photo, which is the same as sending it uncropped.
    guard case .data(let data)? = DocumentStillEncoder.croppedToDocument(blank, maxDimension: 2000, jpegQuality: 0.8)
    else { return }
    let size = UIImage(data: data)?.size ?? .zero
    #expect(size.width >= 760 && size.height >= 570)
}
