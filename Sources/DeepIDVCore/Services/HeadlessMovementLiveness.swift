// DeepIDVCore › Services

import Foundation

/// Minimum frames the server needs to score a movement attempt (`checkTiming`).
private let minMovementFrames = 3
/// Server per-request upload cap (`upload-url` bounds `frame_count` to 1...8).
private let maxMovementFrames = 8

/// Headless custom face-MOVEMENT liveness: uploads an integrator-supplied,
/// ordered "move closer" sequence and returns the server's verdict. Pure
/// orchestration over ``CustomFaceLivenessServicing`` — no camera, no Vision,
/// no UI — so it drives against a stub in tests and the live service in
/// production.
///
/// Movement only: the light challenge needs SDK-driven full-screen flashes and
/// can't run headless. `sessionID` references an existing verification session
/// (created by the integrator's backend) with a `face-liveness` step configured
/// for movement — the challenge type and pass threshold now live in that step's
/// server-side config, not client params. If the step's script turns out to be
/// configured for the light challenge instead, this throws `.validation` before
/// any frames upload (headless movement can't run a light challenge).
package func runMovementLiveness(
    sessionID: String,
    frames: [FileInput],
    clip: Data? = nil,
    service: any CustomFaceLivenessServicing
) async throws -> FaceLivenessResult {
    guard frames.count >= minMovementFrames else {
        throw DeepIDVError.validation(
            "Face movement liveness needs at least \(minMovementFrames) frames, got \(frames.count).")
    }
    // Resolve to bytes before any network I/O so bad input fails as `.validation`.
    let data = try sampleEvenly(frames, to: maxMovementFrames).map { try $0.normalizedData() }

    let session = try await service.createSession(sessionID: sessionID)
    guard session.script.challengeType == .faceMovement else {
        throw DeepIDVError.validation(
            "Headless movement liveness needs a movement-configured face-liveness step, "
            + "but the workflow returned \(session.script.challengeType.rawValue). "
            + "Use CustomFaceLivenessView for the light challenge.")
    }
    // The optional replay clip rides the existing clip-upload plumbing; the
    // recorder always produces mp4, so the mime is fixed when a clip is present.
    let urls = try await service.requestUploadURLs(
        sessionID: sessionID, frameCount: data.count,
        clipMimeType: clip != nil ? "video/mp4" : nil)
    // Timeline is a minimal placeholder — server movement scoring reads only the
    // frames (needs >=3) and runs the PAD model; it ignores checkpoint metadata.
    try await service.uploadFrames(data, timeline: Data("[]".utf8), clip: clip, to: urls)
    return try await service.fetchResult(sessionID: sessionID)
}

/// Evenly picks `count` items across `items` (keeping order); returns `items`
/// unchanged when it already fits.
private func sampleEvenly<T>(_ items: [T], to count: Int) -> [T] {
    guard items.count > count else { return items }
    return (0..<count).map { items[$0 * (items.count - 1) / (count - 1)] }
}
