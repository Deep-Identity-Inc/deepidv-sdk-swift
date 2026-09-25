// DeepIDV › Styling

import SwiftUI

/// Font tokens for the three text roles the SDK renders.
///
/// Families are referenced by name with an automatic system-font fallback:
/// `WF Visual Sans Variable` (body/heading) is the verify-app brand face but
/// isn't bundled yet, and `Geist Variable` (buttons) is bundleable but not
/// yet added. Until the files ship, `Font.custom` resolves each unregistered
/// family to the system font at render time, so nothing breaks.
struct Typography: Sendable, Equatable {
    /// Family name for body copy.
    var bodyFamily: String
    /// Family name for headings.
    var headingFamily: String
    /// Family name for button labels.
    var buttonFamily: String

    /// Body font at `size` (default 16pt).
    func body(size: CGFloat = 16) -> Font { Font.custom(bodyFamily, size: size) }
    /// Heading font at `size` (default 24pt).
    func heading(size: CGFloat = 24) -> Font { Font.custom(headingFamily, size: size) }
    /// Button-label font at `size` (default 14pt).
    func button(size: CGFloat = 14) -> Font { Font.custom(buttonFamily, size: size) }
}

extension Typography {
    /// The fixed deepidv brand typography.
    static let deepidv = Typography(
        bodyFamily: "WF Visual Sans Variable",
        headingFamily: "WF Visual Sans Variable",
        buttonFamily: "Geist Variable"
    )
}
