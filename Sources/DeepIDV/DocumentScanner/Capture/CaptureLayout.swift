// DeepIDV › DocumentScanner › Capture

import SwiftUI
import UIKit

/// The parts of the capture screen: the window the document is framed in, the
/// frosted surround, the document pill, the progress bar and the round buttons.
enum CaptureLayout {
    /// Corner radius of the window.
    static let radius: CGFloat = 18
    /// The widest the window gets, as a share of the screen width. Large, so a
    /// card that fills it is close enough for a sharp photo and a confident read.
    static let maxWindowWidth: CGFloat = 0.8
    /// The tallest the window gets, as a share of the screen height, leaving room
    /// for the words above and the note below.
    static let maxWindowHeight: CGFloat = 0.56
    /// Room on each side of the window.
    static let sideMargin: CGFloat = 28

    /// The window for a document of `aspect` (width ÷ height) on a screen of
    /// `size`: as wide as fits, no wider than `maxWindowWidth` and no taller than
    /// `maxWindowHeight` of the screen, a touch below the middle.
    static func window(in size: CGSize, aspect: CGFloat) -> CGRect {
        var width = min(size.width - sideMargin * 2, size.width * maxWindowWidth)
        var height = width / aspect
        if height > size.height * maxWindowHeight {
            height = size.height * maxWindowHeight
            width = height * aspect
        }
        let midY = size.height * 0.5 + 12
        return CGRect(
            x: (size.width - width) / 2, y: midY - height / 2, width: width, height: height)
    }

    // MARK: - Tone

    /// The window's color, by what the stage means.
    enum Tone: Equatable {
        /// Waiting for a document.
        case idle
        /// A document is in view and being worked on.
        case active
        case warning
        case error
        /// Ready, or captured.
        case success

        func color(in theme: Theme) -> Color {
            switch self {
            case .idle: return theme.colors.grey.s50
            case .active: return theme.colors.primary
            case .warning: return theme.colors.warning
            case .error: return theme.colors.error
            case .success: return theme.colors.success
            }
        }
    }

    // MARK: - Surround

    /// Darkens and frosts everything outside the window, so the document in it
    /// stands out.
    struct Surround: View {
        let window: CGRect
        let cornerRadius: CGFloat
        /// Cut an oval (a face) instead of a rounded rectangle (a document).
        var oval = false

        var body: some View {
            let hole = CutoutShape(hole: window, cornerRadius: cornerRadius, oval: oval)
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .mask(hole.fill(style: FillStyle(eoFill: true)))
                hole.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Window

    /// The document's outline: a tone-colored border with a soft glow, and the
    /// photo frozen inside once taken.
    struct Window: View {
        @Environment(\.theme) private var theme
        let rect: CGRect
        let tone: Tone
        /// Breathe gently while waiting for a document.
        let pulses: Bool
        let image: UIImage?

        @State private var dim = false

        var body: some View {
            let color = tone.color(in: theme)
            let shape = RoundedRectangle(cornerRadius: CaptureLayout.radius, style: .continuous)
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(shape)
                        .transition(.opacity.combined(with: .scale(scale: 1.03)))
                }
                shape
                    .strokeBorder(color, lineWidth: 3)
                    .shadow(color: color.opacity(tone == .idle ? 0.25 : 0.6), radius: 14)
                    .opacity(pulses && dim ? 0.55 : 1)
                if image != nil {
                    CheckBadge(size: 44)
                        .position(x: rect.width - 6, y: 6)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .animation(.easeInOut(duration: 0.3), value: tone)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: image != nil)
            .onAppear(perform: startPulse)
            .onChange(of: pulses) { _ in startPulse() }
            .accessibilityHidden(true)
        }

        private func startPulse() {
            guard pulses else {
                dim = false
                return
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                dim = true
            }
        }
    }

    /// A green disc with a white tick.
    struct CheckBadge: View {
        @Environment(\.theme) private var theme
        let size: CGFloat

        var body: some View {
            ZStack {
                Circle().fill(theme.colors.success)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: theme.colors.success.opacity(0.45), radius: 10, y: 3)
        }
    }

    // MARK: - Pill

    struct PillModel: Equatable {
        enum Style: Equatable {
            /// The classifier confirmed this document.
            case confirmed
            /// A first guess, still being checked.
            case pending
            case warning
            case error
            /// The side was captured.
            case done
        }

        var text: String
        var style: Style
    }

    /// The document the classifier recognised, sitting on the window's top edge.
    struct Pill: View {
        @Environment(\.theme) private var theme
        let pill: PillModel

        var body: some View {
            HStack(spacing: 8) {
                icon
                Text(pill.text)
                    .font(theme.typography.body(size: 15).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay(Capsule().fill(Color.black.opacity(0.35)))
            )
            .overlay(Capsule().strokeBorder(accent.opacity(0.7), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .id(pill.text)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        }

        private var accent: Color {
            switch pill.style {
            case .confirmed, .done: return theme.colors.success
            case .pending: return .white
            case .warning: return theme.colors.warning
            case .error: return theme.colors.error
            }
        }

        @ViewBuilder private var icon: some View {
            switch pill.style {
            case .confirmed:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(theme.colors.success)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.colors.success)
            case .pending:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.75)
                    .frame(width: 16, height: 16)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.colors.warning)
            case .error:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(theme.colors.error)
            }
        }

        private var accessibilityText: String {
            switch pill.style {
            case .confirmed: return "\(pill.text), recognized"
            case .pending: return "\(pill.text), checking"
            default: return pill.text
            }
        }
    }

    // MARK: - Progress bar

    /// A thin bar at the top: filling while the photo is about to be taken, or
    /// sweeping while the document is checked.
    struct ProgressBar: View {
        @Environment(\.theme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        /// 0–1, or `nil` for a sweep.
        let progress: Double?
        let tone: Tone
        /// The unfilled part: light over the camera, darker on a light screen.
        var track = Color.white.opacity(0.22)

        @State private var sweep = false

        var body: some View {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    if let progress {
                        Capsule()
                            .fill(tone.color(in: theme))
                            .frame(width: max(6, width * progress))
                            .animation(.linear(duration: 0.12), value: progress)
                    } else {
                        Capsule()
                            .fill(tone.color(in: theme))
                            .frame(width: width * 0.4)
                            .offset(x: sweep ? width * 0.6 : 0)
                    }
                }
            }
            .frame(height: 5)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    sweep = true
                }
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: - Buttons

    /// A frosted round button with a symbol: close, help.
    struct RoundButton: View {
        let symbol: String
        let label: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                            .overlay(Circle().fill(Color.black.opacity(0.25)))
                    )
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(label)
        }
    }

    /// Shrinks a little while pressed.
    struct PressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

/// A full-area fill with a rounded-rectangle hole, filled even-odd to cover
/// everything but the hole.
struct CutoutShape: Shape {
    var hole: CGRect
    let cornerRadius: CGFloat
    var oval = false

    /// The hole animates, so a window that grows in or changes size moves smoothly.
    var animatableData: CGRect.AnimatableData {
        get { hole.animatableData }
        set { hole.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if oval {
            path.addEllipse(in: hole)
        } else {
            path.addRoundedRect(
                in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
                style: .continuous)
        }
        return path
    }
}
