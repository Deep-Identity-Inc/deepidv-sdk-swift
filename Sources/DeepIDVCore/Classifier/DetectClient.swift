import Foundation

// DeepIDVCore › Classifier

/// Sends one frame to the session's document classifier.
///
/// The frame goes to the API host the SDK already uses, under the session, with
/// the same `x-api-key` as every other session call. A host that proxies the
/// SDK only has to allow this one extra route.
///
/// It never retries: the sampler paces calls and backs off on its own
/// (`DetectPacing`). A failure comes back as a value, not a throw, so a broken
/// classifier can never break capture. The only throw is cancellation.
struct DetectClient: Sendable {
    /// Per-call timeout. A late answer is worth little, since the card has moved
    /// on, and the scan falls back to on-device checks without it.
    static let timeout: TimeInterval = 8

    private let client: APIClient
    private let sessionID: String

    init(client: APIClient, sessionID: String) {
        self.client = client
        self.sessionID = sessionID
    }

    var path: String { "/v1/sessions/\(sessionID)/id-capture/detect" }

    /// Posts one frame. Throws only `CancellationError`.
    func detect(_ request: DetectRequest) async throws -> DetectResponse {
        do {
            let answer: DetectAnswer = try await client.post(
                path, body: request, options: RequestOptions(timeout: Self.timeout, maxRetries: 0))
            return .answer(answer)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DeepIDVError {
            if error.kind == .cancelled { throw CancellationError() }
            return .failure(DetectFailure(error))
        } catch {
            return .failure(DetectFailure(status: 0, reason: .failed))
        }
    }
}

/// One frame for the classifier.
struct DetectRequest: Sendable, Equatable, Encodable {
    /// The JPEG, base64-encoded, with no `data:` prefix.
    var imageB64: String
    /// Joins a capture's frames in the classifier's logs (`ScanID`).
    var scanID: String
    /// The frame's number in the scan; absent on an upside-down probe, which is no
    /// frame of the scan.
    var frame: Int?
    /// The document group the user picked, when there is one.
    var method: String?

    enum CodingKeys: String, CodingKey {
        case imageB64 = "image_b64"
        case scanID = "scan_id"
        case frame
        case method
    }
}

/// Why a classifier call failed, and what the scan should do about it.
struct DetectFailure: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// The classifier isn't available for this session (not enabled, unknown
        /// or finished session, bad key). Switch it off for the session, silently.
        case unavailable
        /// Too many calls or the classifier is busy: back off.
        case rateLimited(retryAfter: TimeInterval?)
        /// Anything else, including network errors and timeouts. Counts toward
        /// fail-over.
        case failed
    }

    /// The HTTP status, or `0` for a network error or timeout.
    var status: Int
    var reason: Reason

    init(status: Int, reason: Reason) {
        self.status = status
        self.reason = reason
    }

    init(_ error: DeepIDVError) {
        let status = error.status ?? 0
        let reason: Reason
        switch error.kind {
        case .authentication, .authorization, .notFound, .conflict:
            reason = .unavailable
        case .rateLimit:
            reason = .rateLimited(retryAfter: error.retryAfter)
        default:
            reason = .failed
        }
        self.init(status: status, reason: reason)
    }
}

/// What came back for one frame.
enum DetectResponse: Sendable, Equatable {
    case answer(DetectAnswer)
    case failure(DetectFailure)

    /// The form the scan rules read.
    var outcome: DetectOutcome {
        switch self {
        case .answer(let answer): return .answer(answer)
        case .failure(let failure): return .failure(status: failure.status)
        }
    }
}

// MARK: - Pacing

/// How long to wait before the next classifier call. Calls go one at a time, at
/// least `minimumInterval` apart from start to start, with extra backoff after
/// some failures. Pure, so the schedule is testable.
struct DetectPacing: Sendable, Equatable {
    /// At most one call this often.
    static let minimumInterval: TimeInterval = 0.5
    /// After a rate limit the backoff doubles from this…
    static let rateLimitInitial: TimeInterval = 1
    /// …up to this.
    static let rateLimitMax: TimeInterval = 4
    /// After a network error, timeout or unavailable gateway.
    static let retryWait: TimeInterval = 2

    /// The current backoff, in seconds.
    private(set) var backoff: TimeInterval = 0

    init() {}

    /// Records how the last call ended.
    mutating func record(_ response: DetectResponse) {
        guard case .failure(let failure) = response else {
            backoff = 0
            return
        }
        switch failure.reason {
        case .rateLimited(let retryAfter):
            let doubled = min(Self.rateLimitMax, max(Self.rateLimitInitial, backoff * 2))
            backoff = max(doubled, min(retryAfter ?? 0, Self.rateLimitMax))
        case .unavailable, .failed:
            backoff = [0, 502, 503, 504].contains(failure.status) ? Self.retryWait : 0
        }
    }

    /// How long to wait before the next call, given how long the last one took.
    func wait(afterCallTaking elapsed: TimeInterval) -> TimeInterval {
        max(Self.minimumInterval - elapsed, backoff, 0)
    }
}

// MARK: - Scan id

/// The tag sent with every frame of one camera run: the session id plus 6 random
/// base36 characters, so a scan's frames can be told apart and found by session.
/// Only letters, digits and hyphens are kept, and it is 8 to 64 characters long.
enum ScanID {
    static let randomLength = 6
    static let maxLength = 64

    static func make(sessionID: String, random: String = randomBase36()) -> String {
        let allowed = sessionID.unicodeScalars.filter {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-"
        }
        let session = String(String.UnicodeScalarView(allowed)).prefix(
            maxLength - random.count - 1)
        return "\(session.isEmpty ? "scan" : String(session))-\(random)"
    }

    static func randomBase36(_ count: Int = randomLength) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<count).map { _ in digits.randomElement()! })
    }

    /// Whether a tag is one the classifier keeps.
    static func isValid(_ id: String) -> Bool {
        (8...maxLength).contains(id.count)
            && id.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                    || $0 == "-"
            }
    }
}

extension DocumentGroup {
    /// The group's name on the wire, as the classifier logs it.
    var wireValue: String {
        switch self {
        case .driversLicence: return "dl"
        case .passport: return "passport"
        case .national: return "national"
        case .permanentResident: return "pr"
        case .military: return "military"
        case .firearm: return "firearm"
        }
    }
}
