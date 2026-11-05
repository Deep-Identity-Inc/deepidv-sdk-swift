// DeepIDV › DocumentScanner › Capture

import DeepIDVCore
import SwiftUI
import UIKit

/// Everything drawn over the live camera while a document is captured.
///
/// One instruction at a time: the ``CaptureStage`` picks the screen and its
/// words. While scanning, the camera shows through a document-shaped window in
/// a dark frosted surround, with the instruction above, the recognised document
/// on the window's edge and the encryption note below. A captured side freezes in
/// the window; turning to the back and finishing get screens of their own.
///
/// Camera-free: it takes plain values and callbacks, so it renders in previews
/// and tests. Colors, type and spacing come from `@Environment(\.theme)`.
struct CaptureOverlayView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one instruction on screen.
    let stage: CaptureStage
    /// What is being captured, for the wording.
    var context = CaptureCopy.Context(documentType: .driversLicense)
    /// The document the classifier names, if any.
    var document: ShownDocument? = nil
    /// The photo just taken, frozen in the window while a side is confirmed.
    var capturedImage: UIImage? = nil
    /// 0–1 progress of the hold before the photo.
    var holdProgress: Double = 0
    var manualShutterVisible = false
    var permissionDenied = false
    /// Width ÷ height of the window: the 1.586∶1 ID-1 card, or the 1.42∶1
    /// passport photo page.
    var guideAspect: CGFloat = 1.586
    var onManualCapture: () -> Void = {}
    var onCancel: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// Reports where the window is drawn: its width as a share of the screen's,
    /// and the screen's width ÷ height.
    var onGuideChange: (_ widthShare: Double, _ screenAspect: Double) -> Void = { _, _ in }

    @State private var showsHelp = false

    var body: some View {
        ZStack {
            if permissionDenied {
                CaptureScreens.Permission(onOpenSettings: onOpenSettings)
            } else {
                switch screen {
                case .camera:
                    cameraScreen
                        .transition(.opacity)
                case .flip:
                    CaptureScreens.Flip(copy: copy, documentType: context.documentType)
                        .transition(.opacity)
                case .done:
                    CaptureScreens.Done(
                        copy: copy, image: capturedImage, aspect: guideAspect, analyzing: false)
                        .transition(.opacity)
                case .processing:
                    CaptureScreens.Done(
                        copy: copy, image: capturedImage, aspect: guideAspect, analyzing: true)
                        .transition(.opacity)
                }
            }
            if screen == .camera || permissionDenied {
                chrome
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: screen)
        .onChange(of: stage) { announce($0) }
        .sheet(isPresented: $showsHelp) { CaptureScreens.Help(onDone: { showsHelp = false }) }
    }

    // MARK: - Screens

    private enum Screen: Equatable {
        case camera, flip, done, processing
    }

    private var screen: Screen {
        switch stage {
        case .flip: return .flip
        case .processing: return .processing
        case .captured where context.isFinalSide: return .done
        default: return .camera
        }
    }

    private var copy: CaptureCopy { CaptureCopy.lines(for: stage, in: context) }

    // MARK: - Camera screen

    private var cameraScreen: some View {
        GeometryReader { geo in
            let window = CaptureLayout.window(in: geo.size, aspect: guideAspect)
            ZStack {
                CaptureLayout.Surround(window: window, cornerRadius: CaptureLayout.radius)

                CaptureLayout.Window(
                    rect: window, tone: tone,
                    pulses: stage == .findDocument && !reduceMotion,
                    image: stage == .captured ? capturedImage : nil)

                instruction
                    .frame(width: min(geo.size.width - theme.spacing.lg * 2, 640))
                    .position(x: geo.size.width / 2, y: window.minY - 64)

                if let pill {
                    CaptureLayout.Pill(pill: pill)
                        .position(x: geo.size.width / 2, y: window.minY)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                encryptionNote
                    .position(x: geo.size.width / 2, y: window.maxY + 32)
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: pill)
            .onAppear { reportGuide(in: geo.size) }
            .onChange(of: geo.size) { reportGuide(in: $0) }
        }
        .ignoresSafeArea()
    }

    private func reportGuide(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let window = CaptureLayout.window(in: size, aspect: guideAspect)
        onGuideChange(Double(window.width / size.width), Double(size.width / size.height))
    }

    /// The title and subtitle, cross-fading when the stage changes.
    private var instruction: some View {
        VStack(spacing: theme.spacing.sm) {
            Text(copy.title)
                .font(theme.typography.heading(size: 26).weight(.semibold))
                .foregroundStyle(theme.colors.grey.s50)
            if let subtitle = copy.subtitle {
                Text(subtitle)
                    .font(theme.typography.body(size: 16))
                    .foregroundStyle(theme.colors.grey.s50.opacity(0.72))
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
        .id(copy)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: copy)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var encryptionNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(CaptureCopy.encryption)
                .font(theme.typography.body(size: 13).weight(.medium))
        }
        .foregroundStyle(theme.colors.grey.s50.opacity(0.78))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Chrome

    /// Close at the top, the progress bar, the shutter and help at the bottom.
    private var chrome: some View {
        VStack(spacing: 0) {
            ZStack {
                if !permissionDenied {
                    CaptureLayout.ProgressBar(progress: progress, tone: tone)
                        .frame(width: 140)
                        .opacity(showsProgress ? 1 : 0)
                }
                HStack {
                    CaptureLayout.RoundButton(symbol: "xmark", label: "Cancel", action: onCancel)
                    Spacer()
                }
            }
            Spacer()
            if !permissionDenied {
                ZStack(alignment: .bottomTrailing) {
                    if manualShutterVisible {
                        shutter.frame(maxWidth: .infinity)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    CaptureLayout.RoundButton(
                        symbol: "questionmark", label: "Help with scanning",
                        action: { showsHelp = true })
                }
                .frame(maxWidth: .infinity, alignment: .bottomTrailing)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.3), value: manualShutterVisible)
            }
        }
        .padding(.horizontal, theme.spacing.lg)
        .padding(.vertical, theme.spacing.md)
    }

    /// The progress bar shows while checking (moving) and holding still (filling).
    private var showsProgress: Bool {
        stage == .checking || stage == .holdStill
    }

    /// The progress bar's fill: the hold while holding still, `nil` (moving) while
    /// checking.
    private var progress: Double? {
        stage == .holdStill ? holdProgress : nil
    }

    private var shutter: some View {
        VStack(spacing: theme.spacing.sm + 2) {
            Text("Having trouble? Take the photo yourself")
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
            .accessibilityLabel("Take photo")
        }
    }

    // MARK: - State

    /// The window's color for the stage.
    private var tone: CaptureLayout.Tone {
        switch stage {
        case .findDocument: return .idle
        case .adjust, .checking: return .active
        case .turnOver, .wrongDocument: return .warning
        case .healthCard: return .error
        case .holdStill, .captured, .flip, .processing: return .success
        }
    }

    /// The label on the window's edge: what the classifier recognised, or what's
    /// wrong with it.
    private var pill: CaptureLayout.PillModel? {
        switch stage {
        case .wrongDocument(let kind):
            return .init(text: DocumentClassCatalog.kindLabel(kind), style: .warning)
        case .healthCard:
            return .init(text: "Health card", style: .error)
        case .findDocument, .adjust, .checking, .turnOver, .holdStill:
            guard let document, let label = document.label else { return nil }
            return .init(text: label, style: document.confirmed ? .confirmed : .pending)
        case .captured, .flip, .processing:
            return nil
        }
    }

    /// Tells VoiceOver about a new stage, with a haptic when a side is captured or
    /// the document is the wrong one.
    private func announce(_ stage: CaptureStage) {
        let lines = CaptureCopy.lines(for: stage, in: context)
        if stage == .captured {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else if stage.isProblem {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        let spoken = [lines.title, lines.subtitle].compactMap { $0 }.joined(separator: ". ")
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    /// The instruction a live guidance hint shows.
    static func hintText(for guidance: CaptureGuidance) -> String {
        CaptureStage(guidance).defaultText ?? ""
    }
}
