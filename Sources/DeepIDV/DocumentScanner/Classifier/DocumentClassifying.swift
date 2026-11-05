// DeepIDV › DocumentScanner › Classifier

import DeepIDVCore
import Foundation

/// The document classifier's say on the current frame of a card front.
enum ClassifierVerdict: Sendable, Equatable {
    /// Not in play for this side: capture runs on the on-device checks alone,
    /// exactly as without a classifier.
    case off
    /// Hold auto-capture. Shows `guidance` when the on-device checks have nothing
    /// to say.
    case hold(CaptureGuidance)
    /// Hold auto-capture and show `guidance` over everything else.
    case block(CaptureGuidance)
    /// The classifier is satisfied: capture once the on-device checks have held
    /// for the classifier hold.
    case go
}

/// What a card-front photo becomes once the classifier has had its say.
struct FrontCaptureReport: Sendable {
    /// The photo to upload: the still, or a sharper kept frame, turned the right
    /// way up when the card was held upside down.
    var photo: FileInput
    /// What the classifier confirmed, or `nil` for nothing confirmed.
    var classification: TierCaptureClassification?
    /// Extra frames to send with the photo (empty unless enabled).
    var extraFrames: [FileInput]
}

/// The classifier as the capture model sees it, for one card front.
///
/// Every call is synchronous and cheap: the network and image work happen
/// inside the implementation, off the main actor.
@MainActor
protocol DocumentClassifying: AnyObject {
    /// Called on every frame of the front. `framed`: the card is in position (seen,
    /// close enough, the right shape, no glare), which is what lets an answer vote.
    /// `visionReady`: every on-device gate passed, steadiness and sharpness too.
    func observe(
        _ frame: CameraFrame, quality: CaptureQuality, framed: Bool, visionReady: Bool,
        at now: TimeInterval)
    /// The classifier's say at `now`.
    func verdict(at now: TimeInterval) -> ClassifierVerdict
    /// The front photo was taken.
    func frontCaptured(photo: FileInput, manual: Bool, at now: TimeInterval) async
        -> FrontCaptureReport
    /// The capture ended without a photo; stop any work in flight.
    func stop()
}

/// Whether the classifier works for this session: unknown until its first
/// answer, then available or not for the rest of the session.
///
/// Shared by every capture of a workflow session. The ID step sends the
/// classifier's fields only once a call has succeeded, because a server that
/// answers the classifier route also accepts its fields.
@MainActor
final class ClassifierAvailability {
    enum State: Sendable, Equatable {
        case unknown
        case available
        case unavailable
    }

    private(set) var state: State = .unknown

    /// Extra frames are only sent once the server reads them. Off until then.
    let sendsExtraFrames: Bool

    init(sendsExtraFrames: Bool = false) {
        self.sendsExtraFrames = sendsExtraFrames
    }

    /// Records how a call ended. Unavailable is final for the session.
    func record(_ response: DetectResponse) {
        guard state != .unavailable else { return }
        switch response {
        case .answer:
            state = .available
        case .failure(let failure):
            if failure.reason == .unavailable { state = .unavailable }
        }
    }
}
