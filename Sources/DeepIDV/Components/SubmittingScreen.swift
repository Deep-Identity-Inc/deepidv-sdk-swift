// DeepIDV › Components

import SwiftUI
import UIKit

/// While photos are sent and checked: the ID just taken, with the selfie on its
/// corner and a light sweeping over them, so the wait shows what is happening.
/// Without photos it falls back to the working badge.
struct SubmittingScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title = L("Verifying your identity")
    var message = L("Securely sending your photos")
    let document: UIImage?
    let selfie: UIImage?

    var body: some View {
        let palette = Kit.Palette(theme, scheme)
        VStack(spacing: theme.spacing.xl) {
            Spacer()
            if let document {
                photos(document: document, palette: palette)
            } else {
                Kit.WorkingBadge(symbol: "person.text.rectangle")
            }
            VStack(spacing: theme.spacing.sm) {
                Text(title)
                    .font(theme.typography.heading(size: 28).weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(message)
                    .font(theme.typography.body(size: 17))
                    .foregroundStyle(palette.secondaryText)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            CaptureLayout.ProgressBar(progress: nil, tone: .active, track: palette.cardLine)
                .frame(width: 160)
            Spacer()
            Kit.SecureNote()
        }
        .padding(theme.spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.ignoresSafeArea())
    }

    private func photos(document: UIImage, palette: Kit.Palette) -> some View {
        let width: CGFloat = 300
        let height = width / 1.586
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        return ZStack(alignment: .bottomTrailing) {
            Image(uiImage: document)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .overlay(sweep(height: height))
                .clipShape(shape)
                .overlay(shape.strokeBorder(theme.colors.primary.opacity(0.6), lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
            if let selfie {
                Image(uiImage: selfie)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 92, height: 92)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(palette.background, lineWidth: 4))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    .offset(x: 26, y: 26)
            }
        }
        .padding(.trailing, selfie == nil ? 0 : 26)
        .padding(.bottom, selfie == nil ? 0 : 26)
        .accessibilityHidden(true)
    }

    /// A soft band of light moving down and back over the ID.
    @ViewBuilder private func sweep(height: CGFloat) -> some View {
        if reduceMotion {
            EmptyView()
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * 2 * .pi / 2.4) + 1) / 2
                LinearGradient(
                    colors: [.clear, theme.colors.primary.opacity(0.35), .clear],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: height * 0.35)
                    .offset(y: (phase - 0.5) * height * 1.1)
            }
        }
    }
}
