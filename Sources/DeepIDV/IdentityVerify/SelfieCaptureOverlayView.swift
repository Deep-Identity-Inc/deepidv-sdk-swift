// DeepIDV › IdentityVerify

import SwiftUI

/// The selfie camera overlay: the oval face guide, the live framing hint,
/// the manual shutter, a cancel affordance, and the permission-denied CTA.
///
/// The selfie sibling of ``CaptureOverlayView`` — camera-free (plain values +
/// callbacks) so it renders in previews and tests. All styling
/// resolves from `@Environment(\.theme)`; opacities derive from grey tokens, not
/// raw literals. Kept separate from the document overlay because
/// the guide shape (oval vs. rectangle) and the hints differ.
struct SelfieCaptureOverlayView: View {
    @Environment(\.theme) private var theme

    let instruction: String
    let guidance: SelfieGuidance?
    let manualShutterVisible: Bool
    let permissionDenied: Bool
    var onManualCapture: () -> Void = {}
    var onCancel: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: theme.spacing.lg) {
            topBar
            Spacer()
            if permissionDenied {
                permissionCTA
            } else {
                ovalGuide
            }
            Spacer()
            if !permissionDenied { bottomBar }
        }
        .padding(theme.spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(theme.typography.button())
                    .foregroundStyle(theme.colors.grey.s50)
            }
            Spacer()
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

    private var ovalGuide: some View {
        VStack(spacing: theme.spacing.md) {
            Ellipse()
                .strokeBorder(theme.colors.primary, lineWidth: 3)
                .aspectRatio(0.78, contentMode: .fit)  // a head-shaped oval
                .frame(maxWidth: .infinity)
                .padding(.horizontal, theme.spacing.xl)

            if let guidance {
                Text(Self.hintText(for: guidance))
                    .font(theme.typography.body())
                    .foregroundStyle(theme.colors.grey.s50)
                    .padding(.horizontal, theme.spacing.md)
                    .padding(.vertical, theme.spacing.sm)
                    .background(theme.colors.grey.s900.opacity(0.6))
                    .clipShape(Capsule())
            }
        }
    }

    private var permissionCTA: some View {
        VStack(spacing: theme.spacing.md) {
            Text("Camera access is off")
                .font(theme.typography.heading(size: 18))
                .foregroundStyle(theme.colors.grey.s50)
            Text("Enable camera access in Settings to take a selfie.")
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
        ZStack {
            if manualShutterVisible {
                Button(action: onManualCapture) {
                    Circle()
                        .fill(theme.colors.grey.s50)
                        .frame(width: 64, height: 64)
                        .overlay(Circle().strokeBorder(theme.colors.primary, lineWidth: 4))
                }
                .accessibilityLabel("Capture")
            }
        }
        .frame(height: 72)
    }

    // MARK: - Hint mapping

    /// Maps a ``SelfieGuidance`` to its user-facing instruction.
    static func hintText(for guidance: SelfieGuidance) -> String {
        switch guidance {
        case .noFace: return "Look at the camera"
        case .multipleFaces: return "Only your face should be visible"
        case .moveCloser: return "Move closer"
        case .centerFace: return "Center your face in the circle"
        case .holdSteady: return "Hold steady"
        }
    }
}

#Preview {
    SelfieCaptureOverlayView(
        instruction: "Center your face in the circle",
        guidance: .moveCloser,
        manualShutterVisible: true,
        permissionDenied: false
    )
    .background(.black)
}
