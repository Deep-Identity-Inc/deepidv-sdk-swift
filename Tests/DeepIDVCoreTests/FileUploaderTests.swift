import Foundation
import Testing

@testable import DeepIDVCore

// MARK: - Test helpers

/// Minimal valid magic-byte samples for the two supported formats.
private let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
private let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

private let testKey = "sk_live_secret_abcd1234"

/// No-op backoff sleeper so retry tests never touch the wall clock.
private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

/// A "never fires" timeout sleeper: the transport always wins the race first, so
/// the group cancels this immediately — no real waiting happens.
private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

/// Builds an `HTTPURLResponse` for canned stub replies.
private func makeResponse(
    url: String = "https://s3.example.com/object", status: Int, headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

/// Encodes a presign response body from `(uploadUrl, fileKey)` pairs.
private func presignJSON(_ uploads: [(uploadUrl: String, fileKey: String)]) -> Data {
    let items =
        uploads
        .map { #"{"uploadUrl":"\#($0.uploadUrl)","fileKey":"\#($0.fileKey)"}"# }
        .joined(separator: ",")
    return Data(#"{"uploads":[\#(items)]}"#.utf8)
}

/// Plays back a fixed sequence of statuses across S3 PUT attempts, repeating the
/// last once exhausted — used to model "503 then 200".
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

/// Wires a `FileUploader` to two separate stubs — one for the presign POST (the
/// `APIClient` transport) and one for the S3 PUTs (the uploader's raw transport)
/// — so PUT assertions aren't polluted by the presign request. Returns both stubs
/// for inspection.
private func makeUploader(
    presign: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
    s3: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
    maxRetries: Int = 3,
    uploadTimeout: TimeInterval = 120,
    timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = neverTimeout
) -> (uploader: FileUploader, presignStub: HTTPTransportStub, s3Stub: HTTPTransportStub) {
    let config = DeepIDVConfig(
        apiKey: testKey, timeout: 30, maxRetries: maxRetries, uploadTimeout: uploadTimeout)
    let presignStub = HTTPTransportStub(handler: presign)
    let s3Stub = HTTPTransportStub(handler: s3)
    let client = APIClient(
        config: config, transport: presignStub, retrySleep: noSleep, timeoutSleep: neverTimeout)
    let uploader = FileUploader(
        config: config, client: client, transport: s3Stub, retrySleep: noSleep,
        timeoutSleep: timeoutSleep)
    return (uploader, presignStub, s3Stub)
}

/// A presign handler returning `count` uploads with predictable url/key pairs.
private func presignHandler(
    count: Int
) -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
    let uploads = (0..<count).map {
        (uploadUrl: "https://s3.example.com/put/\($0)", fileKey: "key\($0)")
    }
    let body = presignJSON(uploads)
    return { _ in (body, makeResponse(url: "https://api.deepidv.com/v1/upload/presign", status: 200)) }
}

/// An S3 handler that always replies `200 OK`.
private let s3OK: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
    (Data(), makeResponse(url: request.url!.absoluteString, status: 200))
}

// MARK: - Input normalization

@Test func testNormalizesDataInput() async throws {
    let (uploader, _, s3Stub) = makeUploader(presign: presignHandler(count: 1), s3: s3OK)
    let keys = try await uploader.upload([.data(pngData)])
    #expect(keys == ["key0"])
    let count = await s3Stub.recorder.requests.count
    #expect(count == 1)
}

@Test func testNormalizesFileURLInput() async throws {
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("deepidv-test-\(UUID().uuidString).png")
    try pngData.write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let (uploader, _, _) = makeUploader(presign: presignHandler(count: 1), s3: s3OK)
    let keys = try await uploader.upload([.fileURL(tempURL)])
    #expect(keys == ["key0"])
}

@Test func testNormalizesRawBase64Input() async throws {
    let (uploader, _, _) = makeUploader(presign: presignHandler(count: 1), s3: s3OK)
    let keys = try await uploader.upload([.base64(pngData.base64EncodedString())])
    #expect(keys == ["key0"])
}

@Test func testNormalizesDataURLBase64Input() async throws {
    let dataURL = "data:image/png;base64,\(pngData.base64EncodedString())"
    let (uploader, _, _) = makeUploader(presign: presignHandler(count: 1), s3: s3OK)
    let keys = try await uploader.upload([.base64(dataURL)])
    #expect(keys == ["key0"])
}

@Test func testInvalidBase64ThrowsValidationBeforeNetwork() async {
    let (uploader, presignStub, _) = makeUploader(presign: presignHandler(count: 1), s3: s3OK)
    do {
        _ = try await uploader.upload([.base64("not-valid-base64!!!")])
        Issue.record("expected a validation error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
    // The bad input must fail before any presign request is made.
    let count = await presignStub.recorder.requests.count
    #expect(count == 0)
}

// MARK: - Magic-byte detection

@Test func testDetectsJPEG() throws {
    #expect(try detectContentType(jpegData) == "image/jpeg")
}

@Test func testDetectsPNG() throws {
    #expect(try detectContentType(pngData) == "image/png")
}

@Test func testTooShortThrowsValidation() {
    #expect(throws: DeepIDVError.self) {
        try detectContentType(Data([0xFF, 0xD8]))
    }
}

@Test func testUnsupportedFormatThrowsValidation() {
    #expect(throws: DeepIDVError.self) {
        try detectContentType(Data([0x00, 0x01, 0x02, 0x03]))
    }
}

@Test func testContentTypeOverrideSkipsDetection() async throws {
    // Bytes that would fail detection; the explicit override makes upload succeed.
    let nonImage = Data([0x00, 0x01, 0x02, 0x03])
    let (uploader, presignStub, s3Stub) = makeUploader(presign: presignHandler(count: 1), s3: s3OK)

    let keys = try await uploader.upload([.data(nonImage)], contentType: "image/png")
    #expect(keys == ["key0"])

    // The override flows into both the presign body and the PUT's Content-Type.
    let presignBody = try #require(await presignStub.recorder.requests.first?.httpBody)
    let json = try JSONSerialization.jsonObject(with: presignBody) as? [String: Any]
    let files = json?["files"] as? [[String: Any]]
    #expect(files?.first?["contentType"] as? String == "image/png")
    #expect(files?.first?["byteLength"] as? Int == 4)

    let s3Request = try #require(await s3Stub.recorder.requests.first)
    #expect(s3Request.value(forHTTPHeaderField: "Content-Type") == "image/png")
}

// MARK: - Batch ordering

@Test func testOrderPreservedAcrossBatch() async throws {
    let (uploader, _, s3Stub) = makeUploader(presign: presignHandler(count: 3), s3: s3OK)

    let keys = try await uploader.upload([.data(pngData), .data(jpegData), .data(pngData)])
    #expect(keys == ["key0", "key1", "key2"])  // fileKeys returned in input order

    // Each presigned URL was PUT exactly once (parallel → order-agnostic, so compare sets).
    let urls = await Set(s3Stub.recorder.requests.compactMap { $0.url?.absoluteString })
    #expect(
        urls == [
            "https://s3.example.com/put/0",
            "https://s3.example.com/put/1",
            "https://s3.example.com/put/2",
        ])
}

// MARK: - S3 transport rules

@Test func testS3PutCarriesNoApiKeyAndSetsContentType() async throws {
    let (uploader, presignStub, s3Stub) = makeUploader(presign: presignHandler(count: 1), s3: s3OK)

    _ = try await uploader.upload([.data(jpegData)])

    // S3 must never receive the api key (UPL-07); the presign call still does.
    let s3Request = try #require(await s3Stub.recorder.requests.first)
    #expect(s3Request.httpMethod == "PUT")
    #expect(s3Request.value(forHTTPHeaderField: "x-api-key") == nil)
    #expect(s3Request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")

    let presignRequest = try #require(await presignStub.recorder.requests.first)
    #expect(presignRequest.value(forHTTPHeaderField: "x-api-key") == testKey)
}

@Test func testUploadUsesUploadTimeoutNotApiTimeout() async throws {
    // Config: API timeout 30s, upload timeout 120s. The PUT must use 120s.
    let (uploader, _, s3Stub) = makeUploader(presign: presignHandler(count: 1), s3: s3OK)

    _ = try await uploader.upload([.data(pngData)])

    let s3Request = try #require(await s3Stub.recorder.requests.first)
    #expect(s3Request.timeoutInterval == 120)
}

// MARK: - S3 status handling

@Test func test403MapsToUploadUrlExpiredNonRetryable() async {
    let s3403: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        (Data(), makeResponse(url: request.url!.absoluteString, status: 403))
    }
    let (uploader, _, s3Stub) = makeUploader(presign: presignHandler(count: 1), s3: s3403)

    do {
        _ = try await uploader.upload([.data(pngData)])
        Issue.record("expected an upload-url-expired error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .api)
        #expect(error.code == "upload_url_expired")
        #expect(error.status == 403)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let count = await s3Stub.recorder.requests.count
    #expect(count == 1)  // 403 is non-retryable → single PUT attempt
}

@Test func test5xxIsRetriedThenSucceeds() async throws {
    let sequencer = StatusSequencer([503, 200])
    let s3: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        let status = await sequencer.next()
        return (Data(), makeResponse(url: request.url!.absoluteString, status: status))
    }
    let (uploader, _, s3Stub) = makeUploader(presign: presignHandler(count: 1), s3: s3, maxRetries: 3)

    let keys = try await uploader.upload([.data(pngData)])
    #expect(keys == ["key0"])

    let count = await s3Stub.recorder.requests.count
    #expect(count == 2)  // 503 retried, then 200
}

@Test func testOther4xxNotRetried() async {
    let s3400: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        (Data(), makeResponse(url: request.url!.absoluteString, status: 400))
    }
    let (uploader, _, s3Stub) = makeUploader(presign: presignHandler(count: 1), s3: s3400)

    do {
        _ = try await uploader.upload([.data(pngData)])
        Issue.record("expected an upload error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .api)
        #expect(error.code == "upload_error")
        #expect(error.status == 400)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let count = await s3Stub.recorder.requests.count
    #expect(count == 1)  // other 4xx is non-retryable
}

// MARK: - Presign contract guard

@Test func testPresignReturningMoreUploadsThanFilesThrows() async {
    // One file requested, but presign returns two uploads — a contract violation.
    let (uploader, _, _) = makeUploader(presign: presignHandler(count: 2), s3: s3OK)

    do {
        _ = try await uploader.upload([.data(pngData)])
        Issue.record("expected an api error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .api)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}
