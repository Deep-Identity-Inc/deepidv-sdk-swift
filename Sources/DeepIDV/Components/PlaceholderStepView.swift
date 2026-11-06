// DeepIDV › Components

import SwiftUI

/// Shared placeholder body for the stub views.
///
/// It also models the theming discipline every real SDK view must follow: each
/// color, font, and spacing value is read from `@Environment(\.theme)` — never an
/// inline literal. That's the seam that makes the (deferred) whitelabel story a
/// drop-in: inject a different `Theme` and this view re-styles, untouched.
struct PlaceholderStepView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let title: String
    let subtitle: String

    var body: some View {
        let palette = Kit.Palette(theme, scheme)
        VStack(spacing: theme.spacing.sm) {
            Text(title)
                .font(theme.typography.heading(size: 28).weight(.semibold))
                .foregroundStyle(palette.text)
            Text(subtitle)
                .font(theme.typography.body(size: 17))
                .foregroundStyle(palette.secondaryText)
        }
        .multilineTextAlignment(.center)
        .padding(theme.spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.ignoresSafeArea())
    }
}
