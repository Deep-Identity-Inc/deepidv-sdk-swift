// DeepIDV › Components

import SwiftUI
import UIKit

/// "You're all set": the last screen of a submitted workflow run. A tick draws
/// in with a small burst, then the screen closes on its own after
/// `autoCloseAfter`, or when "Done" is tapped.
struct CompletionScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the screen stays before closing on its own.
    static let autoCloseAfter: TimeInterval = 3

    var title = "You're all set"
    var message = "Your verification has been submitted. Thank you!"
    let onDone: () -> Void

    @State private var burst = false
    @State private var countdown: Double = 0

    var body: some View {
        let palette = Kit.Palette(theme, scheme)
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: theme.spacing.lg) {
                ZStack {
                    Burst(color: theme.colors.success, spread: burst ? 1 : 0)
                        .opacity(burst ? 0 : 1)
                        .frame(width: 220, height: 220)
                    Kit.SuccessBadge(size: 112)
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
                Kit.PrimaryButton(title: "Done", action: onDone)
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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(notification: .announcement, argument: "\(title). \(message)")
            if !reduceMotion {
                withAnimation(.easeOut(duration: 0.9).delay(0.15)) { burst = true }
            }
            withAnimation(.linear(duration: Self.autoCloseAfter)) { countdown = 1 }
        }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(Self.autoCloseAfter * 1_000_000_000))
            if !Task.isCancelled { onDone() }
        }
    }

    /// Dots thrown out from the badge once.
    private struct Burst: View {
        let color: Color
        var spread: CGFloat

        var body: some View {
            ZStack {
                BurstDots(spread: spread, even: true).fill(color)
                BurstDots(spread: spread, even: false).fill(color.opacity(0.55))
            }
            .accessibilityHidden(true)
        }
    }

    /// Twelve dots round a circle, `spread` 0 (close in) to 1 (thrown out); half
    /// of them, by `even`.
    private struct BurstDots: Shape {
        var spread: CGFloat
        let even: Bool

        var animatableData: CGFloat {
            get { spread }
            set { spread = newValue }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let r = min(rect.width, rect.height) / 2
            for i in 0..<12 where i.isMultiple(of: 2) == even {
                let angle = Double(i) / 12 * 2 * .pi
                let distance = r * (0.45 + 0.55 * spread) * (even ? 1 : 0.8)
                let size: CGFloat = even ? 9 : 6
                let center = CGPoint(
                    x: rect.midX + cos(angle) * distance, y: rect.midY + sin(angle) * distance)
                path.addEllipse(
                    in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            }
            return path
        }
    }
}
