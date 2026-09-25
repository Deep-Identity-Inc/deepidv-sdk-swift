import Foundation
import Testing

@testable import DeepIDVCore

// MARK: - Helpers

private let testKey = "sk_live_secret_abcd1234"
private let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
private let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

private func makeResponse(
    url: String, status: Int, headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: headers)!
}

private actor StatusSequencer {
    private let statuses: [Int]
    private var index = 0

    init(_ statuses: [Int]) { self.statuses = statuses }

    func next() -> Int {
        let status = statuses[Swift.min(index, statuses.count - 1)]
        index += 1
        return status
    }
}

private func sessionPresignJSON(
    _ items: [(fileKey: String, uploadType: String, uploadURL: String)]
) -> Data {
    let entries = items.map {
        #"{"file_key":"\#($0.fileKey)","upload_type":"\#($0.uploadType)","upload_url":"\#($0.uploadURL)"}"#
    }.joined(separator: ",")
    return Data(#"{"signed_urls":[\#(entries)]}"#.utf8)
}

private func makeUploader(
    handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
    maxRetries: Int = 3,
    uploadTimeout: TimeInterval = 120
) -> (uploader: SessionUploader, stub: HTTPTransportStub) {
    let config = DeepIDVConfig(
        apiKey: testKey, timeout: 30, maxRetries: maxRetries, uploadTimeout: uploadTimeout)
    let stub = HTTPTransportStub(handler: handler)
    let uploader = SessionUploader(
        config: config, transport: stub, retrySleep: noSleep, timeoutSleep: neverTimeout)
    return (uploader, stub)
}

// MARK: - Presign + PUT

@Test func sessionUploadSendsPresignShapeAndMapsKeys() async throws {
    let (uploader, stub) = makeUploader { request in
        if request.httpMethod == "POST" {
            let body = sessionPresignJSON([
                (
                    fileKey: "org/sess/front.jpg",
                    uploadType: "id_front",
                    uploadURL: "https://s3.example.com/put/front"
                ),
                (
                    fileKey: "org/sess/selfie.jpg",
                    uploadType: "selfie_front",
                    uploadURL: "https://s3.example.com/put/selfie"
                ),
            ])
            return (body, makeResponse(url: request.url!.absoluteString, status: 200))
        }
        return (Data(), makeResponse(url: request.url!.absoluteString, status: 200))
    }

    let keys = try await uploader.upload(
        sessionID: "sess-1",
        files: [
            .idFront: .data(jpegData),
            .selfieFront: .data(pngData),
        ])

    #expect(keys[.idFront] == "org/sess/front.jpg")
    #expect(keys[.selfieFront] == "org/sess/selfie.jpg")

    let requests = await stub.recorder.requests
    let presign = try #require(requests.first { $0.httpMethod == "POST" })
    #expect(presign.url?.path == "/v1/sessions/sess-1/uploads")
    #expect(presign.value(forHTTPHeaderField: "x-api-key") == testKey)

    let json =
        try JSONSerialization.jsonObject(with: try #require(presign.httpBody))
        as? [String: Any]
    let files = try #require(json?["files"] as? [[String: Any]])
    let byType = Dictionary(
        uniqueKeysWithValues: files.map { ($0["upload_type"] as! String, $0) })
    #expect(byType["id_front"]?["file_name"] as? String == "id_front.jpg")
    #expect(byType["id_front"]?["content_type"] as? String == "image/jpeg")
    #expect(byType["selfie_front"]?["file_name"] as? String == "selfie_front.png")
    #expect(byType["selfie_front"]?["content_type"] as? String == "image/png")

    let puts = requests.filter { $0.httpMethod == "PUT" }
    #expect(puts.count == 2)
    for put in puts {
        #expect(put.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(put.timeoutInterval == 120)
        #expect(put.value(forHTTPHeaderField: "Content-Type") != nil)
    }
}

@Test func sessionUpload403MapsToUploadUrlExpired() async {
    let (uploader, stub) = makeUploader { request in
        if request.httpMethod == "POST" {
            let body = sessionPresignJSON([
                (
                    fileKey: "k",
                    uploadType: "id_front",
                    uploadURL: "https://s3.example.com/put/0"
                )
            ])
            return (body, makeResponse(url: request.url!.absoluteString, status: 200))
        }
        return (Data(), makeResponse(url: request.url!.absoluteString, status: 403))
    }

    do {
        _ = try await uploader.upload(sessionID: "sess-1", files: [.idFront: .data(pngData)])
        Issue.record("expected an upload-url-expired error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .api)
        #expect(error.code == "upload_url_expired")
        #expect(error.status == 403)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let putCount = await stub.recorder.requests.filter { $0.httpMethod == "PUT" }.count
    #expect(putCount == 1)
}

@Test func sessionUpload5xxIsRetried() async throws {
    let sequencer = StatusSequencer([503, 200])
    let (uploader, stub) = makeUploader { request in
        if request.httpMethod == "POST" {
            let body = sessionPresignJSON([
                (
                    fileKey: "k",
                    uploadType: "id_front",
                    uploadURL: "https://s3.example.com/put/0"
                )
            ])
            return (body, makeResponse(url: request.url!.absoluteString, status: 200))
        }
        let status = await sequencer.next()
        return (Data(), makeResponse(url: request.url!.absoluteString, status: status))
    }

    let keys = try await uploader.upload(sessionID: "sess-1", files: [.idFront: .data(pngData)])
    #expect(keys[.idFront] == "k")

    let putCount = await stub.recorder.requests.filter { $0.httpMethod == "PUT" }.count
    #expect(putCount == 2)
}

@Test func sessionUploadTerminalSessionMapsToConflict() async {
    let body = Data(#"{"error":"Session is terminal","current_step":null}"#.utf8)
    let (uploader, _) = makeUploader { request in
        (body, makeResponse(url: request.url!.absoluteString, status: 409))
    }

    do {
        _ = try await uploader.upload(sessionID: "sess-1", files: [.idFront: .data(pngData)])
        Issue.record("expected a conflict error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .conflict)
        #expect(error.conflict?.currentStep == nil)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}
