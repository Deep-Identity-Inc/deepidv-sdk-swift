// DeepIDV › Components

import SwiftUI
import UIKit

/// Everything drawn over the front camera while a face is captured, for the
/// selfie and the liveness check: the frosted surround with an oval window, the
/// instruction above it, a ring that fills as the check progresses, the
/// encryption note below, and the close button.
///
/// The same look as the document camera screen. Camera-free: plain values and
/// callbacks, so it renders in previews and tests.
struct FaceCaptureOverlay: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    var subtitle: String? = nil
    var tone: CaptureLayout.Tone = .idle
    /// 0–1 around the oval, or `nil` for no ring.
    var progress: Double? = nil
    /// A color the whole screen shows (the light check), as hex.
    var flashColor: String? = nil
    /// The photo just taken, frozen in the oval.
    var capturedImage: UIImage? = nil
    var manualShutterVisible = false
    var onManualCapture: () -> Void = {}
    var onCancel: (() -> Void)? = nil

    @State private var dim = false
    /// Set once on appear, so the oval grows gently into place.
    @State private var settled = false

    var body: some View {
        // The drawing runs edge to edge; the close button and shutter keep to
        // the safe area, clear of the status bar and the home indicator.
        ZStack {
            surface
            chrome
        }
        .onAppear {
            startPulse()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.05)) { settled = true }
        }
        .onChange(of: tone) { _ in startPulse() }
    }

    private var surface: some View {
        GeometryReader { geo in
            let oval = Self.oval(in: geo.size, scale: settled || reduceMotion ? 1 : 0.88)
            ZStack {
                CaptureLayout.Surround(window: oval, cornerRadius: 0, oval: true)
                    .opacity(flashColor == nil ? 1 : 0)

                if let flashColor {
                    // Over everything but the words, so the screen casts the color
                    // while the face stays visible to keep it centered.
                    Color(hex: flashColor).opacity(0.6)
                        .transition(.opacity)
                }

                ovalGuide(oval)

                instruction
                    .frame(width: min(geo.size.width - theme.spacing.lg * 2, 600))
                    .position(x: geo.size.width / 2, y: oval.minY - 64)

                Kit.SecureNote(onCamera: true)
                    .position(x: geo.size.width / 2, y: oval.maxY + 36)
                    .opacity(flashColor == nil ? 1 : 0)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: flashColor)
        }
        .ignoresSafeArea()
    }

    /// A head-shaped oval: 70% of the width up to 460 pt, 1.35 times as tall
    /// up to 64% of the height, a little above the middle. Only the look: the
    /// checks measure the face against the camera frame, not the oval. `scale`
    /// shrinks it about its center, for the grow-in.
    static func oval(in size: CGSize, scale: CGFloat = 1) -> CGRect {
        let width = min(size.width * 0.7, 460) * scale
        let height = min(min(size.width * 0.7, 460) * 1.35, size.height * 0.64) * scale
        return CGRect(
            x: (size.width - width) / 2, y: (size.height - height) / 2 - 12,
            width: width, height: height)
    }

    private func ovalGuide(_ rect: CGRect) -> some View {
        // White over a flashed color, which could be any color, the tone's included.
        let color = flashColor == nil ? tone.color(in: theme) : .white
        let ring = flashColor == nil ? theme.colors.success : .white
        return ZStack {
            if let capturedImage {
                Image(uiImage: capturedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(Ellipse())
                    .transition(.opacity)
            }
            Ellipse()
                .strokeBorder(color, lineWidth: 3)
                .shadow(color: color.opacity(tone == .idle ? 0.25 : 0.6), radius: 14)
                .opacity(tone == .idle && dim ? 0.5 : 1)
            if let progress {
                OvalFromTop()
                    .trim(from: 0, to: progress)
                    .stroke(ring, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .animation(.linear(duration: 0.15), value: progress)
            }
            if capturedImage != nil {
                CaptureLayout.CheckBadge(size: 48)
                    .position(x: rect.width * 0.85, y: rect.height * 0.1)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .animation(.easeInOut(duration: 0.3), value: tone)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: capturedImage != nil)
        .accessibilityHidden(true)
    }

    private var instruction: some View {
        VStack(spacing: theme.spacing.sm) {
            Text(title)
                .font(theme.typography.heading(size: 26).weight(.semibold))
                .foregroundStyle(theme.colors.grey.s50)
            if let subtitle {
                Text(subtitle)
                    .font(theme.typography.body(size: 16))
                    .foregroundStyle(theme.colors.grey.s50.opacity(0.75))
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
        .id(title + (subtitle ?? ""))
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var chrome: some View {
        VStack {
            HStack {
                if let onCancel {
                    CaptureLayout.RoundButton(symbol: "xmark", label: L("Cancel"), action: onCancel)
                }
                Spacer()
            }
            Spacer()
            if manualShutterVisible {
                VStack(spacing: theme.spacing.sm + 2) {
                    Text(L("Having trouble? Take the photo yourself"))
                        .font(theme.typography.body(size: 14).weight(.medium))
                        .foregroundStyle(theme.colors.grey.s50)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                    Button(action: onManualCapture) {
                        ZStack {
                            Circle().fill(theme.colors.grey.s50).frame(width: 62, height: 62)
                            Circle().strokeBorder(theme.colors.grey.s50, lineWidth: 4)
                                .frame(width: 78, height: 78)
                        }
                    }
                    .buttonStyle(CaptureLayout.PressStyle())
                    .accessibilityLabel(L("Take photo"))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, theme.spacing.lg)
        .padding(.vertical, theme.spacing.md)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: manualShutterVisible)
    }

    private func startPulse() {
        guard tone == .idle, !reduceMotion else {
            dim = false
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// An oval whose outline starts at the top and runs clockwise, so a trimmed
/// ring fills from 12 o'clock.
struct OvalFromTop: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: .zero, radius: 1, startAngle: .degrees(-90), endAngle: .degrees(270),
            clockwise: false)
        return path.applying(
            CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .scaledBy(x: rect.width / 2, y: rect.height / 2))
    }
}
