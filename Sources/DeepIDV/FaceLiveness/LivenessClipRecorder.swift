// DeepIDV › FaceLiveness

import AVFoundation
import Foundation

/// Records the live camera feed to an H.264 `.mp4` on disk for the custom-liveness
/// operator replay clip (parity with the web verify flow).
///
/// Three things it has to get right (each was a bug in an earlier revision):
///
/// 1. **Never retain the capture buffers.** The camera delivers frames from a
///    small fixed pool; holding those `CMSampleBuffer`s to encode later drains
///    the pool, the session stops delivering frames, and the Vision face-detection
///    that drives centering stalls ("keep your face in the oval" forever). So each
///    frame is copied into a private pool buffer and the camera buffer is released
///    immediately, inside `append`.
///
/// 2. **Feed the encoder the way it expects.** With `expectsMediaDataInRealTime =
///    false` the input only accepts data while it calls back through
///    `requestMediaDataWhenReady`; polling `isReadyForMoreMediaData` by hand leaves
///    it mostly "not ready" and almost nothing gets encoded (a ~0.5s clip). The
///    pull callback (`pump`) appends queued copies whenever the encoder is ready.
///
/// 3. **Even, synthetic timestamps.** Frames are stamped by encode order at a fixed
///    fps, so the clip always plays back smoothly — never frozen — and if a few
///    frames are ever dropped it just runs slightly shorter.
///
/// `@unchecked Sendable`: `pending`/`finishing` are lock-guarded; the writer,
/// `frameCount`, and `finalized` are confined to `writerQueue`. The owner nils its
/// reference on the sample queue before `finish()`, so no `append` races finalize.
final class LivenessClipRecorder: @unchecked Sendable {
    private let outputURL: URL
    private let writerQueue = DispatchQueue(label: "com.deepidv.liveness.clip")
    private let lock = NSLock()

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pool: CVPixelBufferPool?

    private var pending: [(CVPixelBuffer, CMTime)] = []  // lock-guarded (frame + real PTS)
    private var finishing = false               // lock-guarded
    private var frameCount: Int64 = 0           // writerQueue only
    private var sessionStarted = false          // writerQueue only
    private var finalized = false               // writerQueue only
    private var prevPTS: CMTime = .zero          // writerQueue: last frame's real PTS
    private var clipTime: CMTime = .zero         // writerQueue: gap-capped playback time
    private var finishCont: CheckedContinuation<Data?, Never>?

    /// Any inter-frame gap longer than this collapses to this — so a delivery
    /// stall (writer spin-up, a heavy Vision burst) never becomes a frozen
    /// stretch in the replay. Steady capture (≤10 fps and up) is unaffected.
    private static let maxGap = CMTime(value: 1, timescale: 10)  // 0.1s
    /// Floor for the (possibly-capped) inter-frame delta. `AVAssetWriterInputPixelBufferAdaptor`
    /// requires strictly increasing presentation times; two real timestamps can
    /// round to the same tick at this `CMTime` timescale when frames arrive
    /// faster than ~1/600s apart (e.g. a tight append loop), which would
    /// otherwise hand the encoder a duplicate PTS and fail the whole clip.
    private static let minTick = CMTime(value: 1, timescale: 600)

    // Instrumentation (temporary): distinguishes camera-delivery loss from
    // encoder-throughput loss. Logged once at finalize.
    private var appendCount = 0                 // sampleQueue
    private var copyFailCount = 0               // sampleQueue
    private var dropOldestCount = 0             // sampleQueue (lock)
    private var firstAppendAt: Date?            // sampleQueue
    private var totalCopyNanos: UInt64 = 0      // sampleQueue

    private static let queueCap = 12            // encoder keeps up, so this stays near-empty

    init() {
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("liveness-\(UUID().uuidString).mp4")
    }

    /// Sample-buffer entry point (SDK UI flow): pulls the pixel buffer and its
    /// real presentation timestamp off the camera's `CMSampleBuffer`.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let src = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        append(src, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Pixel-buffer entry point (headless replay): the integrator holds only a
    /// `CVPixelBuffer` and supplies the timestamp. Copies the frame into a private
    /// pool buffer and enqueues it; configures the writer lazily from the first
    /// frame.
    func append(_ src: CVPixelBuffer, at pts: CMTime) {
        lock.lock(); let done = finishing; lock.unlock()
        guard !done else { return }
        if firstAppendAt == nil { firstAppendAt = Date() }
        appendCount += 1
        if writer == nil {
            configure(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let pool, let copy = Self.copy(src, pool: pool) else { copyFailCount += 1; return }
        totalCopyNanos += DispatchTime.now().uptimeNanoseconds - t0
        lock.lock()
        if pending.count >= Self.queueCap { pending.removeFirst(); dropOldestCount += 1 }  // drop oldest
        pending.append((copy, pts))
        lock.unlock()
    }

    /// Drains queued copies into the encoder while it's ready. Invoked by the
    /// encoder via `requestMediaDataWhenReady`, and once by `finish()`. Runs only
    /// on `writerQueue`.
    private func pump() {
        guard !finalized, let input, let adaptor, let writer else { return }
        while input.isReadyForMoreMediaData {
            lock.lock()
            let next = pending.isEmpty ? nil : pending.removeFirst()
            let readyToFinish = finishing && pending.isEmpty
            lock.unlock()
            if let (px, pts) = next {
                // Build the playback clock from real capture deltas, but cap each
                // gap — so steady capture plays at true speed while any stall
                // (e.g. the 4s writer/Vision spin-up) collapses instead of
                // freezing the frame.
                if !sessionStarted {
                    writer.startSession(atSourceTime: .zero)
                    clipTime = .zero
                    prevPTS = pts
                    sessionStarted = true
                } else {
                    let delta = CMTimeSubtract(pts, prevPTS)
                    let capped = CMTimeMaximum(Self.minTick, CMTimeMinimum(delta, Self.maxGap))
                    clipTime = CMTimeAdd(clipTime, capped)
                    prevPTS = pts
                }
                adaptor.append(px, withPresentationTime: clipTime)
                frameCount += 1
            } else if readyToFinish {
                finalized = true
                let secs = firstAppendAt.map { Date().timeIntervalSince($0) } ?? 0
                let rate = secs > 0 ? Double(appendCount) / secs : 0
                let avgCopyMs = appendCount > 0 ? Double(totalCopyNanos) / Double(appendCount) / 1_000_000 : 0
                #if DEBUG
                print(String(
                    format: "[LivenessClip] appended=%d encoded=%d copyFails=%d dropOldest=%d realSecs=%.1f deliveredFPS=%.1f avgCopyMs=%.1f",
                    appendCount, frameCount, copyFailCount, dropOldestCount, secs, rate, avgCopyMs))
                #endif
                if frameCount > 0, writer.status == .writing {
                    input.markAsFinished()
                    writer.finishWriting { [weak self] in
                        guard let self else { return }
                        let data = writer.status == .completed ? try? Data(contentsOf: self.outputURL) : nil
                        self.cleanup()
                        self.finishCont?.resume(returning: data)
                        self.finishCont = nil
                    }
                } else {
                    cleanup()
                    finishCont?.resume(returning: nil)
                    finishCont = nil
                }
                return
            } else {
                return  // nothing queued; the next append + ready callback re-pumps
            }
        }
    }

    /// Flushes remaining copies, finalizes the file, and returns the mp4 bytes —
    /// `nil` on failure or if nothing was recorded.
    func finish() async -> Data? {
        markFinishing()
        guard writer != nil else { cleanup(); return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            writerQueue.async {
                self.finishCont = cont
                self.pump()  // kick, in case the ready-callback is currently parked
            }
        }
    }

    private func configure(width: Int, height: Int) {
        guard width > 0, height > 0,
            let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        else { return }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { return }
        writer.add(input)

        // Private pool for the frame copies (IOSurface-backed → fast alloc + fast
        // encode). Sized above the queue cap so held copies never starve it.
        var createdPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: Self.queueCap + 6] as CFDictionary,
            [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ] as CFDictionary,
            &createdPool)

        guard writer.startWriting() else { return }
        // Session start time is set from the first frame's real PTS in `pump`.

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.pool = createdPool

        input.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
            self?.pump()
        }
    }

    /// Copies a camera pixel buffer into a fresh pool buffer so the capture-pool
    /// buffer can be released immediately (design note 1).
    private static func copy(_ src: CVPixelBuffer, pool: CVPixelBufferPool) -> CVPixelBuffer? {
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

    /// Synchronous so the `NSLock` is never touched from `finish()`'s async
    /// context (disallowed in the Swift 6 language mode).
    private func markFinishing() {
        lock.lock(); finishing = true; lock.unlock()
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: outputURL)
    }
}
