// DeepIDV › IGaming

import Combine
import DeepIDVCore
import Foundation

/// The orchestration brain behind ``AntiCheatCheckView`` — the testable half
/// of the anti-cheat step.
///
/// It owns the capture → check → emit state machine but touches **no camera**:
/// the view presents `SelfieCaptureView` for the face photo and forwards its
/// `Result<FileInput, DeepIDVError>` into ``imageCaptured(_:)`` /
/// ``captureFailed(_:)``. Its one dependency is an injected ``IGamingService``
/// (built on the transport stub in tests), so the whole orchestration runs
/// headless — mirroring ``CustomFaceLivenessModel``.
///
/// `onResult` fires **once per attempt**: with the decoded ``AntiCheatResult``
/// (a duplicate/unavailable verdict is a `.success` — the endpoint is
/// fail-soft) or with the mapped failure. ``retry()`` re-arms the machine for
/// a fresh capture, so the next attempt emits again; a cancelled in-flight
/// task drops its late result.
@MainActor
final class AntiCheatModel: ObservableObject {
    /// The flow's current state. `.finished` / `.failed` are terminal per
    /// attempt; the payloads drive the view's result/error chrome.
    enum State: Sendable, Equatable {
        case idle
        case capturing
        case checking
        case finished(AntiCheatResult)
        case failed(DeepIDVError)
    }

    @Published private(set) var state: State = .idle

    private let service: IGamingService
    private let sessionID: String
    private let deviceFingerprint: String?
    private let onResult: (Result<AntiCheatResult, DeepIDVError>) -> Void

    /// The in-flight check task, retained so ``retry()`` can cancel it; a
    /// cancelled task's late result is dropped rather than emitted.
    private var task: Task<Void, Never>?

    init(
        service: IGamingService,
        sessionID: String,
        deviceFingerprint: String? = nil,
        onResult: @escaping (Result<AntiCheatResult, DeepIDVError>) -> Void
    ) {
        self.service = service
        self.sessionID = sessionID
        self.deviceFingerprint = deviceFingerprint
        self.onResult = onResult
    }

    // MARK: - Intent (driven by the view)

    /// Arms the capture step. No-op unless idle, so a re-appearing view can't
    /// reset an in-flight attempt.
    func start() {
        guard case .idle = state else { return }
        state = .capturing
    }

    /// The capture step produced a face photo → run the anti-cheat check.
    func imageCaptured(_ image: FileInput) {
        guard case .capturing = state else { return }
        state = .checking
        let service = service
        let sessionID = sessionID
        let deviceFingerprint = deviceFingerprint
        task = Task { [weak self] in
            do {
                let result = try await service.checkAntiCheat(
                    sessionID: sessionID, image: image, deviceFingerprint: deviceFingerprint)
                guard !Task.isCancelled else { return }
                self?.emit(.success(result))
            } catch let error as DeepIDVError {
                guard !Task.isCancelled else { return }
                self?.emit(.failure(error))
            } catch is CancellationError {
                // retry() owns the terminal emit.
            } catch {
                guard !Task.isCancelled else { return }
                self?.emit(.failure(Self.unexpected(error)))
            }
        }
    }

    /// The capture step failed (permission denied, cancel, camera error) →
    /// surface the error the capture view already mapped.
    func captureFailed(_ error: DeepIDVError) {
        guard state == .capturing || state == .idle else { return }
        emit(.failure(error))
    }

    /// "Try again" — abandons the current attempt and re-arms for a fresh
    /// capture. The next attempt emits `onResult` again.
    func retry() {
        task?.cancel()
        task = nil
        state = .capturing
    }

    /// Awaits the in-flight check task — a test seam so tests never poll.
    func awaitPendingWork() async {
        await task?.value
    }

    // MARK: - Completion

    /// Lands a terminal state and fires the once-per-attempt callback; a
    /// later call (e.g. after a retry already re-armed the machine) is a
    /// no-op.
    private func emit(_ result: Result<AntiCheatResult, DeepIDVError>) {
        switch state {
        case .finished, .failed:
            return  // already emitted this attempt
        default:
            break
        }
        switch result {
        case .success(let value): state = .finished(value)
        case .failure(let error): state = .failed(error)
        }
        onResult(result)
    }

    /// Fallback for the (contractually unreachable) case where the service
    /// throws a non-`DeepIDVError`, non-cancellation error — it only ever
    /// throws `DeepIDVError`.
    private static func unexpected(_ error: Error) -> DeepIDVError {
        .network(
            "Anti-cheat check failed unexpectedly.", causeDescription: String(describing: error))
    }
}
