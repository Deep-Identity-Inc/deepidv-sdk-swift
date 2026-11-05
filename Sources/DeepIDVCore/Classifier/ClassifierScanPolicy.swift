import Foundation

// DeepIDVCore › Classifier

/// What one classifier answer means for the scan of a card front: what to show,
/// whether to take the photo, and whether to give up on the classifier.
///
/// Pure and clock-free (the caller passes `now`, in seconds on any monotonic
/// clock), so the rules are deterministic under test. Ported from the web
/// capture with the same rules and numbers. Card fronts and passport photo pages
/// are scanned; card backs never reach the classifier.
///
/// The model has no passport class, so a passport page is captured as the web
/// captures it: once the classifier has seen a good page for
/// `passportCaptureDelay`, with no hold after.
package struct ClassifierScanPolicy: Sendable {
    /// A well-framed card the classifier can't type is captured anyway once it has
    /// been good this long (plus `holdDuration`).
    package static let untypedCaptureDelay: TimeInterval = 5
    /// A passport page is captured once it has been good this long, with no hold.
    package static let passportCaptureDelay: TimeInterval = 1.5
    /// How long a capture is held, with the card staying good and the same type
    /// leading, before the photo is taken.
    package static let holdDuration: TimeInterval = 1.2
    /// Failed calls in a row after which the classifier is switched off for the
    /// rest of the capture.
    package static let fallbackAfter = 3

    /// Why the photo is being taken.
    package enum CaptureReason: String, Sendable, Equatable {
        case typed
        case voted
        case untyped
        /// A passport page, good for `passportCaptureDelay`.
        case passport
    }

    /// A capture waiting out `holdDuration`: for which type (`nil` when untyped),
    /// why, and since when.
    package struct Hold: Sendable, Equatable {
        package var key: String?
        package var reason: CaptureReason
        package var since: TimeInterval
    }

    /// The document the scan names, and how far it is trusted.
    package struct ShownDoc: Sendable, Equatable {
        package var id: String
        package var source: TypeSource
        package var strength: TypeStrength

        /// The classifier's own type above a strong vote above a margin vote above
        /// a weak one.
        package var rank: Int { source == .api ? 3 : strength.rank }
    }

    package struct State: Sendable, Equatable {
        /// Failed calls in a row.
        package var failures = 0
        /// Since when the card has been good enough to photograph, or `nil`.
        package var goodSince: TimeInterval?
        /// The sticky document: kept from its first confirmation until the card
        /// leaves the frame or fewer than `ClassifierVotes.need` of the recent
        /// frames still put it first. For the same id it only moves up in trust,
        /// so the name doesn't flicker between specific and general.
        package var doc: ShownDoc?
        /// The capture being held, or `nil`.
        package var hold: Hold?
    }

    /// What the guidance shows for one answer.
    package enum Shown: Sendable, Equatable {
        case error
        case noID
        case quality
        case identifying
        case classified
        /// The classifier named another kind of document than the one picked.
        case mismatch
        /// A health card, which can't be used.
        case healthCard
    }

    /// The document chip: confirmed (`pending == false`) or a first guess.
    package struct Chip: Sendable, Equatable {
        package var doc: ShownDoc
        package var pending: Bool
    }

    /// Another kind of document than the one picked, as the classifier named it.
    package struct Mismatch: Sendable, Equatable {
        package var id: String
        package var group: DocumentGroup
    }

    package struct Step: Sendable, Equatable {
        package var shown: Shown
        package var chip: Chip?
        /// Advisory: the card is still captured, as untyped.
        package var mismatch: Mismatch?
        /// The photo is due now.
        package var capture: CaptureReason?
        /// Why the classifier gives up, or `nil`.
        package var fallback: String?
        package var state: State
    }

    /// Per-capture context.
    package struct Context: Sendable, Equatable {
        /// The group the user picked, or `nil`.
        package var picked: DocumentGroup?
        package var health: HealthPolicy
        package var now: TimeInterval
        /// The vote window after this answer: keeps or drops the sticky document.
        package var votes: [VoteEntry] = []
        /// The card looks upside down: no hold and no capture until that clears.
        package var wrongWay = false

        /// A passport page is being scanned.
        package var passport: Bool { picked == .passport }
    }

    // MARK: Running the scan

    /// The group the user picked.
    package let picked: DocumentGroup?
    package let health: HealthPolicy
    package private(set) var memo = ScanMemo()
    package private(set) var state = State()
    /// The latest answer's decision, or `nil` before the first.
    package private(set) var lastDecision: ScanDecision?

    package init(picked: DocumentGroup?, health: HealthPolicy) {
        self.picked = picked
        self.health = health
    }

    package init(documentType: DocumentType) {
        self.init(
            picked: DocumentClassCatalog.group(for: documentType),
            health: DocumentClassCatalog.healthPolicy(for: documentType))
    }

    /// Decides one answer and steps the scan.
    ///
    /// - Parameters:
    ///   - frameGood: whether the frame that was sent passed the on-device quality
    ///     check.
    ///   - wrongWay: whether the upside-down check is holding capture.
    package mutating func step(
        _ outcome: DetectOutcome, frameGood: Bool, now: TimeInterval, wrongWay: Bool = false
    ) -> Step {
        let picked = self.picked
        let health = self.health
        let decision = ClassifierVotes.decide(outcome, frameGood: frameGood, memo: &memo) {
            Self.voteAllows($0, health: health, picked: picked)
        }
        let context = Context(
            picked: picked, health: health, now: now, votes: memo.votes, wrongWay: wrongWay)
        let step = Self.step(state, decision: decision, outcome: outcome, context: context)
        state = step.state
        lastDecision = decision
        return step
    }

    /// The photo is due at `now`: the hold has run its full length.
    package func captureDue(at now: TimeInterval) -> CaptureReason? {
        Self.holdDue(state, now: now)
    }

    /// The confirmed classification of the latest decision, for the submission.
    package func confirmed(_ decision: ScanDecision, captureRotation: Int = 0) -> Confirmed? {
        Self.confirmed(decision, memo: memo, shown: state.doc, captureRotation: captureRotation)
    }

    // MARK: The rules

    /// Whether the vote may confirm `id`: a class of the picked group, or a health
    /// card under the strict policy whatever was picked.
    package static func voteAllows(_ id: String, health: HealthPolicy, picked: DocumentGroup?)
        -> Bool
    {
        if DocumentClassCatalog.isHealthCard(id) { return health == .strict }
        guard let picked else { return false }
        return DocumentClassCatalog.group(of: id) == picked
    }

    package enum HealthVerdict: Sendable, Equatable {
        /// Never photographed automatically; the warning shows.
        case blocked
        /// Auto-capture waits on "Checking your ID…".
        case suspected
    }

    /// What a sticky health card means: blocked when the classifier named it, or
    /// (strict only) on a strong vote; suspected on a weaker vote.
    package static func healthVerdict(_ doc: ShownDoc?, health: HealthPolicy) -> HealthVerdict? {
        guard let doc, DocumentClassCatalog.isHealthCard(doc.id) else { return nil }
        if doc.source == .api { return .blocked }
        guard health == .strict else { return nil }
        return doc.strength == .strong ? .blocked : .suspected
    }

    /// Whether a health card is the window's best guess, at any confidence: no
    /// other id leads more of its frames (a tie counts as leading).
    package static func healthLeads(_ votes: [VoteEntry]) -> Bool {
        var counts: [String: Int] = [:]
        for case let id? in votes.map(\.id) { counts[id, default: 0] += 1 }
        var health = 0
        var other = 0
        for (id, count) in counts {
            if DocumentClassCatalog.isHealthCard(id) {
                health = max(health, count)
            } else {
                other = max(other, count)
            }
        }
        return health > 0 && health >= other
    }

    /// The photo is due: a hold has lasted `holdDuration`.
    package static func holdDue(_ state: State, now: TimeInterval) -> CaptureReason? {
        guard let hold = state.hold else { return nil }
        if hold.reason == .passport { return .passport }
        guard reached(now - hold.since, holdDuration) else { return nil }
        return hold.reason
    }

    /// One answer, decided, to what the scan shows and does.
    package static func step(
        _ previous: State, decision: ScanDecision, outcome: DetectOutcome, context: Context
    ) -> Step {
        var step = stepOf(previous, decision: decision, outcome: outcome, context: context)
        // A card that looks upside down would be photographed upside down: wait.
        let hold = context.wrongWay ? nil : nextHold(previous.hold, step: step, context: context)
        step.state.hold = hold
        step.capture = context.wrongWay ? nil : holdDue(step.state, now: context.now)
        return step
    }

    // MARK: Internals

    /// Compares elapsed time to a threshold, forgiving floating-point dust.
    private static func reached(_ elapsed: TimeInterval, _ threshold: TimeInterval) -> Bool {
        elapsed >= threshold - 1e-9
    }

    private static func base(_ state: State, _ shown: Shown) -> Step {
        let chip = state.doc.flatMap { doc in
            DocumentClassCatalog.isHealthCard(doc.id) ? nil : Chip(doc: doc, pending: false)
        }
        var state = state
        state.hold = nil
        return Step(
            shown: shown, chip: chip, mismatch: nil, capture: nil, fallback: nil, state: state)
    }

    /// The sticky document after this answer.
    private static func nextDoc(
        _ previous: ShownDoc?, confirmed: ShownDoc?, decision: ScanDecision, votes: [VoteEntry]
    ) -> ShownDoc? {
        if decision.key == .noID { return nil }
        if let confirmed {
            if let previous, previous.id == confirmed.id, previous.rank > confirmed.rank {
                return previous
            }
            return confirmed
        }
        guard let previous else { return nil }
        return ClassifierVotes.agreeing(votes, id: previous.id) >= ClassifierVotes.need
            ? previous : nil
    }

    /// The hold after this answer. It goes on while the card stays good (checking,
    /// confirmed or under the advisory mismatch, never a health card) with the same
    /// leading type; an untyped hold may turn typed. Anything else cancels it. A
    /// capture asked for with no hold running starts one.
    private static func nextHold(_ previous: Hold?, step: Step, context: Context) -> Hold? {
        let trigger = step.capture
        let leading = step.state.doc?.id
        let good =
            [.identifying, .classified, .mismatch].contains(step.shown)
            && healthVerdict(step.state.doc, health: context.health) == nil
        if let previous, good, previous.key == nil || previous.key == leading {
            if previous.key == leading { return previous }
            return Hold(key: leading, reason: trigger ?? previous.reason, since: previous.since)
        }
        guard good, let trigger else { return nil }
        return Hold(key: leading, reason: trigger, since: context.now)
    }

    private static func stepOf(
        _ previous: State, decision: ScanDecision, outcome: DetectOutcome, context: Context
    ) -> Step {
        if decision.key == .error {
            // A failed call says nothing about the card: the document stays.
            var state = previous
            state.failures += 1
            state.goodSince = nil
            var step = base(state, .error)
            if state.failures >= fallbackAfter {
                let last: String
                if case .failure(let status) = outcome, status != 0 {
                    last = "HTTP \(status)"
                } else {
                    last = "network error"
                }
                step.fallback = "classifier failed \(state.failures) times in a row (last: \(last))"
            }
            return step
        }

        let votes = context.votes
        let docID = decision.doc?.id
        let source = decision.source ?? .api
        let key: ScanDecision.Key =
            decision.key == .classified && docID == nil ? .identifying : decision.key

        guard key == .identifying || key == .classified else {
            let doc = nextDoc(previous.doc, confirmed: nil, decision: decision, votes: votes)
            // A blocked health card keeps its warning over the quality guidance
            // until it leaves the frame.
            let shown: Shown
            if key != .noID, healthVerdict(doc, health: context.health) == .blocked {
                shown = .healthCard
            } else {
                shown = key == .noID ? .noID : .quality
            }
            return base(State(failures: 0, goodSince: nil, doc: doc), shown)
        }

        let goodSince = previous.goodSince ?? context.now
        if key == .classified, let docID {
            let confirmed = ShownDoc(
                id: docID, source: source, strength: decision.strength ?? .weak)
            let doc = nextDoc(previous.doc, confirmed: confirmed, decision: decision, votes: votes)
            let state = State(failures: 0, goodSince: goodSince, doc: doc)
            switch healthVerdict(doc, health: context.health) {
            case .blocked: return base(state, .healthCard)
            case .suspected: return base(state, .identifying)
            case nil: break
            }
            if source == .api, let picked = context.picked,
                let seen = DocumentClassCatalog.group(of: docID), seen != picked
            {
                // The classifier itself named another kind of document (a vote is
                // never enough to claim this). Its type isn't taken: the card goes
                // on as untyped, under an advisory note, except for the ID card /
                // licence confusion, which says nothing.
                let mismatch =
                    DocumentClassCatalog.isIDCardLicenceMixup(docID, picked: picked)
                    ? nil : Mismatch(id: docID, group: seen)
                return untypedStep(
                    previous, decision: decision, context: context, goodSince: goodSince,
                    doc: nil, mismatch: mismatch)
            }
            var step = base(state, .classified)
            step.capture = source == .vote ? .voted : .typed
            return step
        }

        let doc = nextDoc(previous.doc, confirmed: nil, decision: decision, votes: votes)
        return untypedStep(
            previous, decision: decision, context: context, goodSince: goodSince, doc: doc,
            mismatch: nil)
    }

    /// A good card with no type to capture by: captured once it has been good for
    /// `untypedCaptureDelay` (a passport page: `passportCaptureDelay`), unless a
    /// health card holds it.
    private static func untypedStep(
        _ previous: State, decision: ScanDecision, context: Context, goodSince: TimeInterval,
        doc: ShownDoc?, mismatch: Mismatch?
    ) -> Step {
        let state = State(failures: 0, goodSince: goodSince, doc: doc)
        if let verdict = healthVerdict(doc, health: context.health) {
            // A health card still held by the vote window: no untyped capture behind its back.
            return base(state, verdict == .blocked ? .healthCard : .identifying)
        }
        var step = base(state, mismatch == nil ? .identifying : .mismatch)
        let healthHold = context.health == .strict && healthLeads(context.votes)
        let delay = context.passport ? passportCaptureDelay : untypedCaptureDelay
        let ready = !healthHold && reached(context.now - goodSince, delay)
        step.capture = ready ? (context.passport ? .passport : .untyped) : nil
        step.mismatch = mismatch
        if step.chip == nil, mismatch == nil, let id = decision.doc?.id {
            step.chip = Chip(
                doc: ShownDoc(id: id, source: decision.source ?? .api, strength: .weak),
                pending: true)
        }
        return step
    }
}

// MARK: - The confirmed type, as reported with the photo

extension ClassifierScanPolicy {
    /// The confirmed document a decision names, as sent with the photo.
    package struct Confirmed: Sendable, Equatable {
        package var id: String
        package var confidence: Double
        package var kind: DocumentClassKind?
        package var group: DocumentGroup?
        package var source: TypeSource
        package var strength: TypeStrength
        package var top3: [DetectAnswer.Candidate]
        package var votes: Int
        package var modelVersion: String?
        /// How the frames were turned before they were sent: 0 or 180.
        package var captureRotation: Int
    }

    /// The confirmed document `decision` names. The sticky `shown` document's trust
    /// wins for the same id, because that is what the user was shown.
    package static func confirmed(
        _ decision: ScanDecision, memo: ScanMemo, shown: ShownDoc?, captureRotation: Int = 0
    ) -> Confirmed? {
        guard let doc = decision.doc, let id = doc.id else { return nil }
        let same = shown?.id == id ? shown : nil
        return Confirmed(
            id: id,
            confidence: doc.confidence,
            kind: DocumentClassCatalog.kind(of: id),
            group: DocumentClassCatalog.group(of: id),
            source: same?.source ?? decision.source ?? .api,
            strength: same?.strength ?? decision.strength ?? .weak,
            top3: decision.answer?.documentType?.top3 ?? [],
            votes: ClassifierVotes.agreeing(memo.votes, id: id),
            modelVersion: decision.answer?.modelVersion,
            captureRotation: captureRotation)
    }
}
