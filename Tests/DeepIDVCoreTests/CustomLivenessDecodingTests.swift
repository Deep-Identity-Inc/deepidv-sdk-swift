import Foundation
import Testing

@testable import DeepIDVCore

struct CustomLivenessDecodingTests {
    @Test func decodeSessionWithLightScript() throws {
        let json = Data(
            """
            {"liveness_session_id":"lv-1","script":{"challengeType":"FaceMovementAndLightChallenge","durationMs":4000,
              "steps":[{"kind":"color","atMs":0,"color":"#FF0000"},{"kind":"color","atMs":1000,"color":"#00FF00"}]}}
            """.utf8)
        let s = try JSONDecoder().decode(CustomLivenessSession.self, from: json)
        #expect(s.livenessSessionID == "lv-1")
        #expect(s.script.challengeType == .faceMovementAndLight)
        #expect(s.script.durationMs == 4000)
        #expect(s.script.steps.count == 2)
        #expect(s.script.steps[0].color == "#FF0000")
        #expect(s.script.steps[1].atMs == 1000)
    }

    @Test func decodeMovementScript() throws {
        let json = Data(
            """
            {"liveness_session_id":"lv-2","script":{"challengeType":"FaceMovementChallenge","durationMs":2000,
              "steps":[{"kind":"move-closer","atMs":0}]}}
            """.utf8)
        let s = try JSONDecoder().decode(CustomLivenessSession.self, from: json)
        #expect(s.script.challengeType == .faceMovement)
        #expect(s.script.steps[0].kind == "move-closer")
        #expect(s.script.steps[0].color == nil)
    }

    @Test func decodeUploadURLs() throws {
        let json = Data(
            """
            {"frame_upload_urls":["https://s3/put/0","https://s3/put/1"],"frame_keys":["k0","k1"],
             "timeline_upload_url":"https://s3/put/t","timeline_key":"kt"}
            """.utf8)
        let u = try JSONDecoder().decode(LivenessUploadURLs.self, from: json)
        #expect(u.frameUploadURLs.count == 2)
        #expect(u.frameKeys == ["k0", "k1"])
        #expect(u.timelineKey == "kt")
    }
}
