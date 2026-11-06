// DeepIDV › FaceLiveness

import AVFoundation
import DeepIDVCore
import SwiftUI

/// The live capture surface for one challenge: camera preview + oval + status,
/// with a full-screen color overlay for the flashing-colors challenge. Owns a
/// ``CustomLivenessCaptureController`` scoped to this `script`.
///
/// Shared by ``CustomFaceLivenessFlowView`` and the re-verify flow. The
/// controller is built once per view identity, so a caller that runs a new
/// script must give each run its own `.id(_:)`.
struct CaptureRunView: View {
    @Environment(\.theme) private var theme
    @StateObject private var capture: CustomLivenessCaptureController
    private let challenge: ChallengeType
    private let onCaptured: (CaptureResult) -> Void
    private let onError: (DeepIDVError) -> Void
    private let onCancel: (() -> Void)?

    init(
        script: ChallengeScript,
        onCancel: (() -> Void)? = nil,
        onCaptured: @escaping (CaptureResult) -> Void,
        onError: @escaping (DeepIDVError) -> Void
    ) {
        _capture = StateObject(
            wrappedValue: CustomLivenessCaptureController(
                controller: AVFoundationCameraController(position: .front, lockedFrameRate: 30),
                script: script))
        self.challenge = script.challengeType
        self.onCancel = onCancel
        self.onCaptured = onCaptured
        self.onError = onError
    }

    var body: some View {
        ZStack {
            CameraPreviewView(session: capture.previewSession ?? AVCaptureSession())
                .ignoresSafeArea()
            let copy = Self.copy(
                challenge: challenge, centered: capture.centeringDone,
                tooClose: capture.tooClose, flashing: capture.activeColor != nil)
            FaceCaptureOverlay(
                title: copy.title, subtitle: copy.subtitle,
                tone: Self.tone(
                    centered: capture.centeringDone, tooClose: capture.tooClose,
                    flashing: capture.activeColor != nil),
                progress: capture.centeringDone ? capture.progress : nil,
                flashColor: capture.activeColor,
                onCancel: onCancel)
        }
        .background(theme.colors.grey.s900)
        .task {
            do {
                let result = try await capture.run()
                onCaptured(result)
            } catch let error as DeepIDVError {
                onError(error)
            } catch {
                onError(.captureFailed("Liveness capture failed: \(error)"))
            }
        }
    }

    /// The words for where the check is.
    static func copy(
        challenge: ChallengeType, centered: Bool, tooClose: Bool, flashing: Bool
    ) -> CaptureCopy {
        if flashing {
            return .init(title: L("Hold still"), subtitle: L("Keep looking at the screen"))
        }
        if centered {
            switch challenge {
            case .faceMovement:
                return .init(title: L("Slowly move closer"), subtitle: L("Keep your face inside the oval"))
            case .faceMovementAndLight:
                return .init(title: L("Hold still"), subtitle: L("The screen will flash a few colors"))
            }
        }
        if tooClose {
            return .init(title: L("Move back a little"), subtitle: L("Your whole face should fit in the oval"))
        }
        switch challenge {
        case .faceMovement:
            return .init(title: L("Position your face in the oval"), subtitle: L("Look straight at the screen"))
        case .faceMovementAndLight:
            return .init(
                title: L("Position your face in the oval"),
                subtitle: L("Then hold still while the screen flashes colors"))
        }
    }

    /// The oval's color: white while looking for the face, amber when too close,
    /// green once it's in place.
    static func tone(centered: Bool, tooClose: Bool, flashing: Bool) -> CaptureLayout.Tone {
        if centered || flashing { return .success }
        if tooClose { return .warning }
        return .idle
    }
}
