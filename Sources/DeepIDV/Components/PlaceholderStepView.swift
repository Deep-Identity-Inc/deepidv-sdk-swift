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
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: theme.spacing.sm) {
            Text(title)
                .font(theme.typography.heading())
                .foregroundStyle(theme.colors.grey.s900)
            Text(subtitle)
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s600)
        }
        .padding(theme.spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.grey.s50)
    }
}
