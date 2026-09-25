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
    private let onCaptured: (CaptureResult) -> Void
    private let onError: (DeepIDVError) -> Void

    init(
        script: ChallengeScript,
        onCaptured: @escaping (CaptureResult) -> Void,
        onError: @escaping (DeepIDVError) -> Void
    ) {
        _capture = StateObject(
            wrappedValue: CustomLivenessCaptureController(
                controller: AVFoundationCameraController(position: .front, lockedFrameRate: 30),
                script: script))
        self.onCaptured = onCaptured
        self.onError = onError
    }

    var body: some View {
        ZStack {
            CameraPreviewView(session: capture.previewSession ?? AVCaptureSession())
                .ignoresSafeArea()

            GeometryReader { geo in
                let oval = ovalRect(in: geo.size)
                ZStack {
                    // Translucent scrim outside the oval so the face area reads
                    // as the target while the surroundings stay visible.
                    OvalCutoutScrim(hole: oval)
                        .fill(
                            theme.colors.grey.s900.opacity(0.45), style: FillStyle(eoFill: true))

                    // Full-screen color overlay for the flashing-colors challenge.
                    // Kept semi-transparent so the user can still see their face
                    // to stay centered — the screen still casts enough colored
                    // light for the backend's reflection-based light check.
                    if let hex = capture.activeColor {
                        Color(hex: hex).opacity(0.6)
                    }

                    ovalGuide(in: oval)

                    instructionPill
                        .position(x: geo.size.width / 2, y: oval.maxY + theme.spacing.xl)
                }
            }
            .ignoresSafeArea()
        }
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

    // MARK: - Guide geometry + chrome

    /// A portrait oval about 60% of the screen width (capped for iPad), sat a
    /// little above center so the instruction pill has room underneath.
    private func ovalRect(in size: CGSize) -> CGRect {
        let width = min(size.width * 0.6, 380)
        let height = min(width * 1.4, size.height * 0.6)
        return CGRect(
            x: (size.width - width) / 2, y: (size.height - height) / 2 - theme.spacing.lg,
            width: width, height: height)
    }

    /// Primary outline, with a success ring that fills as the challenge progresses.
    private func ovalGuide(in rect: CGRect) -> some View {
        ZStack {
            Ellipse()
                .strokeBorder(theme.colors.primary.opacity(0.9), lineWidth: 4)
            Ellipse()
                .trim(from: 0, to: capture.progress)
                .stroke(theme.colors.success, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .animation(.linear(duration: 0.1), value: capture.progress)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private var prompt: String {
        if capture.centeringDone {
            return capture.activeColor == nil ? "Slowly move closer" : "Hold still"
        }
        return capture.tooClose ? "Move back a little" : "Center your face in the oval"
    }

    /// Same white pill the document scanner uses for its side label, so the
    /// instruction stays legible over any background.
    private var instructionPill: some View {
        Text(prompt)
            .font(theme.typography.button(size: 17))
            .foregroundStyle(theme.colors.grey.s900)
            .multilineTextAlignment(.center)
            .padding(.horizontal, theme.spacing.lg)
            .padding(.vertical, theme.spacing.md)
            .background(theme.colors.grey.s50)
            .clipShape(Capsule())
            .shadow(color: theme.colors.grey.s900.opacity(0.25), radius: 8, y: 2)
            .animation(.easeInOut(duration: 0.2), value: prompt)
    }
}

/// Full rect minus an ellipse, filled even-odd to dim everything outside the face guide.
private struct OvalCutoutScrim: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addEllipse(in: hole)
        return path
    }
}
