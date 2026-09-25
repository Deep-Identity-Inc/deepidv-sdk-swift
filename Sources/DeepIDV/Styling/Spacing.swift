// DeepIDV › Styling

import CoreGraphics

/// Spacing tokens on an 8-point base scale.
///
/// The verify app uses MUI's numeric `spacing(n) = 8·n`; the SDK exposes the
/// common steps as named tokens so views never hardcode raw padding values.
/// `xs` is the half-step (4pt); every other step is a multiple of the 8pt base.
struct Spacing: Sendable, Equatable {
    /// 4pt — half-step.
    var xs: CGFloat
    /// 8pt — the base unit.
    var sm: CGFloat
    /// 16pt.
    var md: CGFloat
    /// 24pt.
    var lg: CGFloat
    /// 32pt.
    var xl: CGFloat
}

extension Spacing {
    /// The fixed deepidv spacing scale.
    static let deepidv = Spacing(xs: 4, sm: 8, md: 16, lg: 24, xl: 32)
}
