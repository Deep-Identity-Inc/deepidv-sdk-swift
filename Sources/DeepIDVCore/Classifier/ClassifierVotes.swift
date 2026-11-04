// DeepIDVCore › Classifier

/// How a document type came to be confirmed.
enum TypeSource: String, Sendable, Equatable {
    /// The classifier named it on consecutive frames.
    case api
    /// Our vote over its ranked guesses confirmed it: a best guess.
    case vote
}

/// How far a confirmed type is trusted. `strong` and `margin` are specific;
/// `weak` is trusted only as far as its kind.
enum TypeStrength: String, Sendable, Equatable {
    case strong
    case margin
    case weak

    /// For ranking a sticky document: higher is more trusted.
    var rank: Int {
        switch self {
        case .weak: return 0
        case .margin: return 1
        case .strong: return 2
        }
    }
}

/// One frame in the vote window: its best guess, that guess's confidence and its
/// margin over the second guess.
struct VoteEntry: Sendable, Equatable {
    var id: String?
    var confidence: Double
    var margin: Double

    init(_ id: String?, _ confidence: Double, margin: Double = 0) {
        self.id = id
        self.confidence = confidence
        self.margin = margin
    }
}

/// A type that a frame or the vote window points at.
struct ScanDoc: Sendable, Equatable {
    var id: String?
    var confidence: Double
    /// Set when the vote confirmed it: how many frames agreed.
    var votes: Int?
}

/// What one classifier answer means for one frame, before the scan policy.
struct ScanDecision: Sendable, Equatable {
    enum Key: Sendable, Equatable {
        /// The call failed.
        case error
        /// No card in the frame.
        case noID
        /// The on-device quality check didn't pass for the frame that was sent.
        case quality
        /// A good card, type not (yet) confirmed.
        case identifying
        /// A type is confirmed, by streak or by vote.
        case classified
    }

    var key: Key
    var source: TypeSource?
    var strength: TypeStrength?
    var answer: DetectAnswer?
    var doc: ScanDoc?
    /// The best guess, when the classifier named no type.
    var top: DetectAnswer.Candidate?

    init(
        _ key: Key, source: TypeSource? = nil, strength: TypeStrength? = nil,
        answer: DetectAnswer? = nil, doc: ScanDoc? = nil, top: DetectAnswer.Candidate? = nil
    ) {
        self.key = key
        self.source = source
        self.strength = strength
        self.answer = answer
        self.doc = doc
        self.top = top
    }
}

/// The running memory behind `ClassifierVotes.decide`.
struct ScanMemo: Sendable, Equatable {
    /// Failed calls in a row.
    var errors = 0
    /// The type the classifier named on the last good frame.
    var lastType: String?
    /// How many good frames in a row named `lastType`.
    var streak = 0
    /// The last `ClassifierVotes.window` good frames, oldest first.
    var votes: [VoteEntry] = []
}

/// Turns one classifier answer into a per-frame decision: the classifier's own
/// streak, or a vote over the last few frames' ranked guesses.
///
/// Ported from the web capture with the same rules and numbers, which were
/// tuned on real scans.
enum ClassifierVotes {
    /// Frames in a row that must name the same type before it counts as confirmed.
    static let confirmStreak = 2
    /// The vote window: a type is confirmed when it is the best guess on
    /// `need` of the last `window` good frames, each at its floor or more.
    static let window = 5
    static let need = 3
    /// The vote floor for a health card, which the health-card block is tuned on.
    static let healthFloor = 0.2
    /// The vote floor for every other card. An upright card mostly scores well
    /// above this; a card turned upside down mostly scores below it for some
    /// wrong class.
    static let namedFloor = 0.5

    /// A strong vote: the same id leads at least this many frames of the window,
    /// with at least this mean confidence and mean margin over the second guess.
    static let strongVotes = 4
    static let strongMeanConfidence = 0.25
    static let strongMeanMargin = 0.15

    /// A margin vote, just below a strong one: a known class, never a health card.
    static let marginVotes = 4
    static let marginMeanConfidence = 0.2
    static let marginMeanMargin = 0.15

    /// The confidence a frame's best guess `id` needs to vote.
    static func floor(for id: String) -> Double {
        DocumentClassCatalog.isHealthCard(id) ? healthFloor : namedFloor
    }

    /// Frames in the window whose best guess is `id` at its floor or more.
    static func agreeing(_ votes: [VoteEntry], id: String, floor: Double? = nil) -> Int {
        let floor = floor ?? self.floor(for: id)
        return votes.filter { $0.id == id && $0.confidence >= floor }.count
    }

    /// How strong a vote for `id` is, over every frame that put it first (at any
    /// confidence).
    static func strength(_ votes: [VoteEntry], id: String) -> TypeStrength {
        let agree = votes.filter { $0.id == id }
        guard !agree.isEmpty else { return .weak }
        let count = Double(agree.count)
        let confidence = agree.reduce(0) { $0 + $1.confidence } / count
        let margin = agree.reduce(0) { $0 + $1.margin } / count
        if agree.count >= strongVotes, confidence >= strongMeanConfidence,
            margin >= strongMeanMargin
        {
            return .strong
        }
        let marginVote =
            agree.count >= marginVotes && confidence >= marginMeanConfidence
            && margin >= marginMeanMargin && DocumentClassCatalog.kind(of: id) != nil
            && !DocumentClassCatalog.isHealthCard(id)
        return marginVote ? .margin : .weak
    }

    /// The type the window confirms, or `nil`. Each frame votes at its id's floor
    /// unless `floor` is given; `allow` decides which ids may be confirmed.
    static func tally(
        _ votes: [VoteEntry], need: Int = need, floor: Double? = nil,
        allow: (String) -> Bool
    ) -> ScanDoc? {
        // Ordered by first appearance, so the answer never depends on hashing.
        var order: [String] = []
        var counts: [String: (votes: Int, confidence: Double)] = [:]
        for entry in votes {
            guard let id = entry.id, entry.confidence >= (floor ?? self.floor(for: id)) else {
                continue
            }
            if counts[id] == nil { order.append(id) }
            let previous = counts[id]?.votes ?? 0
            // The latest frame's confidence.
            counts[id] = (previous + 1, entry.confidence)
        }
        for id in order {
            guard let count = counts[id], count.votes >= need, allow(id) else { continue }
            return ScanDoc(id: id, confidence: count.confidence, votes: count.votes)
        }
        return nil
    }

    /// One classifier answer to one decision. `memo` is updated in place.
    ///
    /// - Parameters:
    ///   - frameGood: whether the frame that was sent passed the on-device quality
    ///     check. A frame that didn't neither extends a streak nor votes.
    ///   - allow: whether the vote may confirm a given id (see
    ///     `ClassifierScanPolicy.voteAllows`).
    static func decide(
        _ outcome: DetectOutcome, frameGood: Bool, memo: inout ScanMemo,
        allow: (String) -> Bool
    ) -> ScanDecision {
        guard case .answer(let answer) = outcome else {
            memo.errors += 1
            memo.streak = 0
            return ScanDecision(.error)
        }
        memo.errors = 0
        guard answer.present else {
            // The card left the frame: earlier votes may be another card's.
            memo.votes.removeAll()
            memo.streak = 0
            return ScanDecision(.noID, answer: answer)
        }
        guard frameGood else {
            memo.streak = 0
            return ScanDecision(.quality, answer: answer)
        }

        let doc = answer.documentType ?? .init(id: nil, confidence: 0)
        let top = doc.top3.first
        let second = doc.top3.count > 1 ? doc.top3[1].confidence : 0
        memo.votes.append(
            top.map { VoteEntry($0.id, $0.confidence, margin: $0.confidence - second) }
                ?? VoteEntry(nil, 0))
        if memo.votes.count > window { memo.votes.removeFirst() }

        let named = ScanDoc(id: doc.id, confidence: doc.confidence)
        if let id = doc.id {
            memo.streak = id == memo.lastType ? memo.streak + 1 : 1
            memo.lastType = id
            if memo.streak >= confirmStreak {
                return ScanDecision(
                    .classified, source: .api, strength: .strong, answer: answer, doc: named)
            }
        } else {
            memo.lastType = nil
            memo.streak = 0
        }
        if let voted = tally(memo.votes, allow: allow), let id = voted.id {
            return ScanDecision(
                .classified, source: .vote, strength: strength(memo.votes, id: id),
                answer: answer, doc: voted)
        }
        if doc.id != nil {
            return ScanDecision(.identifying, source: .api, answer: answer, doc: named)
        }
        return ScanDecision(.identifying, answer: answer, top: top)
    }
}
