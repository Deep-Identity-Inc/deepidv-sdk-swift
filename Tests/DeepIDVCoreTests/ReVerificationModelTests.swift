import Foundation
import Testing

@testable import DeepIDVCore

// Decoding of the §4.6 wire fixtures, including the hand-written `init(from:)`
// flattening on `ReVerificationSession` and `ReVerifyOutcome`.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func outcomeJSON(
    decision: String, failed: Int = 0, max: Int = 3, status: String = "SUCCEEDED",
    confidence: String = "91.2", extra: String = ""
) -> String {
    """
    {"decision":"\(decision)","failed_attempts":\(failed),"max_attempts":\(max),
     "liveness":{"status":"\(status)","confidence":\(confidence)}\(extra)}
    """
}

struct ReVerificationModelTests {
    // MARK: - ReVerificationSession

    @Test(arguments: [ChallengeType.faceMovement, .faceMovementAndLight])
    func sessionFlattensNestedChallengeType(challengeType: ChallengeType) throws {
        let session = try decode(
            ReVerificationSession.self,
            """
            {"re_verification_id":"rv-1","workflow_id":"wf-1","status":"PENDING",
             "expires_at":"2026-09-24T12:15:00.000Z",
             "liveness":{"challenge_type":"\(challengeType.rawValue)"}}
            """)

        #expect(
            session
                == ReVerificationSession(
                    reVerificationID: "rv-1", workflowID: "wf-1", status: "PENDING",
                    expiresAt: "2026-09-24T12:15:00.000Z", livenessChallengeType: challengeType))
    }

    @Test func sessionWithoutLivenessFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try decode(
                ReVerificationSession.self,
                """
                {"re_verification_id":"rv-1","workflow_id":"wf-1","status":"PENDING",
                 "expires_at":"2026-09-24T12:15:00.000Z"}
                """)
        }
    }

    @Test func sessionWithUnknownChallengeTypeFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try decode(
                ReVerificationSession.self,
                """
                {"re_verification_id":"rv-1","workflow_id":"wf-1","status":"PENDING",
                 "expires_at":"2026-09-24T12:15:00.000Z",
                 "liveness":{"challenge_type":"SomethingElse"}}
                """)
        }
    }

    // MARK: - liveness/start → CustomLivenessSession (reused as-is)

    @Test func startDecodesMovementScriptDirectly() throws {
        let session = try decode(
            CustomLivenessSession.self,
            """
            {"liveness_session_id":"lv-1",
             "script":{"challengeType":"FaceMovementChallenge","durationMs":4000,
                       "steps":[{"kind":"move-closer","atMs":0}]}}
            """)

        #expect(session.livenessSessionID == "lv-1")
        #expect(session.script.challengeType == .faceMovement)
        #expect(session.script.durationMs == 4000)
        #expect(session.script.steps == [ChallengeStep(kind: "move-closer", atMs: 0)])
    }

    @Test func startDecodesLightScriptWithColorSteps() throws {
        let session = try decode(
            CustomLivenessSession.self,
            """
            {"liveness_session_id":"lv-2",
             "script":{"challengeType":"FaceMovementAndLightChallenge","durationMs":4000,
                       "steps":[{"kind":"move-closer","atMs":0},
                                {"kind":"color","atMs":1500,"color":"#FF0000"},
                                {"kind":"color","atMs":2500,"color":"#00FF00"}]}}
            """)

        #expect(session.script.challengeType == .faceMovementAndLight)
        #expect(
            session.script.steps == [
                ChallengeStep(kind: "move-closer", atMs: 0),
                ChallengeStep(kind: "color", atMs: 1500, color: "#FF0000"),
                ChallengeStep(kind: "color", atMs: 2500, color: "#00FF00"),
            ])
    }

    // MARK: - liveness/upload-url → LivenessUploadURLs (reused as-is)

    @Test func uploadURLsDecodeWithoutClip() throws {
        let urls = try decode(
            LivenessUploadURLs.self,
            """
            {"frame_upload_urls":["https://s3.test/f0","https://s3.test/f1","https://s3.test/f2"],
             "frame_keys":["k/frame_0.jpg","k/frame_1.jpg","k/frame_2.jpg"],
             "timeline_upload_url":"https://s3.test/t","timeline_key":"k/timeline.json"}
            """)

        #expect(
            urls.frameUploadURLs.map(\.absoluteString) == [
                "https://s3.test/f0", "https://s3.test/f1", "https://s3.test/f2",
            ])
        #expect(urls.frameKeys.count == 3)
        #expect(urls.timelineKey == "k/timeline.json")
        #expect(urls.clipUploadURL == nil)
        #expect(urls.clipKey == nil)
    }

    @Test func uploadURLsDecodeWithClip() throws {
        let urls = try decode(
            LivenessUploadURLs.self,
            """
            {"frame_upload_urls":["https://s3.test/f0","https://s3.test/f1","https://s3.test/f2"],
             "frame_keys":["k/frame_0.jpg","k/frame_1.jpg","k/frame_2.jpg"],
             "timeline_upload_url":"https://s3.test/t","timeline_key":"k/timeline.json",
             "clip_upload_url":"https://s3.test/c","clip_key":"k/clip.mp4"}
            """)

        #expect(urls.clipUploadURL == URL(string: "https://s3.test/c"))
        #expect(urls.clipKey == "k/clip.mp4")
    }

    // MARK: - ReVerifyOutcome

    @Test func verifiedOutcomeCarriesUserAndOriginalSession() throws {
        let outcome = try decode(
            ReVerifyOutcome.self,
            outcomeJSON(
                decision: "verified", failed: 1,
                extra: #","user_id":"user-1","original_session_id":"sess-orig""#))

        #expect(
            outcome
                == ReVerifyOutcome(
                    decision: .verified, attempts: ReVerifyAttempts(failed: 1, max: 3),
                    livenessStatus: .succeeded, livenessConfidence: 91.2,
                    userID: "user-1", originalSessionID: "sess-orig"))
        #expect(outcome.attemptsRemaining == 2)
    }

    @Test(arguments: [
        ("retry", ReVerifyDecision.retry, "SUCCEEDED", FaceLivenessResult.Status.succeeded),
        ("retry_liveness", .retryLiveness, "FAILED", .failed),
        ("failed", .failed, "SUCCEEDED", .succeeded),
    ])
    func nonVerifiedOutcomeHasNoUserOrOriginalSession(
        wire: String, decision: ReVerifyDecision, wireStatus: String,
        status: FaceLivenessResult.Status
    ) throws {
        let outcome = try decode(
            ReVerifyOutcome.self, outcomeJSON(decision: wire, status: wireStatus))

        #expect(outcome.decision == decision)
        #expect(outcome.livenessStatus == status)
        #expect(outcome.userID == nil)
        #expect(outcome.originalSessionID == nil)
    }

    @Test func nullConfidenceDecodesAsNil() throws {
        let outcome = try decode(
            ReVerifyOutcome.self,
            outcomeJSON(decision: "retry_liveness", status: "FAILED", confidence: "null"))

        #expect(outcome.livenessStatus == .failed)
        #expect(outcome.livenessConfidence == nil)
    }

    @Test(arguments: zip([(0, 3), (2, 3), (3, 3), (5, 3)], [3, 1, 0, 0]))
    func attemptsRemainingClampsAtZero(counters: (failed: Int, max: Int), remaining: Int) throws {
        let outcome = try decode(
            ReVerifyOutcome.self,
            outcomeJSON(decision: "retry", failed: counters.failed, max: counters.max))

        #expect(outcome.attempts == ReVerifyAttempts(failed: counters.failed, max: counters.max))
        #expect(outcome.attemptsRemaining == remaining)
    }

    @Test func unknownDecisionFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try decode(ReVerifyOutcome.self, outcomeJSON(decision: "maybe"))
        }
    }

    @Test func missingAttemptCountersFailToDecode() {
        #expect(throws: DecodingError.self) {
            try decode(
                ReVerifyOutcome.self,
                #"{"decision":"retry","liveness":{"status":"SUCCEEDED","confidence":90}}"#)
        }
    }
}
