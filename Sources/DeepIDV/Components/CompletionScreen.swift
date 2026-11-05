// DeepIDV › Components

import SwiftUI
import UIKit

/// The last screen of a submitted workflow run: a neutral thank-you that says
/// the details were received, never whether they passed. The decision goes
/// to the host app in the run's result, so a declined person learns nothing
/// here. A paper plane settles in with one soft ring, then the screen closes
/// on its own after `autoCloseAfter`, or when "Done" is tapped.
struct CompletionScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the screen stays before closing on its own.
    static let autoCloseAfter: TimeInterval = 3

    var title = L("Thanks, you're done")
    var message = L("We've received your details.")
    let onDone: () -> Void

    @State private var ring = false
    @State private var countdown: Double = 0

    var body: some View {
        let palette = Kit.Palette(theme, scheme)
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: theme.spacing.lg) {
                ZStack {
                    Circle()
                        .strokeBorder(theme.colors.primary.opacity(0.35), lineWidth: 2)
                        .frame(width: 112, height: 112)
                        .scaleEffect(ring ? 1.6 : 1)
                        .opacity(ring ? 0 : 1)
                        .accessibilityHidden(true)
                    Kit.SymbolBadge(symbol: "paperplane.fill", color: theme.colors.primary, size: 112)
                }
                .frame(height: 180)
                VStack(spacing: theme.spacing.sm) {
                    Text(title)
                        .font(theme.typography.heading(size: 32).weight(.semibold))
                        .foregroundStyle(palette.text)
                    Text(message)
                        .font(theme.typography.body(size: 17))
                        .foregroundStyle(palette.secondaryText)
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                Kit.SecureNote().padding(.top, theme.spacing.xs)
            }
            Spacer()
            VStack(spacing: theme.spacing.sm) {
                Kit.PrimaryButton(title: L("Done"), action: onDone)
                // Drains as the screen closes itself.
                GeometryReader { geo in
                    Capsule().fill(palette.cardLine)
                        .overlay(alignment: .leading) {
                            Capsule().fill(theme.colors.primary.opacity(0.6))
                                .frame(width: geo.size.width * (1 - countdown))
                        }
                }
                .frame(height: 3)
                .padding(.horizontal, theme.spacing.xl)
                .accessibilityHidden(true)
            }
        }
        .padding(theme.spacing.lg)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.ignoresSafeArea())
        .onAppear {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            UIAccessibility.post(notification: .announcement, argument: "\(title). \(message)")
            if !reduceMotion {
                withAnimation(.easeOut(duration: 1.1).delay(0.2)) { ring = true }
            }
            withAnimation(.linear(duration: Self.autoCloseAfter)) { countdown = 1 }
        }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(Self.autoCloseAfter * 1_000_000_000))
            if !Task.isCancelled { onDone() }
        }
    }
}
