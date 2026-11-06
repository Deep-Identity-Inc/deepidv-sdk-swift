// DeepIDVTests › DocumentScanner

import Testing

@testable import DeepIDV

@Test func theLargestPhotoSizeIsTakenUpTo12MP() {
    let iPadFront = [PhotoSize(width: 2016, height: 1512), PhotoSize(width: 4032, height: 3024)]
    #expect(PhotoSize.largest(of: iPadFront) == PhotoSize(width: 4032, height: 3024))
    // A 48 MP camera's largest size is passed over for its 12 MP one.
    let iPhonePro = [
        PhotoSize(width: 4032, height: 3024), PhotoSize(width: 8064, height: 6048),
        PhotoSize(width: 1920, height: 1440),
    ]
    #expect(PhotoSize.largest(of: iPhonePro) == PhotoSize(width: 4032, height: 3024))
    // An older camera keeps the largest it has.
    #expect(PhotoSize.largest(of: [PhotoSize(width: 3264, height: 2448)]) == PhotoSize(width: 3264, height: 2448))
}

@Test func noPhotoSizeIsPickedWhenNoneFits() {
    #expect(PhotoSize.largest(of: []) == nil)
    #expect(PhotoSize.largest(of: [PhotoSize(width: 8064, height: 6048), PhotoSize(width: 0, height: 0)]) == nil)
}

@Test func aCutOfA12MPPhotoIsNotShrunk() {
    #expect(DocumentStillEncoder().maxDimension >= 4032)
}
