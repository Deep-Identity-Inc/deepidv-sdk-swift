// DeepIDV › ReVerify

import Combine
import DeepIDVCore
import Foundation

/// What the re-verify view renders.
enum ReVerifyPhase: Equatable {
    /// `create`, and every `startLiveness` (the first attempt and each new one).
    case checking
    /// Capturing. The view keys the capture surface on the session's
    /// `livenessSessionID`, so every attempt gets a fresh capture controller.
    case liveness(CustomLivenessSession, attemptsRemaining: Int?, guidance: ReVerifyGuidance)
    /// `upload-url` and the PUTs.
    case uploading
    /// `complete`: synchronous, up to ~25 s server-side.
    case deciding
    /// Terminal. `onResult` has already fired; the view renders nothing.
    case outcome(Result<ReVerifyResult, DeepIDVError>)
    /// On-screen error: "Try again" when `canRetry`, "Close" always.
    case failed(DeepIDVError)
}

/// The banner the capture screen shows for an attempt.
enum ReVerifyGuidance: Equatable {
    case initial
    /// The last capture wasn't matched to anyone.
    case retryMismatch
    /// The last capture didn't pass the liveness check.
    case retryLiveness
}

/// Drives one re-verification: `create → startLiveness → (view captures) →
/// upload-url + PUTs → complete`, then repeats the liveness leg on a `retry` /
/// `retry_liveness` decision. Fires `onResult` exactly once.
///
/// Branches only on `DeepIDVError.code` / `kind`, never on `message`.
@MainActor
final class ReVerifyFlowModel: ObservableObject {
    typealias CreateOperation = (_ workflowID: String) async throws -> ReVerificationSession
    typealias StartLivenessOperation = (_ reVerificationID: String) async throws ->
        CustomLivenessSession
    typealias RequestUploadURLsOperation = (
        _ reVerificationID: String, _ frameCount: Int, _ clipMimeType: String?
    ) async throws -> LivenessUploadURLs
    typealias UploadFramesOperation = (
        _ frames: [Data], _ timeline: Data, _ clip: Data?, _ urls: LivenessUploadURLs
    ) async throws -> Void
    typealias CompleteOperation = (_ reVerificationID: String) async throws -> ReVerifyOutcome

    /// What `retry()` re-runs from `.failed`.
    private enum ResumePoint {
        /// `create` failed.
        case create
        /// The camera pre-check or `startLiveness` failed, the capture failed,
        /// or the `liveness_not_started` restart limit was hit.
        case startLiveness
        /// `upload-url` or a PUT failed. Re-PUTs the same capture to the URLs
        /// already minted; requests URLs only when there are none.
        case upload(CaptureResult, LivenessUploadURLs?)
        /// `complete` failed with a retryable error: `complete` only.
        case complete(CaptureResult, LivenessUploadURLs)
    }

    /// `liveness_not_started` answers in a row before the flow stops on the
    /// failure screen instead of restarting again.
    private static let maxConsecutiveRestarts = 2

    @Published private(set) var phase: ReVerifyPhase = .checking

    private let workflowID: String
    private let create: CreateOperation
    private let startLiveness: StartLivenessOperation
    private let requestUploadURLs: RequestUploadURLsOperation
    private let uploadFrames: UploadFramesOperation
    private let completeLiveness: CompleteOperation
    private let cameraAuthorizer: any CameraAuthorizing
    private let onResult: (Result<ReVerifyResult, DeepIDVError>) -> Void

    private var task: Task<Void, Never>?
    private var hasStarted = false
    private var hasFinished = false
    private var reVerificationID: String?
    /// Set next to every `.failed`; `nil` there means not retryable.
    private var resumePoint: ResumePoint?
    /// The call running now: where a failure resumes from.
    private var inFlight: ResumePoint = .create
    private var consecutiveRestarts = 0

    // The attempt state `.liveness` is built from. Kept here, not only in the
    // phase, so it survives a failed `startLiveness` and its retry. Only a
    // `complete` decision changes it.
    private var attemptsRemaining: Int?
    private var guidance: ReVerifyGuidance = .initial

    init(
        workflowID: String,
        create: @escaping CreateOperation,
        startLiveness: @escaping StartLivenessOperation,
        requestUploadURLs: @escaping RequestUploadURLsOperation,
        uploadFrames: @escaping UploadFramesOperation,
        completeLiveness: @escaping CompleteOperation,
        cameraAuthorizer: any CameraAuthorizing = AlwaysAuthorizedCamera(),
        onResult: @escaping (Result<ReVerifyResult, DeepIDVError>) -> Void
    ) {
        self.workflowID = workflowID
        self.create = create
        self.startLiveness = startLiveness
        self.requestUploadURLs = requestUploadURLs
        self.uploadFrames = uploadFrames
        self.completeLiveness = completeLiveness
        self.cameraAuthorizer = cameraAuthorizer
        self.onResult = onResult
    }

    /// Binds the operations to one `ReVerificationService` from `client`.
    convenience init(
        client: DeepIDVClient,
        workflowID: String,
        onResult: @escaping (Result<ReVerifyResult, DeepIDVError>) -> Void
    ) {
        let service = client.makeReVerificationService()
        self.init(
            workflowID: workflowID,
            create: { try await service.create(workflowID: $0) },
            startLiveness: { try await service.startLiveness(id: $0) },
            requestUploadURLs: {
                try await service.requestUploadURLs(id: $0, frameCount: $1, clipMimeType: $2)
            },
            uploadFrames: { try await service.uploadFrames($0, timeline: $1, clip: $2, to: $3) },
            completeLiveness: { try await service.completeLiveness(id: $0) },
            cameraAuthorizer: SystemCameraAuthorizer(),
            onResult: onResult)
    }

    // MARK: - Intent (driven by the view)

    /// Creates the re-verification and starts the first attempt, once.
    func start() {
        guard !hasStarted, !hasFinished else { return }
        hasStarted = true
        launch { try await $0.runFromCreate() }
    }

    /// The capture for `livenessSessionID` finished: upload it and decide.
    /// Ignored unless that attempt is the one on screen.
    func captured(_ result: CaptureResult, livenessSessionID: String) {
        guard isCapturing(livenessSessionID) else { return }
        phase = .uploading
        launch { try await $0.runUpload(result, to: nil) }
    }

    /// The capture for `livenessSessionID` failed. A new attempt needs a new
    /// script, so this resumes at `startLiveness`.
    func captureFailed(_ error: DeepIDVError, livenessSessionID: String) {
        guard isCapturing(livenessSessionID) else { return }
        handle(error, at: .startLiveness)
    }

    /// Whether the failure screen offers "Try again".
    var canRetry: Bool {
        guard !hasFinished, case .failed = phase else { return false }
        return resumePoint != nil
    }

    /// "Try again": re-runs only the call that failed.
    func retry() {
        guard canRetry, let resume = resumePoint else { return }
        resumePoint = nil
        task?.cancel()
        // Set synchronously so the failure screen (and a second tap) is gone
        // before the task starts.
        switch resume {
        case .create:
            phase = .checking
            launch { try await $0.runFromCreate() }
        case .startLiveness:
            phase = .checking
            launch { try await $0.runStartLiveness() }
        case .upload(let capture, let urls):
            phase = .uploading
            launch { try await $0.runUpload(capture, to: urls) }
        case .complete(let capture, let urls):
            phase = .deciding
            launch { try await $0.runComplete(capture, urls: urls) }
        }
    }

    /// "Close" on the failure screen: delivers the original error.
    func dismissFailure() {
        guard case .failed(let error) = phase else { return }
        finish(.failure(error))
    }

    /// The host dismissed the view before an outcome. No request is sent; the
    /// server row expires on its own.
    func cancel() {
        guard !hasFinished else { return }
        task?.cancel()
        finish(.failure(.cancelled("Re-verification was cancelled.")))
    }

    /// Test synchronization seam: awaits the in-flight work, including any
    /// work a failure handler started after it.
    func awaitPendingWork() async {
        while let current = task {
            await current.value
            if task == current { return }
        }
    }

    // MARK: - Steps

    private func runFromCreate() async throws {
        phase = .checking
        inFlight = .create
        let session = try await create(workflowID)
        try checkActive()
        reVerificationID = session.reVerificationID
        try await runStartLiveness()
    }

    private func runStartLiveness() async throws {
        phase = .checking
        inFlight = .startLiveness
        let id = try requireReVerificationID()
        guard await cameraAuthorized() else {
            throw DeepIDVError.cameraPermissionDenied(
                "Camera access is required for re-verification.")
        }
        try checkActive()
        let session = try await startLiveness(id)
        try checkActive()
        phase = .liveness(session, attemptsRemaining: attemptsRemaining, guidance: guidance)
    }

    private func runUpload(_ capture: CaptureResult, to minted: LivenessUploadURLs?) async throws {
        phase = .uploading
        inFlight = .upload(capture, minted)
        let id = try requireReVerificationID()
        let urls: LivenessUploadURLs
        if let minted {
            urls = minted
        } else {
            urls = try await requestUploadURLs(
                id, capture.frames.count, capture.clip != nil ? "video/mp4" : nil)
            try checkActive()
            inFlight = .upload(capture, urls)
        }
        let timeline = (try? JSONEncoder().encode(capture.timeline)) ?? Data("[]".utf8)
        try await uploadFrames(capture.frames, timeline, capture.clip, urls)
        try checkActive()
        try await runComplete(capture, urls: urls)
    }

    private func runComplete(_ capture: CaptureResult, urls: LivenessUploadURLs) async throws {
        phase = .deciding
        inFlight = .complete(capture, urls)
        let id = try requireReVerificationID()
        let outcome = try await completeLiveness(id)
        try checkActive()
        consecutiveRestarts = 0

        switch outcome.decision {
        case .verified:
            guard let userID = outcome.userID, let originalSessionID = outcome.originalSessionID
            else {
                // Not retryable: a repeat `complete` replays this same decision.
                throw DeepIDVError.validation(
                    "Re-verification returned a verified decision without its user or original session."
                )
            }
            finish(
                .success(
                    .verified(
                        reVerificationID: id, originalSessionID: originalSessionID,
                        userID: userID)))
        case .retry:
            attemptsRemaining = outcome.attemptsRemaining
            guidance = .retryMismatch
            try await runStartLiveness()
        case .retryLiveness:
            // Liveness-only attempts don't consume budget, so the count is
            // unchanged — but a first-attempt `retry_liveness` still fills it in.
            attemptsRemaining = outcome.attemptsRemaining
            guidance = .retryLiveness
            try await runStartLiveness()
        case .failed:
            // The wire carries no reason, so the counters are the only signal.
            // A recognised-but-ineligible face on the last attempt therefore
            // reads as `.attemptsExhausted` (accepted).
            let exhausted = outcome.attempts.failed >= outcome.attempts.max
            finish(.success(.failed(reason: exhausted ? .attemptsExhausted : .notReVerified)))
        }
    }

    // MARK: - Error routing

    /// Runs `work` as the one in-flight task and routes whatever it throws.
    private func launch(_ work: @escaping @MainActor (ReVerifyFlowModel) async throws -> Void) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // A task cancelled before it first ran must not set a phase
                // over `.outcome`.
                try self.checkActive()
                try await work(self)
            } catch let error as DeepIDVError {
                guard !Task.isCancelled, !self.hasFinished else { return }
                self.handle(error, at: self.inFlight)
            } catch is CancellationError {
                return
            } catch {
                // e.g. a raw `URLError` from a PUT transport failure.
                guard !Task.isCancelled, !self.hasFinished else { return }
                self.handle(Self.unexpected(error), at: self.inFlight)
            }
        }
    }

    /// The error rule, in order: not eligible and expired end the run as
    /// outcomes; 401 / 400 fail with Close only; two server codes recover
    /// in place; everything else fails with a retry from `resume`.
    private func handle(_ error: DeepIDVError, at resume: ResumePoint) {
        if let reason = Self.notEligibleReason(for: error) {
            finish(.success(.failed(reason: .notEligible(reason))))
            return
        }
        // `already_completed` means a terminal row this flow didn't decide,
        // i.e. expired by the scheduler.
        if error.code == "expired" || error.code == "already_completed" {
            finish(.success(.failed(reason: .expired)))
            return
        }
        if error.kind == .authentication || error.kind == .validation {
            fail(error, resume: nil)
            return
        }
        switch (error.code, resume) {
        case ("liveness_upload_incomplete", .complete(let capture, let urls)):
            // Nothing was consumed: re-PUT the same capture, then `complete` again.
            launch { try await $0.runUpload(capture, to: urls) }
        case ("liveness_not_started", .upload), ("liveness_not_started", .complete):
            restartLiveness(after: error)
        default:
            fail(error, resume: resume)
        }
    }

    /// The server has no live attempt (a duplicate `complete` consumed it, or
    /// `upload-url` lost to a concurrent write): start a new one, keeping the
    /// attempt state. The second restart in a row stops on the failure screen.
    private func restartLiveness(after error: DeepIDVError) {
        consecutiveRestarts += 1
        guard consecutiveRestarts < Self.maxConsecutiveRestarts else {
            consecutiveRestarts = 0
            fail(error, resume: .startLiveness)
            return
        }
        launch { try await $0.runStartLiveness() }
    }

    private func fail(_ error: DeepIDVError, resume: ResumePoint?) {
        resumePoint = resume
        phase = .failed(error)
    }

    private func finish(_ result: Result<ReVerifyResult, DeepIDVError>) {
        guard !hasFinished else { return }
        hasFinished = true
        resumePoint = nil
        phase = .outcome(result)
        onResult(result)
    }

    /// Matched on `kind` for 404 / 402 / 403, so a 404 without the
    /// re-verification body is still `.notFound`; `reverify_disabled` arrives
    /// as a 422 `.api` and can only be matched on `code`.
    private static func notEligibleReason(
        for error: DeepIDVError
    ) -> ReVerifyResult.NotEligibleReason? {
        if error.kind == .notFound { return .notFound }
        if error.code == "reverify_disabled" { return .disabled }
        if error.kind == .insufficientFunds { return .insufficientBalance }
        if error.kind == .authorization { return .notAuthorized }
        return nil
    }

    // MARK: - Helpers

    private func isCapturing(_ livenessSessionID: String) -> Bool {
        guard !hasFinished, case .liveness(let session, _, _) = phase else { return false }
        return session.livenessSessionID == livenessSessionID
    }

    private func cameraAuthorized() async -> Bool {
        switch cameraAuthorizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined: return await cameraAuthorizer.requestAccess()
        case .denied: return false
        }
    }

    /// Stops a chain whose flow was cancelled or finished while a call was in
    /// flight; `launch` treats the `CancellationError` as a silent return.
    private func checkActive() throws {
        try Task.checkCancellation()
        if hasFinished { throw CancellationError() }
    }

    private func requireReVerificationID() throws -> String {
        guard let reVerificationID else {
            throw DeepIDVError.validation("Re-verification has no id yet.")
        }
        return reVerificationID
    }

    private static func unexpected(_ error: Error) -> DeepIDVError {
        .network(
            "Re-verification failed unexpectedly.",
            causeDescription: String(describing: error))
    }
}
