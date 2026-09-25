// DeepIDV › DocumentScanner › Capture

import SwiftUI

/// The camera overlay drawn on top of the live preview: the dimmed scrim
/// with a cut-out document guide, the side pill (front / back), the live
/// hint, the per-side success checkmark, the auto-capture-timeout manual shutter,
/// a cancel affordance, and the permission-denied CTA.
///
/// Deliberately camera-free — it takes plain values and callbacks, never a
/// `CameraController` — so it renders in previews and instantiates in tests on any
/// platform. All color/typography/spacing comes from `@Environment(\.theme)`; the
/// only opacities are derived from grey tokens, never raw literals.
struct CaptureOverlayView: View {
    @Environment(\.theme) private var theme

    let instruction: String
    let guidance: CaptureGuidance?
    let manualShutterVisible: Bool
    let isProcessing: Bool
    let permissionDenied: Bool
    /// The pill label for the side being captured (e.g. "Front of your ID"), or
    /// `nil` to hide it.
    var sideLabel: String? = nil
    /// When `true`, the guide is replaced by a full-screen success checkmark — the
    /// brief confirmation flashed after each side locks.
    var sideCaptured: Bool = false
    /// 0–1 fill of the capture progress ring on the guide (the hold-still dwell, D8).
    var holdProgress: Double = 0
    var onManualCapture: () -> Void = {}
    var onCancel: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    /// The 1.586∶1 ID-1 card aspect of the guide cut-out.
    private let guideAspect: CGFloat = 1.586

    /// Whether the live guide (scrim + frame + pill + hint) is on screen — i.e.
    /// none of the takeover states (permission, processing, success) is showing.
    private var isGuiding: Bool {
        !permissionDenied && !isProcessing && !sideCaptured
    }

    var body: some View {
        ZStack {
            // The scrim + guide + takeover states span the full screen (under the
            // safe area) so the shading covers the entire preview. Everything here
            // shares one full-screen coordinate space, so the cut-out and the
            // visible frame stay aligned.
            GeometryReader { geo in
                let guide = guideRect(in: geo.size)

                ZStack {
                    if isGuiding {
                        scrim(cutout: guide)
                        guideFrame(in: guide)
                        if let sideLabel {
                            sidePill(sideLabel)
                                .position(x: geo.size.width / 2, y: guide.minY - theme.spacing.xl)
                        }
                        if let guidance {
                            hint(for: guidance)
                                .position(x: geo.size.width / 2, y: guide.maxY + theme.spacing.lg)
                        }
                    } else if sideCaptured {
                        // Full-bleed confirmation so the checkmark reads cleanly
                        // over the (now irrelevant) live preview.
                        theme.colors.grey.s50
                        successCheckmark
                    } else if isProcessing {
                        // Clean upload screen that covers the frozen preview.
                        theme.colors.grey.s50
                        processing
                    } else if permissionDenied {
                        permissionCTA
                    }
                }
            }
            .ignoresSafeArea()

            // Chrome (cancel up top, manual shutter at the bottom) is shown only
            // over the live camera — the takeover states own the whole screen.
            if isGuiding || permissionDenied {
                VStack {
                    topBar
                    Spacer()
                    if isGuiding { bottomBar }
                }
                .padding(theme.spacing.lg)
            }
        }
    }

    // MARK: - Geometry

    /// The centred guide rectangle, inset from the horizontal edges and sized to
    /// the ID-1 card aspect. Shared by the scrim cut-out and the visible frame so
    /// they always line up.
    private func guideRect(in size: CGSize) -> CGRect {
        let width = size.width - theme.spacing.lg * 2
        let height = width / guideAspect
        return CGRect(
            x: theme.spacing.lg, y: (size.height - height) / 2, width: width, height: height)
    }

    // MARK: - Sections

    /// Dims everything outside the guide so the document area stands out. A single
    /// even-odd fill (full rect minus the rounded cut-out).
    private func scrim(cutout: CGRect) -> some View {
        CutoutScrim(hole: cutout, cornerRadius: theme.spacing.md)
            .fill(theme.colors.grey.s900.opacity(0.6), style: FillStyle(eoFill: true))
    }

    private func guideFrame(in rect: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.spacing.md, style: .continuous)
                .strokeBorder(theme.colors.primary, lineWidth: 3)
            // Fills around the guide as the user holds still; completing the loop
            // is the moment of capture.
            RoundedRectangle(cornerRadius: theme.spacing.md, style: .continuous)
                .trim(from: 0, to: holdProgress)
                .stroke(theme.colors.success, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .animation(.linear(duration: 0.1), value: holdProgress)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    /// The prominent white pill calling out which side to present.
    private func sidePill(_ label: String) -> some View {
        Text(label)
            .font(theme.typography.button(size: 15))
            .foregroundStyle(theme.colors.grey.s900)
            .padding(.horizontal, theme.spacing.md)
            .padding(.vertical, theme.spacing.sm)
            .background(theme.colors.grey.s50)
            .clipShape(Capsule())
            .shadow(color: theme.colors.grey.s900.opacity(0.25), radius: 8, y: 2)
    }

    private func hint(for guidance: CaptureGuidance) -> some View {
        Text(Self.hintText(for: guidance))
            .font(theme.typography.body())
            .foregroundStyle(theme.colors.grey.s50)
            .padding(.horizontal, theme.spacing.md)
            .padding(.vertical, theme.spacing.sm)
            .background(theme.colors.grey.s900.opacity(0.6))
            .clipShape(Capsule())
    }

    /// The per-side success checkmark (a primary ring around a primary tick).
    private var successCheckmark: some View {
        ZStack {
            Circle()
                .strokeBorder(theme.colors.primary, lineWidth: 6)
                .frame(width: 96, height: 96)
            Image(systemName: "checkmark")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(theme.colors.primary)
        }
        .accessibilityLabel("Captured")
    }

    private var topBar: some View {
        HStack {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(theme.typography.button())
                    .foregroundStyle(theme.colors.grey.s50)
            }
            Spacer()
            if isGuiding {
                Text(instruction)
                    .font(theme.typography.body())
                    .foregroundStyle(theme.colors.grey.s50)
                    .multilineTextAlignment(.center)
                Spacer()
                // Balances the leading Cancel button so the instruction stays centered.
                Text("Cancel")
                    .font(theme.typography.button())
                    .foregroundStyle(.clear)
            }
        }
    }

    /// The post-capture upload screen: a centred spinner over a short reassurance,
    /// on a clean full-screen background (no camera, no chrome).
    private var processing: some View {
        VStack(spacing: theme.spacing.lg) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(theme.colors.primary)
                .scaleEffect(1.4)
            VStack(spacing: theme.spacing.sm) {
                Text("Almost there")
                    .font(theme.typography.heading(size: 20))
                    .foregroundStyle(theme.colors.grey.s900)
                Text("Please wait while we process your document…")
                    .font(theme.typography.body())
                    .foregroundStyle(theme.colors.grey.s600)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(theme.spacing.xl)
    }

    private var permissionCTA: some View {
        VStack(spacing: theme.spacing.md) {
            Text("Camera access is off")
                .font(theme.typography.heading(size: 18))
                .foregroundStyle(theme.colors.grey.s50)
            Text("Enable camera access in Settings to scan your document.")
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s300)
                .multilineTextAlignment(.center)
            Button(action: onOpenSettings) {
                Text("Open Settings")
                    .font(theme.typography.button(size: 16))
                    .foregroundStyle(theme.colors.grey.s50)
                    .padding(.horizontal, theme.spacing.lg)
                    .padding(.vertical, theme.spacing.sm)
                    .background(theme.colors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: theme.spacing.sm))
            }
        }
        .padding(theme.spacing.lg)
    }

    private var bottomBar: some View {
        // The manual shutter appears only once auto-capture has timed out.
        ZStack {
            if manualShutterVisible {
                Button(action: onManualCapture) {
                    Circle()
                        .fill(theme.colors.grey.s50)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Circle().strokeBorder(theme.colors.primary, lineWidth: 4)
                        )
                }
                .accessibilityLabel("Capture")
            }
        }
        .frame(height: 72)
    }

    // MARK: - Hint mapping

    /// Maps an analyzer ``CaptureGuidance`` to its user-facing instruction.
    static func hintText(for guidance: CaptureGuidance) -> String {
        switch guidance {
        case .searching: return "Point the camera at your document"
        case .moveCloser: return "Move closer"
        case .fitDocumentInFrame: return "Fit your document in the frame"
        case .reduceGlare: return "Reduce glare"
        case .holdSteady: return "Hold steady"
        }
    }
}

/// A full-area fill with a rounded-rectangle hole, used (with an even-odd fill)
/// to dim everything around the document guide.
private struct CutoutScrim: Shape {
    let hole: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        return path
    }
}
