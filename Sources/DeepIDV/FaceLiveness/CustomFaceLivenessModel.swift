// DeepIDV › FaceLiveness

import DeepIDVCore
import Foundation

/// Drives the custom liveness flow: `create → (view captures) → upload → fetch`,
/// firing `onResult` **once per attempt**. Deliberately imports no AVFoundation /
/// Vision — the camera + challenge choreography live in
/// ``CustomLivenessCaptureController`` / ``CustomFaceLivenessView`` so this model
/// drives headless in tests.
@MainActor
final class CustomFaceLivenessModel: ObservableObject {
    enum State: Equatable {
        case idle
        case creating
        case capturing(ChallengeScript)
        case uploading
        case fetching
        case finished(FaceLivenessResult)
        case failed(DeepIDVError)
    }

    @Published private(set) var state: State = .idle

    private let service: CustomFaceLivenessServicing
    private let sessionID: String
    private let onResult: (Result<FaceLivenessResult, DeepIDVError>) -> Void
    private var task: Task<Void, Never>?

    init(
        service: CustomFaceLivenessServicing,
        sessionID: String,
        onResult: @escaping (Result<FaceLivenessResult, DeepIDVError>) -> Void
    ) {
        self.service = service
        self.sessionID = sessionID
        self.onResult = onResult
    }

    // MARK: - Intent (driven by the view)

    /// Mints a session and publishes its ``ChallengeScript`` for the view to run.
    func start() {
        guard case .idle = state else { return }
        state = .creating
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.service.createSession(sessionID: self.sessionID)
                if Task.isCancelled { return }
                self.state = .capturing(session.script)
            } catch {
                self.emit(.failure(Self.mapError(error)))
            }
        }
    }

    /// The view finished capturing — upload the frames + timeline, then score.
    func submit(frames: [Data], timeline: Data, clip: Data? = nil) {
        guard case .capturing = state else { return }
        state = .uploading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let urls = try await self.service.requestUploadURLs(
                    sessionID: self.sessionID, frameCount: frames.count,
                    clipMimeType: clip != nil ? "video/mp4" : nil)
                try await self.service.uploadFrames(frames, timeline: timeline, clip: clip, to: urls)
                if Task.isCancelled { return }
                self.state = .fetching
                let result = try await self.service.fetchResult(sessionID: self.sessionID)
                self.emit(.success(result))
            } catch {
                self.emit(.failure(Self.mapError(error)))
            }
        }
    }

    /// "Try again" — abandons the current attempt and mints a fresh session.
    func retry() {
        task?.cancel()
        state = .idle
        start()
    }

    /// User backed out — reports `.cancelled` unless the attempt already ended.
    func cancel() {
        task?.cancel()
        emit(.failure(.cancelled("Face liveness was cancelled.")))
    }

    /// The capture engine failed (camera/timeout) before producing frames.
    func captureFailed(_ error: DeepIDVError) {
        guard case .capturing = state else { return }
        emit(.failure(error))
    }

    /// Test seam: awaits the in-flight create/upload/fetch task.
    func awaitPendingWork() async { await task?.value }

    // MARK: - Emit (at most once per attempt)

    private func emit(_ result: Result<FaceLivenessResult, DeepIDVError>) {
        switch state {
        case .finished, .failed: return
        default: break
        }
        switch result {
        case .success(let value): state = .finished(value)
        case .failure(let error): state = .failed(error)
        }
        onResult(result)
    }

    private static func mapError(_ error: Error) -> DeepIDVError {
        (error as? DeepIDVError) ?? .network("Custom liveness failed: \(error)")
    }
}
