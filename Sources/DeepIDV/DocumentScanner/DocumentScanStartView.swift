// DeepIDV › DocumentScanner (UI)

import DeepIDVCore
import SwiftUI

/// The pre-capture intro shown before the camera opens: a short, auto-
/// playing three-page carousel of framing tips, each an illustration over a
/// headline, with the step dots advancing on their own. Skip / Continue start
/// the capture at any point — Skip simply bypasses the rest of the intro.
///
/// Camera-free, so it renders in previews. Themed via `@Environment(\.theme)` like every SDK view; the
/// illustrations are SF Symbols (no bundled art yet) and can be swapped for real
/// illustration assets later without touching the carousel.
struct DocumentScanStartView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var page = 0
    /// Begins capture. Invoked by both Continue and Skip.
    let onStart: () -> Void

    /// One intro page: an SF Symbol illustration and its headline.
    private struct IntroPage: Hashable {
        let symbol: String
        let headline: String
    }

    /// The framing tips, in order — copy and sequence mirror the verify app's
    /// onboarding.
    private static let pages: [IntroPage] = [
        IntroPage(
            symbol: "person.text.rectangle", headline: "Place your valid ID inside the frame"),
        IntroPage(symbol: "globe.americas.fill", headline: "Hold your phone steady"),
        IntroPage(
            symbol: "doc.text.magnifyingglass", headline: "Make sure information is readable"),
    ]

    /// How long each page stays before the carousel advances to the next.
    private static let pageDuration: UInt64 = 2_800_000_000  // 2.8s

    var body: some View {
        let current = Self.pages[page]
        let palette = Kit.Palette(theme, scheme)

        VStack(spacing: theme.spacing.xl) {
            Spacer()

            // The illustration + headline cross-fade/slide together as the
            // carousel advances; `.id(page)` gives each page its own identity so
            // the transition fires.
            VStack(spacing: theme.spacing.xl) {
                Image(systemName: current.symbol)
                    .font(.system(size: 84, weight: .regular))
                    .foregroundStyle(theme.colors.primary)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .background(theme.colors.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: theme.spacing.md, style: .continuous))

                Text(current.headline)
                    .font(theme.typography.heading(size: 22))
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, theme.spacing.md)
                    // Reserve two lines so the dots don't jump as headlines change.
                    .frame(minHeight: 64)
            }
            .id(page)
            .transition(pageTransition)

            dots

            Spacer()

            VStack(spacing: theme.spacing.xs) {
                Kit.PrimaryButton(title: "Continue", action: onStart)
                Kit.SecondaryButton(title: "Skip", action: onStart)
            }
        }
        .padding(theme.spacing.lg)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.ignoresSafeArea())
        .task { await autoAdvance() }
    }

    /// The animated step dots; the active one widens into a pill.
    private var dots: some View {
        HStack(spacing: theme.spacing.xs) {
            ForEach(Self.pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? theme.colors.primary : Kit.Palette(theme, scheme).cardLine)
                    .frame(width: index == page ? 24 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    /// A subtle horizontal slide + cross-fade between pages, reduced to a plain
    /// fade when the user prefers reduced motion.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 40)),
            removal: .opacity.combined(with: .offset(x: -40)))
    }

    /// Walks the carousel forward one page at a time, then stops on the last.
    /// Runs as the view's `.task`, so it's cancelled the moment capture starts.
    @MainActor
    private func autoAdvance() async {
        for next in 1..<Self.pages.count {
            try? await Task.sleep(nanoseconds: Self.pageDuration)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.45)) { page = next }
        }
    }
}

#Preview {
    DocumentScanStartView {}
}
