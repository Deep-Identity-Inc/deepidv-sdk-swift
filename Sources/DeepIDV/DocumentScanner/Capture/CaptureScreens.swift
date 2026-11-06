// DeepIDV › DocumentScanner › Capture

import DeepIDVCore
import SwiftUI
import UIKit

/// The full screens of a capture, between and after the camera: turning the card
/// over, done (or analysing), tips, and camera access.
///
/// They follow the system's light or dark appearance; the camera screen itself is
/// always dark.
enum CaptureScreens {
    typealias Palette = Kit.Palette

    // MARK: - Flip

    /// "Now show the back": a card turning over inside a ring of arrows.
    struct Flip: View {
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var scheme
        let copy: CaptureCopy
        let documentType: DocumentType

        var body: some View {
            let palette = Palette(theme, scheme)
            VStack(spacing: theme.spacing.xl) {
                Spacer()
                VStack(spacing: theme.spacing.sm) {
                    Text(copy.title)
                        .font(theme.typography.heading(size: 26).weight(.semibold))
                        .foregroundStyle(palette.text)
                    if let subtitle = copy.subtitle {
                        Text(subtitle)
                            .font(theme.typography.body(size: 16))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                FlipIllustration(palette: palette)
                    .frame(width: 300, height: 300)
                Spacer()
                Spacer()
            }
            .padding(theme.spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background.ignoresSafeArea())
        }
    }

    /// A card that turns over and back, with a ring of arrows around it. Still
    /// under Reduce Motion.
    struct FlipIllustration: View {
        @Environment(\.theme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let palette: Palette

        /// One turn over and back, with a pause on each face.
        static let period: Double = 3.6

        var body: some View {
            if reduceMotion {
                frame(angle: 0, spin: 0)
            } else {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    frame(angle: Self.cardAngle(at: t), spin: t * 40)
                }
            }
        }

        /// The card's turn at `t`: hold the front, turn, hold the back, turn back.
        static func cardAngle(at t: Double) -> Double {
            let phase = t.truncatingRemainder(dividingBy: period) / period
            func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
            switch phase {
            case ..<0.25: return 0
            case ..<0.5: return 180 * ease((phase - 0.25) / 0.25)
            case ..<0.75: return 180
            default: return 180 + 180 * ease((phase - 0.75) / 0.25)
            }
        }

        private func frame(angle: Double, spin: Double) -> some View {
            let showsBack = cos(angle * .pi / 180) < 0
            return ZStack {
                ArrowRing()
                    .stroke(
                        theme.colors.primary,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .rotationEffect(.degrees(spin))
                    .opacity(0.9)
                CardFace(back: showsBack, palette: palette)
                    .frame(width: 190, height: 120)
                    // The back face is drawn mirrored so it reads correctly once turned.
                    .scaleEffect(x: showsBack ? -1 : 1, y: 1)
                    .rotation3DEffect(.degrees(angle), axis: (0, 1, 0), perspective: 0.45)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
            }
            .accessibilityHidden(true)
        }
    }

    /// Two arcs with arrowheads, chasing each other round a circle.
    struct ArrowRing: Shape {
        func path(in rect: CGRect) -> Path {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - 6
            var path = Path()
            for start in [200.0, 20.0] {
                let end = start + 120
                let s = start * .pi / 180
                path.move(to: CGPoint(x: center.x + radius * cos(s), y: center.y + radius * sin(s)))
                path.addArc(
                    center: center, radius: radius, startAngle: .degrees(start),
                    endAngle: .degrees(end), clockwise: false)
                // An arrowhead at the arc's end, pointing along it.
                let a = end * .pi / 180
                let tip = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
                let back = (end - 9) * .pi / 180
                let base = CGPoint(
                    x: center.x + radius * cos(back), y: center.y + radius * sin(back))
                let dx = tip.x - base.x
                let dy = tip.y - base.y
                path.move(to: CGPoint(x: base.x - dy * 0.9, y: base.y + dx * 0.9))
                path.addLine(to: tip)
                path.addLine(to: CGPoint(x: base.x + dy * 0.9, y: base.y - dx * 0.9))
            }
            return path
        }
    }

    /// A plain ID card drawing: the front (photo and lines) or the back (barcode).
    struct CardFace: View {
        @Environment(\.theme) private var theme
        let back: Bool
        let palette: Palette

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            ZStack {
                shape.fill(palette.card)
                if back { backFace } else { frontFace }
                shape.strokeBorder(palette.cardLine, lineWidth: 1.5)
            }
            .clipShape(shape)
        }

        private var frontFace: some View {
            VStack(spacing: 0) {
                Rectangle().fill(theme.colors.primary).frame(height: 18)
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.colors.primary.opacity(0.14))
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(theme.colors.primary.opacity(0.55))
                        )
                        .frame(width: 52, height: 66)
                    VStack(alignment: .leading, spacing: 8) {
                        line(0.9)
                        line(0.65)
                        line(0.8)
                        line(0.5)
                    }
                    .padding(.top, 4)
                }
                .padding(12)
                Spacer(minLength: 0)
            }
        }

        private var backFace: some View {
            VStack(alignment: .leading, spacing: 10) {
                Barcode()
                    .fill(palette.text.opacity(0.8))
                    .frame(height: 48)
                line(0.7)
                line(0.45)
            }
            .padding(14)
        }

        private func line(_ share: CGFloat) -> some View {
            GeometryReader { geo in
                Capsule()
                    .fill(palette.cardLine)
                    .frame(width: geo.size.width * share, height: 6)
            }
            .frame(height: 6)
        }
    }

    /// A barcode-like block of bars, the same every time.
    struct Barcode: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let rows = 3
            let rowHeight = rect.height / CGFloat(rows)
            var seed: UInt32 = 7
            for row in 0..<rows {
                var x = rect.minX
                while x < rect.maxX {
                    seed = seed &* 1_103_515_245 &+ 12_345
                    let width = CGFloat(1 + (seed >> 16) % 4)
                    if (seed >> 20) % 3 != 0 {
                        path.addRect(
                            CGRect(
                                x: x, y: rect.minY + CGFloat(row) * rowHeight + 1,
                                width: min(width, rect.maxX - x), height: rowHeight - 2))
                    }
                    x += width + 1.5
                }
            }
            return path
        }
    }

    // MARK: - Done

    /// The last side is in: a tick, the words, and the photo in a green frame.
    /// With `analyzing`, a sweeping bar and "Analyzing…" instead of the tick.
    struct Done: View {
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var scheme
        let copy: CaptureCopy
        let image: UIImage?
        let aspect: CGFloat
        let analyzing: Bool

        var body: some View {
            let palette = Palette(theme, scheme)
            GeometryReader { geo in
                let width = min(geo.size.width - 64, 460)
                VStack(spacing: theme.spacing.lg) {
                    Spacer()
                    if analyzing {
                        CaptureLayout.ProgressBar(progress: nil, tone: .active, track: palette.cardLine)
                            .frame(width: 160)
                    } else {
                        Kit.SuccessBadge(size: 72)
                    }
                    VStack(spacing: theme.spacing.sm) {
                        Text(copy.title)
                            .font(theme.typography.heading(size: 28).weight(.semibold))
                            .foregroundStyle(palette.text)
                        if let subtitle = copy.subtitle {
                            Text(subtitle)
                                .font(theme.typography.body(size: 16))
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .accessibilityElement(children: .combine)
                    photo(width: width, palette: palette)
                        .padding(.top, theme.spacing.sm)
                    Spacer()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .padding(theme.spacing.lg)
            .background(palette.background.ignoresSafeArea())
        }

        @ViewBuilder private func photo(width: CGFloat, palette: Palette) -> some View {
            let shape = RoundedRectangle(cornerRadius: CaptureLayout.radius, style: .continuous)
            let color = analyzing ? theme.colors.primary : theme.colors.success
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    palette.card
                }
            }
            .frame(width: width, height: width / aspect)
            .clipShape(shape)
            .overlay(shape.strokeBorder(color, lineWidth: 3))
            .shadow(color: color.opacity(0.35), radius: 18, y: 8)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Help

    /// Tips for a quick scan.
    struct Help: View {
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var scheme
        let onDone: () -> Void

        private let tips: [(symbol: String, title: String, detail: String)] = [
            ("sun.max.fill", L("Find good light"), L("Bright, even light works best.")),
            ("sparkles", L("Avoid glare"), L("Tilt your ID away from lamps and windows.")),
            ("viewfinder", L("Fill the frame"), L("Hold your ID close so its edges line up with the frame.")),
            ("hand.raised.fill", L("Hold still"), L("The photo is taken automatically once your ID is steady.")),
            ("camera.fill", L("Still stuck?"), L("After a few seconds you can take the photo yourself.")),
        ]

        var body: some View {
            let palette = Palette(theme, scheme)
            VStack(alignment: .leading, spacing: theme.spacing.lg) {
                Text(L("Tips for a quick scan"))
                    .font(theme.typography.heading(size: 24).weight(.semibold))
                    .foregroundStyle(palette.text)
                    .padding(.top, theme.spacing.lg)
                ForEach(tips, id: \.title) { tip in
                    HStack(alignment: .top, spacing: theme.spacing.md) {
                        Image(systemName: tip.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.colors.primary)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(theme.colors.primary.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tip.title)
                                .font(theme.typography.body(size: 17).weight(.semibold))
                                .foregroundStyle(palette.text)
                            Text(tip.detail)
                                .font(theme.typography.body(size: 15))
                                .foregroundStyle(palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
                PrimaryButton(title: L("Got it"), action: onDone)
            }
            .padding(theme.spacing.lg)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(palette.background.ignoresSafeArea())
        }
    }

    // MARK: - Camera access

    struct Permission: View {
        @Environment(\.theme) private var theme
        /// What the camera is for: "scan your ID", "take a selfie".
        var purpose = L("scan your ID")
        let onOpenSettings: () -> Void

        var body: some View {
            VStack(spacing: theme.spacing.md) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                Text(L("Camera access is off"))
                    .font(theme.typography.heading(size: 24).weight(.semibold))
                    .foregroundStyle(theme.colors.grey.s50)
                Text(L("Allow camera access in Settings to %@.", purpose))
                    .font(theme.typography.body(size: 16))
                    .foregroundStyle(theme.colors.grey.s400)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: L("Open Settings"), action: onOpenSettings)
                    .frame(maxWidth: 320)
                    .padding(.top, theme.spacing.sm)
            }
            .padding(theme.spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.colors.grey.s900.ignoresSafeArea())
        }
    }

    typealias PrimaryButton = Kit.PrimaryButton
}
