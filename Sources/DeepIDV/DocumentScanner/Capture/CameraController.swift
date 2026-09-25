// DeepIDV › DocumentScanner › Capture

import AVFoundation  // re-exports CoreVideo/CoreMedia: CVPixelBuffer, CMSampleBuffer
import DeepIDVCore
import Foundation

/// One frame handed from a ``CameraController`` to the capture pipeline.
///
/// Cross-platform by design: the live iOS controller fills `pixelBuffer` with a
/// streamed video frame (for analysis) or `imageData` with a high-resolution
/// photo, while tests and SwiftUI previews construct frames carrying a scripted
/// `syntheticQuality` and no pixels. That shape is what lets the capture loop be
/// driven with no camera in tests.
///
/// `@unchecked Sendable`: `CVPixelBuffer` isn't `Sendable`, but a delivered frame
/// is treated as immutable and read-only as it flows camera-thread → analyzer, so
/// it's safe to pass across that boundary.
struct CameraFrame: @unchecked Sendable {
    /// Monotonic index within a capture session. Lets a scripted evaluator map a
    /// frame to its fixture and keeps frames ordered for debugging.
    let index: Int

    /// The live video pixels (for per-frame analysis). `nil` for synthetic
    /// frames and for photo stills (which carry `imageData`).
    let pixelBuffer: CVPixelBuffer?

    /// Pre-computed metrics for the no-camera path (``PassthroughFrameEvaluator``).
    /// The live ``VisionDocumentFrameEvaluator`` ignores this and measures the
    /// pixel buffer instead; it's `nil` for real camera frames.
    let syntheticQuality: CaptureQuality?

    /// A fully-encoded JPEG from a high-resolution photo capture — already upright
    /// (EXIF orientation set by the capture connection). When present, encoders
    /// upload it directly instead of processing a pixel buffer. `nil` for streamed
    /// video frames and synthetic frames.
    let imageData: Data?

    /// A synthetic frame for tests and previews — carries scripted metrics, no pixels.
    init(index: Int, syntheticQuality: CaptureQuality? = nil) {
        self.index = index
        self.pixelBuffer = nil
        self.syntheticQuality = syntheticQuality
        self.imageData = nil
    }

    /// A live video frame from the camera.
    init(index: Int, pixelBuffer: CVPixelBuffer?) {
        self.index = index
        self.pixelBuffer = pixelBuffer
        self.syntheticQuality = nil
        self.imageData = nil
    }

    /// A high-resolution still from the photo output (pre-encoded JPEG).
    init(index: Int, imageData: Data) {
        self.index = index
        self.pixelBuffer = nil
        self.syntheticQuality = nil
        self.imageData = imageData
    }
}

/// The camera seam. The capture views depend on this protocol, never on
/// `AVCaptureSession` directly, so a ``FakeCameraController`` can stand in for the
/// real camera in tests and previews.
///
/// Frames arrive on the `frames` stream; `captureStill()` resolves a high-quality
/// still for the capture path. `Sendable` (a reference type shared across the
/// camera queue and the main actor) — conformers serialize their own mutable state.
protocol CameraController: AnyObject, Sendable {
    /// The live stream of frames once `start()` has run. Finishes when `stop()`
    /// is called or the session ends.
    var frames: AsyncStream<CameraFrame> { get }

    /// Configures (if needed) and starts the capture session. Throws a
    /// `.captureFailed`/`.cameraPermissionDenied` ``DeepIDVError`` if the camera
    /// can't be opened.
    func start() async throws

    /// Stops the session and finishes the `frames` stream.
    func stop()

    /// Captures a single high-resolution still (for the manual-shutter path, and
    /// the moment auto-capture locks).
    func captureStill() async throws -> CameraFrame
}

/// A scripted ``CameraController`` for tests and SwiftUI previews.
///
/// Emits a fixed sequence of synthetic frames — each carrying a ``CaptureQuality``
/// — then finishes. Paired with ``PassthroughFrameEvaluator`` it drives a
/// ``DocumentCaptureAnalyzer`` to a deterministic decision with no camera, on any
/// platform. No real concurrency hazards: the scripted frames are immutable.
final class FakeCameraController: CameraController, @unchecked Sendable {
    private let scriptedFrames: [CameraFrame]
    private let stillIndex: Int

    /// - Parameters:
    ///   - qualities: one scripted ``CaptureQuality`` per emitted frame, in order.
    ///   - stillIndex: which frame ``captureStill()`` returns (defaults to the last).
    init(qualities: [CaptureQuality], stillIndex: Int? = nil) {
        self.scriptedFrames = qualities.enumerated().map { index, quality in
            CameraFrame(index: index, syntheticQuality: quality)
        }
        self.stillIndex = stillIndex ?? max(0, qualities.count - 1)
    }

    /// Emits `frameCount` plain indexed frames (no scripted document quality) — for
    /// the selfie tests, which compute ``FaceQuality`` from a separate evaluator
    /// keyed by ``CameraFrame/index``.
    init(frameCount: Int, stillIndex: Int? = nil) {
        self.scriptedFrames = (0..<max(0, frameCount)).map { CameraFrame(index: $0) }
        self.stillIndex = stillIndex ?? max(0, frameCount - 1)
    }

    var frames: AsyncStream<CameraFrame> {
        AsyncStream { continuation in
            for frame in scriptedFrames { continuation.yield(frame) }
            continuation.finish()
        }
    }

    func start() async throws {}

    func stop() {}

    func captureStill() async throws -> CameraFrame {
        guard scriptedFrames.indices.contains(stillIndex) else {
            throw DeepIDVError.captureFailed("No frame available to capture.")
        }
        return scriptedFrames[stillIndex]
    }
}

/// The live `AVCaptureSession`-backed controller (iOS-only, D9).
///
/// Streams BGRA video frames (the format ``VisionDocumentFrameEvaluator``
/// expects) off a serial queue for per-frame analysis, and serves
/// `captureStill()` from a dedicated `AVCapturePhotoOutput` for a full-resolution
/// final image. All capture connections are rotated to portrait so the analyzed
/// frames and the saved photo are upright (matching the on-screen guide).
///
/// `@unchecked Sendable`: all mutable state is confined to `sessionQueue` /
/// `sampleQueue`; nothing is touched concurrently.
final class AVFoundationCameraController: NSObject, CameraController, @unchecked Sendable {
    private let position: AVCaptureDevice.Position
    /// When set, pins the sensor frame rate so auto-exposure can't drop it in
    /// dim light (a `.photo`-preset sensor otherwise stretches exposures to
    /// ~2-3 fps in low light, starving both face detection and the replay clip).
    /// `nil` leaves the default behavior (document/selfie flows).
    private let lockedFrameRate: Int?
    /// The capture session, exposed so the SwiftUI preview layer can bind to it.
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.deepidv.camera.session")
    private let sampleQueue = DispatchQueue(label: "com.deepidv.camera.frames")

    private let continuation: AsyncStream<CameraFrame>.Continuation
    let frames: AsyncStream<CameraFrame>

    /// Read/written only on `sampleQueue`.
    private var frameIndex = 0
    /// Retains the in-flight photo-capture delegate until it completes.
    private var photoDelegate: PhotoCaptureDelegate?
    /// Active replay-clip recorder (custom-liveness only). Touched only on
    /// `sampleQueue`; `nil` when not recording.
    private var clipRecorder: LivenessClipRecorder?

    init(position: AVCaptureDevice.Position = .back, lockedFrameRate: Int? = nil) {
        self.position = position
        self.lockedFrameRate = lockedFrameRate
        var continuation: AsyncStream<CameraFrame>.Continuation!
        // Liveness: bound the analysis buffer so slow face-detection can't pile up
        // frame copies. Document/selfie keep the unbounded stream (unchanged).
        if lockedFrameRate != nil {
            self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation = $0 }
        } else {
            self.frames = AsyncStream { continuation = $0 }
        }
        self.continuation = continuation
        super.init()
    }

    /// Pool for analysis-frame copies (liveness), lazily created at the sensor's
    /// dimensions. Confined to `sampleQueue`.
    private var analysisPool: CVPixelBufferPool?

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    self.applyFrameRateLock()  // must be after startRunning to stick
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        // Drop any recorder (a successful run finalizes it first via
        // `stopRecording()`; this only matters when capture threw mid-attempt).
        sampleQueue.async { self.clipRecorder = nil }
        continuation.finish()
    }

    /// Starts recording the video feed to a replay clip (custom-liveness only —
    /// the document/selfie flows never call this). Safe to call once per run.
    func startRecording() {
        sampleQueue.async { self.clipRecorder = LivenessClipRecorder() }
    }

    /// Stops recording and returns the finished mp4 bytes (`nil` if unavailable).
    /// Nils the recorder on `sampleQueue` first so no further frames are appended
    /// while the writer is being flushed.
    func stopRecording() async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            sampleQueue.async {
                let recorder = self.clipRecorder
                self.clipRecorder = nil
                guard let recorder else {
                    cont.resume(returning: nil)
                    return
                }
                Task { cont.resume(returning: await recorder.finish()) }
            }
        }
    }

    /// Captures a full-resolution still via the photo output (upright JPEG).
    /// Throws if the photo can't be produced — the caller can then fall back to
    /// a streamed video frame.
    func captureStill() async throws -> CameraFrame {
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<CameraFrame, Error>) in
            sessionQueue.async {
                guard self.session.isRunning,
                    self.session.outputs.contains(where: { $0 === self.photoOutput })
                else {
                    cont.resume(
                        throwing: DeepIDVError.captureFailed(
                            "Camera is not ready to capture a photo."))
                    return
                }
                let settings = AVCapturePhotoSettings(format: [
                    AVVideoCodecKey: AVVideoCodecType.jpeg
                ])
                // Retained here (on `sessionQueue`) until the next capture
                // replaces it; its completion resumes the continuation once.
                let delegate = PhotoCaptureDelegate { result in
                    cont.resume(with: result)
                }
                self.photoDelegate = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// Wires the camera input, a BGRA video output (analysis), and a photo
    /// output (final still); rotates every connection to portrait.
    private func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Liveness manages its own format/frame-rate below, so it must run in
        // input-priority — a concrete preset lets the device override the
        // frame-duration pin we set. Document/selfie keep `.photo` (hi-res stills).
        session.sessionPreset = lockedFrameRate == nil ? .photo : .inputPriority

        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            throw DeepIDVError.captureFailed("Unable to open the camera.")
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(videoOutput) else {
            throw DeepIDVError.captureFailed("Unable to attach the camera output.")
        }
        session.addOutput(videoOutput)

        // Full-resolution still capture for the final image.
        guard session.canAddOutput(photoOutput) else {
            throw DeepIDVError.captureFailed("Unable to attach the photo output.")
        }
        session.addOutput(photoOutput)

        // Deliver upright buffers/photos so Vision's fill/aspect gates and the
        // saved image match what the user frames on screen. Resolved per device:
        // a fixed 90° is right for the rear camera but leaves the iPad's
        // front camera (mounted along the other edge) 180° out.
        Self.applyUprightRotation(
            to: [videoOutput.connection(with: .video), photoOutput.connection(with: .video)],
            device: device,
            previewLayer: nil)

        // Continuous autofocus keeps the document sharp as the user moves.
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            // Pin the frame rate (liveness). The `.photo` preset's active format
            // is the full-resolution stills format, which tops out at a low fps
            // and gets dragged lower in dim light — so we switch to an explicit
            // ≤1080p video format that supports the target rate, then pin it.
            if let fps = lockedFrameRate {
                let picked = Self.videoFormat(for: device, fps: fps)
                if let picked { device.activeFormat = picked }
                let ranges = device.activeFormat.videoSupportedFrameRateRanges
                let canPin = ranges.contains { $0.maxFrameRate >= Double(fps) }
                if canPin {
                    let duration = CMTime(value: 1, timescale: Int32(fps))
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                }
            }
            device.unlockForConfiguration()
        }
    }

    /// Re-pins the sensor frame rate after `startRunning()` — setting it only
    /// during `configureIfNeeded` (before the session runs) doesn't reliably
    /// stick, so low light drags the delivered rate back down.
    private func applyFrameRateLock() {
        guard let fps = lockedFrameRate,
            let device = (session.inputs.first as? AVCaptureDeviceInput)?.device,
            (try? device.lockForConfiguration()) != nil
        else { return }
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        if ranges.contains(where: { $0.maxFrameRate >= Double(fps) }) {
            let duration = CMTime(value: 1, timescale: Int32(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        device.unlockForConfiguration()
    }

    /// Picks the highest-resolution (but ≤1080p) camera format that can sustain
    /// `fps`, so the sensor delivers a smooth stream instead of the low-fps,
    /// full-resolution `.photo` format. `nil` if none qualifies (caller keeps the
    /// preset's format). ≤1080p keeps still quality ample for face PAD while
    /// guaranteeing 30 fps.
    static func videoFormat(for device: AVCaptureDevice, fps: Int) -> AVCaptureDevice.Format? {
        let target = Double(fps)
        let maxArea = 1920 * 1080
        func area(_ format: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        return device.formats
            .filter { format in
                area(format) <= maxArea
                    && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= target }
            }
            .max { area($0) < area($1) }
    }

    /// Rotates a capture connection so its output is upright in portrait. Uses
    /// the iOS 17+ `videoRotationAngle` API, falling back to `videoOrientation`.
    /// Rotates `connections` so their output is upright for `device` as the
    /// user currently holds the phone/tablet — via `RotationCoordinator` on
    /// iOS 17+, which knows how each camera is physically mounted. Pass the
    /// preview layer for a preview connection (its angle accounts for
    /// mirroring), `nil` for capture outputs. Falls back to the legacy
    /// portrait orientation on older systems.
    static func applyUprightRotation(
        to connections: [AVCaptureConnection?],
        device: AVCaptureDevice,
        previewLayer: AVCaptureVideoPreviewLayer?
    ) {
        if #available(iOS 17.0, *) {
            let coordinator = AVCaptureDevice.RotationCoordinator(
                device: device, previewLayer: previewLayer)
            let angle =
                previewLayer == nil
                ? coordinator.videoRotationAngleForHorizonLevelCapture
                : coordinator.videoRotationAngleForHorizonLevelPreview
            for connection in connections {
                guard let connection else { continue }
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                } else {
                    applyPortraitRotation(to: connection)
                }
            }
        } else {
            for connection in connections { applyPortraitRotation(to: connection) }
        }
    }

    static func applyPortraitRotation(to connection: AVCaptureConnection?) {
        guard let connection else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
}

extension AVFoundationCameraController {
    /// Copies a sensor pixel buffer into a private pool buffer so the sensor's
    /// buffer can be released the moment `captureOutput` returns. Runs on
    /// `sampleQueue`. Returns `nil` on failure (caller falls back to the sensor
    /// buffer, accepting the throttle for that frame).
    fileprivate func analysisCopy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        if analysisPool == nil {
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary,
                [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: CVPixelBufferGetWidth(src),
                    kCVPixelBufferHeightKey as String: CVPixelBufferGetHeight(src),
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ] as CFDictionary,
                &pool)
            analysisPool = pool
        }
        guard let pool = analysisPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
            let dst = out
        else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let sb = CVPixelBufferGetBaseAddress(src),
            let db = CVPixelBufferGetBaseAddress(dst)
        else { return nil }
        let srcBPR = CVPixelBufferGetBytesPerRow(src)
        let dstBPR = CVPixelBufferGetBytesPerRow(dst)
        let h = CVPixelBufferGetHeight(src)
        if srcBPR == dstBPR {
            memcpy(db, sb, srcBPR * h)
        } else {
            let rowBytes = min(srcBPR, dstBPR)
            for row in 0..<h {
                memcpy(db.advanced(by: row * dstBPR), sb.advanced(by: row * srcBPR), rowBytes)
            }
        }
        return dst
    }
}

extension AVFoundationCameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Feed the replay-clip recorder (when active) off the same stream.
        clipRecorder?.append(sampleBuffer)
        // Liveness: hand Vision a *copy* so the camera's pool buffer is released
        // immediately. Holding it (the default) starves the tiny video-output
        // pool and throttles delivery to Vision's slow rate. Document/selfie
        // pass the buffer through unchanged.
        let delivered =
            lockedFrameRate == nil ? pixelBuffer : (analysisCopy(pixelBuffer) ?? pixelBuffer)
        let frame = CameraFrame(index: frameIndex, pixelBuffer: delivered)
        frameIndex += 1
        continuation.yield(frame)
    }
}

/// Bridges ``AVCapturePhotoOutput``'s delegate callback to a `Result`, packaging
/// the captured photo as a JPEG-bearing ``CameraFrame``.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<CameraFrame, Error>) -> Void

    init(completion: @escaping (Result<CameraFrame, Error>) -> Void) {
        self.completion = completion
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(
                .failure(
                    DeepIDVError.captureFailed(
                        "Photo capture failed.", causeDescription: error.localizedDescription)))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(DeepIDVError.captureFailed("Captured photo had no data.")))
            return
        }
        completion(.success(CameraFrame(index: 0, imageData: data)))
    }
}
