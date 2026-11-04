import Foundation

// DeepIDVCore › Classifier

/// Which of a session's documents a capture belongs to.
enum DocumentTier: String, Sendable, Equatable, CaseIterable {
    case primary
    case secondary
    case tertiary

    /// The upload slot of this tier's front photo.
    var frontSlot: SessionUploadSlot {
        switch self {
        case .primary: return .idFront
        case .secondary: return .secondaryIDFront
        case .tertiary: return .tertiaryIDFront
        }
    }
}

/// How far the confirmed type was trusted: the classifier's own, or our vote by
/// its strength.
enum CaptureTrust: String, Sendable, Equatable, Encodable {
    case api
    case strongVote = "strong_vote"
    case marginVote = "margin_vote"
    case weakVote = "weak_vote"

    init(source: TypeSource, strength: TypeStrength) {
        switch (source, strength) {
        case (.api, _): self = .api
        case (.vote, .strong): self = .strongVote
        case (.vote, .margin): self = .marginVote
        case (.vote, .weak): self = .weakVote
        }
    }
}

/// How the photo was taken.
enum CaptureTrigger: String, Sendable, Equatable, Encodable {
    case auto
    case manual
}

// MARK: - Diagnostics

/// One frame the classifier judged, for review only (never shown). Every field
/// is sent, `null` when it has no value.
struct FrameDiagnostic: Sendable, Equatable, Encodable {
    /// The decision name logged for an upside-down probe.
    static let probeDecision = "wrong_way_probe"

    /// Milliseconds into the scan.
    var t: Int
    /// Degrees the frame was turned before it was sent.
    var rot: Int
    var top1: String?
    var conf: Double?
    var margin: Double?
    /// The card's share of the frame, from the on-device check.
    var area: Double?
    /// The card's distance from the frame edge, from the on-device check.
    var edge: Double?
    var decision: String

    enum CodingKeys: String, CodingKey {
        case t, rot, top1, conf, margin, area, edge, decision
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t, forKey: .t)
        try container.encode(rot, forKey: .rot)
        try container.encode(top1, forKey: .top1)
        try container.encode(conf, forKey: .conf)
        try container.encode(margin, forKey: .margin)
        try container.encode(area, forKey: .area)
        try container.encode(edge, forKey: .edge)
        try container.encode(decision, forKey: .decision)
    }

    /// Rounds to 3 decimals, as the server stores it.
    static func round3(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return (value * 1000).rounded() / 1000
    }
}

extension ScanDecision.Key {
    /// The decision name logged for this key.
    var diagnosticName: String {
        switch self {
        case .error: return "error"
        case .noID: return "no_id"
        case .quality: return "quality"
        case .identifying: return "identifying"
        case .classified: return "classified"
        }
    }
}

/// The frames judged in one camera run, keeping the last `capacity`. A retake or
/// the next side starts a new log.
struct FrameLog: Sendable, Equatable {
    static let capacity = 12

    let startedAt: TimeInterval
    private(set) var frames: [FrameDiagnostic] = []

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }

    /// Logs an answered frame. A failed call is not a judged frame.
    mutating func add(
        _ decision: ScanDecision, at now: TimeInterval, rotation: Int, area: Double? = nil,
        edge: Double? = nil
    ) {
        guard decision.key != .error else { return }
        append(
            answer: decision.answer, at: now, rotation: rotation, area: area, edge: edge,
            decision: decision.key.diagnosticName)
    }

    /// Logs an answered upside-down probe.
    mutating func addProbe(_ outcome: DetectOutcome, at now: TimeInterval, rotation: Int) {
        guard let answer = outcome.answer else { return }
        append(
            answer: answer, at: now, rotation: rotation, area: nil, edge: nil,
            decision: FrameDiagnostic.probeDecision)
    }

    private mutating func append(
        answer: DetectAnswer?, at now: TimeInterval, rotation: Int, area: Double?, edge: Double?,
        decision: String
    ) {
        let top3 = answer?.documentType?.top3 ?? []
        let first = top3.first
        let second = top3.count > 1 ? top3[1].confidence : 0
        frames.append(
            FrameDiagnostic(
                t: max(0, Int(((now - startedAt) * 1000).rounded())),
                rot: rotation,
                top1: first?.id,
                conf: FrameDiagnostic.round3(first?.confidence),
                margin: first.flatMap { FrameDiagnostic.round3($0.confidence - second) },
                area: FrameDiagnostic.round3(area),
                edge: FrameDiagnostic.round3(edge),
                decision: decision))
        if frames.count > Self.capacity { frames.removeFirst(frames.count - Self.capacity) }
    }
}

// MARK: - Per tier

/// What the classifier had confirmed when one tier's front was photographed.
struct TierCaptureClassification: Sendable, Equatable, Encodable {
    /// Frames from the device are always upright, so there's no forced turn.
    static let orientationMode = "none"

    var documentType: String
    var trust: CaptureTrust
    /// 0...1.
    var confidence: Double
    /// At most 3, best first.
    var top3: [DetectAnswer.Candidate]
    /// 0...5: frames of the vote window that agreed.
    var votes: Int
    var captureMode: CaptureTrigger
    var modelVersion: String?
    /// 0 or 180.
    var captureRotation: Int
    /// The last frames judged before the photo; left out when there are none.
    var frames: [FrameDiagnostic]

    init(
        _ confirmed: ClassifierScanPolicy.Confirmed, captureMode: CaptureTrigger,
        frames: [FrameDiagnostic] = []
    ) {
        documentType = confirmed.id
        trust = CaptureTrust(source: confirmed.source, strength: confirmed.strength)
        confidence = min(1, max(0, confirmed.confidence))
        top3 = Array(confirmed.top3.prefix(3))
        votes = min(5, max(0, confirmed.votes))
        self.captureMode = captureMode
        modelVersion = confirmed.modelVersion
        captureRotation = confirmed.captureRotation
        self.frames = Array(frames.suffix(FrameLog.capacity))
    }

    enum CodingKeys: String, CodingKey {
        case documentType = "document_type"
        case trust, confidence, top3, votes
        case captureMode = "capture_mode"
        case modelVersion = "model_version"
        case captureRotation = "capture_rotation"
        case diagnostics
    }

    private enum DiagnosticsKeys: String, CodingKey {
        case orientationMode = "orientation_mode"
        case frames
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(documentType, forKey: .documentType)
        try container.encode(trust, forKey: .trust)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(top3, forKey: .top3)
        try container.encode(votes, forKey: .votes)
        try container.encode(captureMode, forKey: .captureMode)
        // Sent as null when the answer had no version.
        try container.encode(modelVersion, forKey: .modelVersion)
        try container.encode(captureRotation, forKey: .captureRotation)
        if !frames.isEmpty {
            var diagnostics = container.nestedContainer(
                keyedBy: DiagnosticsKeys.self, forKey: .diagnostics)
            try diagnostics.encode(Self.orientationMode, forKey: .orientationMode)
            try diagnostics.encode(frames, forKey: .frames)
        }
    }
}

extension DetectAnswer.Candidate: Encodable {
    /// Encoded as a pair, the same as on the way in: `["class_id", 0.81]`.
    func encode(to encoder: any Encoder) throws {
        var pair = encoder.unkeyedContainer()
        try pair.encode(id)
        try pair.encode(confidence)
    }
}

// MARK: - The submission field

/// The `capture_classification` field of an ID-step submission, keyed by tier.
///
/// Only fronts with a confirmed type are recorded. An untyped or mismatched
/// front, or one taken after the classifier switched off, removes its tier, so a
/// retake never carries a stale classification. A back leaves its tier alone.
struct CaptureClassificationPayload: Sendable, Equatable, Encodable {
    private(set) var tiers: [DocumentTier: TierCaptureClassification] = [:]

    init(tiers: [DocumentTier: TierCaptureClassification] = [:]) {
        self.tiers = tiers
    }

    var isEmpty: Bool { tiers.isEmpty }

    /// Records one tier's front capture: its classification, or `nil` for none.
    mutating func recordFront(_ tier: DocumentTier, _ classification: TierCaptureClassification?) {
        tiers[tier] = classification
    }

    /// The field to send: the tiers whose front photo is in `uploads`, or `nil`
    /// when there are none, so the field is left out.
    func sent(with uploads: [SessionUploadSlot: String]) -> CaptureClassificationPayload? {
        let kept = tiers.filter { uploads[$0.key.frontSlot] != nil }
        return kept.isEmpty ? nil : CaptureClassificationPayload(tiers: kept)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        for tier in DocumentTier.allCases {
            if let classification = tiers[tier] {
                try container.encode(classification, forKey: StringCodingKey(tier.rawValue))
            }
        }
    }
}

// MARK: - Extra frames

/// The upload slot of one extra frame of a tier's front. Internal, so it never
/// shows up among the public `SessionUploadSlot`s or in `uploads`.
enum ExtraFrameSlot: String, Sendable, Equatable, Hashable, CaseIterable {
    case idFront1 = "id_front_extra_1"
    case idFront2 = "id_front_extra_2"
    case secondaryIDFront1 = "secondary_id_front_extra_1"
    case secondaryIDFront2 = "secondary_id_front_extra_2"
    case tertiaryIDFront1 = "tertiary_id_front_extra_1"
    case tertiaryIDFront2 = "tertiary_id_front_extra_2"

    /// The `n`th (1 or 2) extra frame of a tier's front.
    init?(tier: DocumentTier, number: Int) {
        self.init(rawValue: "\(tier.frontSlot.rawValue)_extra_\(number)")
    }

    var tier: DocumentTier {
        switch self {
        case .idFront1, .idFront2: return .primary
        case .secondaryIDFront1, .secondaryIDFront2: return .secondary
        case .tertiaryIDFront1, .tertiaryIDFront2: return .tertiary
        }
    }
}
