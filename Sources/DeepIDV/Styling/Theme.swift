// DeepIDV › Styling

import SwiftUI

/// The complete set of design tokens SDK views resolve at render time.
///
/// Exactly one value ships today — `.deepidv`, the fixed brand theme. Views read it
/// from `@Environment(\.theme)` and must never hardcode a color, font, or spacing
/// value inline. That discipline is the seam the (deferred) whitelabel story
/// drops into: inject a different `Theme` and every view re-styles, untouched.
struct Theme: Sendable, Equatable {
    var colors: ColorTokens
    var typography: Typography
    var spacing: Spacing
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
    /// No public `.deepIDVTheme(_:)` modifier ships yet — there's nothing for a
    /// host to override. The setter stays reachable internally so the
    /// whitelabel story can add that modifier later without touching any view.
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
