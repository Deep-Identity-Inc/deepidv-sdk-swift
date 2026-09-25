import Combine
import Foundation
import Testing

@testable import DeepIDV
@testable import DeepIDVCore

// MARK: - Fixtures

private let reVerifyScript = ChallengeScript(
    challengeType: .faceMovement, durationMs: 2000,
    steps: [ChallengeStep(kind: "move-closer", atMs: 0)])

private let reVerifyCapture = CaptureResult(
    frames: [Data("frame-0".utf8), Data("frame-1".utf8), Data("frame-2".utf8)],
    timeline: [TimelineEntry(index: 0, atMs: 0, kind: "checkpoint", value: "0")],
    clip: Data("clip".utf8))

private let verifiedOutcome = ReVerifyOutcome(
    decision: .verified, attempts: ReVerifyAttempts(failed: 0, max: 3),
    livenessStatus: .succeeded, livenessConfidence: 92,
    userID: "user-1", originalSessionID: "sess-original")

private let verifiedResult = ReVerifyResult.verified(
    reVerificationID: "rv-1", originalSessionID: "sess-original", userID: "user-1")

private func outcome(_ decision: ReVerifyDecision, failed: Int, max: Int = 3) -> ReVerifyOutcome {
    ReVerifyOutcome(
        decision: decision, attempts: ReVerifyAttempts(failed: failed, max: max),
        livenessStatus: decision == .retryLiveness ? .failed : .succeeded,
        livenessConfidence: 80)
}

/// A re-verification business-rule error as `ReVerificationService` hands it
/// over: the HTTP-mapped `kind` and status, with `code` set to the server code.
private func serverCode(_ code: String, _ kind: DeepIDVError.Kind, status: Int) -> DeepIDVError {
    DeepIDVError(kind: kind, message: "Mapped re-verification copy.", status: status, code: code)
}

private let livenessNotStarted = serverCode("liveness_not_started", .conflict, status: 409)
private let uploadIncomplete = serverCode("liveness_upload_incomplete", .conflict, status: 409)
private let expiredError = serverCode("expired", .conflict, status: 409)
private let alreadyCompleted = serverCode("already_completed", .conflict, status: 409)
private let insufficientBalance = serverCode("insufficient_balance", .insufficientFunds, status: 402)
private let reverifyDisabled = serverCode("reverify_disabled", .api, status: 422)
private let notFoundWithBody = serverCode("not_found", .notFound, status: 404)
/// A 404 without the re-verification body keeps the HTTP layer's code.
private let notFoundNoBody = DeepIDVError.notFound("Not Found")
private let sandboxForbidden = DeepIDVError.authorization("Sandbox keys can't use this route.")
private let unauthenticated = DeepIDVError.authentication("Unauthorized (api key: sk_...abcd)")
private let invalidBody = DeepIDVError.validation("InvalidBody")
private let serverFailure = DeepIDVError.api("ServerError", status: 500)
private let networkDown = DeepIDVError.network("The Internet connection appears to be offline.")
private let timedOut = DeepIDVError.timeout("Request timed out after 60.0s")

/// The service call a test injects an answer into.
enum ReVerifyRoute: Sendable, CaseIterable {
    case create, start, uploadURL, complete
}

// MARK: - Fake service

/// Records every call the model makes and answers from a script: `fail` makes
/// the n-th call of an operation throw, `hang` suspends it until the model's
/// task is cancelled, and `complete` answers `outcomes` in order, then
/// `verifiedOutcome`.
@MainActor
private final class FakeReVerify {
    enum Operation: Hashable {
        case create, start, uploadURL, upload, complete
    }

    struct UploadURLCall: Equatable {
        let reVerificationID: String
        let frameCount: Int
        let clipMimeType: String?
    }

    /// One `timeline.json` entry, decoded — the encoder's key order isn't
    /// stable, so re-encoded bytes differ even when the content is the same.
    struct TimelineRow: Decodable, Equatable {
        let index: Int
        let atMs: Int
        let kind: String
        let value: String
    }

    struct UploadCall: Equatable {
        let frames: [Data]
        let timeline: [TimelineRow]
        let clip: Data?
        let urls: LivenessUploadURLs
    }

    var outcomes: [ReVerifyOutcome] = []
    var camera = TestCamera(status: .authorized)

    private var errors: [Operation: [Int: any Error]] = [:]
    private var hanging: Set<Operation> = []
    private var phaseSubscription: AnyCancellable?

    private(set) var createCalls: [String] = []
    private(set) var startCalls: [String] = []
    private(set) var uploadURLCalls: [UploadURLCall] = []
    private(set) var uploadCalls: [UploadCall] = []
    private(set) var completeCalls: [String] = []
    private(set) var results: [Result<ReVerifyResult, DeepIDVError>] = []
    /// Every distinct phase the model published, as readable labels.
    private(set) var phases: [String] = []

    func fail(_ operation: Operation, call: Int = 1, with error: any Error) {
        errors[operation, default: [:]][call] = error
    }

    func fail(_ route: ReVerifyRoute, call: Int = 1, with error: any Error) {
        switch route {
        case .create: fail(Operation.create, call: call, with: error)
        case .start: fail(Operation.start, call: call, with: error)
        case .uploadURL: fail(Operation.uploadURL, call: call, with: error)
        case .complete: fail(Operation.complete, call: call, with: error)
        }
    }

    func hang(_ operation: Operation) {
        hanging.insert(operation)
    }

    func makeModel() -> ReVerifyFlowModel {
        let model = ReVerifyFlowModel(
            workflowID: "wf-1",
            create: { try await self.create($0) },
            startLiveness: { try await self.startLiveness($0) },
            requestUploadURLs: { try await self.requestUploadURLs($0, frameCount: $1, clipMimeType: $2) },
            uploadFrames: { try await self.uploadFrames($0, timeline: $1, clip: $2, to: $3) },
            completeLiveness: { try await self.complete($0) },
            cameraAuthorizer: camera,
            onResult: { self.results.append($0) })
        phaseSubscription = model.$phase
            .removeDuplicates()
            .sink { [weak self] in self?.phases.append(Self.label($0)) }
        return model
    }

    // MARK: Operations

    private func create(_ workflowID: String) async throws -> ReVerificationSession {
        createCalls.append(workflowID)
        try await answer(.create, call: createCalls.count)
        return ReVerificationSession(
            reVerificationID: "rv-1", workflowID: workflowID, status: "PENDING",
            expiresAt: "2026-09-24T12:15:00.000Z", livenessChallengeType: .faceMovement)
    }

    private func startLiveness(_ reVerificationID: String) async throws -> CustomLivenessSession {
        startCalls.append(reVerificationID)
        try await answer(.start, call: startCalls.count)
        return CustomLivenessSession(
            livenessSessionID: "lv-\(startCalls.count)", script: reVerifyScript)
    }

    private func requestUploadURLs(
        _ reVerificationID: String, frameCount: Int, clipMimeType: String?
    ) async throws -> LivenessUploadURLs {
        uploadURLCalls.append(
            UploadURLCall(
                reVerificationID: reVerificationID, frameCount: frameCount,
                clipMimeType: clipMimeType))
        try await answer(.uploadURL, call: uploadURLCalls.count)
        // Distinct per call, so a test can tell which minting a PUT used.
        let mint = uploadURLCalls.count
        return LivenessUploadURLs(
            frameUploadURLs: (0..<frameCount).map {
                URL(string: "https://s3.test/\(mint)/frame_\($0).jpg")!
            },
            frameKeys: (0..<frameCount).map { "frame_\($0).jpg" },
            timelineUploadURL: URL(string: "https://s3.test/\(mint)/timeline.json")!,
            timelineKey: "timeline.json",
            clipUploadURL: clipMimeType == nil ? nil : URL(string: "https://s3.test/\(mint)/clip.mp4")!,
            clipKey: clipMimeType == nil ? nil : "clip.mp4")
    }

    private func uploadFrames(
        _ frames: [Data], timeline: Data, clip: Data?, to urls: LivenessUploadURLs
    ) async throws {
        let rows = try JSONDecoder().decode([TimelineRow].self, from: timeline)
        uploadCalls.append(UploadCall(frames: frames, timeline: rows, clip: clip, urls: urls))
        try await answer(.upload, call: uploadCalls.count)
    }

    private func complete(_ reVerificationID: String) async throws -> ReVerifyOutcome {
        completeCalls.append(reVerificationID)
        try await answer(.complete, call: completeCalls.count)
        return outcomes.isEmpty ? verifiedOutcome : outcomes.removeFirst()
    }

    private func answer(_ operation: Operation, call: Int) async throws {
        if hanging.contains(operation) {
            try await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
        }
        if let error = errors[operation]?[call] { throw error }
    }

    private static func label(_ phase: ReVerifyPhase) -> String {
        switch phase {
        case .checking: "checking"
        case .liveness(let session, _, _): "liveness(\(session.livenessSessionID))"
        case .uploading: "uploading"
        case .deciding: "deciding"
        case .outcome: "outcome"
        case .failed(let error): "failed(\(error.code ?? "-"))"
        }
    }
}

/// A camera authorizer whose status a test can change between calls.
private final class TestCamera: CameraAuthorizing, @unchecked Sendable {
    var status: CameraAuthorizationStatus
    var grantsOnRequest = true

    init(status: CameraAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() -> CameraAuthorizationStatus { status }
    func requestAccess() async -> Bool { grantsOnRequest }
}

// MARK: - Driving helpers

/// The attempt on screen, when the model is capturing.
@MainActor
private func currentAttempt(
    _ model: ReVerifyFlowModel
) -> (livenessSessionID: String, attemptsRemaining: Int?, guidance: ReVerifyGuidance)? {
    guard case .liveness(let session, let attemptsRemaining, let guidance) = model.phase else {
        return nil
    }
    return (session.livenessSessionID, attemptsRemaining, guidance)
}

/// Hands the model a finished capture for the attempt on screen, then waits.
@MainActor
private func captureCurrentAttempt(_ model: ReVerifyFlowModel) async {
    guard let attempt = currentAttempt(model) else {
        Issue.record("expected .liveness, got \(model.phase)")
        return
    }
    model.captured(reVerifyCapture, livenessSessionID: attempt.livenessSessionID)
    await model.awaitPendingWork()
}

/// Starts the model and, for the routes after `startLiveness`, captures once —
/// so an error injected at `route` is the one the model ends up handling.
@MainActor
private func drive(_ model: ReVerifyFlowModel, through route: ReVerifyRoute) async {
    model.start()
    await model.awaitPendingWork()
    switch route {
    case .create, .start: return
    case .uploadURL, .complete: await captureCurrentAttempt(model)
    }
}

/// Yields until `condition` holds (bounded), for work parked in a hung call.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    var remaining = 1_000
    while !condition(), remaining > 0 {
        await Task.yield()
        remaining -= 1
    }
}

// MARK: - Tests

@MainActor
struct ReVerifyFlowModelTests {

    // MARK: Happy path

    @Test func happyPathRunsCheckingLivenessUploadingDecidingOutcome() async {
        let fake = FakeReVerify()
        let model = fake.makeModel()

        await drive(model, through: .complete)

        #expect(
            fake.phases == ["checking", "liveness(lv-1)", "uploading", "deciding", "outcome"])
        #expect(fake.results == [.success(verifiedResult)])
        #expect(model.phase == .outcome(.success(verifiedResult)))
        #expect(fake.createCalls == ["wf-1"])
        #expect(fake.startCalls == ["rv-1"])
        #expect(
            fake.uploadURLCalls == [
                FakeReVerify.UploadURLCall(
                    reVerificationID: "rv-1", frameCount: 3, clipMimeType: "video/mp4")
            ])
        #expect(fake.completeCalls == ["rv-1"])
    }

    @Test func uploadSendsFramesEncodedTimelineAndClip() async throws {
        let fake = FakeReVerify()
        let model = fake.makeModel()

        await drive(model, through: .complete)

        let upload = try #require(fake.uploadCalls.first)
        #expect(fake.uploadCalls.count == 1)
        #expect(upload.frames == reVerifyCapture.frames)
        #expect(
            upload.timeline == [
                FakeReVerify.TimelineRow(index: 0, atMs: 0, kind: "checkpoint", value: "0")
            ])
        #expect(upload.clip == reVerifyCapture.clip)
        #expect(upload.urls.frameUploadURLs.first?.absoluteString == "https://s3.test/1/frame_0.jpg")
    }

    @Test func captureWithoutClipAnnouncesNoClipMime() async {
        let fake = FakeReVerify()
        let model = fake.makeModel()
        model.start()
        await model.awaitPendingWork()

        let noClip = CaptureResult(
            frames: reVerifyCapture.frames, timeline: reVerifyCapture.timeline, clip: nil)
        model.captured(noClip, livenessSessionID: "lv-1")
        await model.awaitPendingWork()

        #expect(fake.uploadURLCalls.first?.clipMimeType == nil)
        #expect(fake.uploadCalls.first?.clip == nil)
        #expect(fake.results == [.success(verifiedResult)])
    }

    @Test func firstAttemptHasNoCountAndNoGuidance() async {
        let fake = FakeReVerify()
        let model = fake.makeModel()
        model.start()
        await model.awaitPendingWork()

        let attempt = currentAttempt(model)
        #expect(attempt?.livenessSessionID == "lv-1")
        #expect(attempt?.attemptsRemaining == nil)
        #expect(attempt?.guidance == .initial)
    }

    // MARK: Decisions

    @Test func retryDecisionGoesThroughCheckingToAFreshAttempt() async {
        let fake = FakeReVerify()
        fake.outcomes = [outcome(.retry, failed: 1)]
        let model = fake.makeModel()

        await drive(model, through: .complete)

        let attempt = currentAttempt(model)
        #expect(attempt?.livenessSessionID == "lv-2")
        #expect(attempt?.attemptsRemaining == 2)
        #expect(attempt?.guidance == .retryMismatch)
        #expect(fake.startCalls.count == 2)
        #expect(fake.createCalls.count == 1)

        await captureCurrentAttempt(model)

        // Never `.deciding` straight into `.liveness`: the new challenge loads under `.checking`.
        #expect(
            fake.phases == [
                "checking", "liveness(lv-1)", "uploading", "deciding",
                "checking", "liveness(lv-2)", "uploading", "deciding", "outcome",
            ])
        #expect(fake.results == [.success(verifiedResult)])
    }

    @Test func retryLivenessShowsItsOwnGuidanceAndKeepsTheCount() async {
        let fake = FakeReVerify()
        fake.outcomes = [outcome(.retry, failed: 1), outcome(.retryLiveness, failed: 1)]
        let model = fake.makeModel()

        await drive(model, through: .complete)
        #expect(currentAttempt(model)?.attemptsRemaining == 2)
        #expect(currentAttempt(model)?.guidance == .retryMismatch)

        await captureCurrentAttempt(model)
        let attempt = currentAttempt(model)
        #expect(attempt?.livenessSessionID == "lv-3")
        #expect(attempt?.attemptsRemaining == 2)
        #expect(attempt?.guidance == .retryLiveness)
    }

    @Test func retryLivenessOnTheFirstAttemptFillsInTheCount() async {
        let fake = FakeReVerify()
        fake.outcomes = [outcome(.retryLiveness, failed: 0)]
        let model = fake.makeModel()

        await drive(model, through: .complete)

        #expect(currentAttempt(model)?.attemptsRemaining == 3)
        #expect(currentAttempt(model)?.guidance == .retryLiveness)
        #expect(fake.phases.suffix(3) == ["deciding", "checking", "liveness(lv-2)"])
    }

    @Test func strangerCountsDownThenEndsAttemptsExhausted() async {
        let fake = FakeReVerify()
        fake.outcomes = [
            outcome(.retry, failed: 1), outcome(.retry, failed: 2), outcome(.failed, failed: 3),
        ]
        let model = fake.makeModel()

        await drive(model, through: .complete)
        #expect(currentAttempt(model)?.attemptsRemaining == 2)
        await captureCurrentAttempt(model)
        #expect(currentAttempt(model)?.attemptsRemaining == 1)
        await captureCurrentAttempt(model)

        #expect(fake.results == [.success(.failed(reason: .attemptsExhausted))])
        #expect(fake.startCalls.count == 3)
        #expect(model.canRetry == false)
    }

    @Test func recognisedButIneligibleOnTheFirstCompleteIsNotReVerified() async {
        let fake = FakeReVerify()
        fake.outcomes = [outcome(.failed, failed: 1)]
        let model = fake.makeModel()

        await drive(model, through: .complete)

        #expect(fake.results == [.success(.failed(reason: .notReVerified))])
        #expect(fake.startCalls.count == 1)
        #expect(model.phase == .outcome(.success(.failed(reason: .notReVerified))))
    }

    /// Accepted boundary: the wire has no reason, so a `failed` that lands on
    /// the last budgeted attempt reads as `.attemptsExhausted` even when the
    /// face was recognised.
    @Test(arguments: [
        (1, 3, ReVerifyResult.FailureReason.notReVerified),
        (2, 3, .notReVerified),
        (3, 3, .attemptsExhausted),  // recognised-but-ineligible third capture
        (1, 1, .attemptsExhausted),  // max_attempts = 1
    ])
    func failedDecisionReasonComesFromTheCounters(
        failed: Int, max: Int, expected: ReVerifyResult.FailureReason
    ) async {
        let fake = FakeReVerify()
        fake.outcomes = [outcome(.failed, failed: failed, max: max)]
        let model = fake.makeModel()

        await drive(model, through: .complete)

        #expect(fake.results == [.success(.failed(reason: expected))])
    }

    @Test func verifiedWithoutIdsIsANonRetryableFailure() async throws {
        let fake = FakeReVerify()
        fake.outcomes = [
            ReVerifyOutcome(
                decision: .verified, attempts: ReVerifyAttempts(failed: 0, max: 3),
                livenessStatus: .succeeded, livenessConfidence: 92,
                userID: nil, originalSessionID: "sess-original")
        ]
        let model = fake.makeModel()

        await drive(model, through: .complete)

        guard case .failed(let error) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(error.kind == .validation)
        #expect(model.canRetry == false)
        #expect(fake.results.isEmpty)

        model.retry()
        #expect(fake.completeCalls.count == 1)

        model.dismissFailure()
        #expect(fake.results == [.failure(error)])
    }

    // MARK: Not eligible

    @Test(arguments: [
        (notFoundWithBody, ReVerifyResult.NotEligibleReason.notFound),
        (notFoundNoBody, .notFound),
        (reverifyDisabled, .disabled),
        (insufficientBalance, .insufficientBalance),
        (sandboxForbidden, .notAuthorized),
    ])
    func notEligibleOnCreateEndsImmediately(
        error: DeepIDVError, reason: ReVerifyResult.NotEligibleReason
    ) async {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.create, with: error)
        let model = fake.makeModel()

        await drive(model, through: .create)

        #expect(fake.results == [.success(.failed(reason: .notEligible(reason)))])
        #expect(model.phase == .outcome(.success(.failed(reason: .notEligible(reason)))))
        #expect(model.canRetry == false)
        #expect(fake.startCalls.isEmpty)
    }

    @Test(arguments: [ReVerifyRoute.start, .uploadURL, .complete])
    func notFoundWithoutBodyOnAnyRouteIsNotEligible(route: ReVerifyRoute) async {
        let fake = FakeReVerify()
        fake.fail(route, with: notFoundNoBody)
        let model = fake.makeModel()

        await drive(model, through: route)

        #expect(fake.results == [.success(.failed(reason: .notEligible(.notFound)))])
        #expect(model.canRetry == false)
    }

    @Test func insufficientBalanceOnCompleteIsNotEligibleWithoutReupload() async {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.complete, with: insufficientBalance)
        let model = fake.makeModel()

        await drive(model, through: .complete)

        #expect(fake.results == [.success(.failed(reason: .notEligible(.insufficientBalance)))])
        #expect(fake.uploadCalls.count == 1)
        #expect(fake.completeCalls.count == 1)
        #expect(fake.startCalls.count == 1)
    }

    // MARK: Expired

    @Test(arguments: [ReVerifyRoute.start, .uploadURL, .complete], [expiredError, alreadyCompleted])
    func expiredOrAlreadyCompletedEndsExpiredWithoutARecreate(
        route: ReVerifyRoute, error: DeepIDVError
    ) async {
        let fake = FakeReVerify()
        fake.fail(route, with: error)
        let model = fake.makeModel()

        await drive(model, through: route)

        #expect(fake.results == [.success(.failed(reason: .expired))])
        #expect(model.canRetry == false)
        #expect(fake.createCalls.count == 1)
    }

    // MARK: Not retryable

    @Test(arguments: ReVerifyRoute.allCases, [unauthenticated, invalidBody])
    func unauthenticatedOrInvalidFailsWithCloseOnly(
        route: ReVerifyRoute, error: DeepIDVError
    ) async {
        let fake = FakeReVerify()
        fake.fail(route, with: error)
        let model = fake.makeModel()

        await drive(model, through: route)

        #expect(model.phase == .failed(error))
        #expect(model.canRetry == false)
        #expect(fake.results.isEmpty)

        model.dismissFailure()
        // The original error, `message` included — it's a developer string.
        #expect(fake.results == [.failure(error)])
    }

    // MARK: Retryable failures and resume points

    @Test func networkErrorOnCreateRetriesCreate() async {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.create, with: networkDown)
        let model = fake.makeModel()

        await drive(model, through: .create)
        #expect(model.phase == .failed(networkDown))
        #expect(model.canRetry)

        model.retry()
        await model.awaitPendingWork()

        #expect(fake.createCalls.count == 2)
        #expect(fake.startCalls.count == 1)
        #expect(currentAttempt(model)?.livenessSessionID == "lv-1")
        #expect(fake.results.isEmpty)
    }

    @Test func dismissingARetryableFailureDeliversTheOriginalError() async {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.complete, with: serverFailure)
        let model = fake.makeModel()

        await drive(model, through: .complete)
        #expect(model.canRetry)

        model.dismissFailure()

        #expect(fake.results == [.failure(serverFailure)])
        #expect(model.phase == .outcome(.failure(serverFailure)))
    }

    @Test func failedStartLivenessRetriesStartWithTheSameAttemptState() async {
        let fake = FakeReVerify()
        fake.outcomes = [outcome(.retry, failed: 1)]
        fake.fail(ReVerifyRoute.start, call: 2, with: networkDown)
        let model = fake.makeModel()

        await drive(model, through: .complete)
        #expect(model.phase == .failed(networkDown))
        #expect(model.canRetry)

        model.retry()
        await model.awaitPendingWork()

        let attempt = currentAttempt(model)
        #expect(attempt?.livenessSessionID == "lv-3")
        #expect(attempt?.attemptsRemaining == 2)
        #expect(attempt?.guidance == .retryMismatch)
        #expect(fake.createCalls.count == 1)
        #expect(fake.startCalls.count == 3)
    }

    @Test func deniedCameraFailsAndRetryRechecksThenStarts() async {
        let fake = FakeReVerify()
        fake.camera.status = .denied
        let model = fake.makeModel()

        await drive(model, through: .start)
        guard case .failed(let error) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(error.kind == .cameraPermissionDenied)
        #expect(model.canRetry)
        #expect(fake.startCalls.isEmpty)

        fake.camera.status = .authorized
        model.retry()
        await model.awaitPendingWork()

        #expect(currentAttempt(model)?.livenessSessionID == "lv-1")
        #expect(fake.createCalls.count == 1)
    }

    @Test func undeterminedCameraAsksAndProceedsWhenGranted() async {
        let fake = FakeReVerify()
        fake.camera.status = .notDetermined
        let model = fake.makeModel()

        await drive(model, through: .start)

        #expect(currentAttempt(model)?.livenessSessionID == "lv-1")
    }

    @Test func captureFailureResumesAtANewStartLiveness() async {
        let fake = FakeReVerify()
        let model = fake.makeModel()
        await drive(model, through: .start)

        let captureError = DeepIDVError.captureFailed("Liveness capture failed")
        model.captureFailed(captureError, livenessSessionID: "lv-1")
        #expect(model.phase == .failed(captureError))
        #expect(model.canRetry)

        model.retry()
        await model.awaitPendingWork()

        #expect(currentAttempt(model)?.livenessSessionID == "lv-2")
        #expect(fake.startCalls.count == 2)
        #expect(fake.uploadURLCalls.isEmpty)
    }

    @Test func callbacksFromAnotherAttemptAreIgnored() async {
        let fake = FakeReVerify()
        let model = fake.makeModel()
        await drive(model, through: .start)

        model.captureFailed(.captureFailed("stale"), livenessSessionID: "lv-old")
        model.captured(reVerifyCapture, livenessSessionID: "lv-old")
        await model.awaitPendingWork()

        #expect(currentAttempt(model)?.livenessSessionID == "lv-1")
        #expect(fake.uploadURLCalls.isEmpty)
    }

    @Test func uploadURLFailureKeepsItsErrorAndRetryMintsURLs() async {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.uploadURL, with: timedOut)
        let model = fake.makeModel()

        await drive(model, through: .uploadURL)
        // Kept as `.timeout`, not rewritten to `.network`.
        #expect(model.phase == .failed(timedOut))
        #expect(model.canRetry)
        #expect(fake.uploadCalls.isEmpty)

        model.retry()
        await model.awaitPendingWork()

        #expect(fake.uploadURLCalls.count == 2)
        #expect(fake.uploadCalls.count == 1)
        #expect(fake.startCalls.count == 1)
        #expect(fake.results == [.success(verifiedResult)])
    }

    @Test func putFailureRetryReuploadsTheSameCaptureToTheSameURLs() async throws {
        let fake = FakeReVerify()
        fake.fail(.upload, with: networkDown)
        let model = fake.makeModel()

        await drive(model, through: .complete)
        #expect(model.phase == .failed(networkDown))
        #expect(model.canRetry)

        model.retry()
        await model.awaitPendingWork()

        #expect(fake.uploadURLCalls.count == 1)
        #expect(fake.uploadCalls.count == 2)
        let first = try #require(fake.uploadCalls.first)
        #expect(fake.uploadCalls[1] == first)
        #expect(first.clip == reVerifyCapture.clip)
        #expect(fake.startCalls.count == 1)
        #expect(fake.results == [.success(verifiedResult)])
    }

    @Test func rawTransportErrorFromAPutBecomesNetworkAndResumesTheUpload() async {
        let fake = FakeReVerify()
        fake.fail(.upload, with: URLError(.networkConnectionLost))
        let model = fake.makeModel()

        await drive(model, through: .complete)
        guard case .failed(let error) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(error.kind == .network)
        #expect(model.canRetry)

        model.retry()
        await model.awaitPendingWork()

        #expect(fake.uploadURLCalls.count == 1)
        #expect(fake.uploadCalls.count == 2)
        #expect(fake.uploadCalls[0].urls == fake.uploadCalls[1].urls)
        #expect(fake.results == [.success(verifiedResult)])
    }

    @Test(arguments: [timedOut, networkDown, serverFailure])
    func completeFailureRetriesCompleteOnly(error: DeepIDVError) async {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.complete, with: error)
        let model = fake.makeModel()

        await drive(model, through: .complete)
        #expect(model.phase == .failed(error))
        #expect(model.canRetry)

        model.retry()
        await model.awaitPendingWork()

        #expect(fake.completeCalls.count == 2)
        #expect(fake.uploadCalls.count == 1)
        #expect(fake.uploadURLCalls.count == 1)
        #expect(fake.startCalls.count == 1)
        #expect(fake.results == [.success(verifiedResult)])
    }

    // MARK: Server recovery codes

    @Test func uploadIncompleteReuploadsTheSameCaptureAndCompletesAgain() async throws {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.complete, with: uploadIncomplete)
        let model = fake.makeModel()

        await drive(model, through: .complete)

        #expect(fake.uploadURLCalls.count == 1)
        #expect(fake.uploadCalls.count == 2)
        let first = try #require(fake.uploadCalls.first)
        #expect(fake.uploadCalls[1] == first)
        #expect(fake.completeCalls.count == 2)
        #expect(fake.startCalls.count == 1)
        #expect(fake.results == [.success(verifiedResult)])
    }

    @Test func notStartedFromCompleteRestartsLivenessWithTheSameAttemptState() async {
        let fake = FakeReVerify()
        fake.outcomes = [outcome(.retry, failed: 1)]
        fake.fail(ReVerifyRoute.complete, call: 2, with: livenessNotStarted)
        let model = fake.makeModel()

        await drive(model, through: .complete)
        await captureCurrentAttempt(model)

        let attempt = currentAttempt(model)
        #expect(attempt?.livenessSessionID == "lv-3")
        #expect(attempt?.attemptsRemaining == 2)
        #expect(attempt?.guidance == .retryMismatch)
        #expect(fake.phases.suffix(3) == ["deciding", "checking", "liveness(lv-3)"])
        #expect(fake.results.isEmpty)
    }

    @Test func notStartedFromUploadURLRestartsInsteadOfRetryingUploadURL() async {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.uploadURL, with: livenessNotStarted)
        let model = fake.makeModel()

        await drive(model, through: .uploadURL)

        #expect(currentAttempt(model)?.livenessSessionID == "lv-2")
        #expect(fake.uploadURLCalls.count == 1)
        #expect(fake.uploadCalls.isEmpty)

        await captureCurrentAttempt(model)
        #expect(fake.uploadURLCalls.count == 2)
        #expect(fake.results == [.success(verifiedResult)])
    }

    @Test func secondConsecutiveNotStartedStopsOnTheFailureScreen() async {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.complete, call: 1, with: livenessNotStarted)
        fake.fail(ReVerifyRoute.complete, call: 2, with: livenessNotStarted)
        let model = fake.makeModel()

        await drive(model, through: .complete)
        #expect(currentAttempt(model)?.livenessSessionID == "lv-2")
        await captureCurrentAttempt(model)

        #expect(model.phase == .failed(livenessNotStarted))
        #expect(model.canRetry)
        #expect(fake.startCalls.count == 2)

        model.retry()
        await model.awaitPendingWork()
        #expect(currentAttempt(model)?.livenessSessionID == "lv-3")
        #expect(fake.results.isEmpty)
    }

    @Test func notStartedFromUploadURLAndCompleteCountTogether() async {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.uploadURL, call: 1, with: livenessNotStarted)
        fake.fail(ReVerifyRoute.complete, call: 1, with: livenessNotStarted)
        let model = fake.makeModel()

        await drive(model, through: .uploadURL)
        await captureCurrentAttempt(model)

        #expect(model.phase == .failed(livenessNotStarted))
        #expect(fake.startCalls.count == 2)
    }

    @Test func aDecisionResetsTheRestartCount() async {
        let fake = FakeReVerify()
        fake.outcomes = [outcome(.retry, failed: 1)]
        fake.fail(ReVerifyRoute.complete, call: 1, with: livenessNotStarted)
        fake.fail(ReVerifyRoute.complete, call: 3, with: livenessNotStarted)
        let model = fake.makeModel()

        await drive(model, through: .complete)  // not started → lv-2
        await captureCurrentAttempt(model)  // retry decision → lv-3
        await captureCurrentAttempt(model)  // not started again, but not in a row → lv-4

        #expect(currentAttempt(model)?.livenessSessionID == "lv-4")
        await captureCurrentAttempt(model)
        #expect(fake.results == [.success(verifiedResult)])
    }

    // MARK: Cancel and the latch

    @Test func cancelWhileCheckingDeliversCancelled() async {
        let fake = FakeReVerify()
        fake.hang(.create)
        let model = fake.makeModel()
        model.start()
        await waitUntil { fake.createCalls.count == 1 }

        model.cancel()
        await model.awaitPendingWork()

        #expect(fake.results.map(\.failureKind) == [.cancelled])
        #expect(fake.startCalls.isEmpty)
        #expect(fake.phases.last == "outcome")
    }

    @Test func cancelWhileCapturingDeliversCancelled() async {
        let fake = FakeReVerify()
        let model = fake.makeModel()
        await drive(model, through: .start)

        model.cancel()

        #expect(fake.results.map(\.failureKind) == [.cancelled])
        #expect(fake.phases.last == "outcome")
    }

    @Test func cancelWhileUploadingDeliversCancelled() async {
        let fake = FakeReVerify()
        fake.hang(.uploadURL)
        let model = fake.makeModel()
        await drive(model, through: .start)
        model.captured(reVerifyCapture, livenessSessionID: "lv-1")
        await waitUntil { fake.uploadURLCalls.count == 1 }

        model.cancel()
        await model.awaitPendingWork()

        #expect(fake.results.map(\.failureKind) == [.cancelled])
        #expect(fake.uploadCalls.isEmpty)
        #expect(fake.phases.last == "outcome")
    }

    @Test func cancelWhileDecidingDeliversCancelled() async {
        let fake = FakeReVerify()
        fake.hang(.complete)
        let model = fake.makeModel()
        await drive(model, through: .start)
        model.captured(reVerifyCapture, livenessSessionID: "lv-1")
        await waitUntil { fake.completeCalls.count == 1 }
        #expect(model.phase == .deciding)

        model.cancel()
        await model.awaitPendingWork()

        #expect(fake.results.map(\.failureKind) == [.cancelled])
        #expect(fake.phases.last == "outcome")
    }

    @Test func cancelOnTheFailureScreenDeliversCancelledNotTheError() async {
        let fake = FakeReVerify()
        fake.fail(ReVerifyRoute.create, with: networkDown)
        let model = fake.makeModel()
        await drive(model, through: .create)

        model.cancel()

        #expect(fake.results.map(\.failureKind) == [.cancelled])
    }

    /// A task cancelled before it first ran must not publish a phase over the outcome.
    @Test func cancelRightAfterCaptureLeavesTheOutcomeInPlace() async {
        let fake = FakeReVerify()
        let model = fake.makeModel()
        await drive(model, through: .start)

        model.captured(reVerifyCapture, livenessSessionID: "lv-1")
        model.cancel()
        await model.awaitPendingWork()

        #expect(model.phase == .outcome(.failure(.cancelled("Re-verification was cancelled."))))
        #expect(fake.uploadURLCalls.isEmpty)
        #expect(fake.results.count == 1)
    }

    @Test func nothingFiresAfterTheOutcome() async {
        let fake = FakeReVerify()
        let model = fake.makeModel()
        await drive(model, through: .complete)
        #expect(fake.results == [.success(verifiedResult)])

        model.cancel()
        model.dismissFailure()
        model.retry()
        model.start()
        model.captured(reVerifyCapture, livenessSessionID: "lv-1")
        model.captureFailed(.captureFailed("late"), livenessSessionID: "lv-1")
        await model.awaitPendingWork()

        #expect(fake.results == [.success(verifiedResult)])
        #expect(model.phase == .outcome(.success(verifiedResult)))
        #expect(fake.createCalls.count == 1)
        #expect(fake.completeCalls.count == 1)
    }

    @Test func onResultFiresOnceAcrossRetries() async {
        let fake = FakeReVerify()
        fake.outcomes = [outcome(.retry, failed: 1), outcome(.retryLiveness, failed: 1)]
        fake.fail(ReVerifyRoute.create, with: networkDown)
        fake.fail(.upload, call: 2, with: networkDown)
        fake.fail(ReVerifyRoute.complete, call: 3, with: timedOut)
        let model = fake.makeModel()

        await drive(model, through: .create)
        model.retry()  // create again
        await model.awaitPendingWork()
        await captureCurrentAttempt(model)  // retry decision
        await captureCurrentAttempt(model)  // PUT fails
        model.retry()  // re-PUT → retry_liveness decision
        await model.awaitPendingWork()
        await captureCurrentAttempt(model)  // complete times out
        model.retry()  // complete again → verified
        await model.awaitPendingWork()

        #expect(fake.results == [.success(verifiedResult)])
    }
}

extension Result where Failure == DeepIDVError {
    fileprivate var failureKind: DeepIDVError.Kind? {
        guard case .failure(let error) = self else { return nil }
        return error.kind
    }
}
