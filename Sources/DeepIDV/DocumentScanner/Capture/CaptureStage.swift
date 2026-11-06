// DeepIDV › DocumentScanner › Capture

import DeepIDVCore
import Foundation

/// What the capture screen asks of the user right now: one instruction at a
/// time.
///
/// The capture model works out a stage from its state on every frame, and
/// ``CaptureStagePresenter`` decides when the screen moves to it, so a hint that
/// is true for one frame and false the next never flashes on screen.
enum CaptureStage: Sendable, Equatable {
    /// No document in view yet.
    case findDocument
    /// A document is in view but needs adjusting before it can be read.
    case adjust(Adjustment)
    /// The document classifier is checking the document.
    case checking
    /// The card is upside down.
    case turnOver
    /// Another kind of document than the one picked.
    case wrongDocument(DocumentClassKind)
    /// A health card, which can't be used.
    case healthCard
    /// In position: hold still while the capture completes.
    case holdStill
    /// A side was just captured.
    case captured
    /// The front is captured: turn the card over for the back.
    case flip
    /// The photos are being sent.
    case processing

    /// What to change about a document in view.
    enum Adjustment: Sendable, Equatable {
        case turnToLandscape
        case moveCloser
        case fitInFrame
        case reduceGlare
    }

    /// The stage for a live guidance hint.
    init(_ guidance: CaptureGuidance) {
        switch guidance {
        case .searching: self = .findDocument
        case .turnToLandscape: self = .adjust(.turnToLandscape)
        case .moveCloser: self = .adjust(.moveCloser)
        case .fitDocumentInFrame: self = .adjust(.fitInFrame)
        case .reduceGlare: self = .adjust(.reduceGlare)
        case .holdSteady: self = .holdStill
        case .identifying, .connecting: self = .checking
        case .wrongWay: self = .turnOver
        case .healthCard: self = .healthCard
        case .otherDocument(let kind): self = .wrongDocument(kind)
        }
    }

    /// Stages the screen moves to at once. They follow from something that
    /// happened (a photo was taken, a side is done), not from a single frame.
    var isImmediate: Bool {
        switch self {
        case .captured, .flip, .processing: return true
        default: return false
        }
    }

    /// The least time the stage stays on screen once shown, so the flip
    /// animation plays through even when the card is turned at once.
    var minimumShow: TimeInterval {
        self == .flip ? 1.6 : 0
    }

    /// Stages that tell the user something is wrong, for a warning haptic.
    var isProblem: Bool {
        switch self {
        case .wrongDocument, .healthCard: return true
        default: return false
        }
    }

    /// The default English instruction, or `nil` for a stage the screen shows
    /// without one (the captured tick, the processing screen).
    var defaultText: String? {
        switch self {
        case .findDocument: return L("Point the camera at your document")
        case .adjust(.turnToLandscape): return L("Turn your card to landscape")
        case .adjust(.moveCloser): return L("Move closer")
        case .adjust(.fitInFrame): return L("Fit your document in the frame")
        case .adjust(.reduceGlare): return L("Tilt it away from the light to reduce glare")
        case .checking: return L("Checking your ID…")
        case .turnOver: return L("Your card is upside down. Turn it the right way up")
        case .wrongDocument(let kind):
            return L("This looks like %@. Is this the right document?", Self.kindLabel(kind))
        case .healthCard: return L("Health cards can't be used. Please use a different ID.")
        case .holdStill: return L("Hold still")
        case .captured, .processing: return nil
        case .flip: return L("Now turn it over to scan the back")
        }
    }

    /// A document kind in a sentence: "a driver's license", "an ID card".
    static func kindLabel(_ kind: DocumentClassKind) -> String {
        switch kind {
        case .driversLicence: return L("a driver's license")
        case .idCard: return L("an ID card")
        case .healthCard: return L("a health card")
        case .federal: return L("a government ID")
        case .passport: return L("a passport")
        }
    }
}

/// Decides which stage is on screen. A new stage replaces the one shown only
/// once it has held for `settle`, so a frame or two of a different reading
/// never flashes a different instruction. Stages that follow from an event
/// (``CaptureStage/isImmediate``) show at once.
///
/// Pure and clock-free: the caller passes `now`.
struct CaptureStagePresenter: Sendable, Equatable {
    /// How long a new stage must hold before it replaces the one on screen.
    static let settle: TimeInterval = 0.5

    private(set) var shown: CaptureStage
    private var shownSince: TimeInterval?
    private var candidate: CaptureStage?
    private var candidateSince: TimeInterval = 0

    init(_ initial: CaptureStage = .findDocument) {
        shown = initial
    }

    /// Offers the stage the capture is in at `now`; returns the stage to show.
    @discardableResult
    mutating func update(_ next: CaptureStage, at now: TimeInterval) -> CaptureStage {
        let since = shownSince ?? now
        shownSince = since
        if next == shown {
            candidate = nil
        } else if next.isImmediate {
            show(next, at: now)
        } else {
            if candidate != next {
                candidate = next
                candidateSince = now
            }
            let held = now - candidateSince >= Self.settle - 1e-9
            let shownLongEnough = now - since >= shown.minimumShow - 1e-9
            if held, shownLongEnough { show(next, at: now) }
        }
        return shown
    }

    private mutating func show(_ stage: CaptureStage, at now: TimeInterval) {
        shown = stage
        shownSince = now
        candidate = nil
    }
}
