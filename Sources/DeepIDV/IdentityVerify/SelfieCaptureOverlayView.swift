// DeepIDV › IdentityVerify

import SwiftUI
import UIKit

/// The selfie camera overlay: the frosted surround with an oval window, the
/// instruction above it, a color that follows the framing, the photo frozen
/// with a tick once taken, the manual shutter and the close button. Camera
/// access off gets its own screen.
///
/// The selfie sibling of ``CaptureOverlayView``, drawn with
/// ``FaceCaptureOverlay``. Camera-free (plain values and callbacks), so it
/// renders in previews and tests.
struct SelfieCaptureOverlayView: View {
    /// The subtitle while waiting for a face.
    let instruction: String
    let guidance: SelfieGuidance?
    let manualShutterVisible: Bool
    let permissionDenied: Bool
    /// The photo just taken.
    var capturedImage: UIImage? = nil
    var onManualCapture: () -> Void = {}
    var onCancel: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    var body: some View {
        if permissionDenied {
            CaptureScreens.Permission(purpose: L("take a selfie"), onOpenSettings: onOpenSettings)
                .overlay(alignment: .topLeading) {
                    CaptureLayout.RoundButton(symbol: "xmark", label: L("Cancel"), action: onCancel)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
        } else {
            let copy = Self.copy(
                guidance: guidance, captured: capturedImage != nil, instruction: instruction)
            FaceCaptureOverlay(
                title: copy.title, subtitle: copy.subtitle,
                tone: Self.tone(guidance: guidance, captured: capturedImage != nil),
                capturedImage: capturedImage,
                manualShutterVisible: manualShutterVisible && capturedImage == nil,
                onManualCapture: onManualCapture,
                onCancel: onCancel)
                .onChange(of: guidance) { announce($0) }
        }
    }

    /// The title and subtitle for the framing.
    static func copy(
        guidance: SelfieGuidance?, captured: Bool, instruction: String
    ) -> CaptureCopy {
        if captured { return .init(title: L("Got it!"), subtitle: L("Your selfie was taken")) }
        switch guidance {
        case nil, .noFace?:
            return .init(title: L("Position your face in the oval"), subtitle: instruction)
        case .multipleFaces?:
            return .init(title: L("Only your face, please"), subtitle: L("Make sure no one else is in view"))
        case .moveCloser?:
            return .init(title: L("Move a little closer"), subtitle: L("Your face should fill the oval"))
        case .centerFace?:
            return .init(title: L("Center your face in the oval"), subtitle: L("Look straight at the screen"))
        case .holdSteady?:
            return .init(title: L("Hold still…"), subtitle: L("Taking the photo"))
        }
    }

    /// The oval's color: white while looking, blue while lining up, amber for
    /// someone else in view, green when the photo is about to be taken.
    static func tone(guidance: SelfieGuidance?, captured: Bool) -> CaptureLayout.Tone {
        if captured { return .success }
        switch guidance {
        case nil, .noFace?: return .idle
        case .moveCloser?, .centerFace?: return .active
        case .multipleFaces?: return .warning
        case .holdSteady?: return .success
        }
    }

    private func announce(_ guidance: SelfieGuidance?) {
        guard let guidance else { return }
        UIAccessibility.post(notification: .announcement, argument: Self.hintText(for: guidance))
    }

    /// Maps a ``SelfieGuidance`` to its user-facing instruction.
    static func hintText(for guidance: SelfieGuidance) -> String {
        copy(guidance: guidance, captured: false, instruction: "").title
    }
}

#Preview {
    SelfieCaptureOverlayView(
        instruction: L("The photo will be taken automatically"),
        guidance: .moveCloser,
        manualShutterVisible: true,
        permissionDenied: false
    )
    .background(.black)
}
