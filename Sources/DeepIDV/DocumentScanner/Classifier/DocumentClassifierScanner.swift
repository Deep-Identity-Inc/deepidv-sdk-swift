// DeepIDV › DocumentScanner › Classifier

import CoreVideo
import DeepIDVCore
import Foundation
import OSLog

/// Sends one frame to the classifier. The seam that lets the scanner run against
/// scripted answers in tests.
protocol DetectSending: Sendable {
    func detect(_ request: DetectRequest) async throws -> DetectResponse
}

extension DetectClient: DetectSending {}

/// Runs the document classifier alongside the on-device checks for one card
/// front or passport photo page.
///
/// The capture model offers it every frame. At most one call is in flight, at
/// least half a second apart, with backoff after failures. Each answer steps the
/// scan rules (`ClassifierScanPolicy`) and, on a card, the upside-down check
/// (`WrongWayDetector`). The model has no passport class, so a passport page is
/// never probed upside down: it is captured once good and steady. Meanwhile a few recent frames are kept as candidates for
/// the photo.
///
/// It can only ever hold capture back for a while, never block it: it switches
/// itself off for the side after three failed calls in a row, or when the
/// on-device checks have passed for `waitLimit` with no answer at all, and for
/// the session when the classifier isn't available to it.
@MainActor
final class DocumentClassifierScanner: DocumentClassifying {
    private let detector: any DetectSending
    private let imaging: any ClassifierImaging
    private let availability: ClassifierAvailability
    private let method: String?
    private let scanID: String
    private let waitLimit: TimeInterval
    private let clock: () -> TimeInterval
    private let picked: DocumentGroup?
    private let health: HealthPolicy
    private let log = Logger(subsystem: "com.deepidv.sdk", category: "doc-classifier")

    private var policy: ClassifierScanPolicy
    private var wrongWay = WrongWayDetector()
    private var pacing = DetectPacing()
    private var frames: FrameLog
    /// Degrees every frame, and the photo, is turned: 180 once the card was found
    /// upside down.
    private(set) var rotation = 0
    private var frameNumber = 0
    private var call: Task<Void, Never>?
    /// The wrong-way probe in flight. It runs beside the normal calls, so
    /// checking for an upside-down card never holds up reading a right-way one.
    private var probeCall: Task<Void, Never>?
    private var nextCallAt: TimeInterval = 0
    private var failedOver = false
    private var gaveUpWaiting = false
    private var answered = false
    private var stopped = false
    private var visionReadySince: TimeInterval?
    private var lastStep: ClassifierScanPolicy.Step?
    /// The latest confirmed type the sticky document still agrees with.
    private var confirmed: ClassifierScanPolicy.Confirmed?
    private var ring: [BufferedFrame<FileInput>] = []
    private var keeping: [Int: Task<Void, Never>] = [:]
    private var keepCount = 0
    private var lastKeptAt: TimeInterval?
    private var frameWidth: Int?

    init(
        documentType: DocumentType,
        sessionID: String,
        detector: any DetectSending,
        imaging: any ClassifierImaging = CoreImageClassifierImaging(),
        availability: ClassifierAvailability,
        waitLimit: TimeInterval = 4,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.detector = detector
        self.imaging = imaging
        self.availability = availability
        self.waitLimit = waitLimit
        self.clock = clock
        self.picked = DocumentClassCatalog.group(for: documentType)
        self.health = DocumentClassCatalog.healthPolicy(for: documentType)
        self.method = picked?.wireValue
        self.scanID = ScanID.make(sessionID: sessionID)
        self.policy = ClassifierScanPolicy(picked: picked, health: health)
        self.frames = FrameLog(startedAt: clock())
    }

    /// Whether the classifier still has a say on this side.
    var isActive: Bool {
        !stopped && !failedOver && !gaveUpWaiting && availability.state != .unavailable
    }

    // MARK: DocumentClassifying

    func observe(
        _ frame: CameraFrame, quality: CaptureQuality, framed: Bool, visionReady: Bool,
        at now: TimeInterval
    ) {
        guard isActive else { return }
        if visionReady {
            visionReadySince = visionReadySince ?? now
        } else {
            visionReadySince = nil
        }
        if !answered, let since = visionReadySince, now - since >= waitLimit {
            log.info(
                "no classifier answer after \(self.waitLimit, privacy: .public)s; on-device only")
            gaveUpWaiting = true
            call?.cancel()
            return
        }
        keep(frame, quality: quality, at: now)
        if call == nil, now >= nextCallAt {
            send(frame, quality: quality, frameGood: framed, at: now)
        }
    }

    func verdict(at now: TimeInterval) -> ClassifierVerdict {
        guard isActive else { return .off }
        guard let step = lastStep else { return .hold(.connecting) }
        if step.shown == .healthCard { return .block(.healthCard) }
        if wrongWay.shown { return .hold(.wrongWay) }
        if wrongWay.pending != nil { return .hold(.identifying) }
        if policy.state.hold != nil { return .go }
        if let mismatch = step.mismatch, let kind = DocumentClassCatalog.kind(of: mismatch.id) {
            return .hold(.otherDocument(kind))
        }
        return .hold(.identifying)
    }

    func frontCaptured(photo: FileInput, manual: Bool, at now: TimeInterval) async
        -> FrontCaptureReport
    {
        let classification = currentClassification(manual: manual)
        stop()

        let picked = CaptureFramePicker.pick(
            ring, now: now,
            window: manual ? CaptureFramePicker.shutterWindow : CaptureFramePicker.captureWindow)
        var main = photo
        var spares = picked.extras.map(\.frame)
        if let best = picked.main {
            let imaging = self.imaging
            let frameWidth = self.frameWidth ?? 0
            let stillSharpness = await Task.detached {
                imaging.sharpness(of: photo, frameWidth: frameWidth)
            }.value
            if CaptureFramePicker.prefersKeptFrame(
                stillSharpness: stillSharpness, keptSharpness: best.sharpness)
            {
                main = best.frame
            } else {
                spares.insert(best.frame, at: 0)
            }
        }
        var extras =
            availability.sendsExtraFrames
            ? Array(spares.prefix(CaptureFramePicker.extraCount)) : []

        if rotation == 180 {
            let imaging = self.imaging
            let originals = [main] + extras
            let turned = await Task.detached { originals.map { imaging.turnedOver($0) ?? $0 } }
                .value
            main = turned[0]
            extras = Array(turned.dropFirst())
        }
        return FrontCaptureReport(photo: main, classification: classification, extraFrames: extras)
    }

    var shownDocument: ShownDocument? {
        guard isActive, let chip = lastStep?.chip else { return nil }
        return ShownDocument(id: chip.doc.id, confirmed: !chip.pending)
    }

    func stop() {
        stopped = true
        call?.cancel()
        call = nil
        probeCall?.cancel()
        probeCall = nil
    }

    /// Waits for the call and the frame copies in flight. For tests.
    func settle() async {
        while let task = call ?? probeCall ?? keeping.values.first {
            await task.value
            if call == task { call = nil }
            if probeCall == task { probeCall = nil }
            keeping = keeping.filter { $0.value != task }
        }
    }

    // MARK: Calls

    private func send(
        _ frame: CameraFrame, quality: CaptureQuality, frameGood: Bool, at startedAt: TimeInterval
    ) {
        frameNumber += 1
        let number = frameNumber
        let rotation = self.rotation
        let imaging = self.imaging
        let box = quality.boundingBox
        call = Task { [weak self] in
            let prepared = await Task.detached { imaging.prepare(frame, box: box) }.value
            let image = await Task.detached {
                prepared.flatMap { imaging.detectImage($0, rotation: rotation) }
            }
            .value
            guard let self, !Task.isCancelled else { return }
            guard let prepared, let image else {
                self.nextCallAt = self.clock() + DetectPacing.minimumInterval
                self.call = nil
                return
            }
            let request = DetectRequest(
                imageB64: image, scanID: self.scanID, frame: number, method: self.method)
            guard let response = try? await self.detector.detect(request), !Task.isCancelled,
                self.isActive
            else { return }
            // A probe turned the scan while this frame was out: its answer is for
            // the old way round, so it says nothing now.
            guard self.rotation == rotation else {
                self.call = nil
                return
            }
            self.handle(response, quality: quality, frameGood: frameGood, startedAt: startedAt)
            if self.isActive, self.picked != .passport, self.probeCall == nil,
                self.wrongWay.probeDue(at: self.clock())
            {
                self.startProbe(prepared)
            }
            if !Task.isCancelled { self.call = nil }
        }
    }

    private func handle(
        _ response: DetectResponse, quality: CaptureQuality, frameGood: Bool,
        startedAt: TimeInterval
    ) {
        availability.record(response)
        let now = clock()
        pacing.record(response)
        nextCallAt = now + pacing.wait(afterCallTaking: now - startedAt)
        guard availability.state != .unavailable else {
            log.info("classifier unavailable for this session; on-device only")
            return
        }
        if case .answer = response { answered = true }

        let outcome = response.outcome
        let step = policy.step(
            outcome, frameGood: frameGood, now: now, wrongWay: wrongWay.holdsCapture)
        lastStep = step
        if let decision = policy.lastDecision {
            wrongWay.recordFrame(outcome, at: now, confirmed: decision.key == .classified)
            frames.add(
                decision, at: now, rotation: rotation, area: quality.boxArea,
                edge: quality.edgeMargin)
            if step.state.doc == nil {
                confirmed = nil
            } else if decision.key == .classified, decision.doc?.id == step.state.doc?.id {
                confirmed = policy.confirmed(decision, captureRotation: rotation)
            }
        }
        if let reason = step.fallback {
            log.info("\(reason, privacy: .public); on-device only for this side")
            failedOver = true
        }
    }

    /// Sends the same frame turned the other way, to catch a card held upside down.
    private func startProbe(_ prepared: PreparedFrame) {
        probeCall = Task { [weak self] in
            await self?.probe(prepared)
            if !Task.isCancelled { self?.probeCall = nil }
        }
    }

    private func probe(_ prepared: PreparedFrame) async {
        let sentRotation = rotation
        let turned = (rotation + 180) % 360
        let imaging = self.imaging
        let image: String? = await Task.detached {
            imaging.detectImage(prepared, rotation: turned)
        }.value
        guard let image,
            let response = try? await detector.detect(
                DetectRequest(imageB64: image, scanID: scanID, method: method)),
            !Task.isCancelled, isActive, rotation == sentRotation
        else { return }
        availability.record(response)
        let now = clock()
        pacing.record(response)
        // Only a backoff (a rate limit, a failing gateway) slows the normal calls.
        if pacing.backoff > 0 { nextCallAt = max(nextCallAt, now + pacing.backoff) }
        wrongWay.recordProbe(response.outcome, at: now)
        frames.addProbe(response.outcome, at: now, rotation: turned)
        if wrongWay.flip {
            log.info("card is upside down; turning frames and photo by \(turned, privacy: .public)")
            rotation = turned
            wrongWay = WrongWayDetector()
            policy = ClassifierScanPolicy(picked: picked, health: health)
            lastStep = nil
            confirmed = nil
        }
    }

    // MARK: Photo

    /// What is reported with the photo: only a confirmed type, and only once the
    /// classifier has answered in this session and is still in play.
    private func currentClassification(manual: Bool) -> TierCaptureClassification? {
        guard isActive, availability.state == .available, let confirmed else { return nil }
        return TierCaptureClassification(
            confirmed, captureMode: manual ? .manual : .auto, frames: frames.frames)
    }

    /// Keeps a copy of the frame, every `CaptureFramePicker.interval`, as a
    /// candidate photo.
    private func keep(_ frame: CameraFrame, quality: CaptureQuality, at now: TimeInterval) {
        guard quality.documentDetected else { return }
        if let lastKeptAt, now - lastKeptAt < CaptureFramePicker.interval - 1e-9 { return }
        lastKeptAt = now
        if let pixelBuffer = frame.pixelBuffer { frameWidth = CVPixelBufferGetWidth(pixelBuffer) }
        let imaging = self.imaging
        let sharpness = quality.sharpness
        keepCount += 1
        let id = keepCount
        keeping[id] = Task { [weak self] in
            let kept = await Task.detached { imaging.keptFrame(frame) }.value
            guard let self else { return }
            self.keeping[id] = nil
            guard let kept, !self.stopped else { return }
            self.ring.append(BufferedFrame(time: now, frame: kept, sharpness: sharpness))
            self.ring.sort { $0.time < $1.time }
            if self.ring.count > CaptureFramePicker.capacity {
                self.ring.removeFirst(self.ring.count - CaptureFramePicker.capacity)
            }
        }
    }
}
