import Foundation
import Testing

@testable import DeepIDVCore

private func resp(_ status: Int, _ url: String = "https://api.test") -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
}

struct CustomFaceLivenessServiceTests {
    @Test func createSessionPostsStartAndDecodesScript() async throws {
        let stub = HTTPTransportStub { _ in
            (
                Data(
                    """
                    {"liveness":{"liveness_session_id":"lv-1","script":{"challengeType":"FaceMovementChallenge","durationMs":2000,"steps":[{"kind":"move-closer","atMs":0}]}}}
                    """.utf8),
                resp(200)
            )
        }
        let svc = CustomFaceLivenessService(config: DeepIDVConfig(apiKey: "k"), transport: stub)
        let session = try await svc.createSession(sessionID: "sess-1")
        #expect(session.livenessSessionID == "lv-1")
        #expect(session.script.challengeType == .faceMovement)

        let requests = await stub.recorder.requests
        #expect(requests.last?.url?.path == "/v1/sessions/sess-1/steps/face-liveness")
        #expect(requests.last?.httpMethod == "POST")
        let body = try #require(requests.last?.httpBody)
        #expect(String(data: body, encoding: .utf8)!.contains("start"))
    }

    /// A `start` answer without a challenge script is a clear validation error,
    /// not a decode failure.
    @Test func createSessionWithoutScriptIsClearValidationError() async throws {
        let stub = HTTPTransportStub { _ in
            (
                Data(
                    """
                    {"step_id":"FACE_LIVENESS","step_status":"IN_PROGRESS","liveness":{"liveness_session_id":"lv-1"}}
                    """.utf8),
                resp(200)
            )
        }
        let svc = CustomFaceLivenessService(config: DeepIDVConfig(apiKey: "k"), transport: stub)
        do {
            _ = try await svc.createSession(sessionID: "sess-1")
            Issue.record("expected a validation error")
        } catch let error as DeepIDVError {
            #expect(error.kind == .validation)
            #expect(error.message.contains("no challenge script"))
        }
    }

    @Test func fetchResultDecodesServerPassed() async throws {
        let stub = HTTPTransportStub { _ in
            (
                Data(#"{"liveness":{"status":"SUCCEEDED","confidence":90,"passed":true}}"#.utf8),
                resp(200)
            )
        }
        let svc = CustomFaceLivenessService(config: DeepIDVConfig(apiKey: "k"), transport: stub)
        let result = try await svc.fetchResult(sessionID: "sess-1")
        #expect(result.status == .succeeded)
        #expect(result.confidence == 90)
        #expect(result.passed == true)  // server-provided, not recomputed

        let requests = await stub.recorder.requests
        #expect(requests.last?.url?.path == "/v1/sessions/sess-1/steps/face-liveness")
        let body = try #require(requests.last?.httpBody)
        #expect(String(data: body, encoding: .utf8)!.contains("complete"))
    }

    @Test func fetchResultNotLiveIsSuccessWithPassedFalse() async throws {
        let stub = HTTPTransportStub { _ in
            (
                Data(#"{"liveness":{"status":"FAILED","confidence":10,"passed":false}}"#.utf8),
                resp(200)
            )
        }
        let svc = CustomFaceLivenessService(config: DeepIDVConfig(apiKey: "k"), transport: stub)
        let result = try await svc.fetchResult(sessionID: "sess-1")
        #expect(result.passed == false)  // still a success, not an error
    }

    @Test func requestUploadURLsPostsFrameCount() async throws {
        let stub = HTTPTransportStub { _ in
            (
                Data(
                    """
                    {"liveness":{"frame_upload_urls":["https://s3/0"],"frame_keys":["k0"],"timeline_upload_url":"https://s3/t","timeline_key":"kt"}}
                    """.utf8),
                resp(200)
            )
        }
        let svc = CustomFaceLivenessService(config: DeepIDVConfig(apiKey: "k"), transport: stub)
        let urls = try await svc.requestUploadURLs(sessionID: "sess-1", frameCount: 4)
        #expect(urls.frameKeys == ["k0"])

        let requests = await stub.recorder.requests
        #expect(requests.last?.url?.path == "/v1/sessions/sess-1/steps/face-liveness")
        let body = try #require(requests.last?.httpBody)
        #expect(String(data: body, encoding: .utf8)!.contains("\"frame_count\""))
        #expect(String(data: body, encoding: .utf8)!.contains("upload-url"))
    }
}
