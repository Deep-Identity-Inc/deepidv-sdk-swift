// DeepIDV › GuidedFlow

import Combine
import DeepIDVCore
import Foundation

/// The orchestration brain behind the drop-in ``DeepIDVVerificationView``.
///
/// It sequences the full identity-verify flow — **doc-type select → front/back
/// document capture → selfie → anti-cheat → `verifyIdentity`** — holding the
/// captured images between steps and firing `onResult` exactly once with the
/// aggregate ``DeepIDVVerificationResult``. The camera-driving sub-steps
/// (document/selfie capture) live in their own models and call back into the
/// `…Captured`/`…Failed` methods here, so this coordinator is pure state
/// machine: no camera, fully testable by driving the methods directly.
///
/// The anti-cheat step is likewise optional (the `antiCheat` seam, `nil` unless
/// an `igamingSessionID` is supplied) and, when present, reuses the already
/// -captured selfie rather than capturing a second image.
///
/// `verify` is a seam (production passes `client.verifyIdentity`; tests pass a
/// spy), so the orchestration is exercised without a transport.
@MainActor
final class VerificationFlowModel: ObservableObject {
    /// The flow's current step. Payload-free (the captured ``FileInput``s are
    /// held separately) so it stays `Equatable` for the view's `switch`.
    enum Step: Sendable, Equatable {
        case selectType
        case captureDocument
        case captureSelfie
        case antiCheat
        case verifying
    }

    /// Uploads the document + selfie and runs the combined verify — the flow's one
    /// outward call. Not `@Sendable`: stored and invoked only on the main actor.
    typealias VerifyOperation =
        (
            _ documentFront: FileInput, _ documentBack: FileInput?, _ selfie: FileInput,
            _ type: DocumentType
        ) async throws -> IdentityVerifyResult

    /// Runs the iGaming anti-cheat check with the already-captured selfie —
    /// the guided flow reuses that image rather than capturing a second one
    /// (the enrolled face is then the very image verify compares). Not
    /// `@Sendable`: stored and invoked only on the main actor.
    typealias AntiCheatOperation = (_ image: FileInput) async throws -> AntiCheatResult

    @Published private(set) var step: Step = .selectType

    /// The chosen document type — read by the view to configure the capture step.
    /// Set before the step advances past `.selectType`.
    private(set) var documentType: DocumentType = .auto

    /// The anti-cheat seam; `nil` means the flow runs without the step (no
    /// `igamingSessionID` supplied). Production wraps
    /// `client.checkAntiCheat`; tests pass a spy.
    private let antiCheat: AntiCheatOperation?
    private var antiCheatResult: AntiCheatResult?

    private let verify: VerifyOperation
    private let onResult: (Result<DeepIDVVerificationResult, DeepIDVError>) -> Void

    private var documentFront: FileInput?
    private var documentBack: FileInput?
    private var selfie: FileInput?
    private var hasFinished = false

    init(
        antiCheat: AntiCheatOperation? = nil,
        verify: @escaping VerifyOperation,
        onResult: @escaping (Result<DeepIDVVerificationResult, DeepIDVError>) -> Void
    ) {
        self.antiCheat = antiCheat
        self.verify = verify
        self.onResult = onResult
    }

    // MARK: - Step transitions (driven by the sub-step views)

    /// Document type chosen in the picker → advance to document capture.
    func selectType(_ type: DocumentType) {
        guard !hasFinished, step == .selectType else { return }
        documentType = type
        step = .captureDocument
    }

    /// Document images captured → advance to the selfie.
    func documentCaptured(front: FileInput, back: FileInput?) {
        guard !hasFinished, step == .captureDocument else { return }
        documentFront = front
        documentBack = back
        step = .captureSelfie
    }

    /// Document capture failed/denied/cancelled → report it.
    func documentFailed(_ error: DeepIDVError) {
        finish(.failure(error))
    }

    /// Selfie captured → anti-cheat (when configured), then verify. `async` so
    /// callers (and tests) can await the verify round-trip.
    func selfieCaptured(_ selfie: FileInput) async {
        guard !hasFinished, step == .captureSelfie, documentFront != nil else { return }
        self.selfie = selfie
        await runAntiCheatThenVerify()
    }

    /// Selfie capture failed/denied/cancelled → report it.
    func selfieFailed(_ error: DeepIDVError) {
        finish(.failure(error))
    }

    /// User backed out of the whole flow.
    func cancel() {
        finish(.failure(.cancelled("Identity verification was cancelled.")))
    }

    // MARK: - Anti-cheat (iGaming)

    /// Runs the optional anti-cheat step with the held selfie, then verify.
    /// No seam configured → straight to verify (the step never appears).
    /// `action == .block` ends the flow — the server has already failed the
    /// session — while every other verdict (including a flagged duplicate)
    /// rides the aggregate for the host to act on.
    private func runAntiCheatThenVerify() async {
        guard let antiCheat else {
            await runVerify()
            return
        }
        guard let selfie else { return }
        step = .antiCheat
        do {
            let result = try await antiCheat(selfie)
            antiCheatResult = result
            if result.isBlocked {
                finish(
                    .failure(
                        .antiCheatBlocked(
                            "The anti-cheat check blocked this session "
                                + "(verdict: \(result.verdict)).")))
            } else {
                await runVerify()
            }
        } catch let error as DeepIDVError {
            finish(.failure(error))
        } catch {
            finish(
                .failure(
                    .network(
                        "Anti-cheat check failed.",
                        causeDescription: String(describing: error))))
        }
    }

    // MARK: - Verify

    /// Runs the combined verify with the held images and assembles the aggregate.
    private func runVerify() async {
        guard let front = documentFront, let selfie else { return }
        step = .verifying
        do {
            let identity = try await verify(front, documentBack, selfie, documentType)
            finish(
                .success(
                    DeepIDVVerificationResult(
                        identity: identity, antiCheat: antiCheatResult)))
        } catch let error as DeepIDVError {
            finish(.failure(error))
        } catch {
            finish(
                .failure(
                    .captureFailed(
                        "Identity verification failed.",
                        causeDescription: String(describing: error))))
        }
    }

    // MARK: - Completion

    private func finish(_ result: Result<DeepIDVVerificationResult, DeepIDVError>) {
        guard !hasFinished else { return }
        hasFinished = true
        onResult(result)
    }
}
