import Foundation
import Testing

@testable import DeepIDVCore

// The iGaming service: three thin POSTs on `APIClient`. Tests drive the
// request shape (path, snake_case body, raw base64 with no data-URI prefix)
// and the response decode through the transport stub — no live API.

private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }
private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

private func makeResponse(url: String, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

private func makeService(
    handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
) -> (service: IGamingService, stub: HTTPTransportStub) {
    let config = DeepIDVConfig(apiKey: "sk_test", timeout: 30, maxRetries: 0)
    let stub = HTTPTransportStub(handler: handler)
    let service = IGamingService(
        config: config, transport: stub, retrySleep: noSleep, timeoutSleep: neverTimeout)
    return (service, stub)
}

private let uniqueBody = Data(#"{"verdict":"UNIQUE","action":"allow"}"#.utf8)
private let clearBody = Data(#"{"verdict":"CLEAR","action":"allow","evidence":{}}"#.utf8)
private let imageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])

private func bodyJSON(of request: URLRequest?) throws -> [String: Any] {
    let data = try #require(request?.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - checkAntiCheat

@Test func antiCheatPostsBase64ImageWithSnakeCaseFields() async throws {
    let (service, stub) = makeService { request in
        (uniqueBody, makeResponse(url: request.url!.absoluteString, status: 200))
    }

    let result = try await service.checkAntiCheat(
        sessionID: "sess-1", image: .data(imageBytes), deviceFingerprint: "fp-9")

    #expect(result.verdict == .unique)
    #expect(result.action == .allow)

    let requests = await stub.recorder.requests
    #expect(requests.count == 1)
    #expect(requests.first?.url?.path == "/v1/igaming/anti-cheat")
    #expect(requests.first?.httpMethod == "POST")

    let body = try bodyJSON(of: requests.first)
    #expect(body["session_id"] as? String == "sess-1")
    #expect(body["device_fingerprint"] as? String == "fp-9")
    // Raw base64 of the bytes — no `data:image/...;base64,` prefix.
    #expect(body["image"] as? String == imageBytes.base64EncodedString())
}

@Test func antiCheatOmitsNilDeviceFingerprint() async throws {
    let (service, stub) = makeService { request in
        (uniqueBody, makeResponse(url: request.url!.absoluteString, status: 200))
    }

    _ = try await service.checkAntiCheat(sessionID: "sess-1", image: .data(imageBytes))

    let body = try bodyJSON(of: await stub.recorder.requests.first)
    #expect(body["device_fingerprint"] == nil)
}

@Test func antiCheatRejectsOversizedImageBeforeAnyNetworkIO() async throws {
    let (service, stub) = makeService { request in
        (uniqueBody, makeResponse(url: request.url!.absoluteString, status: 200))
    }
    // ~4.5 MB of raw bytes → ~6 MB base64, over the 5 MB JSON body cap.
    let oversized = Data(count: 4_500_000)

    await #expect(throws: DeepIDVError.self) {
        try await service.checkAntiCheat(sessionID: "sess-1", image: .data(oversized))
    }
    do {
        _ = try await service.checkAntiCheat(sessionID: "sess-1", image: .data(oversized))
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    }
    #expect(await stub.recorder.requests.isEmpty)
}

@Test func antiCheatMapsSessionNotFoundTo404NotFound() async throws {
    let (service, _) = makeService { request in
        (
            Data(#"{"error":"Session not found"}"#.utf8),
            makeResponse(url: request.url!.absoluteString, status: 404)
        )
    }

    do {
        _ = try await service.checkAntiCheat(sessionID: "missing", image: .data(imageBytes))
        Issue.record("expected .notFound")
    } catch let error as DeepIDVError {
        #expect(error.kind == .notFound)
        #expect(error.message == "Session not found")
    }
}

@Test func antiCheatDecodesFailSoftUnavailableAsSuccess() async throws {
    let (service, _) = makeService { request in
        (
            Data(#"{"verdict":"UNAVAILABLE","action":"allow"}"#.utf8),
            makeResponse(url: request.url!.absoluteString, status: 200)
        )
    }

    let result = try await service.checkAntiCheat(sessionID: "sess-1", image: .data(imageBytes))
    #expect(result.verdict == .unavailable)
    #expect(!result.isBlocked)
}

// MARK: - IP checks

@Test func vpnCheckPostsSessionAndIPToVPNDetection() async throws {
    let (service, stub) = makeService { request in
        (clearBody, makeResponse(url: request.url!.absoluteString, status: 200))
    }

    let result = try await service.checkVPN(sessionID: "sess-1", ipAddress: "203.0.113.7")

    #expect(result.verdict == .clear)
    let requests = await stub.recorder.requests
    #expect(requests.first?.url?.path == "/v1/igaming/vpn-detection")
    let body = try bodyJSON(of: requests.first)
    #expect(body["session_id"] as? String == "sess-1")
    #expect(body["ip_address"] as? String == "203.0.113.7")
}

@Test func jurisdictionCheckPostsToIPJurisdiction() async throws {
    let (service, stub) = makeService { request in
        (
            Data(
                #"{"verdict":"HIT","action":"block","evidence":{"country":"US","state":"UT"}}"#
                    .utf8),
            makeResponse(url: request.url!.absoluteString, status: 200)
        )
    }

    let result = try await service.checkIPJurisdiction(
        sessionID: "sess-1", ipAddress: "203.0.113.7")

    #expect(result.verdict == .hit)
    #expect(result.action == "block")
    #expect(result.evidence == ["country": "US", "state": "UT"])
    #expect(await stub.recorder.requests.first?.url?.path == "/v1/igaming/ip-jurisdiction")
}

@Test func antiCheatBodyNeverEscapesBase64Slashes() async throws {
    // `0xFF 0xFF 0xFF` encodes to "////" — four slash characters. Foundation's
    // default JSONEncoder escapes "/" as "\/", inflating a near-cap base64
    // payload by ~1.6% and blowing the server's 5 MB body-parser limit even
    // though the client-side cap passed (regression: server 413 on images in
    // the passthrough band just under the cap).
    let (service, stub) = makeService { request in
        (uniqueBody, makeResponse(url: request.url!.absoluteString, status: 200))
    }

    _ = try await service.checkAntiCheat(
        sessionID: "sess-1", image: .data(Data([0xFF, 0xFF, 0xFF])))

    let body = try #require(await stub.recorder.requests.first?.httpBody)
    let text = try #require(String(data: body, encoding: .utf8))
    #expect(text.contains("////"))
    #expect(!text.contains("\\/"))
}
