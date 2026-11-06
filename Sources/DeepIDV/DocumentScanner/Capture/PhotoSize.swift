// DeepIDV › DocumentScanner › Capture

/// A photo size a camera offers, and which of them document capture takes.
struct PhotoSize: Equatable, Sendable {
    var width: Int
    var height: Int

    var pixels: Int { width * height }

    /// The most pixels taken: 12 MP, a 4032 x 3024 photo. Larger sizes (the
    /// 48 MP of recent iPhones) are slower to take and too heavy to upload.
    static let maxPixels = 4032 * 3024

    /// The size with the most pixels, up to ``maxPixels``; `nil` when none fits.
    static func largest(of sizes: [PhotoSize]) -> PhotoSize? {
        sizes.filter { $0.pixels > 0 && $0.pixels <= maxPixels }.max { $0.pixels < $1.pixels }
    }
}
