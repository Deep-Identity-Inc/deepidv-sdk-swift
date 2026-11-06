// DeepIDV › Styling

import SwiftUI

/// The complete set of design tokens SDK views resolve at render time.
///
/// `.deepidv` is the brand default; a host's ``DeepIDVAppearance`` is laid over
/// it. Views read it from `@Environment(\.theme)` and never hardcode a color,
/// font, spacing or corner radius inline, so every screen follows the host's
/// choices.
struct Theme: Sendable, Equatable {
    var colors: ColorTokens
    var typography: Typography
    var spacing: Spacing
    /// The corner radius of buttons.
    var cornerRadius: CGFloat = 14

    /// Buttons.
    var buttonRadius: CGFloat { cornerRadius }
    /// Cards, list rows and photos: a little rounder than buttons, square
    /// when buttons are.
    var cardRadius: CGFloat { cornerRadius == 0 ? 0 : cornerRadius + 4 }
}

extension Theme {
    /// The fixed deepidv brand theme.
    static let deepidv = Theme(
        colors: .deepidv,
        typography: .deepidv,
        spacing: .deepidv
    )
}

// MARK: - Environment

/// Environment key carrying the active `Theme`, defaulting to `.deepidv`.
private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .deepidv
}

extension EnvironmentValues {
    /// The active design-system theme. Defaults to `.deepidv`.
    ///
    /// Hosts set it through ``SwiftUI/View/deepIDVAppearance(_:)``.
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
