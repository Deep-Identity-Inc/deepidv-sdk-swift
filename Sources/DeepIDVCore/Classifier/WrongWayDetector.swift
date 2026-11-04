import Foundation

// DeepIDVCore › Classifier

/// Catches a card held upside down.
///
/// An upside-down card reaches the classifier upside down and is never
/// confirmed: it scores low, often for some wrong class. So once a card has been
/// in frame for `stuckDelay` with no type confirmed, a frame is also sent turned
/// by `probeRotation`, at most once every `probeInterval`. A probe that is
/// clearly a known card the right way up, on `flipProbes` probes in a row, sets
/// `flip`: the scan turns every later frame, and the photo, the other way. A
/// probe that only beats the normal frames holds capture and asks the user to
/// turn the card.
///
/// A probe's answer is never voted on or captured from. Pure and clock-free, as
/// `ClassifierScanPolicy` is.
struct WrongWayDetector: Sendable, Equatable {
    /// How long a card must be in frame unconfirmed before probing starts.
    static let stuckDelay: TimeInterval = 1
    /// At most one probe this often; while a flip waits for its second probe, one
    /// with every answer.
    static let probeInterval: TimeInterval = 1
    /// The best-guess confidence a probe needs to ask the user to turn the card.
    static let probeMinConfidence = ClassifierVotes.namedFloor
    /// The best-guess confidence a probe needs to flip the scan.
    static let flipMinConfidence = 0.75
    /// Probes in a row, naming the same class, that flip the scan.
    static let flipProbes = 2
    /// The normal frames a probe is compared with: those of the last few seconds.
    static let recentWindow: TimeInterval = 3
    /// How far a probe frame is turned, in degrees. Frames reach the classifier
    /// upright for the device, so the wrong way is a half turn.
    static let probeRotation = 180

    struct Sample: Sendable, Equatable {
        var time: TimeInterval
        var confidence: Double
    }

    struct Pending: Sendable, Equatable {
        var id: String
        var probes: Int
    }

    /// When the current run of unconfirmed frames with a card began, or `nil`.
    private(set) var stuckSince: TimeInterval?
    /// That run's best-guess confidences, the last `recentWindow` of them.
    var recent: [Sample] = []
    /// Ask the user to turn the card.
    private(set) var shown = false
    /// The class a strong probe named, and how many strong probes in a row named it.
    private(set) var pending: Pending?
    /// `flipProbes` strong probes agreed: turn the scan the other way.
    private(set) var flip = false
    /// When the last probe was answered (or failed), or `nil`.
    private(set) var lastProbeAt: TimeInterval?

    init() {}

    /// Whether auto-capture must wait: the turn-the-card note shows, or a flip
    /// waits for its next probe.
    var holdsCapture: Bool { shown || pending != nil }

    /// The mean best-guess confidence of the recent normal frames, or 0.
    var recentMean: Double {
        recent.isEmpty ? 0 : recent.reduce(0) { $0 + $1.confidence } / Double(recent.count)
    }

    /// Whether the answer at `now` should also get a probe.
    func probeDue(at now: TimeInterval) -> Bool {
        if pending != nil { return true }
        guard let stuckSince, now - stuckSince >= Self.stuckDelay - 1e-9 else { return false }
        guard let lastProbeAt else { return true }
        return now - lastProbeAt >= Self.probeInterval - 1e-9
    }

    /// Whether one answer's best guess reaches its class's vote floor.
    static func reachesFloor(_ outcome: DetectOutcome) -> Bool {
        guard let reading = Reading(outcome), let id = reading.id else { return false }
        return reading.confidence >= ClassifierVotes.floor(for: id)
    }

    /// Records a normal frame's answer at `now`. A frame without a card, or a
    /// `confirmed` type, ends the run. By default a frame counts as confirmed when
    /// it reaches its floor; the scan passes the real verdict, because one
    /// upside-down frame can reach the floor without confirming anything.
    mutating func recordFrame(_ outcome: DetectOutcome, at now: TimeInterval, confirmed: Bool? = nil) {
        guard let reading = Reading(outcome) else { return }
        let confirmed = confirmed ?? Self.reachesFloor(outcome)
        if !reading.box || confirmed {
            if stuckSince != nil || shown || pending != nil { self = WrongWayDetector() }
            return
        }
        recent.append(Sample(time: now, confidence: reading.confidence))
        recent.removeAll { $0.time < now - Self.recentWindow }
        if stuckSince == nil { stuckSince = now }
    }

    /// Whether a probe's answer clearly beats the normal frames.
    func probeBeats(_ outcome: DetectOutcome) -> Bool {
        guard let reading = Reading(outcome) else { return false }
        return reading.confidence >= Self.probeMinConfidence && reading.confidence > recentMean
    }

    /// Whether a probe's answer is a known document the right way up, clearly
    /// enough to flip the scan.
    func probeFlips(_ outcome: DetectOutcome) -> Bool {
        guard let reading = Reading(outcome), let id = reading.id else { return false }
        return DocumentClassCatalog.kind(of: id) != nil
            && reading.confidence >= Self.flipMinConfidence && reading.confidence > recentMean
    }

    /// Records a probe's answer at `now`. A strong probe counts towards a flip for
    /// the same class as the last; any other drops a pending flip and shows the
    /// note while it beats the normal frames. A failed probe only counts for the
    /// schedule.
    mutating func recordProbe(_ outcome: DetectOutcome, at now: TimeInterval) {
        let flips = probeFlips(outcome)
        let beats = probeBeats(outcome)
        lastProbeAt = now
        guard let reading = Reading(outcome) else { return }
        if flips, let id = reading.id {
            let probes = pending?.id == id ? (pending?.probes ?? 0) + 1 : 1
            shown = false
            if probes >= Self.flipProbes {
                flip = true
                pending = nil
            } else {
                pending = Pending(id: id, probes: probes)
            }
            return
        }
        pending = nil
        shown = beats
    }

    /// One answer's card box and best guess; `nil` for a failed call, which says
    /// nothing.
    private struct Reading {
        var box: Bool
        var id: String?
        var confidence: Double

        init?(_ outcome: DetectOutcome) {
            guard let answer = outcome.answer else { return nil }
            box = answer.box != nil
            id = answer.top?.id
            confidence = answer.top?.confidence ?? 0
        }
    }
}
