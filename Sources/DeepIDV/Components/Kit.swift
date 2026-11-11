// DeepIDV › Components

import SwiftUI

/// The shared building blocks of every SDK screen outside the live camera: the
/// light/dark palette, buttons, the round close button and the status screen
/// used for every wait, result and error.
///
/// One look everywhere, and one place for the styling options to reach.
enum Kit {
    // MARK: - Palette

    /// A screen's colors for the current appearance. The camera screens are
    /// always dark; everything else follows the system.
    struct Palette {
        let background: Color
        let text: Color
        let secondaryText: Color
        let card: Color
        let cardLine: Color

        init(_ theme: Theme, _ scheme: ColorScheme) {
            let dark = scheme == .dark
            background = dark ? theme.colors.grey.s900 : theme.colors.grey.s50
            text = dark ? theme.colors.grey.s50 : theme.colors.grey.s900
            secondaryText = dark ? theme.colors.grey.s400 : theme.colors.grey.s600
            card = dark ? theme.colors.grey.s800 : .white
            cardLine = dark ? theme.colors.grey.s700 : theme.colors.grey.s300
        }
    }

    // MARK: - Buttons

    /// The full-width primary button.
    struct PrimaryButton: View {
        @Environment(\.theme) private var theme
        let title: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(theme.typography.button(size: 17).weight(.semibold))
                    .foregroundStyle(theme.colors.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
                            .fill(theme.colors.primary))
            }
            .buttonStyle(PressStyle())
        }
    }

    /// A quiet text button under the primary one: "Cancel", "Close".
    struct SecondaryButton: View {
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var scheme
        let title: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(theme.typography.button(size: 16).weight(.medium))
                    .foregroundStyle(Palette(theme, scheme).secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
        }
    }

    /// The round close button at the top left of a light or dark screen. Over
    /// the camera it is the frosted one, ``CaptureLayout/RoundButton``.
    struct CloseButton: View {
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var scheme
        var label = L("Cancel")
        let action: () -> Void

        var body: some View {
            let palette = Palette(theme, scheme)
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(palette.card))
                    .overlay(Circle().strokeBorder(palette.cardLine, lineWidth: 1))
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(label)
        }
    }

    /// Shrinks a little while pressed.
    struct PressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(configuration.isPressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }

    // MARK: - Status screen

    /// What the status screen's badge shows.
    enum Badge: Equatable {
        /// Working: a ring turning round `symbol`.
        case working(symbol: String)
        /// Done.
        case success
        /// Something needs the user: a warning sign.
        case warning
        /// Try again.
        case retry
        /// Camera access is off.
        case camera
    }

    /// One action under the words.
    struct Action {
        var title: String
        var run: () -> Void
    }

    /// Every wait, result and error: a badge, a title, a line or two, optional
    /// content, and up to two actions. A close button sits at the top left when
    /// `onClose` is set.
    struct StatusScreen<Content: View>: View {
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var scheme
        let badge: Badge
        let title: String
        var message: String? = nil
        /// A small line under the message: "2 attempts left".
        var note: String? = nil
        var primary: Action? = nil
        var secondary: Action? = nil
        var onClose: (() -> Void)? = nil
        @ViewBuilder var content: () -> Content

        var body: some View {
            let palette = Palette(theme, scheme)
            VStack(spacing: 0) {
                Spacer(minLength: theme.spacing.xl)
                VStack(spacing: theme.spacing.lg) {
                    BadgeView(badge: badge)
                    VStack(spacing: theme.spacing.sm) {
                        Text(title)
                            .font(theme.typography.heading(size: 28).weight(.semibold))
                            .foregroundStyle(palette.text)
                        if let message {
                            Text(message)
                                .font(theme.typography.body(size: 17))
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    if let note {
                        Text(note)
                            .font(theme.typography.body(size: 14).weight(.medium))
                            .foregroundStyle(palette.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(palette.card))
                            .overlay(Capsule().strokeBorder(palette.cardLine, lineWidth: 1))
                    }
                    content()
                }
                Spacer(minLength: theme.spacing.xl)
                if primary != nil || secondary != nil {
                    VStack(spacing: theme.spacing.xs) {
                        if let primary { PrimaryButton(title: primary.title, action: primary.run) }
                        if let secondary {
                            SecondaryButton(title: secondary.title, action: secondary.run)
                        }
                    }
                }
            }
            .padding(theme.spacing.lg)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if let onClose {
                    CloseButton(action: onClose).padding(theme.spacing.md)
                }
            }
            .background(palette.background.ignoresSafeArea())
        }
    }

    // MARK: - Badges

    /// The badge at the top of a status screen.
    struct BadgeView: View {
        @Environment(\.theme) private var theme
        let badge: Badge

        var body: some View {
            switch badge {
            case .working(let symbol):
                WorkingBadge(symbol: symbol)
            case .success:
                SuccessBadge(size: 84)
            case .warning:
                SymbolBadge(symbol: "exclamationmark", color: theme.colors.warning, ink: theme.colors.onWarning)
            case .retry:
                SymbolBadge(symbol: "arrow.clockwise", color: theme.colors.primary, ink: theme.colors.onPrimary)
            case .camera:
                SymbolBadge(symbol: "camera.fill", color: theme.colors.primary, ink: theme.colors.onPrimary)
            }
        }
    }

    /// A ring turning round a symbol, on a soft disc. Still under Reduce Motion.
    struct WorkingBadge: View {
        @Environment(\.theme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let symbol: String
        var size: CGFloat = 96

        var body: some View {
            ZStack {
                Circle().fill(theme.colors.primary.opacity(0.1))
                Circle()
                    .stroke(theme.colors.primary.opacity(0.15), lineWidth: 5)
                    .padding(5)
                if reduceMotion {
                    arc
                } else {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        arc.rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360))
                    }
                }
                Image(systemName: symbol)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(theme.colors.primary)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }

        private var arc: some View {
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(theme.colors.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .padding(5)
        }
    }

    /// A green disc whose tick draws in, with a ring that pulses out once.
    struct SuccessBadge: View {
        @Environment(\.theme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let size: CGFloat
        @State private var shown = false

        var body: some View {
            let done = shown || reduceMotion
            ZStack {
                Circle()
                    .stroke(theme.colors.success.opacity(0.35), lineWidth: 2)
                    .scaleEffect(done ? 1.45 : 1)
                    .opacity(done ? 0 : 1)
                Circle()
                    .fill(theme.colors.success)
                    .shadow(color: theme.colors.success.opacity(0.4), radius: 16, y: 6)
                    .scaleEffect(done ? 1 : 0.4)
                TickShape()
                    .trim(from: 0, to: done ? 1 : 0)
                    .stroke(
                        theme.colors.onSuccess,
                        style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.42, height: size * 0.32)
            }
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { shown = true }
            }
            .accessibilityHidden(true)
        }
    }

    /// A tick, drawn left to right.
    struct TickShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return path
        }
    }

    /// A symbol in a tinted disc that pops in.
    struct SymbolBadge: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let symbol: String
        let color: Color
        /// The symbol's color on `color`.
        var ink: Color = .white
        var size: CGFloat = 84
        @State private var shown = false

        var body: some View {
            ZStack {
                Circle().fill(color.opacity(0.14))
                Circle().fill(color).padding(size * 0.14)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundStyle(ink)
            }
            .frame(width: size, height: size)
            .scaleEffect(shown || reduceMotion ? 1 : 0.6)
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) { shown = true }
            }
            .accessibilityHidden(true)
        }
    }

    /// The fixed security line: a lock and the encryption note.
    struct SecureNote: View {
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var scheme
        /// Over the camera the note is white.
        var onCamera = false

        var body: some View {
            // One run of text, so the lock wraps with the first word instead of
            // being left on its own line by a wide font or a long translation.
            (Text(Image(systemName: "lock.fill")) + Text(" ") + Text(CaptureCopy.encryption))
                .font(theme.typography.body(size: 13).weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(
                    onCamera
                        ? theme.colors.grey.s50.opacity(0.78) : Palette(theme, scheme).secondaryText)
                .accessibilityLabel(CaptureCopy.encryption)
        }
    }
}

extension Kit.StatusScreen where Content == EmptyView {
    init(
        badge: Kit.Badge, title: String, message: String? = nil, note: String? = nil,
        primary: Kit.Action? = nil, secondary: Kit.Action? = nil, onClose: (() -> Void)? = nil
    ) {
        self.init(
            badge: badge, title: title, message: message, note: note, primary: primary,
            secondary: secondary, onClose: onClose, content: { EmptyView() })
    }
}
